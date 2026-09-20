// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../core/interfaces/IVault.sol";
import "./interfaces/IPhase.sol"; 
import "../fund-pool/v2/interfaces/IPoolDataV2.sol";  
import "../fund-pool/v2/interfaces/IStruct.sol";         
import "../meme/interfaces/IMemeFactory.sol";
import "../meme/interfaces/IMemeData.sol";
import "../meme/interfaces/IMemeStruct.sol";
import "./interfaces/ICoinData.sol";
import "../upgradeability/Synchron.sol";
import "../core/interfaces/IDataReader.sol";

contract CalculatePNL is Synchron {
    /// @notice Precision base for all rate/factor values (4-decimal precision)
    /// @dev 100% = 10000. All factors/rates (DEFAULT_MAX_PNL_FACTOR_FOR_TRADERS,
    ///      setMaxPnlFactorForTraders, singleTokenMaxPnlFactorForTraders, hardtopRate) are scaled by BASE_RATE.
    uint256 public constant BASE_RATE = 10000;

    /// @notice Default hardtop rate used when a pool's rate is not explicitly set
    /// @dev Scaled by BASE_RATE (10000 = 100%). Defaults to 5% = 500. Gov-set range: 100 (1%) ~ 2000 (20%).
    uint256 public constant DEFAULT_HARDTOP_RATE = 500;

    /// @notice Default max PnL factor for traders when no pool-collection or single-token override is set
    /// @dev Scaled by BASE_RATE (10000 = 100%). Defaults to 10% = 1000. Range: 500 (5%) <= x <= 10000 (100%).
    ///      Only regular (non-meme, non-channel) fund pools are capped; meme & channel pools are excluded.
    uint256 public constant DEFAULT_MAX_PNL_FACTOR_FOR_TRADERS = 1000;

    /// @notice Pool-collection max PnL factor for traders: poolTargetToken => memberTokenTargetID => factor
    /// @dev Applies to member tokens that belong to a pool collection (coinData belongTo == 2).
    ///      Single tokens (belongTo == 1) use singleTokenMaxPnlFactorForTraders instead.
    ///      Scaled by BASE_RATE (10000 = 100%). Range: 500 (5%) <= x <= 10000 (100%).
    mapping(address => mapping(uint256 => uint256)) setMaxPnlFactorForTraders;

    /// @notice Single-token max PnL factor for traders: poolTargetToken => indexToken => factor
    /// @dev Applies to single tokens that are NOT part of any pool collection (coinData belongTo == 1).
    ///      Scaled by BASE_RATE (10000 = 100%). Range: 500 (5%) <= x <= 10000 (100%).
    mapping(address => mapping(address => uint256)) singleTokenMaxPnlFactorForTraders;

    /// @notice Whether the contract has been initialized
    /// @dev Prevents re-initialization attacks on upgradeable pattern
    bool public initialized;

    /// @notice The vault contract for pool amount and position data
    IVault public vault;

    /// @notice The Phase contract (source of instrument PnL, sole caller of recordActualLoss)
    IPhase public phase;

    /// @notice PoolDataV2 contract for fund-pool period lookups
    IPoolDataV2 public poolDataV2;

    /// @notice The MemeFactory contract for channel pool lookups
    IMemeFactory public memeFactory;

    /// @notice The MemeData contract for meme token checks
    IMemeData public memeData;

    /// @notice The CoinData contract (source of token classification)
    /// @dev Provides getTokenInfo (belongTo: 1 single / 2 member), used to route maxPnlFactorForTraders
    ///      between single-token and pool-collection factors. Pool target resolution is handled by
    ///      dataReader.getTargetIndexToken (idempotent), not by coinData.
    ICoinData public coinData;

    /// @notice The DataReader contract for idempotent index-token resolution
    /// @dev getTargetIndexToken normalizes any input (USDT / single / member / pool target token)
    ///      to the pool target token, matching the normalization Vault applies before recordActualLoss.
    IDataReader public dataReader;

    /// @notice Address of the governance account
    /// @dev Only gov can call admin functions. Set during initialize()
    address public gov;

    /// @notice The USDT collateral token used for pool PnL valuation
    address public usdt;

    /// @notice Per-pool hard cap rate for PnL settlement
    /// @dev Keyed by pool target token. Scaled by BASE_RATE (10000 = 100%, e.g. 100 = 1%, 2000 = 20%)
    mapping (address => uint256) hardtopRate;

    /// @notice Per-period actual loss amounts
    /// @dev periodID => poolTargetToken => collateralToken => actual loss amount for that period
    mapping (uint256 => mapping (address => mapping (address => uint256))) public actualLossAmount;

    /// @notice Batch entry for setting a trader PnL factor on one index token
    /// @dev indexToken is resolved by coinData.getTokenInfo to decide single vs pool-collection routing.
    struct MaxPnlFactorForTraders {
        address indexToken; // The index token
        uint256 maxPnlFactorForTraders; // The new factor (BASE_RATE-scaled, 500 (5%) <= x <= 10000 (100%))
    }

    /// @notice Emitted when a pool-collection (member-token group) max PnL factor is set
    /// @param tokenToPoolTargetToken The pool target token
    /// @param indexToken The member token through which the factor was set
    /// @param value The new factor (BASE_RATE-scaled, 10000 = 100%)
    event SetMaxPnlFactorForTraders(address indexed tokenToPoolTargetToken, address indexed indexToken, uint256 value);

    /// @notice Emitted when a single-token (not part of any pool collection) max PnL factor is set
    /// @param tokenToPoolTargetToken The pool target token
    /// @param indexToken The single index token
    /// @param value The new factor (BASE_RATE-scaled, 10000 = 100%)
    event SingleTokenMaxPnlFactorForTraders(address indexed tokenToPoolTargetToken, address indexed indexToken, uint256 value);

    /// @notice Emitted when a pool's hardtopRate is updated
    /// @param poolTargetToken The pool target token the rate applies to
    /// @param oldValue The previous hardtopRate
    /// @param newValue The new hardtopRate
    event SetHardtopRate(address indexed poolTargetToken, uint256 oldValue, uint256 newValue);   

    /// @notice Emitted when actual loss is recorded for a period
    /// @param indexToken The instrument token
    /// @param collateralToken The collateral token
    /// @param amount The recorded loss amount
    /// @param period The settlement period ID
    event RecordActualLoss(address indexed indexToken, address indexed collateralToken, uint256 amount, uint256 period);

    constructor() {
        initialized = true;
    }

    // ============ Modifiers ============

    /// @notice Restricts function access to governance only
    modifier onlyGov() {
        if(gov != msg.sender) revert();
        _;
    }

    /// @notice Restricts function access to the Phase contract only
    modifier onlyPhase() {
        if(msg.sender != address(phase)) revert();
        _;
    }

    // ============ Initialization ============

    /**
     * @notice Initialize the contract with caller as governance
     * @dev Called once during deployment via proxy pattern.
     *      Sets msg.sender as initial governance address.
     *      Contract addresses must be set separately via setContract().
     */
    function initialize(address _usdt) external {
        if(initialized || _usdt == address(0)) revert();
        usdt = _usdt;
        initialized = true;
        gov = msg.sender;
    }

    /// @notice Set core contract addresses
    /// @dev Only callable by governance. All addresses must be non-zero.
    ///      When using the upgradeable proxy pattern, pass each contract's Proxy address.
    /// @param _vault The Vault contract address
    /// @param _phase The Phase contract address
    /// @param _poolDataV2 The PoolDataV2 contract address
    /// @param _memeFactory The MemeFactory contract address
    /// @param _memeData The MemeData contract address
    /// @param _coinData The CoinData contract address (token classification for factor routing)
    function setContract(
        address _vault,
        address _phase,
        address _poolDataV2,
        address _memeFactory,
        address _memeData,
        address _coinData,
        address _dataReader
    ) external onlyGov {
        if (
            _vault == address(0) ||
            _phase == address(0) ||
            _poolDataV2 == address(0) ||
            _memeFactory == address(0) ||
            _memeData == address(0) ||
            _coinData == address(0) ||
            _dataReader == address(0)
        ) revert("addr err");

        vault = IVault(_vault);
        phase = IPhase(_phase);
        poolDataV2 = IPoolDataV2(_poolDataV2);
        memeFactory = IMemeFactory(_memeFactory);
        memeData = IMemeData(_memeData);
        coinData = ICoinData(_coinData);
        dataReader = IDataReader(_dataReader);
    }

    /// @notice Transfer governance to a new account
    /// @dev Only callable by current governance. Non-zero address required.
    function setGov(address _account) external onlyGov {
        if(_account == address(0)) revert();
        gov = _account;
    }

    /// @notice Batch set max PnL factors for traders (gov only)
    /// @dev Meme tokens are rejected (no PnL cap for meme/channel pools).
    ///      Routing by coinData.getTokenInfo(_indexToken).belongTo:
    ///      - belongTo == 2 (member token of a pool collection): stored in setMaxPnlFactorForTraders[poolTarget][memberTokenTargetID]
    ///      - belongTo == 1 (single token, NOT part of any collection): stored in singleTokenMaxPnlFactorForTraders[poolTarget][indexToken]
    ///      - otherwise reverts.
    /// @param _maxPnlFactorForTraders Array of (indexToken, factor) pairs
    function batchSetMaxPnlFactorForTraders(MaxPnlFactorForTraders[] calldata _maxPnlFactorForTraders) external onlyGov {
        uint256 len = _maxPnlFactorForTraders.length;
        if(len == 0) revert();
        for(uint256 i = 0; i < len; i++) {
            address _indexToken = _maxPnlFactorForTraders[i].indexToken;
            uint256 _factor = _maxPnlFactorForTraders[i].maxPnlFactorForTraders;
            _revertIfMeme(_indexToken);
            if(_factor < 500 || _factor > 10000) revert("_maxPnlFactorForTraders err");     
            (address _tokenToPoolTargetToken, uint256 _memberTokenTargetID, , uint8 _belongTo) = coinData.getTokenInfo(_indexToken);
            if(_belongTo == 2) {
                // Member tokens belong to a pool collection: store per (pool, member-token-target-ID)
                setMaxPnlFactorForTraders[_tokenToPoolTargetToken][_memberTokenTargetID] = _factor;
                emit SetMaxPnlFactorForTraders(_tokenToPoolTargetToken, _indexToken, _factor);
            } else if (_belongTo == 1) {
                // Single token is not part of any pool collection: store per (pool, index token)
                singleTokenMaxPnlFactorForTraders[_tokenToPoolTargetToken][_indexToken] = _factor;
                emit SingleTokenMaxPnlFactorForTraders(_tokenToPoolTargetToken, _indexToken, _factor);
            } else {
                revert("_belongTo err");
            }
        }
    }

    /// @notice Set a pool's per-period hardtopRate (gov only)
    /// @dev Only regular (non-meme) pools are capped; meme tokens revert. The input token is
    ///      resolved to its pool target token via dataReader.getTargetIndexToken.
    ///      Scaled by BASE_RATE (10000 = 100%). Range: 100 (1%) <= _hardtopRate <= 2000 (20%).
    /// @param _indexToken Token whose pool the rate applies to (resolved to pool target token)
    /// @param _hardtopRate The new hardtop rate for the pool
    function setHardtopRate(address _indexToken, uint256 _hardtopRate) external onlyGov {
        _revertIfMeme(_indexToken);
        address poolTargetToken = dataReader.getTargetIndexToken(_indexToken);
        if(_hardtopRate < 100 || _hardtopRate > 2000) revert();
        uint256 oldValue = hardtopRate[poolTargetToken];
        hardtopRate[poolTargetToken] = _hardtopRate;
        emit SetHardtopRate(poolTargetToken, oldValue, _hardtopRate);
    }

    /// @notice Record the actual loss amount for the current period, callable only by the Phase contract
    /// @dev Only regular (non-meme) fund pools are subject to loss accounting; meme tokens are skipped
    ///      (meme & channel pools are excluded from PnL capping entirely). Only accumulates losses for
    ///      periods AFTER this contract is deployed/configured — periods completed before deployment
    ///      are excluded and never recorded. Access restricted to Phase via onlyPhase modifier.
    ///      The (pool target token, period) is resolved by _resolvePoolPeriod
    ///      (pool target via dataReader.getTargetIndexToken + current fund-pool period via getCurrPeriodID).
    /// @param _indexToken The instrument token
    /// @param _collateralToken The collateral token
    /// @param _amount The actual loss amount for the current period
    function recordActualLoss(address _indexToken, address _collateralToken, uint256 _amount) external onlyPhase {
        if(memeData.isAddMeme(_indexToken)) return;
        (address _poolTargetToken, uint256 _period,) = _resolvePoolPeriod(_indexToken);
        actualLossAmount[_period][_poolTargetToken][_collateralToken] += _amount;
        emit RecordActualLoss(_indexToken, _collateralToken, _amount, _period);
    }

    /// @notice Get pool PnL data: uncapped PnL, max PnL cap, capped PnL and scale factor
    /// @dev Only regular (non-meme) fund pools are capped; for meme tokens this returns all zeros
    ///      (getDelta short-circuits meme positions before ever calling here).
    ///      Algorithm:
    ///      poolPnl = Σ_k max(instrumentAgg_k, 0)  (sum of net-positive instrument PnL)
    ///      poolTokenUsd = tokenToUsdMin(_collateralToken, poolAmounts(target, _collateralToken) * setRate / BASE_RATE)
    ///        setRate = coinData.getCurrRate(_indexToken).rate (BASE_RATE-scaled) — scales the raw pool
    ///        token balance to the instrument's effective pool depth.
    ///      maxPnl = poolTokenUsd * maxPnlFactorForTraders / BASE_RATE  (effective pool value * cap ratio)
    ///      cappedPoolPnl = min(poolPnl, maxPnl)
    ///      scaleFactor = poolPnl > 0 ? cappedPoolPnl / poolPnl : 1  (scaled by BASE_RATE)
    ///      poolPnl is always >= 0 (only net-positive instruments are accumulated), so the uint256 cast is safe.
    ///      scaleFactor is scaled by BASE_RATE (10000 = 100%). When poolPnl is 0, scaleFactor returns BASE_RATE to avoid division by zero.
    /// @param _indexToken The index token of the pool
    /// @param _collateralToken The collateral token
    /// @return poolPnl The uncapped pool PnL (always >= 0)
    /// @return maxPnl The max PnL cap = poolTokenUsd * cap ratio
    /// @return cappedPoolPnl The capped pool PnL = min(poolPnl, maxPnl)
    /// @return scaleFactor The capped/uncapped PnL ratio scaled by BASE_RATE
    function getPnlData(address _indexToken, address _collateralToken) public view returns(
        uint256 poolPnl,
        uint256 maxPnl,
        uint256 cappedPoolPnl,
        uint256 scaleFactor
    ) {
        if(!memeData.isAddMeme(_indexToken)) {
            // _poolPnl (totalValue) is always >= 0 because _accumulateLongShortValue only adds tokens with positive aggregate value
            (,, int256 _poolPnl) = _getPoolInstrumentAgg(_indexToken);
            poolPnl = uint256(_poolPnl);

            address _poolTargetToken = dataReader.getTargetIndexToken(_indexToken);
            (uint256 setRate,) = coinData.getCurrRate(_indexToken);
            uint256 poolAmount = vault.poolAmounts(_poolTargetToken, _collateralToken) * setRate / BASE_RATE;
            uint256 poolTokenUsd = vault.tokenToUsdMin(_collateralToken, poolAmount);
            uint256 maxPnlFactorForTraders = getMaxPnlFactorForTraders(_indexToken);
            maxPnl = poolTokenUsd * maxPnlFactorForTraders / BASE_RATE;

            cappedPoolPnl = poolPnl > maxPnl ? maxPnl : poolPnl;

            if(poolPnl == 0) {
                scaleFactor = BASE_RATE;
            } else {
                scaleFactor = cappedPoolPnl * BASE_RATE / poolPnl;
                if(scaleFactor > BASE_RATE) scaleFactor = BASE_RATE;
            }
        }
    }

    /// @notice Apply the pool PnL cap/scale logic to a single position's raw PnL
    /// @dev Meme tokens and losing positions are settled as-is (no cap). Only profitable regular-pool
    ///      positions are capped. Algorithm per requirement:
    ///      - If !_hasProfit or meme token: scaledPnl_i = rawPnl_i (settle as-is).
    ///      - Else if instrumentAgg_k > 0 (instrument net PnL positive, participates in capping):
    ///          scaledPnl_i = min(rawPnl_i * scaleFactor / BASE_RATE, maxPnl)  // pro-rata scale + hard cap
    ///      - Else (instrumentAgg_k <= 0, does not participate in capping):
    ///          scaledPnl_i = min(rawPnl_i, maxPnl)  // settle as-is, still apply per-position hard cap
    ///      Final result is additionally capped by the remaining period hardtop allowance:
    ///          scaledPnl_i = min(scaledPnl_i, remainingUsd)  // per-period remaining loss capacity
    /// @param _indexToken The position's instrument token
    /// @param _rawPnl The raw (uncapped) position PnL, must be >= 0 when _hasProfit is true
    /// @param _hasProfit Whether the position is profitable (rawPnl_i > 0)
    /// @return The scaled/capped position PnL
    function getDelta(
        address _indexToken, 
        uint256 _rawPnl,
        bool _hasProfit
    ) external view returns (uint256) {
        if(!_hasProfit || memeData.isAddMeme(_indexToken)) return _rawPnl;
        (, uint256 maxPnl, , uint256 scaleFactor) = getPnlData(_indexToken, usdt);
        (int256 tokenLongValue, int256 tokenShortValue) = phase.getIndexTokenLongShortValue(_indexToken);
        if(tokenLongValue + tokenShortValue > 0) {
            _rawPnl = _rawPnl * scaleFactor / BASE_RATE;
        }
        _rawPnl = _rawPnl > maxPnl ? maxPnl : _rawPnl;
        // Cap by the remaining per-period loss capacity (0 once the hard cap is reached)
        (uint256 remainingUsd,,) = getRemainingLossCapacity(_indexToken);
        _rawPnl = _rawPnl > remainingUsd ? remainingUsd : _rawPnl;
        return _rawPnl;
    } 

    /// @notice Get a pool's effective hardtopRate, falling back to DEFAULT_HARDTOP_RATE if not set
    /// @dev The input token is resolved to its pool target token via dataReader.getTargetIndexToken.
    /// @param _indexToken Token whose pool's hardtopRate to query
    /// @return The effective hardtop rate for the pool (scaled by BASE_RATE, 10000 = 100%)
    function getHardtopRate(address _indexToken) public view returns(uint256) {
        address _poolTargetToken = dataReader.getTargetIndexToken(_indexToken);
        if(hardtopRate[_poolTargetToken] == 0) return DEFAULT_HARDTOP_RATE;
        return hardtopRate[_poolTargetToken];
    }

    /// @notice Get the remaining hardtop allowance for the current settlement period
    /// @dev Only regular (non-meme) fund pools are subject to the per-period hardtop; meme tokens revert.
    ///      USDT is the only margin token in this project, so all valuation uses the configured usdt address.
    ///      Computes:
    ///      (poolTargetToken, period, periodStartPoolUsd) = resolvePoolPeriod(_indexToken)
    ///      hardtopUsd = periodStartPoolUsd * getHardtopRate(_indexToken) / BASE_RATE
    ///      usedUsd = vault.tokenToUsdMin(usdt, actualLossAmount[period][poolTargetToken][usdt])
    ///      remainingUsd = usedUsd >= hardtopUsd ? 0 : hardtopUsd - usedUsd
    ///      periodStartPoolUsd is the pool net value (fund-pool period-start deposit, USDT-denominated)
    ///      at the start of the current settlement period, resolved by resolvePoolPeriod.
    /// @param _indexToken The instrument token
    /// @return remainingUsd The remaining hardtop allowance in USD (0 if the hard cap is already reached)
    /// @return hardtopUsd The dynamic hard cap in USD
    /// @return usedUsd The current used loss amount in USD
    function getRemainingLossCapacity(address _indexToken) public view returns(uint256 remainingUsd, uint256 hardtopUsd, uint256 usedUsd) {
        _revertIfMeme(_indexToken);
        (address _poolTargetToken, uint256 _period, uint256 periodStartPoolUsd) = resolvePoolPeriod(_indexToken);

        // Dynamic hard cap = period-start pool value * hardtop rate
        uint256 _hardtopRate = getHardtopRate(_indexToken);
        hardtopUsd = periodStartPoolUsd * _hardtopRate / BASE_RATE;

        // Current used loss converted to USD for comparison with the hard cap
        uint256 usedAmount = actualLossAmount[_period][_poolTargetToken][usdt];
        usedUsd = vault.tokenToUsdMin(usdt, usedAmount);

        if(usedUsd >= hardtopUsd) {
            remainingUsd = 0;
        } else {
            remainingUsd = hardtopUsd - usedUsd;
        }
    }

    /// @notice Get the current fund-pool period ID for a pool target token
    /// @dev Only returns the currently active period. Completed (historical) periods are not included,
    ///      so losses from periods before this contract's deployment are never recorded.
    /// @param _poolTargetToken The pool target token
    /// @return The current period ID (reverts if no active period exists)
    function getCurrPeriodID(address _poolTargetToken) public view returns(uint256) {
        uint256 _period = poolDataV2.currPeriodID(poolDataV2.tokenToPool(_poolTargetToken));
        if(_period == 0) revert("_period err"); 
        return _period;
    }

    /// @notice Aggregate net-positive long/short PnL of a single token or a whole member-token group
    /// @dev Only regular (non-meme) pools are supported; meme tokens revert.
    ///      poolPnl equivalent: Σ_k max(instrumentAgg_k, 0), where instrumentAgg_k = long_k + short_k.
    /// @param _indexToken The instrument token (single token, or any member token of the group)
    /// @return longValue Accumulated positive long PnL across instruments
    /// @return shortValue Accumulated positive short PnL across instruments
    /// @return totalValue longValue + shortValue, always >= 0
    function getPoolInstrumentAgg(address _indexToken) public view returns(int256 longValue, int256 shortValue, int256 totalValue) {
        _revertIfMeme(_indexToken);
        (longValue, shortValue, totalValue) = _getPoolInstrumentAgg(_indexToken);
    }

    /// @notice Aggregate net-positive long/short PnL of a single index token or a member-token group
    /// @dev Single tokens (belongTo == 1) accumulate their own PnL; member tokens (belongTo == 2)
    ///      iterate the whole member-token target group. Only net-positive instruments are summed,
    ///      guaranteeing totalValue >= 0.
    /// @param _indexToken The instrument token (single token, or any member token of the group)
    /// @return longValue Accumulated positive long PnL
    /// @return shortValue Accumulated positive short PnL
    /// @return totalValue longValue + shortValue, always >= 0
    function _getPoolInstrumentAgg(address _indexToken) internal view returns(int256 longValue, int256 shortValue, int256 totalValue) {
        (address _poolTargetToken, uint256 _memberTokenTargetID,,uint8 _belongTo) = coinData.getTokenInfo(_indexToken);

        if(_belongTo == 1) {
            (longValue, shortValue) = _accumulateLongShortValue(_indexToken, longValue, shortValue);
        } else if(_belongTo == 2) {
            uint256 _len = coinData.getCurrMemberTokensLength(_poolTargetToken, _memberTokenTargetID);
            for(uint256 i = 0; i < _len; i++) {
                address _memberToken = coinData.getCurrMemberToken(_poolTargetToken, _memberTokenTargetID, i);
                (longValue, shortValue) = _accumulateLongShortValue(_memberToken, longValue, shortValue);
            }
        } else {
            revert("_belongTo err");
        }

        totalValue = longValue + shortValue;
    }

    /// @notice Accumulate an instrument's PnL if its net value is positive
    /// @dev instrumentAgg_k = tokenLongValue + tokenShortValue. Only when instrumentAgg_k > 0 (net positive PnL)
    ///      is the instrument added to the pool totals. Negative or zero-net instruments are skipped,
    ///      so the summed totals only contain positive PnL (instrumentAgg_k), guaranteeing poolPnl >= 0.
    /// @param _indexToken The instrument token to evaluate
    /// @param _longValue Accumulated long PnL so far
    /// @param _shortValue Accumulated short PnL so far
    /// @return Updated (longValue, shortValue) after possibly adding this instrument
    function _accumulateLongShortValue(address _indexToken, int256 _longValue, int256 _shortValue) internal view returns(int256, int256) {
        if(_indexToken != address(0)) {
            (int256 tokenLongValue, int256 tokenShortValue) = phase.getIndexTokenLongShortValue(_indexToken);
            if(tokenLongValue + tokenShortValue > 0) {
                _longValue += tokenLongValue;
                _shortValue += tokenShortValue;
            }
        }
        return (_longValue, _shortValue);
    }

    /// @notice Resolve a regular-pool instrument token to its pool target token, current fund-pool
    ///         period and period-start pool USD value
    /// @dev Only regular (non-meme) fund pools are supported; meme tokens revert (meme & channel pools
    ///      are excluded from PnL capping). Shared by recordActualLoss and getRemainingLossCapacity.
    ///      periodStartPoolUsd = vault.tokenToUsdMin(usdt, getFoundState(tokenToPool(target), period).depositAmount),
    ///      i.e. the pool net value (USDT-denominated) at the start of the current settlement period
    ///      — the per-period hardtop base.
    /// @param _indexToken The instrument token
    /// @return _poolTargetToken The resolved pool target token
    /// @return _period The current fund-pool period ID (reverts if no active period)
    /// @return periodStartPoolUsd The pool value in USD at the start of the current settlement period (hardtop base)
    function resolvePoolPeriod(address _indexToken) public view returns(address _poolTargetToken, uint256 _period, uint256 periodStartPoolUsd) {
        _revertIfMeme(_indexToken);
        (_poolTargetToken, _period, periodStartPoolUsd) = _resolvePoolPeriod(_indexToken);
    }

    /// @notice Internal fund-pool resolution: pool target via dataReader.getTargetIndexToken,
    ///         period via getCurrPeriodID, period-start deposit via poolDataV2.getFoundState
    /// @dev getTargetIndexToken is idempotent: Vault already normalizes the index token to the pool
    ///      target token before calling recordActualLoss, and coinData cannot resolve that normalized
    ///      token (it only maps members -> target), so DataReader's channel-aware resolution is required.
    function _resolvePoolPeriod(address _indexToken) internal view returns(address _poolTargetToken, uint256 _period, uint256 periodStartPoolUsd) {
        _poolTargetToken = dataReader.getTargetIndexToken(_indexToken);
        _period = getCurrPeriodID(_poolTargetToken);
        IStruct.FoundStateV2 memory foundState = poolDataV2.getFoundState(poolDataV2.tokenToPool(_poolTargetToken), _period);
        periodStartPoolUsd = vault.tokenToUsdMin(usdt, foundState.depositAmount);
    }

    /// @notice Get the effective max PnL factor for a regular-pool instrument token
    /// @dev Only regular (non-meme) tokens are supported; meme tokens revert.
    ///      Routing by coinData.getTokenInfo(_indexToken).belongTo:
    ///      - belongTo == 1 (single token, not part of any collection): singleTokenMaxPnlFactorForTraders[poolTarget][indexToken]
    ///      - belongTo == 2 (member token of a pool collection): setMaxPnlFactorForTraders[poolTarget][memberTokenTargetID]
    ///      An unconfigured (0) value falls back to DEFAULT_MAX_PNL_FACTOR_FOR_TRADERS, so the
    ///      returned factor is always within the valid 5%-100% range.
    /// @param _indexToken The instrument token
    /// @return The effective max PnL factor (BASE_RATE-scaled, 10000 = 100%), never 0
    function getMaxPnlFactorForTraders(address _indexToken) public view returns(uint256) {
        _revertIfMeme(_indexToken);
        (address _poolTargetToken, uint256 _memberTokenTargetID,,uint8 _belongTo) = coinData.getTokenInfo(_indexToken);
        if(_belongTo == 1) {
            uint256 factor = singleTokenMaxPnlFactorForTraders[_poolTargetToken][_indexToken];
            return factor == 0 ? DEFAULT_MAX_PNL_FACTOR_FOR_TRADERS : factor;
        } else if(_belongTo == 2) {
            uint256 factor = setMaxPnlFactorForTraders[_poolTargetToken][_memberTokenTargetID];
            return factor == 0 ? DEFAULT_MAX_PNL_FACTOR_FOR_TRADERS : factor;
        } else {
            revert("_belongTo err");
        }
    }

    /// @notice Revert for meme tokens — meme & channel pools are excluded from PnL capping entirely
    /// @param _indexToken The instrument token to check
    function _revertIfMeme(address _indexToken) internal view {
        if(memeData.isAddMeme(_indexToken)) revert("_indexToken err");
    }
}