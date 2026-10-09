// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../core/interfaces/IVault.sol";
import "../core/interfaces/IDataReader.sol";
import "./interfaces/ISlippage.sol";
import "../core/interfaces/IPositionRouter.sol";
import "../core/interfaces/IOrderBook.sol";
import "../upgradeability/Synchron.sol";
import "../meme/interfaces/IMemeFactory.sol";
import "../meme/interfaces/IMemeData.sol";

contract SlippageControl is Synchron {

    // ============ Storage Variables ============

    /// @notice High-precision multiplier for slip / ratio calculations (1e8)
    uint256 public constant MUTI = 1e8;

    /// @notice Basis points divisor (10000 = 100%, 1 = 0.01%)
    uint256 public constant BASE_RATE_DIVISOR = 10000;

    /// @notice Default base cap rate when not explicitly configured (5% = 500 bp)
    uint256 public constant DEFAULT_BASE_CAP_RATE = 500;

    /// @notice Default impact factor (k) when not explicitly configured per collection
    /// @dev 5% = 500 basis points. Controls the overall slippage curve amplitude.
    uint256 public constant DEFAULT_IMPACT_FACTOR_K = 500;

    /// @notice Default exponent (n) controlling curve steepness per order size
    /// @dev n ∈ {1,2,3}: linear / quadratic / cubic curves. Larger orders face disproportionately higher slippage.
    uint256 public constant DEFAULT_EXPONENT_N = 2;

    /// @notice Default slip cap multiplier for finalSlipCap = multiplier × defaultBaseCapRate
    /// @dev 12000 basis points = 1.2x. Controls the scaling factor applied to base cap rate.
    uint256 public constant DEFAULT_SLIP_CAP_MULTIPLIER = 12000;

    /// @notice Default soft threshold rate for skew surcharge trigger
    /// @dev 5000 basis points = 50% of pool depth D. skewAfter must exceed Dusd × 50% to trigger surcharge.
    uint256 public constant DEFAULT_SOFT_THRESHOLD_RATE = 5000;

    /// @notice Global slip cap multiplier, overrides DEFAULT_SLIP_CAP_MULTIPLIER when set
    uint256 public slipCapMultiplier;

    /// @notice Maximum skew ratio for surcharge slope calculation (10000 = 1.0 in basis points)
    uint256 public maxSkewRatio;

    /// @notice Global discount factor for case ② skew relief: finalSlip = baseSlip × discountFactor (e.g. 6500 = 65% retained)
    uint256 public discountFactor;

    /// @notice Whether the contract has been initialized
    /// @dev Prevents re-initialization attacks on upgradeable pattern
    bool public initialized;

    /// @notice Address of the governance account
    /// @dev Only gov can call admin functions. Set during initialize()
    address public gov;

    /// @notice The vault contract for pool amount and position data
    IVault public vault;

    /// @notice DataReader contract for pool size / OI / average price data
    IDataReader public dataReader;

    /// @notice Slippage contract for rate computation (getRate) and decrease price passthrough
    ISlippage public slippage;

    /// @notice PositionRouter contract for reading the market-decrease cached price
    IPositionRouter public positionRouter;

    /// @notice OrderBook contract for reading the limit-decrease cached market price (no slippage)
    IOrderBook public orderBook;

    /// @notice Default slippage params by (poolTargetToken, memberTokenTargetID) — belongTo == 2
    mapping(address => mapping(uint256 => SlippageParams)) _defaultSlippageTargetIDParams;

    /// @notice Default slippage params by (poolTargetToken, indexToken address) — belongTo == 1
    mapping(address => mapping(address => SlippageParams)) _defaultSlippageSingleTokenParams;

    /// @notice Per-indexToken slippage params, overrides defaults when set (indexToken != address(0))
    mapping(address => IndexTokenSlippageParams) _indexTokenSlippageParams;

    /// @notice Struct for per-indexToken explicit slippage configuration
    struct IndexTokenSlippageParams {
        address indexToken;           // Target index token; when set (≠ address(0)), overrides default params
        uint256 baseCapRate;          // Base cap rate (basis points)
        uint256 impactFactorK;        // Impact factor k (basis points)
        uint256 exponentN;            // Exponent n
    }

    /// @notice Struct for default slippage params set per pool collection or single token
    struct SlippageParams {
        uint256 defaultBaseCapRate;          // Base cap rate (basis points)
        uint256 defaultImpactFactorK;        // Impact factor k (basis points)
        uint256 defaultExponentN;            // Exponent n
        uint256 defaultSoftThresholdRate;    // Skew surcharge trigger threshold (USD nominal)
        bool isSet;                          // Explicitly set flag; false = use global defaults
    }

    /// @notice Emitted when default slippage params are set for a pool collection or single token
    event SetDefaultSlippageParams(address poolTargetToken, address indexToken, uint256 memberTokenTargetID, uint8 belongTo, uint256 defaultBaseCapRate, uint256 defaultImpactFactorK, uint256 defaultExponentN, uint256 defaultSoftThresholdRate);

    /// @notice Emitted when per-indexToken slippage params are batch set
    event SetIndexTokenSlippageParams(address indexToken, uint256 baseCapRate, uint256 impactFactorK, uint256 exponentN);

    /// @notice Emitted when the global slip cap multiplier is updated
    event SetSlipCapMultiplier(uint256 multiplier);

    /// @notice Emitted when the global discount factor is updated
    event SetDiscountFactor(uint256 discountFactor);

    /// @notice Emitted when the max skew ratio is updated
    event SetMaxSkewRatio(uint256 maxSkewRatio);

    constructor() {
        initialized = true;
    }

    // ============ Modifiers ============

    /// @notice Restricts function access to governance only
    modifier onlyGov() {
        if(gov != msg.sender) revert();
        _;
    }

    // ============ Initialization ============

    /**
     * @notice Initialize the contract with caller as governance
     * @dev Called once during deployment via proxy pattern.
     *      Sets msg.sender as initial governance address.
     *      Contract addresses must be set separately via setContract().
     */
    function initialize() external {
        if(initialized) revert();
        initialized = true;
        gov = msg.sender;
        discountFactor = 6500; // 65% of baseSlip retained (PRD: finalSlip = baseSlip × 0.65)
        maxSkewRatio = 10000;
    }

    /// @notice Set the core contract addresses used by slip pricing
    /// @dev Only callable by governance. All addresses must be non-zero:
    ///      vault + dataReader — pool depth / OI / rate data;
    ///      slippage — getRate / getLongRate / getShortRate used by decrease pricing;
    ///      positionRouter + orderBook — request-scoped decrease price caches.
    function setContract(
        address _vault,
        address _dataReader,
        address _slippage,
        address _positionRouter,
        address _orderBook
    ) external onlyGov {
        if (
            _vault == address(0) ||
            _dataReader == address(0) ||
            _slippage == address(0) ||
            _positionRouter == address(0) ||
            _orderBook == address(0)
        ) revert("addr err");

        vault = IVault(_vault);
        dataReader = IDataReader(_dataReader);
        slippage = ISlippage(_slippage);
        positionRouter = IPositionRouter(_positionRouter);
        orderBook = IOrderBook(_orderBook);
    }

    /// @notice Transfer governance to a new account
    /// @dev Only callable by current governance. Non-zero address required.
    function setGov(address _account) external onlyGov {
        if(_account == address(0)) revert();
        gov = _account;
    }

    /// @notice Set default slippage parameters
    /// @dev Only callable by governance.
    ///      Primarily used to set default params for collections (belongTo == 2),
    ///      identified by memberTokenTargetID under the pool target token.
    ///      Also supports single-token mode (belongTo == 1), though generally not used —
    ///      per-token configuration is preferred via setIndexTokenSlippageParams.
    ///      Params are keyed by the input token itself (under its pool target token derived via
    ///      getTargetIndexToken), so a channel token gets its OWN default slot; when no channel-level
    ///      default is set, _getDefaultSlippageParams falls back to the main-pool default — meaning
    ///      channel tokens inherit the main-pool configuration unless configured separately.
    ///      Field validation:
    ///      - defaultBaseCapRate: caps Layer-1 baseSlip (baseSlip = min(k × ratioⁿ, baseCapRate)),
    ///        in basis points, range (0, 1000] i.e. ≤ 10%.
    ///      - defaultImpactFactorK: Layer-1 impact coefficient k (rawBaseSlip = k × ratioⁿ / DIVISOR),
    ///        in basis points, range (0, 1000] i.e. ≤ 10%.
    ///      - defaultExponentN: Layer-1 power exponent n, range [1, 3].
    ///      - defaultSoftThresholdRate: skew surcharge trigger threshold, in basis points,
    ///        range (0, BASE_RATE_DIVISOR].
    /// @param _indexToken Any token within the target pool/collection.
    ///      For collections, passing any member token resolves to the correct collection.
    ///      A channel token is stored under its own slot (keyed by the channel token itself) and
    ///      inherits the main-pool default only when it has no dedicated default set.
    /// @param _params The default slippage parameters to set
    function setDefaultSlippageParams(
        address _indexToken,
        SlippageParams calldata _params
    ) external onlyGov {
        address targetToken = dataReader.getTargetIndexToken(_indexToken);
        (, uint256 memberTokenTargetID, , uint8 belongTo) = dataReader.getTokenInfo(_indexToken);
        if(belongTo != 1 && belongTo != 2) revert("belongTo err");
        if(_params.defaultBaseCapRate == 0 || _params.defaultBaseCapRate > 1000) revert("defaultBaseCapRate err");  // defaultBaseCapRate ∈ (0, 1000]
        if(_params.defaultImpactFactorK == 0 || _params.defaultImpactFactorK > 1000) revert("defaultImpactFactorK err");  // defaultImpactFactorK ∈ (0, 1000]
        if(_params.defaultExponentN == 0 || _params.defaultExponentN > 3) revert("defaultExponentN err");  // defaultExponentN ∈ [1, 3]
        if(_params.defaultSoftThresholdRate == 0 || _params.defaultSoftThresholdRate > BASE_RATE_DIVISOR) revert("defaultSoftThresholdRate err");  // defaultSoftThresholdRate ∈ (0, BASE_RATE_DIVISOR]

        SlippageParams memory p = _params;
        p.isSet = true;
        if(belongTo == 2) {
            _defaultSlippageTargetIDParams[targetToken][memberTokenTargetID] = p;
        } else {
            _defaultSlippageSingleTokenParams[targetToken][_indexToken] = p;
        }
        emit SetDefaultSlippageParams(targetToken, _indexToken, memberTokenTargetID, belongTo, _params.defaultBaseCapRate, _params.defaultImpactFactorK, _params.defaultExponentN, _params.defaultSoftThresholdRate);
    }

    /// @notice Batch set per-token slippage parameters
    /// @dev Only callable by governance.
    ///      Once set, getIndexTokenSlippageParams returns these values instead of the defaults
    ///      from getDefaultSlippageParams. Does NOT fall back to defaults for any field.
    ///      Channel tokens: pass the channel token itself to store dedicated params under that
    ///      channel token; these then take priority over the main pool. Channel tokens without
    ///      dedicated params fall back to the main-pool / default params.
    ///      Field validation:
    ///      - indexToken must be non-zero.
    ///      - baseCapRate: caps Layer-1 baseSlip (baseSlip = min(k × ratioⁿ, baseCapRate)),
    ///        in basis points, range (0, 1000] i.e. ≤ 10%.
    ///      - impactFactorK: Layer-1 impact coefficient k (rawBaseSlip = k × ratioⁿ / DIVISOR),
    ///        in basis points, range (0, 1000] i.e. ≤ 10%.
    ///      - exponentN: Layer-1 power exponent n, range [1, 3].
    /// @param _params Array of IndexTokenSlippageParams to set
    function setIndexTokenSlippageParams(IndexTokenSlippageParams[] calldata _params) external onlyGov {
        uint256 len = _params.length;
        if(len == 0) revert("empty params");
        for (uint256 i = 0; i < len; i++) {
            IndexTokenSlippageParams calldata p = _params[i];
            // Validity check only: the token must resolve to a pool target token, otherwise DataReader
            // reverts with "_indexToken err" (this also rejects address(0)). The return value is unused.
            dataReader.getTargetIndexToken(p.indexToken);
            if(p.baseCapRate == 0 || p.baseCapRate > 1000) revert("baseCapRate err");  // baseCapRate ∈ (0, 1000]
            if(p.impactFactorK == 0 || p.impactFactorK > 1000) revert("impactFactorK err");  // impactFactorK ∈ (0, 1000]
            if(p.exponentN == 0 || p.exponentN > 3) revert("exponentN err");  // exponentN ∈ [1, 3]
            _indexTokenSlippageParams[p.indexToken] = p;
            emit SetIndexTokenSlippageParams(p.indexToken, p.baseCapRate, p.impactFactorK, p.exponentN);
        }
    }

    /// @notice Set the global slip cap multiplier used to compute finalSlipCap
    /// @dev finalSlipCap = slipCapMultiplier × baseCapRate / BASE_RATE_DIVISOR.
    ///      Only callable by governance. Value in basis points relative to baseCapRate,
    ///      range [BASE_RATE_DIVISOR, 20000], i.e. between 1.0× and 2.0× the base cap rate.
    ///      Passing 0 is rejected too; when the contract was never configured (storage 0),
    ///      getSlipCapMultiplierCache still falls back to DEFAULT_SLIP_CAP_MULTIPLIER (12000).
    /// @param _multiplier The multiplier in basis points (10000 ≤ _multiplier ≤ 20000)
    function setSlipCapMultiplier(uint256 _multiplier) external onlyGov {
        if(_multiplier < BASE_RATE_DIVISOR || _multiplier > 20000) revert("multiplier err");
        slipCapMultiplier = _multiplier;
        emit SetSlipCapMultiplier(_multiplier);
    }

    /// @notice Set the global discount factor: finalSlip = baseSlip × discountFactor
    /// @dev Only callable by governance. Represents the RETAINED fraction of baseSlip
    ///      after case ② skew relief (e.g. 6500 = 65% retained).
    ///      Must be > 0 and ≤ BASE_RATE_DIVISOR.
    /// @param _discountFactor Retained ratio in basis points
    function setDiscountFactor(uint256 _discountFactor) external onlyGov {
        if(_discountFactor == 0 || _discountFactor > BASE_RATE_DIVISOR) revert("discountFactor err");
        discountFactor = _discountFactor;
        emit SetDiscountFactor(_discountFactor);
    }

    /// @notice Set the max skew ratio for surcharge slope computation
    /// @dev Only callable by governance. Restricted to [BASE_RATE_DIVISOR (1.0), 20000 (2.0)].
    /// @param _maxSkewRatio The max skew ratio in basis points (10000 = 1.0, 20000 = 2.0)
    function setMaxSkewRatio(uint256 _maxSkewRatio) external onlyGov {
        if(_maxSkewRatio < BASE_RATE_DIVISOR || _maxSkewRatio > 20000) revert("maxSkewRatio err");
        maxSkewRatio = _maxSkewRatio;
        emit SetMaxSkewRatio(_maxSkewRatio);
    }

    /// @notice Get default slippage parameters resolved by belongTo (collection or single token)
    /// @param _indexToken The token to query: a channel token's own default wins when configured,
    ///        otherwise it falls back to the resolved main-pool default
    /// @return defaultBaseCapRate The base cap rate (basis points)
    /// @return defaultImpactFactorK The impact factor k (basis points)
    /// @return defaultExponentN The exponent n
    /// @return defaultSoftThresholdRate Skew surcharge trigger threshold (basis points)
    function getDefaultSlippageParams(address _indexToken)
        public view returns(uint256 defaultBaseCapRate, uint256 defaultImpactFactorK, uint256 defaultExponentN, uint256 defaultSoftThresholdRate)
    {
        (defaultBaseCapRate, defaultImpactFactorK, defaultExponentN, defaultSoftThresholdRate, ) = _getDefaultSlippageParams(_indexToken);
    }

    /// @notice Default slippage parameters for a token
    /// @dev    IMPORTANT: always pass the ORIGINAL token (a channel token or a main-pool token),
    ///         never a token that has already been resolved via getIndexToken — resolution happens
    ///         inside this function, and that is what keeps a channel token's own default reachable
    ///         (passing the resolved main-pool token would silently skip the channel level).
    ///         Resolution order:
    ///         1. Channel-level default: only when the input token resolves to a different index
    ///            token (i.e. it is a channel token) and a default is configured under the input
    ///            token itself, that value is returned.
    ///         2. Main-pool default: the default configured for the resolved index token's slot.
    ///         3. Global default constants (DEFAULT_*).
    ///      For a regular token steps 1 and 2 address the SAME slot, so it is read only once.
    /// @param _indexToken The token to resolve (a channel token or a main-pool token); it is
    ///        resolved internally via getIndexToken only to detect the channel case and to fall
    ///        back to the main pool
    /// @return defaultBaseCapRate The base cap rate (basis points)
    /// @return defaultImpactFactorK The impact factor k (basis points)
    /// @return defaultExponentN The exponent n
    /// @return defaultSoftThresholdRate Skew surcharge trigger threshold (basis points)
    /// @return channelDefaultSet True only when the input token is channel-mapped AND a default is
    ///         stored under the channel token itself; callers use it to give the channel level
    ///         priority over the main-pool per-token config
    function _getDefaultSlippageParams(address _indexToken)
        internal view returns(uint256 defaultBaseCapRate, uint256 defaultImpactFactorK, uint256 defaultExponentN, uint256 defaultSoftThresholdRate, bool channelDefaultSet)
    {
        address indexToken = dataReader.getIndexToken(_indexToken);
        (, uint256 memberTokenTargetID, , uint8 belongTo) = dataReader.getTokenInfo(_indexToken);

        // Slot keyed by the input token: for a channel token this is its own channel-level default,
        // for a regular token it is already the main-pool slot.
        SlippageParams memory p = _loadDefaultParams(dataReader.getTargetIndexToken(_indexToken), memberTokenTargetID, belongTo, _indexToken);

        if(indexToken != _indexToken) {
            // Channel token: a channel-level default wins, otherwise fall back to the main pool.
            if(p.isSet) {
                return (p.defaultBaseCapRate, p.defaultImpactFactorK, p.defaultExponentN, p.defaultSoftThresholdRate, true);
            }

            p = _loadDefaultParams(dataReader.getTargetIndexToken(indexToken), memberTokenTargetID, belongTo, indexToken);
        }

        defaultBaseCapRate = p.isSet ? p.defaultBaseCapRate : DEFAULT_BASE_CAP_RATE;
        defaultImpactFactorK = p.isSet ? p.defaultImpactFactorK : DEFAULT_IMPACT_FACTOR_K;
        defaultExponentN = p.isSet ? p.defaultExponentN : DEFAULT_EXPONENT_N;
        defaultSoftThresholdRate = p.isSet ? p.defaultSoftThresholdRate : DEFAULT_SOFT_THRESHOLD_RATE;
    }

    /// @notice Load the default slippage params stored in one pool slot
    /// @dev belongTo == 2 → collection slot _defaultSlippageTargetIDParams[poolTargetToken][memberTokenTargetID];
    ///      otherwise      → single-token slot _defaultSlippageSingleTokenParams[poolTargetToken][token].
    /// @param poolTargetToken The pool target token of the slot
    /// @param memberTokenTargetID The member token target ID (used when belongTo == 2)
    /// @param belongTo Token classification (1 = single, 2 = member)
    /// @param token The token key used for the single-token slot
    /// @return p The stored params (p.isSet == false when the slot was never configured)
    function _loadDefaultParams(
        address poolTargetToken,
        uint256 memberTokenTargetID,
        uint8 belongTo,
        address token
    ) private view returns (SlippageParams memory p) {
        if(belongTo == 2) {
            p = _defaultSlippageTargetIDParams[poolTargetToken][memberTokenTargetID];
        } else {
            p = _defaultSlippageSingleTokenParams[poolTargetToken][token];
        }
    }

    /// @notice Get slippage parameters for an index token, with channel and per-token overrides
    /// @dev Resolution order (highest priority first):
    ///      1. Per-token params stored under the input token itself — this is how a CHANNEL token
    ///         gets its own baseCapRate / k / n (set via setIndexTokenSlippageParams with the
    ///         channel token).
    ///      2. Channel-level default of the input token: only when the input is a channel token and
    ///         a default was configured for it via setDefaultSlippageParams (the WHOLE set is used,
    ///         never mixed with main-pool values).
    ///      3. Per-token params stored under the resolved underlying index token (main-pool config).
    ///      4. Default params of the input token: main-pool default, then global defaults (DEFAULT_*).
    ///      softThresholdRate ALWAYS comes from the default-params path (steps 2/4) — it is never
    ///      taken from _indexTokenSlippageParams, whose struct has no such field — so it resolves as
    ///      channel default → main-pool default → global default, independently of which level
    ///      supplied baseCapRate / k / n.
    /// @param _indexToken The index or channel token to query
    /// @return baseCapRate The base cap rate (basis points)
    /// @return impactFactorK The impact factor k (basis points)
    /// @return exponentN The exponent n
    /// @return softThresholdRate Skew surcharge trigger threshold (basis points)
    function getIndexTokenSlippageParams(address _indexToken)
        public view returns(uint256 baseCapRate, uint256 impactFactorK, uint256 exponentN, uint256 softThresholdRate)
    {
        // Case 1: per-token params stored under the input token itself win over everything else.
        IndexTokenSlippageParams memory p = _indexTokenSlippageParams[_indexToken];
        if(p.indexToken != address(0)) {
            (, , , softThresholdRate, ) = _getDefaultSlippageParams(_indexToken);
            return (p.baseCapRate, p.impactFactorK, p.exponentN, softThresholdRate);
        }

        // Resolve the default layer once: it supplies the fallback values AND reports whether the
        // input token carries its own channel-level default.
        uint256 defBaseCapRate;
        uint256 defImpactFactorK;
        uint256 defExponentN;
        bool channelDefaultSet;
        (defBaseCapRate, defImpactFactorK, defExponentN, softThresholdRate, channelDefaultSet) =
            _getDefaultSlippageParams(_indexToken);

        if(channelDefaultSet) {
            // Case 2: the channel token's own default (set via setDefaultSlippageParams with the
            // channel token) takes priority over the main-pool per-token config.
            return (defBaseCapRate, defImpactFactorK, defExponentN, softThresholdRate);
        }

        // Case 3: main-pool per-token config. For a regular token getIndexToken returns the input
        // unchanged (same slot as case 1), so this second lookup is skipped and no duplicate read
        // is paid.
        address indexToken = dataReader.getIndexToken(_indexToken);
        if(indexToken != _indexToken) {
            p = _indexTokenSlippageParams[indexToken];
            if(p.indexToken != address(0)) {
                return (p.baseCapRate, p.impactFactorK, p.exponentN, softThresholdRate);
            }
        }

        // Case 4: defaults of the input token (channel default absent → main pool → global).
        return (defBaseCapRate, defImpactFactorK, defExponentN, softThresholdRate);
    }

    /// @notice Get the global slip cap multiplier
    /// @dev Returns DEFAULT_SLIP_CAP_MULTIPLIER (1.2x) if not explicitly set
    /// @return The slip cap multiplier (basis points)
    function getSlipCapMultiplier() external view returns(uint256) {
        return getSlipCapMultiplierCache();
    }

    // ============ Slip Calculation ============

    /// @notice Calculate order-size-based slippage (baseSlip and finalSlip), MUTI-scaled (1e8)
    /// @dev Channel-whitelist short-circuit: the local isSetChannelFinalslipcap flag is checked FIRST
    ///      (tokens without a configured cap pay no channel lookup at all), then the token must
    ///      belong to a whitelisted channel pool; in that case the configured cap is returned as
    ///      BOTH baseSlip and finalSlip with zero skew adjustment (no Layer-1/Layer-2 computation).
    ///      Normal path formula:
    ///      Dusd = poolAmounts × tokenToUsdMin × currRate / BASE_RATE_DIVISOR
    ///      ratio = _sizeDelta / D  (scaled by MUTI)
    ///      baseSlip = min(k × ratioⁿ, baseCapRate)  (n ∈ {1,2,3}, all MUTI-scaled)
    ///      finalSlipCap = getEffectiveSlipLimits(_indexToken).multiplier × baseCapRate / BASE_RATE_DIVISOR
    ///                     (channel-pool multiplier when configured, otherwise the global multiplier)
    ///      finalSlip = min(baseSlip + skewAdjustment, finalSlipCap)
    /// @param _indexToken The index token
    /// @param _collateralToken The collateral token (for pool depth)
    /// @param _sizeDelta Order notional value in USD (30 decimals)
    /// @param _isLong true = long, false = short (for skew direction)
    /// @return baseSlip Slip before cap (MUTI-scaled, 1e8 = 100%)
    /// @return finalSlip Slip after skew adjustment + finalSlipCap (MUTI-scaled, 1e8 = 100%)
    /// @return skewAdjustment Skew adjustment (positive = surcharge, negative = discount, MUTI-scaled, 1e8 = 100%)
    function getSlipData(
        address _indexToken,
        address _collateralToken,
        uint256 _sizeDelta,
        bool _isLong
    ) external view returns(uint256 baseSlip, uint256 finalSlip, int256 skewAdjustment) {
        if(isSetChannelFinalslipcap[_indexToken] && isChannelWhitelist(_indexToken)) {
            return (channelIndexTokenTofinalSlipCap[_indexToken], channelIndexTokenTofinalSlipCap[_indexToken], 0);
        }

        // Layer 1: order-size impact
        uint256 baseCapRate;
        (baseSlip, baseCapRate) = _computeLayer1Slip(_indexToken, _collateralToken, _sizeDelta);
        if(baseSlip == 0) return (0, 0, 0);

        // Layer 2: skew adjustment
        skewAdjustment = getSkewAdjustment(_indexToken, _collateralToken, _sizeDelta, _isLong, baseSlip);
        // rawFinalSlip = min(baseSlip + skewAdjustment, finalSlipCap); clamped at 0
        int256 raw = int256(baseSlip) + skewAdjustment;
        uint256 rawFinalSlip = raw > 0 ? uint256(raw) : 0;

        // finalSlip = min(rawFinalSlip, finalSlipCap)
        //   finalSlipCap = multiplier × baseCapRate / BASE_RATE_DIVISOR (e.g. 1.2 × cap)
        //   baseCapRate is the MUTI-scaled value returned by _computeLayer1Slip
        (uint256 multiplier, ) = getEffectiveSlipLimits(_indexToken);
        uint256 finalSlipCap = multiplier * baseCapRate / BASE_RATE_DIVISOR;
        finalSlip = rawFinalSlip < finalSlipCap ? rawFinalSlip : finalSlipCap;
    }

    /// @notice Layer 1: compute baseSlip from order-size impact (k × ratioⁿ capped by baseCapRate)
    /// @dev Formula:
    ///      D = poolAmounts × tokenToUsdMin × currRate / DIVISOR  (pool depth in USD)
    ///      ratio = _sizeDelta / D  (scaled by MUTI)
    ///      n = getIndexTokenSlippageParams(...).exponentN  (1 ≤ n ≤ 3)
    ///      baseSlip = min(k × ratioⁿ, baseCapRate)
    ///      NOTE ON UNITS: getIndexTokenSlippageParams returns baseCapRate in BASIS POINTS; it is
    ///      converted to MUTI scaling below, so BOTH returned values are MUTI-scaled. This is NOT
    ///      the same unit as the basis-points baseCapRate used inside _computeSkewSurchargeRate.
    function _computeLayer1Slip(
        address _indexToken,
        address _collateralToken,
        uint256 _sizeDelta
    ) private view returns(uint256 baseSlip, uint256 baseCapRate) {
        // D = pool depth in USD, weighted by current rate
        uint256 D = vault.poolAmounts(_indexToken, _collateralToken);
        if(D == 0) return (0, 0);
        uint256 Dusd = vault.tokenToUsdMin(_collateralToken, D) * dataReader.getCurrRate(_indexToken) / BASE_RATE_DIVISOR;
        if(Dusd == 0) return (0, 0);

        uint256 k;
        uint256 n;
        (baseCapRate, k, n, ) = getIndexTokenSlippageParams(_indexToken);   // baseCapRate in basis points

        // ratio = _sizeDelta / Dusd, scaled by MUTI
        uint256 ratio = _sizeDelta * MUTI / Dusd;

        // ratio^n, scaled by MUTI (n ∈ {1,2,3})
        uint256 ratioPow = _powRatio(ratio, n);

        // baseSlip = k × ratioⁿ, capped by baseCapRate, all MUTI-scaled
        uint256 rawBaseSlip = k * ratioPow / BASE_RATE_DIVISOR;
        // Convert baseCapRate from basis points (as returned by getIndexTokenSlippageParams) to MUTI
        // scaling, so it shares the unit of rawBaseSlip and of finalSlipCap in getSlipData.
        baseCapRate = baseCapRate * MUTI / BASE_RATE_DIVISOR;
        baseSlip = rawBaseSlip < baseCapRate ? rawBaseSlip : baseCapRate;
    }

    /// @notice Compute ratio^n, scaled by MUTI (n ∈ {1,2,3})
    /// @dev n=1 → ratio, n=2 → ratio²/MUTI, n=3 → ratio³/MUTI²
    function _powRatio(uint256 _ratio, uint256 _n) private pure returns(uint256) {
        if(_n == 1) return _ratio;
        if(_n == 2) return _ratio * _ratio / MUTI;
        return _ratio * _ratio * _ratio / MUTI / MUTI; // n=3 default
    }

    /// @notice Layer 2 Skew Adjustment: directional surcharge/discount based on OI imbalance
    /// @dev Three cases:
    ///      ① skew_after > skew_before && skew_after > softThreshold → surcharge
    ///         adjust = skewSurchargeRate × (skew_after - softThreshold) / Dusd
    ///      ② skew_after < skew_before → discount: finalSlip = baseSlip × discountFactor
    ///      ③ otherwise → no adjustment (return 0)
    /// @param _indexToken The index token
    /// @param _collateralToken The collateral token for pool depth Dusd
    /// @param _sizeDelta Order notional value in USD
    /// @param _isLong true = long (increase long OI), false = short (increase short OI)
    /// @param _baseSlip Base slip from Layer 1 (MUTI-scaled, 1e8 = 100%)
    /// @return skewAdjustment Adjustment amount (positive = surcharge, negative = discount, MUTI-scaled, 1e8 = 100%)
    function getSkewAdjustment(
        address _indexToken,
        address _collateralToken,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _baseSlip
    ) public view returns(int256 skewAdjustment) {
        (uint256 skewBefore, uint256 skewAfter) = _computeSkew(_indexToken, _sizeDelta, _isLong);

        uint256 D = vault.poolAmounts(_indexToken, _collateralToken);
        if(D == 0) return 0;
        uint256 Dusd = vault.tokenToUsdMin(_collateralToken, D) * dataReader.getCurrRate(_indexToken) / BASE_RATE_DIVISOR;
        if(Dusd == 0) return 0;

        // softThreshold = Dusd × softThresholdRate / BASE_RATE_DIVISOR
        uint256 softThreshold;
        uint256 skewSurchargeRate;
        {
            (,,, uint256 softThresholdRate) = getIndexTokenSlippageParams(_indexToken);
            softThreshold = Dusd * softThresholdRate / BASE_RATE_DIVISOR;
            skewSurchargeRate = _computeSkewSurchargeRate(_indexToken, softThresholdRate);
        }

        // Three-case Skew Adjustment:
        //   skew_after > skew_before  → order exacerbates imbalance
        //   skew_after < skew_before  → order reduces imbalance (hedging)
        //   skew_after == skew_before → no change
        if(skewAfter > skewBefore && skewAfter > softThreshold && skewSurchargeRate > 0 && softThreshold > 0) {
            // Case ①: exacerbate beyond soft threshold → surcharge
            //   surcharge = skewSurchargeRate × (skewAfter - softThreshold) / Dusd
            skewAdjustment = int256(skewSurchargeRate * (skewAfter - softThreshold) / Dusd);
        } else if(skewAfter < skewBefore) {
            // Case ②: reduce imbalance → discount, finalSlip = baseSlip × discountFactor
            //   discount = -(baseSlip × (1 - discountFactor)) = -(baseSlip × (DIVISOR - df) / DIVISOR)
            skewAdjustment = -int256(_baseSlip * (BASE_RATE_DIVISOR - discountFactor) / BASE_RATE_DIVISOR);
        } else {
            // Case ③: exacerbate but within soft threshold, or no change → 0
            skewAdjustment = 0;
        }
    }

    /// @notice Compute skewSurchargeRate: slope that pushes baseSlip from baseCapRate to finalSlipCap at max imbalance
    /// @dev Formula: (finalSlipCap - baseCapRate) / (maxSkewRatio - softThresholdRate), scaled by MUTI
    ///      finalSlipCap = getEffectiveSlipLimits(_indexToken).multiplier × baseCapRate / BASE_RATE_DIVISOR
    ///      maxSkewRatio = getEffectiveSlipLimits(_indexToken).skewRatio  (channel override when configured,
    ///      otherwise the global maxSkewRatio; both are the "1" in 1 - softThreshold share of D)
    ///      baseCapRate   = getIndexTokenSlippageParams(_indexToken).baseCapRate
    ///      At max imbalance, total slip = baseSlip + skewAdjustment ≤ finalSlipCap
    /// @param _indexToken The index token for param lookup
    /// @param _softThresholdRate Soft threshold as fraction of D (basis points)
    /// @return skewSurchargeRate Surcharge slope (MUTI-scaled, 1e8 = 100% per unit of D exceeded)
    function _computeSkewSurchargeRate(
        address _indexToken,
        uint256 _softThresholdRate
    ) private view returns(uint256 skewSurchargeRate) {
        (uint256 baseCapRate, , , ) = getIndexTokenSlippageParams(_indexToken);
        // multiplier + max skew ratio resolved together in ONE channel lookup
        (uint256 multiplier, uint256 skewRatio) = getEffectiveSlipLimits(_indexToken);
        // finalSlipCap = multiplier × baseCapRate / BASE_RATE_DIVISOR (basis points, same unit as baseCapRate)
        uint256 finalSlipCap = multiplier * baseCapRate / BASE_RATE_DIVISOR;

        // Available total surcharge space: finalSlipCap - baseCapRate
        // Divided by remaining skew headroom: maxSkewRatio - softThresholdRate
        // scaled by MUTI for integer precision
        if(skewRatio <= _softThresholdRate) return 0;
        skewSurchargeRate = (finalSlipCap - baseCapRate) * MUTI / (skewRatio - _softThresholdRate);
    }

    /// @notice Compute OI imbalance skew before and after a candidate order
    /// @dev skew_before = |longOI - shortOI| (absolute imbalance before trade)
    ///      skew_after  = |longOI' - shortOI'| (after applying _sizeDelta in order direction)
    /// @param _indexToken The index token for OI data
    /// @param _sizeDelta Order notional value added to long/short OI
    /// @param _isLong true = increase long OI, false = increase short OI
    /// @return skewBefore Absolute OI imbalance before the order
    /// @return skewAfter  Absolute OI imbalance after the order
    function _computeSkew(
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong
    ) private view returns(uint256 skewBefore, uint256 skewAfter) {
        (uint256 shortOI, uint256 longOI, ) = dataReader.getSizeData(_indexToken);

        // skew_before = |longOI - shortOI| (absolute OI imbalance before the order)
        skewBefore = longOI > shortOI ? longOI - shortOI : shortOI - longOI;

        // Apply order direction: long increases longOI, short increases shortOI
        // skew_after = |(longOI ± sizeDelta) - (shortOI ± sizeDelta)|
        uint256 newLongOI = _isLong ? longOI + _sizeDelta : longOI;
        uint256 newShortOI = _isLong ? shortOI : shortOI + _sizeDelta;
        skewAfter = newLongOI > newShortOI ? newLongOI - newShortOI : newShortOI - newLongOI;
    }

    /// @notice Internal helper to read slip cap multiplier without external call
    function getSlipCapMultiplierCache() internal view returns(uint256) {
        return slipCapMultiplier > 0 ? slipCapMultiplier : DEFAULT_SLIP_CAP_MULTIPLIER;
    }

    /// @notice Returns the execution price (with slippage) for a decrease/close position
    /// @dev Resolution order:
    ///      1. Market decrease via PositionRouter — use its cached (price, sPrice, rate).
    ///      2. Limit decrease via OrderBook — no slippage, return (price, price, 0) with rate = 0.
    ///      3. Fallback (liquidation / room close / ADL / auto-decrease) — compute slippage here.
    ///      For case 3, closing a long reduces longOI (≈ increasing shortOI) and closing a
    ///      short reduces shortOI (≈ increasing longOI), so the skew is computed with !isLong
    ///      while the price add/subtract below still follows the position direction (isLong).
    /// @param indexToken The index token address
    /// @param size The position size being decreased
    /// @param isLong Whether the position being closed is long
    /// @return price The base market price (min for long, max for short)
    /// @return sPrice The slippage-adjusted execution price (equals price when no slippage)
    /// @return rate The slippage rate in bps (0 means no slippage)
    function getDecreaseSlipPrice(address indexToken, uint256 size, bool isLong) external view returns(uint256, uint256, uint256) {
        // 1. Market decrease: read the price cached by PositionRouter during execution
        (uint256 price, uint256 sPrice, uint256 rate) = positionRouter.getDecreaseSlippagePrice();
        if(sPrice > 0) {
            return (price, sPrice, rate);
        }

        // 2. Limit decrease: read the market price cached by OrderBook; no slippage applies
        price = orderBook.getTemporaryOrderBookDecreasePrice();
        if(price > 0) {
            return (price, price, 0);
        }

        // 3. Fallback: compute slippage locally (no request-scoped cache).
        return _getDecreaseSlipPriceFallback(indexToken, size, isLong);
    }

    /// @notice Decrease/close pricing that ALWAYS skips the request-scoped execution caches
    ///         (PositionRouter market cache / OrderBook limit cache) and prices purely from the
    ///         current market for the given size.
    /// @dev Used for mark-to-market health checks of the REMAINING position after a partial
    ///      decrease (e.g. VaultUtils._validateLiquidation). Reusing the execution price of the
    ///      current decrease request there would price the remaining exposure at the wrong size
    ///      (a cached price computed for the closed sizeDelta, or an OrderBook raw price), which
    ///      could under/over-state whether the remaining position is liquidatable.
    /// @param indexToken The index token address
    /// @param size The size against which the mark-to-market price should be computed
    /// @param isLong Whether the evaluated position is long
    /// @return price The base market price (min for long, max for short)
    /// @return sPrice The slippage-adjusted mark price
    /// @return rate The slippage rate in bps (0 means no slippage)
    function getLiquidationPrice(address indexToken, uint256 size, bool isLong) external view returns(uint256, uint256, uint256) {
        return _getDecreaseSlipPriceFallback(indexToken, size, isLong);
    }

    /// @notice Fallback pricing for a decrease: base price uses the position direction
    ///         (long → bid/min, short → ask/max) and slippage is computed from the given size.
    /// @dev Closing a long reduces longOI (≈ increasing shortOI) and closing a short
    ///      reduces shortOI (≈ increasing longOI), so the skew is computed with !isLong
    ///      while the price add/subtract below still follows the position direction (isLong).
    function _getDecreaseSlipPriceFallback(address indexToken, uint256 size, bool isLong) internal view returns(uint256, uint256, uint256) {
        uint256 price = isLong ? vault.getMinPrice(indexToken) : vault.getMaxPrice(indexToken);
        uint256 sPrice = price;
        uint256 rate = slippage.getRate(indexToken, size, !isLong);

        if(rate > 0) {
            if(!isLong) {
                // closing short (buy back) → price moves up by slip
                sPrice = price * (MUTI + rate) / MUTI;
            } else {
                // closing long (sell) → price moves down by slip
                if(rate < MUTI) {
                    sPrice = price * (MUTI - rate) / MUTI;
                } else {
                    revert("getDecreaseSlipPrice exceeds 100%");    
                }  
            }
        }
        return (price, sPrice, rate);
    }

    function getSlipRate(address indexToken, uint256 size) external view returns(uint256, uint256) {
        return (slippage.getLongRate(indexToken, size), slippage.getShortRate(indexToken, size));
    }

    // ***********************************************************************************
    /// @notice Emitted when a channel token's fixed final slip cap is configured
    /// @param indexToken The channel token (channel-mapped placeholder token)
    /// @param finalSlipCap The cap in MUTI-scaled units (1e8 = 100%), max 5% (0.05e8);
    ///        0 means no slippage is charged for that token
    event SetChannelFinalslipcap(address indexToken, uint256 finalSlipCap);

    /// @notice Emitted when a channel pool's slip-cap multiplier and max skew ratio are set
    /// @param targetToken The channel pool's target token (channel pool token) the values are stored under
    /// @param multiplier The slip cap multiplier in basis points (10000 = 1.0x, max 20000 = 2.0x)
    /// @param maxSkewRatio The max skew ratio in basis points (10000 = 1.0, max 20000 = 2.0)
    event SetChannelCapMulAndMaxSkewRatio(address targetToken, uint256 multiplier, uint256 maxSkewRatio);

    /// @notice Channel-pool override of the slip cap multiplier (the 1.2x coefficient), keyed by the pool's channel pool token
    /// @dev Key = getChannelMappedTokenPoolInfo(channelToken).targetToken, i.e. the pool's own channel
    ///      pool token, which is created and configured with the pool (createChannelPool) — one slot
    ///      per pool. A pool whose target token is not configured (address(0)) cannot be used on the
    ///      channel path.
    ///      0 (unset) falls back to the global slipCapMultiplier / DEFAULT_SLIP_CAP_MULTIPLIER (12000).
    ///      Pool-level setting only: whitelisting is NOT required for this override — the whitelist
    ///      only gates the per-channel-token fixed final slip cap (batchSetChannelFinalslipcap).
    mapping(address => uint256) public channelSlipCapMultiplier;

    /// @notice Channel-pool override of maxSkewRatio (the 1 in 1 - softThreshold share of D), keyed by the pool's channel pool token
    /// @dev Same key / availability rules as channelSlipCapMultiplier (targetToken must be configured).
    ///      0 (unset) falls back to the global maxSkewRatio.
    ///      Pool-level setting only: whitelisting is NOT required for this override.
    mapping(address => uint256) public channelMaxSkewRatio;

    /// @notice Per-channel-token fixed final slip cap, keyed by the channel token itself
    /// @dev MUTI-scaled (1e8 = 100%), max 5%. Applied only when the pool owner is whitelisted
    ///      (see isChannelWhitelist) and isSetChannelFinalslipcap[channelToken] is true.
    ///      A configured value of 0 is valid and means no slippage at all for that token.
    mapping(address => uint256) public channelIndexTokenTofinalSlipCap;

    /// @notice Whether a channel token has an explicit final slip cap configured
    mapping(address => bool) public isSetChannelFinalslipcap;

    /// @notice Input struct for batchSetChannelFinalslipcap
    /// @param indexToken The channel token
    /// @param finalSlipCap The final slip cap in MUTI-scaled units (1e8 = 100%), must be <= 5% (0.05e8);
    ///        0 is allowed and means no slippage
    struct FinalslipcapData {
        address indexToken;
        uint256 finalSlipCap;
    }

    /// @notice Batch-set the fixed final slip cap for channel tokens
    /// @dev Only callable by governance. For each entry:
    ///      - The channel token's pool owner must be whitelisted (isChannelWhitelist) at WRITE time
    ///        here, and is checked again at READ time in getSlipData; otherwise the entry is skipped.
    ///        Whitelist the pool owner in MemeData before configuring a cap.
    ///      - The cap must be <= 5% (0.05e8 in MUTI-scaled units); otherwise the entry is skipped.
    ///        A cap of 0 is valid and means no slippage is charged for that token.
    ///      - Skipped entries do NOT revert and emit NO event, so failed entries are silent.
    ///      The stored key is the channel token itself and the isSet flag is latched on first write.
    /// @param _slipcapData Array of {channel token, final slip cap (MUTI-scaled)}
    function batchSetChannelFinalslipcap(FinalslipcapData[] calldata _slipcapData) external onlyGov {
        uint256 len = _slipcapData.length;
        if(len == 0) revert("empty _slipcapData");
        for(uint256 i = 0; i < len; i++) {
            address _indexToken = _slipcapData[i].indexToken;
            if(isChannelWhitelist(_indexToken)) {
                uint256 _finalSlipCap = _slipcapData[i].finalSlipCap;
                if(_finalSlipCap <= 0.05e8) {
                    channelIndexTokenTofinalSlipCap[_indexToken] = _finalSlipCap;
                    if(!isSetChannelFinalslipcap[_indexToken]) isSetChannelFinalslipcap[_indexToken] = true;
                    emit SetChannelFinalslipcap(_indexToken, _finalSlipCap);
                }
            }
        }
    }

    /// @notice Set a channel pool's slip-cap multiplier (1.2x coefficient) and max skew ratio
    /// @dev Only callable by governance. _indexToken must be a channel-mapped token.
    ///      Both values are in basis points and restricted to [BASE_RATE_DIVISOR (1.0x), 20000 (2.0x)].
    ///      Values are stored under the pool's channel pool token (targetToken). The pool's target
    ///      token is configured when the pool is created (createChannelPool); a token whose pool has
    ///      no configured target token (address(0)) cannot be used on the channel path.
    /// @param _indexToken The channel token used to resolve its pool
    /// @param _multiplier The slip cap multiplier in basis points (10000 = 1.0x)
    /// @param _maxSkewRatio The max skew ratio in basis points (10000 = 1.0, max 20000 = 2.0)
    function setChannelCapMulAndMaxSkewRatio(address _indexToken, uint256 _multiplier, uint256 _maxSkewRatio) external onlyGov {
        (address pool,,address targetToken,) = IMemeFactory(dataReader.memeFactory()).getChannelMappedTokenPoolInfo(_indexToken);
        if(pool == address(0)) revert("_indexToken err");
        if(_multiplier < BASE_RATE_DIVISOR || _multiplier > 20000) revert("multiplier err");
        if(_maxSkewRatio < BASE_RATE_DIVISOR || _maxSkewRatio > 20000) revert("maxSkewRatio err");

        channelSlipCapMultiplier[targetToken] = _multiplier;
        channelMaxSkewRatio[targetToken] = _maxSkewRatio;
        emit SetChannelCapMulAndMaxSkewRatio(targetToken, _multiplier, _maxSkewRatio);
    }

    /// @notice Whether the owner of the channel pool behind a channel token is whitelisted
    /// @dev Returns false for non-channel tokens (pool == address(0)). Whitelisting is looked up
    ///      on the channel pool owner in MemeData (isChannelWhitelist).
    /// @param _indexToken The channel token to query
    /// @return True when the token is channel-mapped AND its pool owner is whitelisted
    function isChannelWhitelist(address _indexToken) public view returns(bool) {
        IMemeFactory memeFactory = IMemeFactory(dataReader.memeFactory());
        (address pool,,,) = memeFactory.getChannelMappedTokenPoolInfo(_indexToken);
        if(pool == address(0)) return false;
        address user = memeFactory.channelPoolOwner(pool);
        return IMemeData(dataReader.memeData()).isChannelWhitelist(user);
    }

    /// @notice Effective slip limits for a token: cap multiplier and max skew ratio
    /// @dev Both values are resolved with a SINGLE channel lookup (getChannelMappedTokenPoolInfo).
    ///      For a channel-mapped token a configured channel-pool override wins, otherwise the global
    ///      configuration is used. Whitelisting is NOT required here — it only gates the fixed final
    ///      slip cap configured via batchSetChannelFinalslipcap.
    /// @param _indexToken The index / channel token to query
    /// @return multiplier The effective slip cap multiplier in basis points (falls back to the global
    ///         slipCapMultiplier / DEFAULT_SLIP_CAP_MULTIPLIER = 12000 when unset)
    /// @return skewRatio The effective max skew ratio in basis points (falls back to the global
    ///         maxSkewRatio when unset)
    function getEffectiveSlipLimits(address _indexToken) public view returns(uint256 multiplier, uint256 skewRatio) {
        (address pool,,address targetToken, ) = IMemeFactory(dataReader.memeFactory()).getChannelMappedTokenPoolInfo(_indexToken);
        if(pool != address(0)) {
            uint256 channelMultiplier = channelSlipCapMultiplier[targetToken];
            uint256 channelSkewRatio = channelMaxSkewRatio[targetToken];
            multiplier = channelMultiplier > 0 ? channelMultiplier : getSlipCapMultiplierCache();
            skewRatio = channelSkewRatio > 0 ? channelSkewRatio : maxSkewRatio;
        } else {
            multiplier = getSlipCapMultiplierCache();
            skewRatio = maxSkewRatio;
        }
    }
}