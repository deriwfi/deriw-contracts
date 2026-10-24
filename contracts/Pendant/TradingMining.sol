// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../upgradeability/Synchron.sol";
import "../core/interfaces/IVault.sol";
import "../core/interfaces/IDataReader.sol";
import "../core/interfaces/IEventStruct.sol";
import "./interfaces/ICoinData.sol";
import "./interfaces/IPhase.sol";
import "./interfaces/ISlippage.sol";
import "./interfaces/IChainBlacklist.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TradingMining
/// @notice Trading mining (loss-to-mine) plus a payout queue, merged into one upgradeable contract
/// @dev Data flow: Vault -> VaultUtils (passthrough) -> TradingMining (this contract, which
///      performs every calculation and owns the queue).
///      1. Main pools only (CoinData.getCoinType == 1); meme pools / channel pools emit an event
///         and return immediately.
///      2. The water level trackedLp is read live from Vault.poolAmounts(targetToken, usdt) minus
///         the unpaid queue debt. It may be negative. No cumulative parameters are maintained.
///      3. High watermark H = max(H, trackedLp - threshold); it never decreases and is stored per
///         targetToken.
///      4. The mint curve is configurable per targetToken: the underwater zone uses
///         underwaterRate, the flat zone uses flatRate and the ratchet zone uses
///         flatRate * (S / (S + H))^2, scaled by the decay factor D (default 0.9, governable per
///         targetToken via setDecayFactor). A single report uses the pre-settlement trackedLp to
///         pick the zone and the pre-settlement H (synced with the pre-settlement level) to pick
///         the rate; crossing the threshold is split into segments. No per-dollar integration.
///      5. There is a single global payout queue (one per pool); records are mapped by targetToken.
///         The payout entry point is called by an authorized address and loops over
///         Vault.transferOut. The head record must be fully paid before moving on (no skipping).
///      6. Precision: interface amounts use USDT 6 decimals; flatRate is DER per USDT; minted
///         amounts are scaled by 1e12 to DER 18 decimals.
///      7. Amount units (quick reference):
///         - USD / prices inside the Vault: 30 decimals (converted here via USD_DECIMALS_TO_6)
///         - USDT balances and minimum reserve: 6 decimals
///         - Queue debt (originalDebt / paid / remaining): the collateral token's own units, the
///           same unit as Vault.poolAmounts, obtained through IVault.usdToTokenMin. For the main
///           pools (USDT collateral) the value is numerically identical to 6 decimals.
///         - DER balances and payouts: 18 decimals (USDT amounts scaled by DER_SCALE)
///      8. PnL pricing belongs to this contract: the Vault passes the closed size and its
///         execution price, and this contract calls Phase.getDeltaFor for the same figures the
///         Vault settles with. The DER payout base is that same realised loss, slippage included
///         and with no cap, so the base and the water-level credit always agree.
///      9. Queue record lifecycle:
///         NONE (unused id) -> PENDING (enqueued) -> PARTIAL (paid in part) -> CLEARED (fully paid).
///         Only PENDING / PARTIAL ids can be the head.
///      10. Mining is OFF by default (miningEnabled = false). While off, _mint returns before any
///          calculation, transfer or event, so a close / liquidation behaves exactly as if the
///          contract had no mining at all, and syncTrackedLp freezes H. Governance must call
///          setMiningEnabled(true) after the upgrade.
contract TradingMining is Synchron {
    using SafeERC20 for IERC20;

    /// @notice Scale factor from USDT (6 decimals) to DER (18 decimals)
    uint256 public constant DER_SCALE = 1e12;
    /// @notice Scale factor from USD (30 decimals) to USDT (6 decimals)
    uint256 public constant USD_DECIMALS_TO_6 = 1e24;
    /// @notice Upper bound of decayS, prevents overflow
    uint256 public constant MAX_DECAY_S = 1e24;
    /// @notice Upper bound of underwaterRate / flatRate (DER per USDT), prevents overflow in
    ///         _rateWad / _computeMint (default values are 100)
    uint256 public constant MAX_RATE = 1e6;
    /// @notice Default minimum reserve (USDT 6 decimals, 5,000,000); the pool balance may not go below it
    uint256 public constant DEFAULT_MIN_RESERVE = 5_000_000e6;
    /// @notice Lower bound accepted by setMinReserve (USDT 6 decimals, 1,000,000)
    uint256 public constant MIN_RESERVE_FLOOR = 1_000_000e6;
    /// @notice System blacklist contract consulted before every DER payout
    /// @dev Hard-coded on purpose: it is a chain-level system contract, so there is nothing to
    ///      govern. Queries are fail-open (see _isBlacklisted), therefore an absent or upgraded
    ///      contract can never block a close.
    address public constant BLACKLIST = 0x00000000000000000000000000000000000007eB;
    /// @notice Default decay factor D for the ratchet segment (WAD, 0.9 = 9e17)
    /// @dev Applied on top of the squared-curve rate: ratchet payout × D. Governance can override
    ///      it per targetToken with setDecayFactor; a zero override falls back to this value.
    uint256 public constant DEFAULT_DECAY_FACTOR = 9e17;
    /// @notice Skip reason: the funding source cannot cover the payout (balance or allowance)
    uint8 public constant SKIP_INSUFFICIENT_DER = 0;
    /// @notice Skip reason: the account is flagged by the blacklist contract
    uint8 public constant SKIP_BLACKLISTED = 1;
    /// @notice Skip reason: the blacklist contract could not answer, so the payout is withheld
    uint8 public constant SKIP_BLACKLIST_UNAVAILABLE = 2;

    /// @notice Zone: underwater (trackedLp < 0)
    uint8 public constant ZONE_UNDERWATER = 0;
    /// @notice Zone: flat (0 <= trackedLp < threshold)
    uint8 public constant ZONE_FLAT = 1;
    /// @notice Zone: ratchet (trackedLp >= threshold)
    uint8 public constant ZONE_RATCHET = 2;

    /// @notice Queue status: none (default when the record does not exist)
    uint8 public constant STATUS_NONE = 0;
    /// @notice Queue status: pending
    uint8 public constant STATUS_PENDING = 1;
    /// @notice Queue status: partially paid
    uint8 public constant STATUS_PARTIAL = 2;
    /// @notice Queue status: cleared
    uint8 public constant STATUS_CLEARED = 3;

    /// @notice Mint curve parameters (configured per targetToken)
    struct CurveParams {
        uint256 underwaterRate; // Underwater zone rate (trackedLp < 0): DER per USDT (default 100)
        uint256 flatRate;       // Flat zone rate (0 <= trackedLp < threshold): DER per USDT (default 100)
        uint256 threshold;      // Ratchet threshold (USDT 6 decimals, default 2,000,000e6)
        uint256 decayS;         // Decay parameter S (USDT 6 decimals, default 120,000,000e6)
    }

    /// @notice Payout queue record
    struct QueueRecord {
        uint256 id;                 // Queue id (auto-increments from 1)
        address account;            // Creditor
        bytes32 positionKey;        // Source position identifier
        address indexToken;         // Index token of the source position
        address collateralToken;    // Debt token
        bool isLong;                // Direction of the source position
        uint256 originalDebt;       // Original debt (collateral token units, = poolAmounts unit)
        uint256 paid;               // Amount already paid (collateral token units)
        uint256 remaining;          // Remaining debt (collateral token units)
        uint256 enqueuedAt;         // Enqueue timestamp
        uint8 status;               // 0 none / 1 pending / 2 partial / 3 cleared
    }

    /// @notice Queue summary (per targetToken)
    struct QueueConfig {
        uint256 openCount;          // Number of unsettled records
        uint256 totalOutstanding;   // Queue debt (total unpaid)
        uint256 totalQueued;        // Cumulative enqueued
        uint256 totalPaid;          // Cumulative paid
    }

    /// @notice Per-mint record emitted for off-chain auditing
    /// @dev `rate` is the curve payout per unit of base, computed before the DER balance cap.
    ///      The amount actually transferred is `minted`; a shortfall shows up as `minted` being
    ///      lower than what `mintBase` and `rate` imply.
    struct MintRecord {
        address account;            // Losing trader (DER receiver)
        bytes32 positionKey;        // Position identifier
        address collateralToken;    // Collateral token
        uint256 realisedLoss;       // Realised loss at the execution price, slippage included (USDT 6 dec)
        uint256 mintBase;           // Payout base actually used (USDT 6 decimals); equals realisedLoss
        uint256 minted;             // DER actually transferred (capped by this contract's balance)
        int256 trackedLpBefore;     // Water level before settlement
        int256 trackedLpAfter;      // Water level after settlement
        uint256 hBefore;            // H before settlement
        uint256 hAfter;             // H after settlement
        uint256 rate;               // Curve payout per base unit (DER per USDT)
        uint8 zone;                 // Zone determined by the pre-settlement water level
        bool isLiquidation;         // true = liquidation, false = loss close
        uint256 shortfall;          // Curve payout not delivered because the DER balance ran out
        uint256 rateWad;            // Same average rate as `rate`, with 1e18 precision.
                                    // minted + shortfall == mintBase * rateWad / 1e18 * DER_SCALE
                                    // (up to the rounding of the division), so integrators can
                                    // reconcile the payout exactly instead of using the truncated
                                    // integer `rate`.
    }

    /// @notice Payout request passed to _mint
    /// @dev Grouped in a struct to keep the internal function within the stack limit
    struct MintRequest {
        address targetToken;      // Main-pool targetToken
        address account;          // DER receiver
        bytes32 positionKey;      // Source position identifier
        address collateralToken;  // Collateral token (used by the event only)
        uint256 realisedLoss;     // Realised loss at the execution price, slippage included (USDT 6 dec)
        uint256 mintBase;         // Payout base actually used (USDT 6 decimals)
        uint256 poolCredit;       // Token amount the Vault credits to the pool right AFTER this
                                  // report (same unit as poolAmounts, i.e. collateral decimals)
        bool isLiquidation;       // True = liquidation, false = loss close (event flag only; the
                                  // Vault always books the credit after reporting)
    }

    /// @notice Result of `previewClose` (read-only estimate of a losing close)
    struct LossPreview {
        uint256 realisedLoss;   // Loss at the settlement price, slippage included (USDT 6 decimals)
        uint256 mintBase;       // Mint base (USDT 6 decimals); equals realisedLoss here
        uint256 rate;           // Average payout per unit of base (DER per USDT)
        uint256 payout;         // DER that would be paid (18 decimals, before the balance cap)
        int256 lpBefore;        // Water level used for the segment split (USDT 6 decimals)
        uint256 hBefore;        // Effective H used for the ratchet segment
        uint8 zone;             // 0 underwater / 1 flat / 2 ratchet (0 when not applicable)
        uint256 availableDer;   // min(derSource balance, allowance to this contract); caps the payout
        bool miningEnabled;     // false = nothing will actually be minted, so `payout` is reported as 0
                                // while the other figures (loss, base, level, zone) stay valid
    }

    // ==================== Storage (order is fixed, append only) ====================

    /// @notice Whether the contract is initialized
    bool public initialized;
    /// @notice Governance address
    address public gov;
    /// @notice DataReader address
    address public dataReader;
    /// @notice Whitelist of contracts allowed to report data
    mapping(address => bool) public isRecorder;

    /// @notice DerToken address (fixed at initialize, cannot be changed afterwards)
    address public derToken;
    /// @notice USDT address (fixed at initialize, cannot be changed afterwards)
    address public usdt;
    /// @notice Vault address (pool balance / positions / payouts)
    address public vault;

    /// @notice targetToken => mint curve parameters
    mapping(address => CurveParams) public curveParams;
    /// @notice targetToken => high watermark H (monotonic)
    mapping(address => uint256) public highWatermark;
    /// @notice targetToken => latest queue id (auto-increment)
    mapping(address => uint256) public queueID;
    /// @notice targetToken => last processed id (monotonic)
    mapping(address => uint256) public processedID;
    /// @notice targetToken => id => queue record
    mapping(address => mapping(uint256 => QueueRecord)) public queueRecords;
    /// @notice targetToken => queue summary
    mapping(address => QueueConfig) public queueConfigs;

    /// @notice Treasury address for idle-fund transfers (set at initialize, changeable via setTreasury)
    address public treasury;
    /// @notice targetToken => minimum reserve (USDT 6 decimals); the balance must stay above it
    mapping(address => uint256) public minReserve;
    /// @notice Withdrawer whitelist (true = may call withdrawExcess / withdrawAllExcess)
    mapping(address => bool) public isWithdrawer;
    /// @notice Settlement keeper whitelist; governance may always call settleQueue
    mapping(address => bool) public isKeeper;
    /// @notice DER funding source (set at initialize, changeable via setDerSource)
    /// @dev This contract never needs to hold DER: mining payouts are pulled from here with
    ///      safeTransferFrom, so the source must approve this contract for the DER it will hand out.
    address public derSource;
    /// @notice Mining switch; OFF by default
    /// @dev A freshly added storage slot reads as zero, so every already-deployed proxy comes up
    ///      with mining disabled. Governance must call setMiningEnabled(true) to start mining.
    bool public miningEnabled;
    /// @notice Ratchet-segment decay factor D per targetToken (WAD)
    /// @dev Stored as an override. Zero means "not set", in which case DEFAULT_DECAY_FACTOR (0.9)
    ///      applies; callers should read getDecayFactor() rather than this mapping directly.
    mapping(address => uint256) public decayFactor;


    // ==================== Events ====================

    /// @notice Base initialization completed
    event Initialized(address indexed derToken, address indexed usdt);
    /// @notice Curve parameters updated
    event CurveParamsSet(
        address indexed targetToken,
        uint256 underwaterRate,
        uint256 flatRate,
        uint256 threshold,
        uint256 decayS
    );
    /// @notice DataReader and Vault updated
    event ContractsSet(address indexed dataReader, address indexed vault);
    /// @notice Reporter whitelist updated
    event RecorderSet(address indexed account, bool allowed);
    /// @notice Treasury address updated
    event TreasurySet(address indexed treasury);
    /// @notice DER funding source updated (payouts are pulled from it with safeTransferFrom)
    event DerSourceSet(address indexed derSource);
    /// @notice Mining switch changed. While disabled nothing is minted and no mining events fire
    event MiningEnabledSet(bool enabled);
    /// @notice Ratchet decay factor D changed
    /// @param targetToken Main-pool targetToken
    /// @param decayFactor Stored override (0 = cleared, i.e. the default applies again); read
    ///        getDecayFactor() for the value that is actually in use
    event DecayFactorSet(address indexed targetToken, uint256 decayFactor);
    /// @notice Governance address updated
    event GovSet(address indexed gov);
    /// @notice Settlement keeper whitelist updated
    event KeeperSet(address indexed account, bool allowed);
    /// @notice Minimum reserve updated
    event MinReserveSet(address indexed targetToken, uint256 oldValue, uint256 newValue);
    /// @notice Idle funds transferred to the treasury
    event ExcessWithdrawn(address indexed targetToken, address indexed to, uint256 amount, uint256 remaining);
    /// @notice Withdrawer whitelist updated
    event WithdrawerSet(address indexed account, bool allowed);
    /// @notice Non-main-pool call skipped
    event NonMainPoolSkipped(address sender, address indexToken, uint8 coinType);
    /// @notice Mint skipped because the curve of this pool is not configured yet
    event CurveNotSet(address indexed targetToken);
    /// @notice Mint record emitted for off-chain auditing
    event MintRecorded(address indexed targetToken, MintRecord record);
    /// @notice This contract's DER balance was insufficient, the transfer was truncated
    /// @notice A DER payout was skipped: nothing was transferred to the trader
    /// @param account Trader that should have received the DER
    /// @param computed Payout the curve allowed (DER 18 decimals)
    /// @param reason Why nothing was sent, see SKIP_* below
    event DerPayoutSkipped(address indexed account, uint256 computed, uint8 reason);
    /// @notice DER tokens transferred out
    event DerWithdrawn(address indexed to, uint256 amount);
    /// @notice A debt record was enqueued
    event Enqueued(address indexed targetToken, QueueRecord record);
    /// @notice A single repayment
    event Repaid(
        address indexed targetToken,
        uint256 indexed id,
        address account,
        address collateralToken,
        uint256 amount,
        uint256 paid,
        uint256 remaining,
        uint8 status
    );
    /// @notice Batch settlement summary
    event QueueSettled(address indexed targetToken, uint256 processed, uint256 paidTotal, uint256 headId, uint256 outstanding);
    /// @notice Queue fully cleared
    /// @param totalPaid Cumulative amount paid for this queue at the moment it became empty
    ///        (not the amount of this batch; use Repaid / QueueSettled for per-batch figures)
    event QueueCleared(address indexed targetToken, uint256 totalPaid);

    /// @dev The implementation contract itself cannot be initialized (writes implementation storage)
    constructor() {
        initialized = true;
    }

    modifier onlyGov() {
        if(msg.sender != gov) revert("gov err");
        _;
    }

    modifier onlyRecorder() {
        if(!isRecorder[msg.sender]) revert("recorder err");
        _;
    }

    modifier onlyWithdrawer() {
        if(!isWithdrawer[msg.sender]) revert("withdrawer err");
        _;
    }

    /// @dev Settlement caller: governance or a whitelisted keeper.
    ///      It cannot be limited to the reporter: the VaultUtils passthrough never triggers
    ///      settlement, so a reporter-only rule would leave the queue growing forever. Keepers
    ///      cannot report PnL, so leaking a keeper key can only move pool cash to queue creditors.
    modifier onlyKeeper() {
        if(msg.sender != gov && !isKeeper[msg.sender]) revert("keeper err");
        _;
    }

    // ==================== Initialization and governance ====================

    /// @notice One-time base initialization, called after the proxy is deployed
    /// @dev Also sets the minimum reserve to DEFAULT_MIN_RESERVE (5,000,000 USDT); it can be
    ///      adjusted later through setMinReserve.
    /// @param _derToken DerToken address (must not be zero, cannot be changed afterwards)
    /// @param _usdt USDT address (must not be zero, cannot be changed afterwards)
    /// @param _treasury Treasury address for idle-fund transfers (must not be zero, changeable via setTreasury)
    /// @param _derSource DER funding source for mining payouts (must not be zero, changeable via
    ///        setDerSource). It must approve this contract, otherwise the payout cannot be pulled.
    function initialize(address _derToken, address _usdt, address _treasury, address _derSource) external {
        if(initialized) revert("has initialized");
        if(_derToken == address(0)) revert("derToken err");
        if(_usdt == address(0)) revert("usdt err");
        if(_treasury == address(0)) revert("treasury err");
        if(_derSource == address(0)) revert("derSource err");

        initialized = true;
        gov = msg.sender;
        derToken = _derToken;
        usdt = _usdt;
        treasury = _treasury;
        derSource = _derSource;
        minReserve[_usdt] = DEFAULT_MIN_RESERVE;

        emit Initialized(_derToken, _usdt);
        emit TreasurySet(_treasury);
        emit DerSourceSet(_derSource);
        emit MinReserveSet(_usdt, 0, DEFAULT_MIN_RESERVE);
    }

    /// @notice Transfer governance to a new address (governance only)
    /// @param _gov New governance address (must not be zero)
    function setGov(address _gov) external onlyGov {
        if(_gov == address(0)) revert("gov err");
        gov = _gov;
        emit GovSet(_gov);
    }

    /// @notice Set the treasury address for idle-fund transfers (governance only)
    /// @param _treasury New address (must not be zero)
    function setTreasury(address _treasury) external onlyGov {
        if(_treasury == address(0)) revert("treasury err");
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    /// @notice Set the DER funding source used for mining payouts (governance only)
    /// @dev Payouts are pulled with safeTransferFrom, so the new source must approve this contract
    ///      BEFORE the next close. Switching it does not move any DER by itself.
    /// @param _derSource New source address (must not be zero)
    function setDerSource(address _derSource) external onlyGov {
        if(_derSource == address(0)) revert("derSource err");
        derSource = _derSource;
        emit DerSourceSet(_derSource);
    }

    /// @notice Turn mining on or off (governance only)
    /// @dev Mining is OFF by default, so it must be enabled explicitly before any DER is paid.
    ///      While disabled `_mint` returns before doing anything: no DER is transferred and no
    ///      mining event (MintRecorded / CurveNotSet / DerPayoutSkipped) is emitted. Closes and
    ///      liquidations are unaffected. The water level keeps being tracked by the Vault through
    ///      syncTrackedLp, so H is not rewound when mining is turned back on.
    /// @param _enabled true = mine, false = stop mining
    function setMiningEnabled(bool _enabled) external onlyGov {
        miningEnabled = _enabled;
        emit MiningEnabledSet(_enabled);
    }

    /// @notice Effective ratchet decay factor D for a pool (WAD)
    /// @param _targetToken Main-pool targetToken
    /// @return The stored override, or DEFAULT_DECAY_FACTOR (0.9) when none is set
    function getDecayFactor(address _targetToken) public view returns (uint256) {
        uint256 f = decayFactor[_targetToken];
        return f == 0 ? DEFAULT_DECAY_FACTOR : f;
    }

    /// @notice Set the ratchet decay factor D for a pool (governance only)
    /// @dev D multiplies the ratchet segment only: payout = curve payout × D / 1e18. The underwater
    ///      and flat segments are not affected. 1e18 means "no decay"; the largest value below that
    ///      is 1, which effectively mutes the segment. Values above 1e18 are rejected (D must never
    ///      amplify the payout).
    ///      Zero clears the override and restores the default (DEFAULT_DECAY_FACTOR), so a zero
    ///      override cannot be stored: DEFAULT_DECAY_FACTOR is a constant, therefore "clear" and
    ///      "set it to the default explicitly" are the same state and need no separate entry point.
    /// @param _targetToken Main-pool targetToken
    /// @param _decayFactor Decay factor in WAD (0 = restore the default, 1 <= D <= 1e18)
    function setDecayFactor(address _targetToken, uint256 _decayFactor) external onlyGov {
        if(_targetToken != usdt) revert("targetToken err");
        if(_decayFactor > 1e18) revert("decayFactor err");

        decayFactor[_targetToken] = _decayFactor;
        emit DecayFactorSet(_targetToken, _decayFactor);
    }

    /// @notice Set the minimum reserve of a main pool (governance only)
    /// @dev When idle funds are transferred out, the remaining pool balance may not go below it.
    ///      The value cannot go below MIN_RESERVE_FLOOR (1,000,000 USDT).
    /// @param _targetToken Main-pool targetToken (must equal the USDT fixed at initialize)
    /// @param _minReserve New minimum reserve (USDT 6 decimals)
    function setMinReserve(address _targetToken, uint256 _minReserve) external onlyGov {
        if(_targetToken != usdt) revert("targetToken err");
        if(_minReserve < MIN_RESERVE_FLOOR) revert("minReserve err");

        emit MinReserveSet(_targetToken, minReserve[_targetToken], _minReserve);
        minReserve[_targetToken] = _minReserve;
    }

    /// @notice Grant or revoke a settlement keeper (governance only)
    /// @dev Keepers may only call settleQueue: leaking a keeper key can move pool cash to queue
    ///      creditors but can never report PnL or mint DER.
    /// @param _keeper Keeper address (must not be zero)
    /// @param _allowed true = grant, false = revoke
    function setKeeper(address _keeper, bool _allowed) external onlyGov {
        if(_keeper == address(0)) revert("keeper err");
        isKeeper[_keeper] = _allowed;
        emit KeeperSet(_keeper, _allowed);
    }

    /// @notice Grant or revoke a withdrawer (governance only)
    /// @dev Withdrawers may call withdrawExcess / withdrawAllExcess, which move idle pool funds
    ///      to the treasury outside Vault transactions.
    /// @param _withdrawer Withdrawer address
    /// @param _allowed true = grant, false = revoke
    function setWithdrawer(address _withdrawer, bool _allowed) external onlyGov {
        if(_withdrawer == address(0)) revert("withdrawer err");
        isWithdrawer[_withdrawer] = _allowed;
        emit WithdrawerSet(_withdrawer, _allowed);
    }

    /// @notice Transfer DER tokens held by this contract to a given address (governance only)
    /// @dev DER is minted externally in advance and transferred into this contract. Loss payouts
    ///      transfer DER to users directly inside _mint; this entry point moves idle / pre-funded
    ///      DER to operations, market makers or other addresses.
    ///      Reverts on zero receiver, zero amount, or insufficient balance.
    /// @param _to Receiver address
    /// @param _amount Amount to transfer (DER 18 decimals)
    function withdrawDer(address _to, uint256 _amount) external onlyGov {
        if(_to == address(0)) revert("to err");
        if(_amount == 0) revert("amount err");

        uint256 balance = IERC20(derToken).balanceOf(address(this));
        if(_amount > balance) revert("balance err");

        IERC20(derToken).safeTransfer(_to, _amount);

        emit DerWithdrawn(_to, _amount);
    }

    /// @notice Set the DataReader and Vault addresses
    /// @dev Governance only; neither may be zero. The Vault must authorize this contract as a
    ///      manager before it can transfer funds out.
    /// @param _dataReader DataReader address
    /// @param _vault Vault address
    function setContracts(address _dataReader, address _vault) external onlyGov {
        if(_dataReader == address(0)) revert("dataReader err");
        if(_vault == address(0)) revert("vault err");

        dataReader = _dataReader;
        vault = _vault;

        // PRD 2.1: bootstrap H = max(0, initial trackedLp - threshold) once the vault is known
        // (skipped silently while the curve is still unconfigured)
        _bootstrapHighWatermark(usdt);

        emit ContractsSet(_dataReader, _vault);
    }

    /// @notice Grant or revoke a reporter (governance only)
    /// @dev The reporter is the only address allowed to call recordPnl / recordLiquidation.
    ///      In production it must be the VaultUtils passthrough contract, which is in turn
    ///      restricted to the Vault; never grant it to an EOA, since a reporter can trigger DER
    ///      payouts. Queue settlement uses the separate keeper whitelist (setKeeper).
    /// @param _recorder Reporter address
    /// @param _allowed true = grant, false = revoke
    function setRecorder(address _recorder, bool _allowed) external onlyGov {
        if(_recorder == address(0)) revert("recorder err");
        isRecorder[_recorder] = _allowed;
        emit RecorderSet(_recorder, _allowed);
    }

    /// @notice Configure the mint curve of a main pool (per targetToken, governance only)
    /// @dev The zone is picked from the PRE-SETTLEMENT trackedLp and the rate from the
    ///      PRE-SETTLEMENT H. A single report crossing the threshold is split into segments:
    ///        trackedLp = Vault.poolAmounts(targetToken, usdt) - unpaid queue debt (may be negative)
    ///        1) underwater zone: trackedLp < 0             -> underwaterRate
    ///        2) flat zone:       0 <= trackedLp < threshold -> flatRate
    ///        3) ratchet zone:    trackedLp >= threshold    -> flatRate * (S / (S + H))^2 * D
    ///      When crossing the threshold, min(mintBase, threshold - trackedLp) uses the rate of
    ///      1)/2) and the remainder uses the rate of 3). The ratchet zone performs no per-dollar
    ///      integration (the pre-settlement H rate is applied once).
    ///      Changes take effect immediately but never roll back the recorded H (H is monotonic).
    /// @param _targetToken Main-pool targetToken (must equal the USDT fixed at initialize)
    /// @param _underwaterRate Underwater zone rate (DER per USDT, default 100, must be > 0)
    /// @param _flatRate Flat zone rate (DER per USDT, default 100, must be > 0; also the base rate of the ratchet zone)
    /// @param _threshold Ratchet threshold (USDT 6 decimals, default 2,000,000e6, must be > 0)
    /// @param _decayS Decay parameter S (USDT 6 decimals, default 120,000,000e6, 0 < S <= MAX_DECAY_S)
    function setCurveParams(
        address _targetToken,
        uint256 _underwaterRate,
        uint256 _flatRate,
        uint256 _threshold,
        uint256 _decayS
    ) external onlyGov {
        if(_targetToken != usdt) revert("targetToken err");
        if(_underwaterRate == 0 || _underwaterRate > MAX_RATE) revert("underwaterRate err");
        if(_flatRate == 0 || _flatRate > MAX_RATE) revert("flatRate err");
        if(_threshold == 0) revert("threshold err");
        if(_decayS == 0 || _decayS > MAX_DECAY_S) revert("decayS err");

        // NOTE: the stored H is max(trackedLp - threshold) in absolute terms and is intentionally
        // NOT reset here. Governance is expected to account for this when re-configuring: after a
        // threshold change the stored H describes a different water level, so it must be reviewed
        // off-chain before applying new parameters.
        curveParams[_targetToken] = CurveParams({
            underwaterRate: _underwaterRate,
            flatRate: _flatRate,
            threshold: _threshold,
            decayS: _decayS
        });

        // Bootstrap H only while it has never been initialised; an existing H is never reset
        if(highWatermark[_targetToken] == 0) {
            _bootstrapHighWatermark(_targetToken);
        }

        emit CurveParamsSet(_targetToken, _underwaterRate, _flatRate, _threshold, _decayS);
    }

    // ==================== Mining reports (onlyRecorder) ====================

    /// @notice Report the realised PnL of a position close
    /// @dev Prices the closing part with the same Phase call the Vault uses (`getDeltaFor` at the
    ///      execution price), so `adjustedDelta` returned here is exactly the value the Vault
    ///      settles. On a loss the DER payout base is that same realised loss at the execution
    ///      price (slippage included, no cap), so the base and the water-level credit agree.
    ///      Profitable closes are paid when the pool has cash and the queue is empty; otherwise the
    ///      whole profit is enqueued. Non-main pools emit NonMainPoolSkipped and get the full delta
    ///      back, so the Vault keeps its legacy behaviour for meme / channel pools.
    /// @param _indexToken Index token of the position
    /// @param _collateralToken Collateral token
    /// @param _account Position owner
    /// @param _isLong true for a long position
    /// @param _sizeDelta Size being closed (USD 30 decimals)
    /// @param _price Execution price the Vault uses for this decrease (USD 30 decimals)
    /// @return hasProfit true when the closing part is profitable
    /// @return adjustedDelta Realised PnL of the closing part, absolute value (USD 30 decimals)
    /// @return payableUsd Amount the Vault may pay out now (USD 30 decimals): the full PnL when it
    ///         can be paid immediately, otherwise 0 because the whole profit was enqueued. Always
    ///         0 on a loss (payout is DER and does not move the pool).
    function recordPnl(
        address _indexToken,
        address _collateralToken,
        address _account,
        bool _isLong,
        uint256 _sizeDelta,
        uint256 _price
    ) external onlyRecorder returns (bool hasProfit, uint256 adjustedDelta, uint256 payableUsd) {
        bytes32 key = IVault(vault).getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        IEventStruct.Position memory p = IVault(vault).getPositionFrom(key);
        if(p.size == 0 || _sizeDelta == 0) return (false, 0, 0);

        (hasProfit, adjustedDelta) = _pnlDelta(_indexToken, p, _isLong, _sizeDelta, _price);

        address targetToken = _mainPoolTarget(_indexToken);
        if(targetToken == address(0)) return (hasProfit, adjustedDelta, adjustedDelta);

        if(hasProfit) {
            payableUsd = _payOrQueue(
                targetToken, _account, key, _indexToken, _collateralToken, _isLong, adjustedDelta
            );
        } else {
            _settleLoss(targetToken, _account, key, _collateralToken, adjustedDelta);
            payableUsd = 0;
        }
    }

    /// @dev Pay the DER for a losing close
    /// @dev The Vault credits the realised delta right after this report, which is what shifts the
    ///      post-settlement level; the payout base only feeds the mint curve. The credit is
    ///      converted with the same helper the Vault uses, so it matches the token amount it adds
    ///      to poolAmounts regardless of the collateral token's decimals.
    /// @param _targetToken Main-pool targetToken
    /// @param _account DER receiver
    /// @param _key Position identifier
    /// @param _collateralToken Collateral token
    /// @param _adjustedDelta Realised loss at the execution price, slippage included (USD 30)
    function _settleLoss(
        address _targetToken,
        address _account,
        bytes32 _key,
        address _collateralToken,
        uint256 _adjustedDelta
    ) internal {
        // Payout base = the realised loss at the execution price, i.e. slippage included.
        // Slippage is treated as a genuine loss: it is neither stripped nor capped against a
        // slippage-free figure, so a trader who pays price impact is compensated for it. This also
        // keeps the base and the water-level credit on exactly the same amount.
        uint256 mintBase = _adjustedDelta / USD_DECIMALS_TO_6;
        if(mintBase == 0) return;

        _mint(MintRequest(
            _targetToken, _account, _key, _collateralToken,
            mintBase, mintBase,
            IVault(vault).usdToTokenMin(_collateralToken, _adjustedDelta), false
        ));
    }

    /// @dev PnL of the closing part at the given execution price (mirrors the Vault's own call)
    /// @param _indexToken Index token
    /// @param _p Live position
    /// @param _isLong true for a long position
    /// @param _sizeDelta Size being closed (USD 30 decimals)
    /// @param _price Execution price (USD 30 decimals)
    /// @return hasProfit true when the closing part is profitable
    /// @return adjustedDelta PnL of the closing part, absolute value (USD 30 decimals)
    function _pnlDelta(
        address _indexToken,
        IEventStruct.Position memory _p,
        bool _isLong,
        uint256 _sizeDelta,
        uint256 _price
    ) internal view returns (bool hasProfit, uint256 adjustedDelta) {
        uint256 delta;
        (hasProfit, delta) = IPhase(IVault(vault).phase()).getDeltaFor(
            _indexToken, _p.size, _p.averagePrice, _isLong, _p.lastIncreasedTime, _price
        );
        adjustedDelta = _sizeDelta * delta / _p.size;
    }

    /// @dev Pay a profit now, or enqueue the whole amount when cash is short or the queue is busy
    /// @param _targetToken Main-pool targetToken
    /// @param _account Profit owner
    /// @param _key Position identifier
    /// @param _indexToken Index token
    /// @param _collateralToken Collateral token
    /// @param _isLong true for a long position
    /// @param _adjustedDelta Realised profit (USD 30 decimals)
    /// @return payableUsd Payable now (USD 30 decimals); 0 when fully enqueued
    function _payOrQueue(
        address _targetToken,
        address _account,
        bytes32 _key,
        address _indexToken,
        address _collateralToken,
        bool _isLong,
        uint256 _adjustedDelta
    ) internal returns (uint256 payableUsd) {
        // Queue debt is denominated in the collateral token's own units (the same unit as
        // poolAmounts), so convert through the Vault instead of assuming USDT has 6 decimals
        uint256 profit = IVault(vault).usdToTokenMin(_collateralToken, _adjustedDelta);
        if(profit == 0) return _adjustedDelta;

        // persist the peak BEFORE this call can lower the level. Both branches do:
        // paying the profit reduces pool cash, enqueuing turns it into queue debt (the Vault
        // reduces trackedLp in either case).
        _syncHighWatermark(_targetToken);

        // While the queue still has unpaid debt, every inflow goes to the head record first, so
        // the whole profit is enqueued (PRD 4.2/4.4). Insufficient pool cash behaves the same
        // (partial settlement only happens in settleQueue).
        uint256 cash = IVault(vault).poolAmounts(_targetToken, _collateralToken);
        if(profit <= cash && queueConfigs[_targetToken].totalOutstanding == 0) return _adjustedDelta;

        _enqueue(_targetToken, _account, _key, _indexToken, _collateralToken, _isLong, profit);
        return 0;
    }

    /// @notice Report a liquidation
    /// @dev The payout base is the full lost collateral (the liquidation fee is not deducted),
    ///      read from the Vault position before it is deleted. The Vault credits
    ///      `collateral - fees - liquidationFee` to the pool right AFTER this call, so
    ///      the credit is still pending here: the live level is the pre-settlement one and
    ///      `_poolCredit` only shifts the post-settlement level.
    ///      Liquidations are not subject to any hold-time rule.
    /// @param _indexToken Index token of the position
    /// @param _collateralToken Collateral token
    /// @param _account Position owner (DER receiver)
    /// @param _isLong true for a long position
    /// @param _poolCredit USD value the Vault credits to the pool right AFTER this report, in 6
    ///        decimals (converted to the collateral token's units inside)
    function recordLiquidation(
        address _indexToken,
        address _collateralToken,
        address _account,
        bool _isLong,
        uint256 _poolCredit
    ) external onlyRecorder {
        address targetToken = _mainPoolTarget(_indexToken);
        if(targetToken == address(0)) return;

        bytes32 key = IVault(vault).getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        uint256 mintBase = IVault(vault).getPositionFrom(key).collateral / USD_DECIMALS_TO_6;
        if(mintBase == 0) return;

        // Liquidation: the Vault reports BEFORE crediting the pool, so the credit is
        // still pending here and is flagged as a liquidation for the event only.
        // _poolCredit is a USD value in 6 decimals; convert it to the collateral token's units
        // (same unit as poolAmounts) with the same helper the Vault uses when crediting.
        if(_poolCredit > mintBase) _poolCredit = mintBase;
        uint256 creditTokens = IVault(vault).usdToTokenMin(_collateralToken, _poolCredit * USD_DECIMALS_TO_6);
        _mint(MintRequest(
            targetToken, _account, key, _collateralToken,
            mintBase, mintBase, creditTokens, true
        ));
    }

    // ==================== Payout queue (onlyKeeper) ====================

    /// @notice Settle the queue head in batches (governance or a whitelisted keeper)
    /// @dev Processes ids from processedID + 1, at most _maxCount records:
    ///      - each record pays at most min(remaining debt, current pool cash); when the pool is
    ///        short, only the payable part is transferred
    ///      - head record not fully paid -> stop immediately (no skipping); the next batch resumes
    ///        from the same id
    ///      - fully paid -> mark the record as cleared and advance to the next id
    ///      WARNING: must not be called from a nonReentrant Vault transaction
    ///      (Vault.transferOut is nonReentrant itself).
    /// @param _indexToken Main-pool index token (used to resolve targetToken)
    /// @param _maxCount Maximum number of records handled in this call
    /// @return processed Number of records handled (including partial payments)
    /// @return paidTotal Total amount paid in this call (collateral token units, the same unit as
    ///         Vault.poolAmounts; numerically 6 decimals for USDT collateral)
    function settleQueue(address _indexToken, uint256 _maxCount)
        external
        onlyKeeper
        returns (uint256 processed, uint256 paidTotal)
    {
        address targetToken = _mainPoolTarget(_indexToken);
        if(targetToken == address(0)) revert("targetToken err");
        if(_maxCount == 0) revert("maxCount err");

        QueueConfig storage cfg = queueConfigs[targetToken];
        if(cfg.openCount == 0) revert("queue empty");

        uint256 id = processedID[targetToken] + 1;
        uint256 lastId = queueID[targetToken];

        // Read the pool cash once: transferOut below is the only outflow in this loop, so the
        // local figure stays in sync and no extra external call is needed per record.
        uint256 cash = IVault(vault).poolAmounts(targetToken, usdt);

        while(id <= lastId && processed < _maxCount) {
            QueueRecord storage r = queueRecords[targetToken][id];
            // Cleared or non-existent ids are skipped (amortized O(1))
            if(r.status == STATUS_NONE || r.status == STATUS_CLEARED) {
                id++;
                continue;
            }

            // When the pool cash is short, pay only what can be paid
            if(cash == 0) break;
            uint256 pay = r.remaining < cash ? r.remaining : cash;

            // CEI: apply every state change BEFORE the external transfer, so a callback during the
            // payout (token hook or Vault side effects) observes a consistent queue
            r.paid += pay;
            r.remaining -= pay;
            cfg.totalOutstanding -= pay;
            cfg.totalPaid += pay;
            paidTotal += pay;
            processed += 1;
            cash -= pay;

            if(r.remaining == 0) {
                r.status = STATUS_CLEARED;
                cfg.openCount -= 1;
            } else {
                r.status = STATUS_PARTIAL;
            }

            // Pay the creditor through Vault.transferOut (decreases the pool balance)
            IVault(vault).transferOut(targetToken, usdt, r.account, pay);

            emit Repaid(
                targetToken, id, r.account, r.collateralToken,
                pay, r.paid, r.remaining, r.status
            );

            if(r.remaining == 0) {
                // Fully paid -> continue with the next record
                id++;
                continue;
            }

            // Head record is not fully paid -> stop here, never skip it.
            // processedID marks the last FULLY handled id and the next batch starts at
            // processedID + 1, so it must stay at id - 1: writing `id` here would advance the
            // start past this record and the remaining debt could never be paid.
            processedID[targetToken] = id - 1;
            emit QueueSettled(targetToken, processed, paidTotal, id, cfg.totalOutstanding);
            return (processed, paidTotal);
        }

        // id has already moved past the last record handled by the loop (either because it was
        // cleared and incremented, or because it stopped on an unpaid one), so the last handled
        // position is id - 1. Writing it once here avoids one SSTORE per record; skipping it
        // would not duplicate payments (cleared records are skipped) but would rescan the whole
        // processed prefix on every batch and in getHeadId.
        processedID[targetToken] = id - 1;

        if(cfg.openCount == 0 && cfg.totalOutstanding == 0) {
            emit QueueCleared(targetToken, cfg.totalPaid);
        }
        emit QueueSettled(targetToken, processed, paidTotal, processedID[targetToken], cfg.totalOutstanding);
    }

    // ==================== Idle fund transfers (onlyWithdrawer) ====================

    /// @notice Transfer idle pool funds to the treasury (withdrawer only)
    /// @dev MUST be called in a standalone transaction, never from inside a Vault call:
    ///      Vault.transferOut is nonReentrant and the whole call would revert otherwise.
    ///      Transferable cap = poolAmounts - minReserve[targetToken] - totalOutstanding, so the
    ///      reserve and any unpaid queue debt are preserved. Reverts on zero amount, no excess,
    ///      or an amount above the cap.
    /// @param _indexToken Main-pool index token
    /// @param _amount Amount to transfer (collateral token units, = poolAmounts unit)
    function withdrawExcess(address _indexToken, uint256 _amount) external onlyWithdrawer {
        if(_amount == 0) revert("amount err");

        _transferExcess(_indexToken, _amount, false);
    }

    /// @notice Transfer every idle pool fund above the reserve and queue debt (withdrawer only)
    /// @dev Same constraints as withdrawExcess. After the call the pool balance equals
    ///      minReserve[targetToken] + totalOutstanding.
    /// @param _indexToken Main-pool index token
    /// @return amount Transferred amount (collateral token units, = poolAmounts unit)
    function withdrawAllExcess(address _indexToken) external onlyWithdrawer returns (uint256 amount) {
        (, amount) = _transferExcess(_indexToken, 0, true);
    }

    /// @dev Shared implementation of the idle-fund transfer: resolve the main pool, cap the amount
    ///      by (poolAmounts - reserve - queue debt), move the funds to the treasury and emit.
    ///      NOTE: this contract cannot read Vault's reserved amounts (open-position margin), so the
    ///      cap only protects the reserve and the queue. Keep minReserve large enough to cover the
    ///      outstanding position margin, otherwise a later profit settlement may revert when the
    ///      Vault deducts the pool.
    /// @param _indexToken Main-pool index token
    /// @param _amount Requested amount (ignored when _all is true)
    /// @param _all True = transfer the whole excess instead of _amount
    /// @return targetToken Resolved main-pool targetToken
    /// @return amount Transferred amount (collateral token units, = poolAmounts unit)
    function _transferExcess(address _indexToken, uint256 _amount, bool _all)
        internal
        returns (address targetToken, uint256 amount)
    {
        targetToken = _mainPoolTarget(_indexToken);
        if(targetToken == address(0)) revert("targetToken err");

        // The withdrawal lowers the water level, so persist the peak first
        _syncHighWatermark(targetToken);

        (uint256 cash, uint256 locked) = _poolSnapshot(targetToken);
        if(cash <= locked) revert("no excess");

        uint256 excess = cash - locked;
        amount = _all ? excess : _amount;
        if(amount > excess) revert("excess err");

        IVault(vault).transferOut(targetToken, usdt, treasury, amount);

        emit ExcessWithdrawn(targetToken, treasury, amount, cash - amount);
    }

    /// @dev Pool cash and the amount locked by the reserve plus the unpaid queue debt
    /// @param targetToken Main-pool targetToken
    /// @return cash Current pool balance (collateral token units, = poolAmounts unit)
    /// @return locked Reserve (USDT 6 decimals) + unpaid queue debt (collateral token units)
    function _poolSnapshot(address targetToken) internal view returns (uint256 cash, uint256 locked) {
        cash = IVault(vault).poolAmounts(targetToken, usdt);
        // Neither the minimum reserve nor the unpaid queue debt may be transferred out.
        // minReserve is stored in USDT 6 decimals while the queue debt uses the collateral token's
        // units; main pools are USDT-collateralised, so the two are numerically identical. If a
        // non-6-decimal collateral is ever enabled here, minReserve must be converted as well.
        locked = minReserve[targetToken] + queueConfigs[targetToken].totalOutstanding;
    }

    // ==================== Views ====================

    /// @notice Unpaid queue debt
    /// @param _targetToken Main-pool targetToken
    /// @return Sum of the remaining debt of every open queue record (collateral token units, the
    ///         same unit as Vault.poolAmounts; numerically 6 decimals for USDT collateral)
    function getOutstanding(address _targetToken) public view returns(uint256) {
        return queueConfigs[_targetToken].totalOutstanding;
    }

    /// @notice Idle funds currently transferable to the treasury
    /// @dev Amount = poolAmounts[targetToken][usdt] - minReserve[targetToken] - totalOutstanding,
    ///      i.e. exactly what withdrawExcess / withdrawAllExcess may move out. Returns 0 for a
    ///      non-main pool, or when the pool does not exceed the reserve plus unpaid queue debt.
    ///      Read-only helper, never emits NonMainPoolSkipped.
    /// @param _indexToken Main-pool index token
    /// @return amount Transferable amount (collateral token units, = poolAmounts unit)
    function getWithdrawableAmount(address _indexToken) external view returns (uint256 amount) {
        if(_getCoinType(_indexToken) != 1) return 0;

        address targetToken = IDataReader(dataReader).getTargetIndexToken(_indexToken);
        (uint256 cash, uint256 locked) = _poolSnapshot(targetToken);
        if(cash <= locked) return 0;

        return cash - locked;
    }

    /// @notice Current water level (may be negative) = pool balance - queue debt
    /// @dev Read live on every call; nothing is stored. A negative value means the unpaid queue
    ///      debt exceeds the pool balance, which puts the curve in the underwater zone.
    /// @param _targetToken Main-pool targetToken
    /// @return Water level, signed: poolAmounts - unpaid queue debt. Both terms use the collateral
    ///         token's units, which equal USDT 6 decimals for the (USDT-collateralised) main pools
    ///         and therefore compare directly with threshold / decayS
    function getTrackedLp(address _targetToken) public view returns(int256) {
        uint256 cash = IVault(vault).poolAmounts(_targetToken, usdt);
        return int256(cash) - int256(queueConfigs[_targetToken].totalOutstanding);
    }

    /// @notice Current payout rate (integer DER per USDT); returns 0 when the curve is not configured
    /// @dev This is the MARGINAL rate at the current water level, computed with the effective H
    ///      (stored H aligned with the current level), so fees / funding that raised the level
    ///      after the last report already lower it. A single report that crosses the threshold is
    ///      split into segments by `_computeMint`, so its average rate can be higher than this
    ///      value when the level sits just below the threshold.
    /// @dev This is the CURVE rate, not a promise of a payout: it keeps answering while mining is
    ///      disabled so the curve stays observable, but nothing is minted then. Callers MUST also
    ///      read miningEnabled() (the global bool getter) before presenting it as a reward.
    /// @param _targetToken Main-pool targetToken
    /// @return rate Underwater / flat rate, or flatRate * (S / (S + H))^2 * D in the ratchet zone
    function getCurrentRate(address _targetToken) public view returns(uint256 rate) {
        CurveParams memory c = curveParams[_targetToken];
        // setCurveParams enforces decayS > 0, so decayS == 0 means the pool is not configured yet
        if(c.decayS == 0) return 0;

        int256 lp = getTrackedLp(_targetToken);
        if(lp < 0) return c.underwaterRate;                  // Underwater zone
        if(lp < int256(c.threshold)) return c.flatRate;      // Flat zone

        // Ratchet zone: uses the effective H (stored H aligned with the current level)
        uint256 h = _effectiveHighWatermark(lp, highWatermark[_targetToken], c);

        // Apply the same decay factor _computeMint applies, otherwise this view would report a rate
        // 1/D too high in the ratchet zone and disagree with what a close actually pays out
        rate = _rateWad(h, c) * getDecayFactor(_targetToken) / 1e18 / 1e18;
    }

    /// @notice Water level, effective H, marginal rate and zone in a single call
    /// @dev Dashboard entry point: saves several eth_call round trips and keeps every figure on
    ///      the same effective-H definition that `_mint` uses. `effectiveH` is
    ///      max(stored H, water level - threshold), so it already reflects fees / funding that
    ///      arrived after the last report; use the `highWatermark()` getter for the persisted value.
    /// @param _targetToken Main-pool targetToken
    /// @return lp Current water level (signed, USDT 6 decimals)
    /// @return effectiveH Effective high watermark (0 when the curve is unconfigured)
    /// @return rate Marginal payout rate at the current level (DER per USDT, includes D; 0 when
    ///         unconfigured)
    /// @return zone 0 underwater / 1 flat / 2 ratchet (0 when unconfigured)
    function getWaterLevelSnapshot(address _targetToken)
        external
        view
        returns (int256 lp, uint256 effectiveH, uint256 rate, uint8 zone)
    {
        CurveParams memory c = curveParams[_targetToken];
        lp = getTrackedLp(_targetToken);                 // single poolAmounts call

        if(c.threshold == 0 || c.decayS == 0) {
            return (lp, 0, 0, ZONE_UNDERWATER);
        }

        effectiveH = _effectiveHighWatermark(lp, highWatermark[_targetToken], c);
        zone = _zoneOf(lp, c.threshold);

        if(zone == ZONE_UNDERWATER) {
            rate = c.underwaterRate;
        } else if(zone == ZONE_FLAT) {
            rate = c.flatRate;
        } else {
            // Ratchet zone: the decay factor D applies here too, so the snapshot agrees with
            // getCurrentRate and with what a close actually pays out
            rate = _rateWad(effectiveH, c) * getDecayFactor(_targetToken) / 1e18 / 1e18;
        }
    }

    /// @notice Preview the DER payout of a close before it is submitted (loss branch only)
    /// @dev Mirrors the loss branch of `recordPnl` step for step, including the price source:
    ///      1. exit price from the SAME helper the Vault settles with (getDecreaseSlipPrice), so
    ///         slippage is included exactly as it will be at execution
    ///      2. delta from the SAME Phase.getDeltaFor call `recordPnl` uses, scaled by
    ///         `_sizeDelta / size`; a favourable move returns 0
    ///      3. mint base = that realised loss, capped by the remaining collateral
    ///      4. the curve, the stored H and the decay factor are read for the SAME targetToken the
    ///         report will use (resolved through IDataReader.getTargetIndexToken), not for a fixed
    ///         usdt, so the preview cannot describe a different curve than the one that prices it
    ///      5. payout = _computeMint(mint base, current level, effective H, decay factor)
    ///      Read-only: nothing is stored and no DER is moved.
    ///      While mining is OFF, `payout` (and the `rate` derived from it) is reported as 0, because
    ///      nothing will actually be minted, and `p.miningEnabled` is false. The other figures
    ///      (realised loss, mint base, level, effective H, zone) stay valid: they describe the
    ///      position, not the reward. Integrators should check `p.miningEnabled` before showing a
    ///      payout at all.
    ///      WARNING: this is an ESTIMATE taken at the moment of the call. The actual payout is
    ///      priced at execution time, using the price and the pool level that exist in the block
    ///      where the close is settled, so the minted amount can differ. Integrators must present
    ///      it as a preview ("subject to the execution price"), never as a guaranteed payout.
    /// @param _indexToken Index token of the position
    /// @param _collateralToken Collateral token
    /// @param _account Position owner
    /// @param _isLong true for a long position
    /// @param _sizeDelta Size to close (USD 30 decimals); clamped to the position size
    /// @return p Estimated loss, mint base, rate, payout, level, zone and the mining flag. All zero
    ///         when the pool is unconfigured, the position does not exist or the price moved in
    ///         favour; when mining is merely disabled only `payout` and `rate` are 0 (and
    ///         `miningEnabled` is false)
    function previewClose(
        address _indexToken,
        address _collateralToken,
        address _account,
        bool _isLong,
        uint256 _sizeDelta
    ) external view returns (LossPreview memory p) {
        // Set first so every early return below reports the real switch state, not the zero default
        p.miningEnabled = miningEnabled;

        if(_getCoinType(_indexToken) != 1 || _sizeDelta == 0) return p;

        // Resolve the pool target exactly like _mint does (via the Vault's report) instead of
        // assuming usdt. They agree for the current main pools, but the curve / watermark / decay
        // factor are all keyed by targetToken, so the preview must read the same keys as the report
        // or it could describe a different curve than the one that will price the close.
        // _mainPoolTarget is not used here: it emits NonMainPoolSkipped and this function is view.
        address targetToken = IDataReader(dataReader).getTargetIndexToken(_indexToken);

        CurveParams memory c = curveParams[targetToken];
        if(c.threshold == 0 || c.decayS == 0) return p;

        IEventStruct.Position memory pos = IVault(vault).getPositionFrom(
            IVault(vault).getPositionKey(_account, _collateralToken, _indexToken, _isLong)
        );
        if(pos.size == 0) return p;
        if(_sizeDelta > pos.size) _sizeDelta = pos.size;

        // Same price the Vault will settle at: slippage included
        (, uint256 exitPrice,) = ISlippage(IVault(vault).slippage()).getDecreaseSlipPrice(
            _indexToken, _sizeDelta, _isLong
        );

        // Same delta source as _pnlDelta, so the direction and the amount match the report
        (bool hasProfit, uint256 delta) = IPhase(IVault(vault).phase()).getDeltaFor(
            _indexToken, pos.size, pos.averagePrice, _isLong, pos.lastIncreasedTime, exitPrice
        );
        if(hasProfit) return p;

        p.realisedLoss = _sizeDelta * delta / pos.size / USD_DECIMALS_TO_6;

        // The Vault cannot report a delta larger than the remaining collateral
        uint256 collateral6 = pos.collateral / USD_DECIMALS_TO_6;
        if(p.realisedLoss > collateral6) p.realisedLoss = collateral6;
        if(p.realisedLoss == 0) return p;

        p.mintBase = p.realisedLoss;

        // Nothing is booked yet, so the pre-settlement level is the current level
        p.lpBefore = getTrackedLp(targetToken);
        p.hBefore = _effectiveHighWatermark(p.lpBefore, highWatermark[targetToken], c);
        p.zone = _zoneOf(p.lpBefore, c.threshold);
        p.payout = _computeMint(p.mintBase, p.lpBefore, p.hBefore, c, getDecayFactor(targetToken));

        // Mining off: nothing is actually minted, so the payout is reported as zero while the other
        // figures stay valid (they describe the position, not the reward)
        if(!miningEnabled) p.payout = 0;

        // Derived from the reported payout, so it is 0 whenever nothing would be minted
        p.rate = p.payout / (p.mintBase * DER_SCALE);
        // The payout above is what the curve allows; the transfer is capped by whichever is smaller,
        // the source balance or the allowance this contract was granted
        p.availableDer = _availableDer();
    }

    /// @notice Persist the current peak water level as the high watermark
    /// @dev Called by the Vault through VaultUtils on every pool-amount change, so a peak that is
    ///      later lowered (profit payout, queue debt, operator withdrawal) is never lost.
    ///      `_updateHighWatermark` is monotonic, therefore redundant calls are harmless and
    ///      repeated hits cost only a comparison plus one SLOAD.
    ///      Writes storage only: it never moves funds, so it is safe inside the Vault's
    ///      nonReentrant context.
    ///      Only the watermark update is skipped for non-main pools and unconfigured curves; the
    ///      resolved targetToken is always returned so the caller can price the pool either way.
    /// @param _indexToken Index token of the pool whose accounting changed
    /// @return targetToken Main-pool targetToken resolved from `_indexToken`
    function syncTrackedLp(address _indexToken) external onlyRecorder returns(address) {
        address targetToken = IDataReader(dataReader).getTargetIndexToken(_indexToken);
        // Cheap coin-type check (does not emit NonMainPoolSkipped for every transfer)
        if(_getCoinType(_indexToken) != 1) return targetToken;

        // Freeze the peak while mining is off.
        if(!miningEnabled) return targetToken;

        CurveParams memory c = curveParams[targetToken];
        if(c.threshold == 0 || c.decayS == 0) return targetToken;

        _updateHighWatermark(targetToken, getTrackedLp(targetToken), highWatermark[targetToken], c);
        return targetToken;
    }

    /// @notice Curve parameters of a pool
    /// @param _targetToken Main-pool targetToken
    /// @return Configured curve; all fields are zero when the pool was never configured
    function getCurveParams(address _targetToken) external view returns(CurveParams memory) {
        return curveParams[_targetToken];
    }

    /// @notice Current zone, determined by the current water level
    /// @dev Returns 0 when the curve is not configured (same value as underwater); callers can
    ///      cross-check with getCurrentRate, which returns 0 for unconfigured pools.
    /// @param _targetToken Main-pool targetToken
    /// @return 0 underwater or unconfigured / 1 flat / 2 ratchet
    function getZone(address _targetToken) external view returns(uint8) {
        CurveParams memory c = curveParams[_targetToken];
        if(c.decayS == 0) return ZONE_UNDERWATER;

        return _zoneOf(getTrackedLp(_targetToken), c.threshold);
    }

    /// @notice Queue summary
    /// @param _targetToken Main-pool targetToken
    /// @return openCount, outstanding debt, cumulative queued and cumulative paid
    function getQueueConfig(address _targetToken) external view returns(QueueConfig memory) {
        return queueConfigs[_targetToken];
    }

    /// @notice Single queue record
    /// @param _targetToken Main-pool targetToken
    /// @param _id Queue id (1-based)
    /// @return Record; every field is zero when the id does not exist (status == STATUS_NONE)
    function getQueueRecord(address _targetToken, uint256 _id) external view returns(QueueRecord memory) {
        return queueRecords[_targetToken][_id];
    }

    /// @notice Current queue head (returns an empty struct when openCount == 0)
    /// @param _targetToken Main-pool targetToken
    /// @return First record whose status is PENDING or PARTIAL, or an all-zero struct when the
    ///         queue is empty (status == STATUS_NONE)
    function getHead(address _targetToken) external view returns(QueueRecord memory) {
        uint256 id = getHeadId(_targetToken);
        if(id == 0) return QueueRecord(0, address(0), bytes32(0), address(0), address(0), false, 0, 0, 0, 0, STATUS_NONE);
        return queueRecords[_targetToken][id];
    }

    /// @notice Current head id (0 = empty queue)
    /// @dev Scans from processedID + 1 and skips cleared / unused ids, so it stays O(1) while
    ///      settlement keeps processedID in step with the paid records.
    /// @param _targetToken Main-pool targetToken
    /// @return Head id, or 0 when openCount == 0 or no PENDING / PARTIAL record is left
    function getHeadId(address _targetToken) public view returns(uint256) {
        QueueConfig memory cfg = queueConfigs[_targetToken];
        if(cfg.openCount == 0) return 0;

        uint256 id = processedID[_targetToken] + 1;
        uint256 lastId = queueID[_targetToken];
        while(id <= lastId) {
            QueueRecord memory r = queueRecords[_targetToken][id];
            if(r.status == STATUS_PENDING || r.status == STATUS_PARTIAL) {
                return id;
            }
            id++;
        }
        return 0;
    }

    /// @notice Paginated query over an id range
    /// @dev _limit is clamped to the remaining ids, so a very large value cannot overflow.
    /// @param _targetToken Main-pool targetToken
    /// @param _fromId First id to include (1-based)
    /// @param _limit Maximum number of records returned
    /// @return list Records in [fromId, min(fromId + limit - 1, lastId)]; empty for an invalid range
    function getQueueRecords(address _targetToken, uint256 _fromId, uint256 _limit)
        external
        view
        returns (QueueRecord[] memory list)
    {
        uint256 lastId = queueID[_targetToken];
        if(_fromId == 0 || _fromId > lastId || _limit == 0) return new QueueRecord[](0);

        // Clamp first so that _fromId + _limit - 1 cannot overflow for a huge limit
        uint256 maxLen = lastId - _fromId + 1;
        if(_limit > maxLen) _limit = maxLen;

        list = new QueueRecord[](_limit);
        for(uint256 i = 0; i < _limit; i++) {
            list[i] = queueRecords[_targetToken][_fromId + i];
        }
    }

    // ==================== Internal helpers ====================

    /// @dev Enqueue a record at the tail (auto-increment id)
    /// @param _targetToken Main-pool targetToken
    /// @param _account Creditor
    /// @param _positionKey Source position identifier
    /// @param _collateralToken Debt token
    /// @param _debtAmount Debt amount (collateral token units, the same unit as poolAmounts)
    /// @return id New queue id
    function _enqueue(
        address _targetToken,
        address _account,
        bytes32 _positionKey,
        address _indexToken,
        address _collateralToken,
        bool _isLong,
        uint256 _debtAmount
    ) internal returns (uint256 id) {
        id = queueID[_targetToken] + 1;
        queueID[_targetToken] = id;

        QueueRecord memory r;
        r.id = id;
        r.account = _account;
        r.positionKey = _positionKey;
        r.indexToken = _indexToken;
        r.collateralToken = _collateralToken;
        r.isLong = _isLong;
        r.originalDebt = _debtAmount;
        r.remaining = _debtAmount;
        r.enqueuedAt = block.timestamp;
        r.status = STATUS_PENDING;
        queueRecords[_targetToken][id] = r;

        QueueConfig storage cfg = queueConfigs[_targetToken];
        cfg.openCount += 1;
        cfg.totalOutstanding += _debtAmount;
        cfg.totalQueued += _debtAmount;

        emit Enqueued(_targetToken, r);
    }

    /// @dev Coin type as registered in CoinData (1 = main pool)
    /// @param _token Index token
    /// @return Coin type
    function _getCoinType(address _token) internal view returns(uint8) {
        return ICoinData(IDataReader(dataReader).coinData()).getCoinType(_token);
    }

    /// @dev Resolve the main-pool targetToken; non-main pools emit NonMainPoolSkipped
    /// @param _indexToken Index token
    /// @return targetToken Main-pool target, or address(0) when the pool is not a main pool
    function _mainPoolTarget(address _indexToken) internal returns(address) {
        uint8 coinType = _getCoinType(_indexToken);
        if(coinType != 1) {
            emit NonMainPoolSkipped(msg.sender, _indexToken, coinType);
            return address(0);
        }
        return IDataReader(dataReader).getTargetIndexToken(_indexToken);
    }

    /// @dev Determine the zone from the water level
    /// @param _lp Water level (USDT 6 decimals, signed)
    /// @param _threshold Ratchet threshold (USDT 6 decimals)
    /// @return 0 underwater / 1 flat / 2 ratchet
    function _zoneOf(int256 _lp, uint256 _threshold) internal pure returns(uint8) {
        if(_lp < 0) return ZONE_UNDERWATER;
        if(uint256(_lp) < _threshold) return ZONE_FLAT;
        return ZONE_RATCHET;
    }

    /// @dev Rate for the given H (1e18 fixed point, DER per USDT): flatRate * (S / (S + H))^2
    /// @param _h High watermark driving the decay (USDT 6 decimals)
    /// @param c Curve parameters
    /// @return Rate scaled by 1e18; divide by 1e18 for the integer DER/USDT value
    function _rateWad(uint256 _h, CurveParams memory c) internal pure returns(uint256) {
        uint256 den = c.decayS + _h;
        return c.flatRate * c.decayS * c.decayS * 1e18 / (den * den);
    }

    /// @dev Compute the payout amount using the pre-settlement water level and pre-settlement H;
    ///      crossing the threshold is split into segments. The ratchet segment alone is scaled by
    ///      the decay factor D, so the underwater and flat segments keep paying their full rate
    /// @param _mintBase Payout base (USDT 6 decimals)
    /// @param _lpBefore Pre-settlement water level (signed, collateral token units)
    /// @param _hBefore Pre-settlement high watermark (collateral token units)
    /// @param c Curve parameters of the pool
    /// @param _decayFactor Ratchet decay factor D (WAD, 1e18 = no decay)
    /// @return payout Computed payout (DER 18 decimals), before the DER balance cap
    function _computeMint(
        uint256 _mintBase,
        int256 _lpBefore,
        uint256 _hBefore,
        CurveParams memory c,
        uint256 _decayFactor
    ) internal pure returns(uint256 payout) {
        uint256 remaining = _mintBase;
        int256 lp = _lpBefore;

        // 1) Underwater segment (trackedLp < 0): the part bringing the level to 0 uses underwaterRate
        if(lp < 0 && remaining > 0) {
            uint256 span = uint256(-lp);
            uint256 part = remaining < span ? remaining : span;
            payout += part * c.underwaterRate * DER_SCALE;
            remaining -= part;
            lp += int256(part);
        }

        // 2) Flat segment (0 <= trackedLp < threshold): uses flatRate
        if(remaining > 0 && lp < int256(c.threshold)) {
            uint256 span = uint256(int256(c.threshold) - lp);
            uint256 part = remaining < span ? remaining : span;
            payout += part * c.flatRate * DER_SCALE;
            remaining -= part;
        }

        // 3) Ratchet segment (>= threshold): rate based on the pre-settlement H, scaled by the
        //    decay factor D (WAD). D is a plain multiplier on this segment only: the underwater
        //    and flat segments above are untouched.
        //    D is folded into the rate BEFORE scaling by the base. Applying it afterwards would
        //    add an extra 1e18 to the intermediate (the final figure fits either way, but this
        //    order keeps the widest headroom and truncates exactly the same amount)
        if(remaining > 0) {
            uint256 decayedRateWad = _rateWad(_hBefore, c) * _decayFactor / 1e18;
            payout += remaining * decayedRateWad / 1e18 * DER_SCALE;
        }
    }

    /// @dev Blacklist verdict for a payout, from the system contract
    /// @dev Fail-CLOSED on the payout, but never blocking the close: the DER is only sent when both
    ///      sides answered AND neither is flagged. An unreachable, upgraded or mis-addressed
    ///      contract withholds the reward instead of bypassing the check, and since withholding
    ///      means "transfer nothing" it needs no revert, so the close always completes.
    ///      A low-level staticcall is used instead of try/catch: try/catch does NOT cover a return
    ///      data decoding failure, so an address without code would revert the whole close.
    /// @param _account Trader address
    /// @return blocked true = do NOT pay (flagged, or the answer is unusable)
    /// @return answered false = at least one side could not give a usable answer
    function _blacklistQuery(address _account) internal view returns (bool blocked, bool answered) {
        (bool toBlocked, bool toAnswered) = _blacklistFlagged(
            abi.encodeWithSelector(IChainBlacklist.isBlacklistTxTo.selector, _account)
        );
        // Short-circuit: once the payout is blocked there is no need to ask the other side
        if(toBlocked) return (true, toAnswered);

        (bool fromBlocked, bool fromAnswered) = _blacklistFlagged(
            abi.encodeWithSelector(IChainBlacklist.isBlacklistTxFrom.selector, _account)
        );
        if(fromBlocked) return (true, fromAnswered);

        // Clean only when BOTH answers were usable
        return (false, toAnswered && fromAnswered);
    }

    /// @dev Single blacklist query. Fail-CLOSED on the payout side but never reverting: a query
    ///      that cannot be answered withholds the DER instead of bypassing the check, yet it still
    ///      lets the close go through (nothing is transferred, so no revert is needed).
    /// @param _data Pre-encoded call to the blacklist contract
    /// @return flagged true = do NOT pay (flagged, or the answer is unusable)
    /// @return answered false = the contract could not give a usable answer
    function _blacklistFlagged(bytes memory _data) internal view returns (bool flagged, bool answered) {
        (bool ok, bytes memory ret) = BLACKLIST.staticcall(_data);
        // ok == false: reverted. ret.length < 32: no code at the address, or a short answer
        if(!ok || ret.length < 32) return (true, false);

        // Read the raw word instead of abi.decode(ret, (bool)): decode reverts on any value other
        // than 0/1, which would fail the whole close on a malformed or upgraded answer
        uint256 value;
        assembly {
            value := mload(add(ret, 32))
        }

        return (value != 0, true);
    }

    /// @dev DER this contract can actually pull from derSource right now
    /// @return available min(balance held by derSource, allowance granted to this contract)
    function _availableDer() internal view returns (uint256 available) {
        available = IERC20(derToken).balanceOf(derSource);
        uint256 allowance_ = IERC20(derToken).allowance(derSource, address(this));
        if(available > allowance_) available = allowance_;
    }

    /// @dev Pay out DER and update H, then emit the record. Returns immediately (no transfer, no
    ///      event) while mining is disabled, so the switch is invisible on chain
    /// @param _req Payout request (target token, receiver, position, payout base, pool credit and
    ///        the liquidation flag)
    function _mint(MintRequest memory _req) internal {
        // Mining switch: OFF by default. Stop before any calculation, transfer or event, so a
        // disabled switch is invisible on chain: no MintRecorded, no CurveNotSet, no
        // DerPayoutSkipped.
        if(!miningEnabled) return;

        address targetToken = _req.targetToken;
        CurveParams memory c = curveParams[targetToken];
        // Mining is an add-on incentive: an unconfigured curve must never block a close or a
        // liquidation. Emit and skip instead of reverting.
        if(c.flatRate == 0) {
            emit CurveNotSet(targetToken);
            return;
        }

        // The Vault always reports BEFORE crediting the pool, so the credit is still
        // pending for both paths and only shifts the post-settlement level:
        //   lpBefore = current, lpAfter = current + poolCredit
        int256 lpNow = getTrackedLp(targetToken);
        int256 lpCredit = int256(_req.poolCredit);
        int256 lpBefore = lpNow;
        int256 lpAfter = lpNow + lpCredit;

        // PRD 2.1: H must follow every trackedLp change. Sync it with the pre-settlement level
        // first (fees / funding may have pushed the level up since the last report), use the
        // synced value for the rate, then raise it again from the post-settlement level.
        uint256 hBefore = _updateHighWatermark(targetToken, lpBefore, highWatermark[targetToken], c);

        uint256 payout = _computeMint(_req.mintBase, lpBefore, hBefore, c, getDecayFactor(targetToken));

        // Actual payout: pulled from the funding source with safeTransferFrom. This contract does
        // not hold DER, so the source must both hold the tokens AND approve this contract.
        // All-or-nothing by design: the trader either receives the full payout or nothing at all.
        // A partial transfer is never sent, because a dust amount is worse than a clean skip for
        // both accounting and the trader.
        // The blacklist is fail-CLOSED on the payout: only an answered-and-clean verdict pays out.
        // A flagged account OR an unusable answer withholds the DER, and the reason tells the two
        // apart. Withholding never reverts, so the close always goes through.
        uint256 actual;
        if(payout > 0) {
            (bool blocked, bool answered) = _blacklistQuery(_req.account);

            if(blocked) {
                emit DerPayoutSkipped(
                    _req.account, payout,
                    answered ? SKIP_BLACKLISTED : SKIP_BLACKLIST_UNAVAILABLE
                );
            } else if(_availableDer() < payout) {
                emit DerPayoutSkipped(_req.account, payout, SKIP_INSUFFICIENT_DER);
            } else {
                actual = payout;
                IERC20(derToken).safeTransferFrom(derSource, _req.account, actual);
            }
        }

        // Raise the high watermark from the post-settlement level (monotonic)
        uint256 hAfter = _updateHighWatermark(targetToken, lpAfter, hBefore, c);

        MintRecord memory r;
        r.account = _req.account;
        r.positionKey = _req.positionKey;
        r.collateralToken = _req.collateralToken;
        r.realisedLoss = _req.realisedLoss;
        r.mintBase = _req.mintBase;
        r.minted = actual;
        r.shortfall = payout - actual;
        r.trackedLpBefore = lpBefore;
        r.trackedLpAfter = lpAfter;
        r.hBefore = hBefore;
        r.hAfter = hAfter;
        // Curve payout per unit of base (DER per USDT): with several segments the average is
        // weighted by the segment amounts; a DER balance cap is not reflected here.
        // `rate` keeps the legacy integer value (truncated, convenient for magnitude checks);
        // `rateWad` carries the same figure with 1e18 precision so the payout can be reconciled
        // exactly: mintBase * rateWad / 1e18 * DER_SCALE == payout.
        r.rate = _req.mintBase > 0 ? payout / (_req.mintBase * DER_SCALE) : 0;
        r.rateWad = _req.mintBase > 0 ? payout * 1e18 / (_req.mintBase * DER_SCALE) : 0;
        r.zone = _zoneOf(lpBefore, c.threshold);
        // Pure path flag for the event. The credit timing is NOT a discriminator any more: the
        // Vault reports before crediting on both paths, so liquidation and loss close
        // only differ in the payout base, not in when the pool is credited.
        r.isLiquidation = _req.isLiquidation;

        emit MintRecorded(targetToken, r);
    }

    /// @dev Raise H from the current water level: H = max(H, trackedLp - threshold).
    ///      Used for bootstrapping after deployment / around the first curve configuration.
    ///      Skips silently while the curve is unconfigured.
    /// @param _targetToken Main-pool targetToken
    function _bootstrapHighWatermark(address _targetToken) internal {
        CurveParams memory c = curveParams[_targetToken];
        if(c.threshold == 0) return;   // not configured yet

        _updateHighWatermark(_targetToken, getTrackedLp(_targetToken), highWatermark[_targetToken], c);
    }

    /// @dev Persist the current peak as H (no-op when the curve is unconfigured)
    /// @param _targetToken Main-pool targetToken
    function _syncHighWatermark(address _targetToken) internal {
        CurveParams memory c = curveParams[_targetToken];
        if(c.threshold == 0 || c.decayS == 0) return;
        _updateHighWatermark(_targetToken, getTrackedLp(_targetToken), highWatermark[_targetToken], c);
    }

    /// @dev Update the high watermark: H = max(H, trackedLp - threshold), monotonic
    /// @dev Freezes while mining is off. The check lives here, on the single write path, rather than
    ///      only in syncTrackedLp: profit payouts, excess sweeps and governance re-config all reach
    ///      this function directly, and any of them would otherwise record a peak during the pause
    /// @param _hBefore Stored H already loaded by the caller (avoids a duplicate SLOAD)
    function _updateHighWatermark(address _targetToken, int256 _lp, uint256 _hBefore, CurveParams memory c)
        internal
        returns (uint256 h)
    {
        if(!miningEnabled) return _hBefore;

        h = _effectiveHighWatermark(_lp, _hBefore, c);
        if(h != _hBefore) {
            highWatermark[_targetToken] = h;
        }
    }

    /// @dev Effective H = max(hStart, lp - threshold), pure helper shared by the storage update,
    ///      the rate math and the views so their definitions cannot drift apart.
    /// @param _lp Water level the rate is evaluated at
    /// @param _hStart Stored H already loaded by the caller
    /// @return h Effective high watermark
    function _effectiveHighWatermark(int256 _lp, uint256 _hStart, CurveParams memory c)
        internal
        pure
        returns (uint256 h)
    {
        h = _hStart;
        int256 x = _lp - int256(c.threshold);
        if(x > 0 && uint256(x) > h) h = uint256(x);
    }
}
