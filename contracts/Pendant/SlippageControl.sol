// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../core/interfaces/IVault.sol";
import "../core/interfaces/IDataReader.sol";
import "./interfaces/ISlippage.sol";
import "../core/interfaces/IPositionRouter.sol";
import "../core/interfaces/IOrderBook.sol";
import "../upgradeability/Synchron.sol";

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

    /// @notice Set core contract addresses (vault + dataReader only; others unused)
    /// @dev Only callable by governance. All addresses must be non-zero.
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
    ///      Channel tokens resolve to their underlying main-pool token via getIndexToken,
    ///      and the pool target token is derived automatically via getTargetIndexToken,
    ///      so channel tokens inherit the main-pool default configuration.
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
    ///      For channel tokens, resolves to the underlying main-pool token automatically.
    /// @param _params The default slippage parameters to set
    function setDefaultSlippageParams(
        address _indexToken,
        SlippageParams calldata _params
    ) external onlyGov {
        _indexToken = dataReader.getIndexToken(_indexToken);
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
    ///      Channel tokens resolve to their underlying main-pool token via getIndexToken,
    ///      so the params are stored under the main-pool token key.
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
            if(p.indexToken == address(0)) revert("indexToken err");
            if(p.baseCapRate == 0 || p.baseCapRate > 1000) revert("baseCapRate err");  // baseCapRate ∈ (0, 1000]
            if(p.impactFactorK == 0 || p.impactFactorK > 1000) revert("impactFactorK err");  // impactFactorK ∈ (0, 1000]
            if(p.exponentN == 0 || p.exponentN > 3) revert("exponentN err");  // exponentN ∈ [1, 3]
            address indexToken = dataReader.getIndexToken(p.indexToken);
            _indexTokenSlippageParams[indexToken] = p;
            emit SetIndexTokenSlippageParams(indexToken, p.baseCapRate, p.impactFactorK, p.exponentN);
        }
    }

    /// @notice Set the global slip cap multiplier used to compute finalSlipCap
    /// @dev finalSlipCap = slipCapMultiplier × baseCapRate / BASE_RATE_DIVISOR.
    ///      Only callable by governance. Value in basis points relative to baseCapRate,
    ///      e.g. 12000 = 1.2× (the default), 20000 = 2×. Must be > 0 and ≤ 20000.
    ///      When unset (0), getSlipCapMultiplier falls back to DEFAULT_SLIP_CAP_MULTIPLIER (12000).
    /// @param _multiplier The multiplier in basis points (0 < _multiplier ≤ 20000)
    function setSlipCapMultiplier(uint256 _multiplier) external onlyGov {
        if(_multiplier == 0 || _multiplier > 20000) revert("multiplier err");
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
    /// @dev Only callable by governance. Must be >= BASE_RATE_DIVISOR (1.0 in basis points).
    /// @param _maxSkewRatio The max skew ratio in basis points (e.g. 10000 = 1.0)
    function setMaxSkewRatio(uint256 _maxSkewRatio) external onlyGov {
        if(_maxSkewRatio < BASE_RATE_DIVISOR) revert("maxSkewRatio err");
        maxSkewRatio = _maxSkewRatio;
        emit SetMaxSkewRatio(_maxSkewRatio);
    }

    /// @notice Get default slippage parameters resolved by belongTo (collection or single token)
    /// @param _indexToken The index token to query
    /// @return defaultBaseCapRate The base cap rate (basis points)
    /// @return defaultImpactFactorK The impact factor k (basis points)
    /// @return defaultExponentN The exponent n
    /// @return defaultSoftThresholdRate Skew surcharge trigger threshold (basis points)
    function getDefaultSlippageParams(address _indexToken)
        public view returns(uint256 defaultBaseCapRate, uint256 defaultImpactFactorK, uint256 defaultExponentN, uint256 defaultSoftThresholdRate)
    {
        _indexToken = dataReader.getIndexToken(_indexToken);
        address targetToken = dataReader.getTargetIndexToken(_indexToken);
        (, uint256 memberTokenTargetID, , uint8 belongTo) = dataReader.getTokenInfo(_indexToken);
        SlippageParams memory p;
        if(belongTo == 2) {
            p = _defaultSlippageTargetIDParams[targetToken][memberTokenTargetID];
        } else {
            p = _defaultSlippageSingleTokenParams[targetToken][_indexToken];
        }
        defaultBaseCapRate = p.isSet ? p.defaultBaseCapRate : DEFAULT_BASE_CAP_RATE;
        defaultImpactFactorK = p.isSet ? p.defaultImpactFactorK : DEFAULT_IMPACT_FACTOR_K;
        defaultExponentN = p.isSet ? p.defaultExponentN : DEFAULT_EXPONENT_N;
        defaultSoftThresholdRate = p.isSet ? p.defaultSoftThresholdRate : DEFAULT_SOFT_THRESHOLD_RATE;
    }

    /// @notice Get slippage parameters for an index token, with per-token override
    /// @dev If _indexTokenSlippageParams[_indexToken] is set, returns those values.
    ///      Otherwise falls back to getDefaultSlippageParams.
    /// @param _indexToken The index token to query
    /// @return baseCapRate The base cap rate (basis points)
    /// @return impactFactorK The impact factor k (basis points)
    /// @return exponentN The exponent n
    /// @return softThresholdRate Skew surcharge trigger threshold (basis points)
    function getIndexTokenSlippageParams(address _indexToken)
        public view returns(uint256 baseCapRate, uint256 impactFactorK, uint256 exponentN, uint256 softThresholdRate)
    {
        _indexToken = dataReader.getIndexToken(_indexToken);
        IndexTokenSlippageParams memory p = _indexTokenSlippageParams[_indexToken];
        if(p.indexToken != address(0)) {
            (, , , softThresholdRate) = getDefaultSlippageParams(_indexToken);
            return (p.baseCapRate, p.impactFactorK, p.exponentN, softThresholdRate);
        }
        return getDefaultSlippageParams(_indexToken);
    }

    /// @notice Get the global slip cap multiplier
    /// @dev Returns DEFAULT_SLIP_CAP_MULTIPLIER (1.2x) if not explicitly set
    /// @return The slip cap multiplier (basis points)
    function getSlipCapMultiplier() external view returns(uint256) {
        return getSlipCapMultiplierCache();
    }

    // ============ Slip Calculation ============

    /// @notice Calculate order-size-based slippage (baseSlip and finalSlip), MUTI-scaled (1e8)
    /// @dev Formula:
    ///      Dusd = poolAmounts × tokenToUsdMin × currRate / BASE_RATE_DIVISOR
    ///      ratio = _sizeDelta / D  (scaled by MUTI)
    ///      baseSlip = min(k × ratioⁿ, baseCapRate)  (n ∈ {1,2,3}, all MUTI-scaled)
    ///      finalSlipCap = slipCapMultiplier × baseCapRate / BASE_RATE_DIVISOR
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
        uint256 finalSlipCap = getSlipCapMultiplierCache() * baseCapRate / BASE_RATE_DIVISOR;
        finalSlip = rawFinalSlip < finalSlipCap ? rawFinalSlip : finalSlipCap;
    }

    /// @notice Layer 1: compute baseSlip from order-size impact (k × ratioⁿ capped by baseCapRate)
    /// @dev Formula:
    ///      D = poolAmounts × tokenToUsdMin × currRate / DIVISOR  (pool depth in USD)
    ///      ratio = _sizeDelta / D  (scaled by MUTI)
    ///      n = getIndexTokenSlippageParams(...).exponentN  (1 ≤ n ≤ 3)
    ///      baseSlip = min(k × ratioⁿ, baseCapRate)
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
        (baseCapRate, k, n, ) = getIndexTokenSlippageParams(_indexToken);

        // ratio = _sizeDelta / Dusd, scaled by MUTI
        uint256 ratio = _sizeDelta * MUTI / Dusd;

        // ratio^n, scaled by MUTI (n ∈ {1,2,3})
        uint256 ratioPow = _powRatio(ratio, n);

        // baseSlip = k × ratioⁿ, capped by baseCapRate, all MUTI-scaled
        uint256 rawBaseSlip = k * ratioPow / BASE_RATE_DIVISOR;
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
    ///      finalSlipCap = multiplier × baseCapRate / BASE_RATE_DIVISOR
    ///      baseCapRate = getIndexTokenSlippageParams(_indexToken).baseCapRate
    ///      At max imbalance, total slip = baseSlip + skewAdjustment ≤ finalSlipCap
    /// @param _indexToken The index token for param lookup
    /// @param _softThresholdRate Soft threshold as fraction of D (basis points)
    /// @return skewSurchargeRate Surcharge slope (MUTI-scaled, 1e8 = 100% per unit of D exceeded)
    function _computeSkewSurchargeRate(
        address _indexToken,
        uint256 _softThresholdRate
    ) private view returns(uint256 skewSurchargeRate) {
        (uint256 baseCapRate, , , ) = getIndexTokenSlippageParams(_indexToken);
        // finalSlipCap = multiplier × baseCapRate / BASE_RATE_DIVISOR (basis points, same unit as baseCapRate)
        uint256 finalSlipCap = getSlipCapMultiplierCache() * baseCapRate / BASE_RATE_DIVISOR;

        // Available total surcharge space: finalSlipCap - baseCapRate
        // Divided by remaining skew headroom: maxSkewRatio - softThresholdRate
        // scaled by MUTI for integer precision
        if(maxSkewRatio <= _softThresholdRate) return 0;
        skewSurchargeRate = (finalSlipCap - baseCapRate) * MUTI / (maxSkewRatio - _softThresholdRate);
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

        // 3. Fallback: base price uses position direction (long → bid/min, short → ask/max)
        price = isLong ? vault.getMinPrice(indexToken) : vault.getMaxPrice(indexToken);
        sPrice = price;
        // Decrease reverses the OI direction: closing long reduces longOI (≈ increasing shortOI),
        // closing short reduces shortOI (≈ increasing longOI). So pass !isLong to skew computation,
        // while the price add/subtract below still uses the position direction (isLong).
        rate = slippage.getRate(indexToken, size, !isLong);
        
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
}