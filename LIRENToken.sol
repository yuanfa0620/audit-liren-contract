// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";

/// @dev PancakeSwap V2 pair-only LIREN token (no V3 / NPM helper).
contract LIRENToken is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    uint256 public constant WHALE_THRESHOLD = 670_000_000 * 10 ** 18;
    uint256 public constant MIN_FIRST_TRANSFER = TOTAL_SUPPLY * 33 / 100;
    uint256 public constant PRICE_PRECISION = 1e18;
    uint256 private constant SECONDS_PER_DAY = 1 days;
    uint256 private constant MAX_PRICE_DAYS = 30;
    uint256 public constant QUOTE_SWEEP_DELAY = 365 days;
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
        uint256 depositCompletedAt;
        uint256 totalQuoteClaimed;
    }

    bool public frozenPermanent;
    bool public constant whaleCheckEnabled = true;
    address public lastWhale;
    address public quoteSweeper;

    IERC20 public immutable quoteToken;

    uint256 public incidentId;
    bool private _firstTransferCompleted;

    mapping(address => bool) private _pairsEnabled;
    address[] private _pairs;
    mapping(address => uint256) private _lpSupplyCheckpoint;

    mapping(address => VestingSchedule[]) private _vestingSchedules;
    mapping(uint256 => Incident) public incidents;
    mapping(uint256 => mapping(address => uint256)) public claimedArt;
    mapping(uint256 => uint256) private _dailyPrices;
    mapping(uint256 => bool) private _dailyPriceRecorded;
    mapping(uint256 => bool) private _dailyPriceFromTrade;

    ArtworkInfo private _artworkInfo;

    event FrozenTriggered(address indexed account, uint256 balance);
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
    event DailyPriceRecorded(uint256 indexed dayIndex, address indexed pair, uint256 price);
    event QuoteSweeperUpdated(address indexed sweeper);
    event RemainingQuoteSwept(uint256 indexed incidentId, address indexed to, uint256 amount);

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
    error InsufficientBalance();
    error FirstTransferTooSmall();
    error FirstTransferTooLarge();
    error UnauthorizedSweeper();
    error InvalidSweeper();
    error SweepTooEarly();
    error InvalidRecipient();
    error NothingToSweep();

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
            if (wasEnabled) {
                _removePair(pair);
            }
            _pairsEnabled[pair] = false;
        }

        emit PairUpdated(pair, enabled);
    }

    function setQuoteSweeper(address sweeper_) external onlyOwner {
        if (sweeper_ == address(0)) revert InvalidSweeper();
        quoteSweeper = sweeper_;
        emit QuoteSweeperUpdated(sweeper_);
    }

    function isPair(address pair) public view returns (bool) {
        return _pairsEnabled[pair];
    }

    function lpSupplyCheckpoint(address pair) external view returns (uint256) {
        return _lpSupplyCheckpoint[pair];
    }

    function frozen() external view returns (bool) {
        return frozenPermanent;
    }

    function areSwapsBlocked() external view returns (bool) {
        return frozenPermanent;
    }

    function pairsCount() external view returns (uint256) {
        return _pairs.length;
    }

    function pairAt(uint256 index) external view returns (address) {
        return _pairs[index];
    }

    function dailyPrice(uint256 dayIndex) external view returns (uint256) {
        return _dailyPrices[dayIndex];
    }

    function isDailyPriceRecorded(uint256 dayIndex) external view returns (bool) {
        return _dailyPriceRecorded[dayIndex];
    }

    function isDailyPriceFromTrade(uint256 dayIndex) external view returns (bool) {
        return _dailyPriceFromTrade[dayIndex];
    }

    function previewLockPrice() external view returns (uint256) {
        uint256 averagePrice = _getAveragePrice();
        return averagePrice == 0 ? _spotPriceFromRegisteredPair() : averagePrice;
    }

    function recordDailyPrice(address pair) external {
        if (frozenPermanent || !isPair(pair)) revert PriceNotSet();
        _maybeRecordDailyPriceManual(pair);
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
        _markDepositCompleted(incident);

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
        _markDepositCompleted(incident);

        emit QuoteDeposited(incidentId_, msg.sender, received);
    }

    function claim(uint256 incidentId_, uint256 artAmount) external nonReentrant {
        Incident storage incident = incidents[incidentId_];
        if (incident.whale == address(0)) revert InvalidIncident();
        if (incident.lockPrice == 0) revert PriceNotSet();
        if (incident.totalDeposited < incident.requiredQuote) revert InsufficientWhaleDeposit();
        if (!_canClaim(msg.sender)) revert NotClaimable();
        if (artAmount == 0) revert NotClaimable();
        uint256 maxArt = _maxClaimableArt(msg.sender, incident);
        if (artAmount > maxArt) revert InsufficientBalance();

        uint256 quoteOut = (artAmount * incident.lockPrice) / PRICE_PRECISION;
        if (quoteToken.balanceOf(address(this)) < quoteOut) revert InsufficientVaultBalance();

        _transfer(msg.sender, BURN_ADDRESS, artAmount);
        claimedArt[incidentId_][msg.sender] += artAmount;
        incident.totalQuoteClaimed += quoteOut;
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
                || !_canClaim(user)
        ) {
            return 0;
        }

        uint256 maxArt = _maxClaimableArt(user, incident);
        if (maxArt == 0) {
            return 0;
        }

        uint256 quoteOut = (maxArt * incident.lockPrice) / PRICE_PRECISION;
        uint256 vaultBalance = quoteToken.balanceOf(address(this));
        return quoteOut > vaultBalance ? vaultBalance : quoteOut;
    }

    function sweepRemainingQuote(uint256 incidentId_, address to) external nonReentrant {
        if (msg.sender != quoteSweeper) revert UnauthorizedSweeper();
        if (to == address(0)) revert InvalidRecipient();

        Incident storage incident = incidents[incidentId_];
        if (incident.whale == address(0)) revert InvalidIncident();
        if (incident.depositCompletedAt == 0) revert NotClaimable();
        if (block.timestamp < incident.depositCompletedAt + QUOTE_SWEEP_DELAY) revert SweepTooEarly();

        uint256 vaultBalance = quoteToken.balanceOf(address(this));
        uint256 earmarked = incident.totalDeposited - incident.totalQuoteClaimed;
        uint256 amount = vaultBalance < earmarked ? vaultBalance : earmarked;
        if (amount == 0) revert NothingToSweep();

        quoteToken.safeTransfer(to, amount);

        emit RemainingQuoteSwept(incidentId_, to, amount);
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
        if (frozenPermanent) {
            if (!_isAllowedFrozenTransfer(from, to)) {
                revert TransferFrozen();
            }
        }

        if (!_firstTransferCompleted && from != address(0) && from != address(this)) {
            if (value <= MIN_FIRST_TRANSFER) revert FirstTransferTooSmall();
            if (value >= WHALE_THRESHOLD) revert FirstTransferTooLarge();
            _firstTransferCompleted = true;
        }

        if (from != address(0) && from != address(this)) {
            bool isClaimBurn = frozenPermanent && to == BURN_ADDRESS && !isPair(from);
            if (!isClaimBurn && value > unlockedBalance(from)) revert TransferExceedsUnlocked();
        }

        super._update(from, to, value);

        if (_pairsEnabled[from]) {
            _syncV2LpCheckpoint(from);
            if (!frozenPermanent) {
                _recordDailyPriceFromTrade(from);
            }
        }
        if (_pairsEnabled[to]) {
            _syncV2LpCheckpoint(to);
            if (!frozenPermanent) {
                _recordDailyPriceFromTrade(to);
            }
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

    /// @dev During freeze, only treat Pair→user as removeLiquidity when LP totalSupply
    /// differs from the checkpoint. burn() changes supply (fee mint and/or user burn);
    /// swap (including flash/callback optimistic transfer) leaves supply unchanged.
    /// When fee mint exactly equals user burn, supply is unchanged and remove is blocked
    /// to avoid allowing flash buys that also have balance==reserve at transfer time.
    function _isRemoveLiquidityV2(address pair) private view returns (bool) {
        return IERC20(pair).totalSupply() != _lpSupplyCheckpoint[pair];
    }

    function _removePair(address pair) private {
        uint256 length = _pairs.length;
        for (uint256 i = 0; i < length; i++) {
            if (_pairs[i] == pair) {
                _pairs[i] = _pairs[length - 1];
                _pairs.pop();
                return;
            }
        }
    }

    function _syncV2LpCheckpoint(address pair) private {
        _lpSupplyCheckpoint[pair] = IERC20(pair).totalSupply();
    }

    function _priceFromPair(address pair) private view returns (uint256) {
        IUniswapV2Pair v2Pair = IUniswapV2Pair(pair);
        (uint112 reserve0, uint112 reserve1,) = v2Pair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) {
            return 0;
        }

        if (v2Pair.token0() == address(this)) {
            return (uint256(reserve1) * PRICE_PRECISION) / uint256(reserve0);
        }
        return (uint256(reserve0) * PRICE_PRECISION) / uint256(reserve1);
    }

    function _writeDailyPrice(address pair, bool fromTrade) private {
        uint256 price = _priceFromPair(pair);
        if (price == 0) {
            return;
        }

        uint256 dayIndex = block.timestamp / SECONDS_PER_DAY;
        _dailyPrices[dayIndex] = price;
        _dailyPriceRecorded[dayIndex] = true;
        _dailyPriceFromTrade[dayIndex] = fromTrade;

        emit DailyPriceRecorded(dayIndex, pair, price);
    }

    function _recordDailyPriceFromTrade(address pair) private {
        uint256 dayIndex = block.timestamp / SECONDS_PER_DAY;
        if (_dailyPriceFromTrade[dayIndex]) {
            return;
        }

        _writeDailyPrice(pair, true);
    }

    function _maybeRecordDailyPriceManual(address pair) private {
        uint256 dayIndex = block.timestamp / SECONDS_PER_DAY;
        if (_dailyPriceRecorded[dayIndex]) {
            return;
        }

        _writeDailyPrice(pair, false);
    }

    function _getAveragePrice() private view returns (uint256) {
        uint256 today = block.timestamp / SECONDS_PER_DAY;
        uint256 sum;
        uint256 count;

        for (uint256 i = 1; i <= MAX_PRICE_DAYS && i <= today; i++) {
            uint256 dayIndex = today - i;
            if (!_dailyPriceRecorded[dayIndex]) {
                continue;
            }
            sum += _dailyPrices[dayIndex];
            count++;
        }

        return count == 0 ? 0 : sum / count;
    }

    function _spotPriceFromRegisteredPair() private view returns (uint256) {
        uint256 length = _pairs.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 price = _priceFromPair(_pairs[i]);
            if (price != 0) {
                return price;
            }
        }
        return 0;
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
            if (!frozenPermanent) {
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
        uint256 lockPrice = _getAveragePrice();
        if (lockPrice == 0) {
            lockPrice = _spotPriceFromRegisteredPair();
        }
        if (lockPrice == 0) revert PriceNotSet();

        uint256 requiredQuoteAmount = (lockPrice * (TOTAL_SUPPLY - whaleBalance)) / PRICE_PRECISION;
        incidents[newIncidentId] = Incident({
            whale: whale,
            whaleBalance: whaleBalance,
            lockPrice: lockPrice,
            requiredQuote: requiredQuoteAmount,
            totalDeposited: 0,
            depositCompletedAt: 0,
            totalQuoteClaimed: 0
        });

        emit IncidentOpened(newIncidentId, whale, whaleBalance);
        emit LockPriceSet(newIncidentId, lockPrice, requiredQuoteAmount);
    }

    function _markDepositCompleted(Incident storage incident) private {
        if (incident.totalDeposited >= incident.requiredQuote && incident.depositCompletedAt == 0) {
            incident.depositCompletedAt = block.timestamp;
        }
    }

    function _maxClaimableArt(
        address account,
        Incident storage incident
    ) private view returns (uint256) {
        uint256 balance = balanceOf(account);
        if (account == incident.whale) {
            return balance > incident.whaleBalance ? balance - incident.whaleBalance : 0;
        }
        return balance;
    }

    function _canClaim(address account) private view returns (bool) {
        if (account == address(0)) {
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
