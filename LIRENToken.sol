// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev PancakeSwap V2 pair-only LIREN token (no V3 / NPM helper).
contract LIRENToken is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant WHALE_THRESHOLD = 670_000_000 * 10 ** 18;
    uint256 public constant PRICE_PRECISION = 1e18;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    struct VestingSchedule {
        uint256 fixedAmount;
        uint256 linearAmount;
        uint256 fixedLockEndTime;
        uint256 linearDuration;
    }

    struct ArtworkInfo {
        string vaultFilesIpfsCID;
        string originalIpfsCID;
        string artworkName;
        string artist;
        string description;
    }

    struct Incident {
        address whale;
        uint256 whaleBalance;
        uint256 lockPrice;
        uint256 requiredQuote;
        uint256 totalDeposited;
    }

    bool public frozen;
    bool public frozenPermanent;
    bool public whaleCheckEnabled;
    address public lastWhale;

    IERC20 public immutable quoteToken;

    uint256 public incidentId;

    mapping(address => bool) private _pairsEnabled;
    address[] private _pairs;
    mapping(address => uint256) private _lpSupplyCheckpoint;

    mapping(address => VestingSchedule[]) private _vestingSchedules;
    mapping(uint256 => Incident) public incidents;
    mapping(uint256 => mapping(address => uint256)) public claimedArt;

    ArtworkInfo private _artworkInfo;

    event FrozenTriggered(address indexed account, uint256 balance);
    event WhaleCheckEnabled(address indexed admin);
    event PairUpdated(address indexed pair, bool enabled);
    event LockScheduleCreated(
        address indexed beneficiary,
        uint256 indexed scheduleId,
        uint256 fixedLockAmount,
        uint256 linearAmount,
        uint256 fixedLockEndTime
    );
    event IncidentOpened(uint256 indexed incidentId, address indexed whale, uint256 whaleBalance);
    event LockPriceSet(uint256 indexed incidentId, uint256 lockPrice, uint256 requiredQuote);
    event QuoteDeposited(uint256 indexed incidentId, address indexed whale, uint256 amount);
    event QuoteClaimed(
        uint256 indexed incidentId,
        address indexed claimant,
        uint256 artAmount,
        uint256 quoteAmount
    );

    error TransferFrozen();
    error InvalidBeneficiary();
    error ZeroTransferAmount();
    error LinearDurationRequired();
    error InvalidSchedule();
    error TransferExceedsUnlocked();
    error InvalidIncident();
    error PriceAlreadySet();
    error PriceNotSet();
    error NotWhale();
    error NotClaimable();
    error InsufficientVaultBalance();
    error InsufficientWhaleDeposit();
    error FrozenConfigLocked();
    error DepositExceedsRequired();
    error InvalidQuoteToken();

    constructor(
        string memory vaultFilesIpfsCID_,
        string memory originalIpfsCID_,
        string memory artworkName_,
        string memory artist_,
        string memory description_,
        address initialOwner_,
        IERC20 quoteToken_
    ) ERC20("LI REN XING TOKEN", "LIREN") Ownable(initialOwner_) {
        _artworkInfo = ArtworkInfo({
            vaultFilesIpfsCID: vaultFilesIpfsCID_,
            originalIpfsCID: originalIpfsCID_,
            artworkName: artworkName_,
            artist: artist_,
            description: description_
        });
        if (address(quoteToken_) == address(0)) revert InvalidQuoteToken();
        quoteToken = quoteToken_;
        _mint(initialOwner_, TOTAL_SUPPLY);
        whaleCheckEnabled = true;
    }

    function getArtworkInfo()
        external
        view
        returns (
            string memory vaultFilesIpfsCID,
            string memory originalIpfsCID,
            string memory artworkName,
            string memory artist,
            string memory description
        )
    {
        ArtworkInfo storage info = _artworkInfo;
        return (
            info.vaultFilesIpfsCID,
            info.originalIpfsCID,
            info.artworkName,
            info.artist,
            info.description
        );
    }

    function setPair(address pair, bool enabled) external onlyOwner {
        if (frozenPermanent) revert FrozenConfigLocked();

        bool wasEnabled = _pairsEnabled[pair];

        if (enabled) {
            _pairsEnabled[pair] = true;

            if (!wasEnabled) {
                _pairs.push(pair);
            }
            _syncV2LpCheckpoint(pair);
        } else {
            _pairsEnabled[pair] = false;
        }

        emit PairUpdated(pair, enabled);
    }

    function isPair(address pair) public view returns (bool) {
        return _pairsEnabled[pair];
    }

    function lpSupplyCheckpoint(address pair) external view returns (uint256) {
        return _lpSupplyCheckpoint[pair];
    }

    function areSwapsBlocked() external view returns (bool) {
        return frozen;
    }

    function pairsCount() external view returns (uint256) {
        return _pairs.length;
    }

    function pairAt(uint256 index) external view returns (address) {
        return _pairs[index];
    }

    function enableWhaleCheck() external onlyOwner {
        if (frozenPermanent) revert FrozenConfigLocked();
        whaleCheckEnabled = true;
        emit WhaleCheckEnabled(msg.sender);
    }

    function setLockPrice(uint256 incidentId_, uint256 lockPrice_) external onlyOwner {
        Incident storage incident = incidents[incidentId_];
        if (incident.whale == address(0)) revert InvalidIncident();
        if (incident.lockPrice != 0) revert PriceAlreadySet();
        if (lockPrice_ == 0) revert PriceNotSet();

        uint256 nonWhaleArt = TOTAL_SUPPLY - incident.whaleBalance;
        uint256 required = (lockPrice_ * nonWhaleArt) / PRICE_PRECISION;

        incident.lockPrice = lockPrice_;
        incident.requiredQuote = required;

        emit LockPriceSet(incidentId_, lockPrice_, required);
    }

    function depositQuote(uint256 incidentId_, uint256 amount) external nonReentrant {
        Incident storage incident = incidents[incidentId_];
        if (incident.whale == address(0)) revert InvalidIncident();
        if (msg.sender != incident.whale) revert NotWhale();
        if (incident.lockPrice == 0) revert PriceNotSet();
        if (amount == 0) revert NotClaimable();

        uint256 beforeBalance = quoteToken.balanceOf(address(this));
        quoteToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = quoteToken.balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert NotClaimable();
        if (incident.totalDeposited + received > incident.requiredQuote) {
            revert DepositExceedsRequired();
        }

        incident.totalDeposited += received;

        emit QuoteDeposited(incidentId_, msg.sender, received);
    }

    function depositQuoteFull(uint256 incidentId_) external nonReentrant {
        Incident storage incident = incidents[incidentId_];
        if (incident.whale == address(0)) revert InvalidIncident();
        if (msg.sender != incident.whale) revert NotWhale();
        if (incident.lockPrice == 0) revert PriceNotSet();

        uint256 remaining = incident.requiredQuote - incident.totalDeposited;
        if (remaining == 0) revert NotClaimable();

        uint256 beforeBalance = quoteToken.balanceOf(address(this));
        quoteToken.safeTransferFrom(msg.sender, address(this), remaining);
        uint256 received = quoteToken.balanceOf(address(this)) - beforeBalance;
        if (received == 0) revert NotClaimable();
        if (incident.totalDeposited + received > incident.requiredQuote) {
            revert DepositExceedsRequired();
        }

        incident.totalDeposited += received;

        emit QuoteDeposited(incidentId_, msg.sender, received);
    }

    function claim(uint256 incidentId_, uint256 artAmount) external nonReentrant {
        Incident storage incident = incidents[incidentId_];
        if (incident.whale == address(0)) revert InvalidIncident();
        if (incident.lockPrice == 0) revert PriceNotSet();
        if (incident.totalDeposited < incident.requiredQuote) revert InsufficientWhaleDeposit();
        if (!_canClaim(msg.sender, incident.whale)) revert NotClaimable();
        if (artAmount == 0) revert NotClaimable();
        if (artAmount > unlockedBalance(msg.sender)) revert TransferExceedsUnlocked();

        uint256 quoteOut = (artAmount * incident.lockPrice) / PRICE_PRECISION;
        if (quoteToken.balanceOf(address(this)) < quoteOut) revert InsufficientVaultBalance();

        _transfer(msg.sender, BURN_ADDRESS, artAmount);
        claimedArt[incidentId_][msg.sender] += artAmount;
        quoteToken.safeTransfer(msg.sender, quoteOut);

        emit QuoteClaimed(incidentId_, msg.sender, artAmount, quoteOut);
    }

    function requiredQuote(uint256 incidentId_) external view returns (uint256) {
        return incidents[incidentId_].requiredQuote;
    }

    function claimable(address user, uint256 incidentId_) external view returns (uint256) {
        Incident storage incident = incidents[incidentId_];
        if (
            incident.lockPrice == 0 || incident.totalDeposited < incident.requiredQuote
                || !_canClaim(user, incident.whale)
        ) {
            return 0;
        }

        uint256 maxArt = unlockedBalance(user);
        if (maxArt == 0) {
            return 0;
        }

        uint256 quoteOut = (maxArt * incident.lockPrice) / PRICE_PRECISION;
        uint256 vaultBalance = quoteToken.balanceOf(address(this));
        return quoteOut > vaultBalance ? vaultBalance : quoteOut;
    }

    function vestingScheduleCount(address beneficiary) external view returns (uint256) {
        return _vestingSchedules[beneficiary].length;
    }

    function getVestingSchedule(
        address beneficiary,
        uint256 scheduleId
    )
        external
        view
        returns (
            uint256 fixedAmount,
            uint256 linearAmount,
            uint256 fixedLockEndTime,
            uint256 linearDuration,
            uint256 vested
        )
    {
        if (scheduleId >= _vestingSchedules[beneficiary].length) revert InvalidSchedule();
        VestingSchedule storage schedule = _vestingSchedules[beneficiary][scheduleId];
        if (schedule.fixedAmount + schedule.linearAmount == 0) revert InvalidSchedule();
        return (
            schedule.fixedAmount,
            schedule.linearAmount,
            schedule.fixedLockEndTime,
            schedule.linearDuration,
            _vestedAmount(schedule)
        );
    }

    function unlockedBalance(address account) public view returns (uint256) {
        uint256 balance = balanceOf(account);
        uint256 locked = _lockedBalance(account);
        return balance > locked ? balance - locked : 0;
    }

    function adminTransferWithLock(
        address beneficiary,
        uint256 fixedLockAmount,
        uint256 linearAmount,
        uint256 fixedLockEndTime,
        uint256 linearDuration
    ) external onlyOwner {
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (fixedLockAmount + linearAmount == 0) revert ZeroTransferAmount();
        if (linearAmount > 0 && linearDuration == 0) revert LinearDurationRequired();

        uint256 totalAmount = fixedLockAmount + linearAmount;
        _vestingSchedules[beneficiary].push(
            VestingSchedule({
                fixedAmount: fixedLockAmount,
                linearAmount: linearAmount,
                fixedLockEndTime: fixedLockEndTime,
                linearDuration: linearDuration
            })
        );
        _transfer(msg.sender, beneficiary, totalAmount);
        emit LockScheduleCreated(
            beneficiary,
            _vestingSchedules[beneficiary].length - 1,
            fixedLockAmount,
            linearAmount,
            fixedLockEndTime
        );
    }

    function _vestedAmount(
        VestingSchedule storage schedule
    ) private view returns (uint256) {
        if (block.timestamp < schedule.fixedLockEndTime) {
            return 0;
        }

        uint256 vested = schedule.fixedAmount;

        if (schedule.linearAmount > 0) {
            uint256 elapsed = block.timestamp - schedule.fixedLockEndTime;
            if (elapsed > schedule.linearDuration) {
                elapsed = schedule.linearDuration;
            }
            vested += (schedule.linearAmount * elapsed) / schedule.linearDuration;
        }

        return vested;
    }

    function _lockedBalance(address account) private view returns (uint256) {
        VestingSchedule[] storage schedules = _vestingSchedules[account];
        uint256 length = schedules.length;
        uint256 locked = 0;

        for (uint256 i = 0; i < length; i++) {
            VestingSchedule storage schedule = schedules[i];
            uint256 total = schedule.fixedAmount + schedule.linearAmount;
            uint256 vested = _vestedAmount(schedule);
            locked += total - vested;
        }

        return locked;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (frozen) {
            if (!_isAllowedFrozenTransfer(from, to)) {
                revert TransferFrozen();
            }
        }

        if (from != address(0) && from != address(this)) {
            if (value > unlockedBalance(from)) revert TransferExceedsUnlocked();
        }

        super._update(from, to, value);

        if (_pairsEnabled[from]) {
            _syncV2LpCheckpoint(from);
        }
        if (_pairsEnabled[to]) {
            _syncV2LpCheckpoint(to);
        }

        if (whaleCheckEnabled && from != address(0)) {
            _checkWhale(from);
            _checkWhale(to);
        }
    }

    function _isAllowedFrozenTransfer(address from, address to) private view returns (bool) {
        if (to == address(0)) {
            return false;
        }

        // Compensation claims burn LIRENToken during permanent freeze.
        if (to == BURN_ADDRESS && !isPair(from)) {
            return true;
        }

        if (!_pairsEnabled[from] || isPair(to)) {
            return false;
        }

        return _isRemoveLiquidityV2(from);
    }

    /// @dev LP burn in the same tx lowers pair LP totalSupply below the checkpoint.
    function _isRemoveLiquidityV2(address pair) private view returns (bool) {
        uint256 checkpoint = _lpSupplyCheckpoint[pair];
        uint256 currentSupply = IERC20(pair).totalSupply();
        return currentSupply < checkpoint;
    }

    function _syncV2LpCheckpoint(address pair) private {
        _lpSupplyCheckpoint[pair] = IERC20(pair).totalSupply();
    }

    function _resyncAllPairCheckpoints() private {
        uint256 length = _pairs.length;
        for (uint256 i = 0; i < length; i++) {
            _syncV2LpCheckpoint(_pairs[i]);
        }
    }

    function _checkWhale(address account) private {
        if (account == address(0) || account == BURN_ADDRESS || account == address(this)) {
            return;
        }
        if (isPair(account)) {
            return;
        }

        uint256 balance = balanceOf(account);
        if (balance >= WHALE_THRESHOLD) {
            if (!frozen) {
                frozen = true;
                frozenPermanent = true;
                lastWhale = account;
                _resyncAllPairCheckpoints();
                emit FrozenTriggered(account, balance);
                _openIncident(account, balance);
            }
        }
    }

    function _openIncident(address whale, uint256 whaleBalance) private {
        if (whale == address(0)) revert InvalidIncident();

        uint256 newIncidentId = ++incidentId;
        incidents[newIncidentId] = Incident({
            whale: whale,
            whaleBalance: whaleBalance,
            lockPrice: 0,
            requiredQuote: 0,
            totalDeposited: 0
        });

        emit IncidentOpened(newIncidentId, whale, whaleBalance);
    }

    function _canClaim(address account, address whale) private view returns (bool) {
        if (account == address(0)) {
            return false;
        }
        if (account == whale) {
            return false;
        }
        if (account == address(this)) {
            return false;
        }
        if (account == BURN_ADDRESS) {
            return false;
        }
        if (isPair(account)) {
            return false;
        }
        return true;
    }
}
