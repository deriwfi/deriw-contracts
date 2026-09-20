// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICalculatePNL {
    /// @notice Record the actual loss amount for the current period, callable only by the Phase contract
    /// @dev Only regular (non-meme) fund pools are subject to loss accounting; meme tokens are skipped
    ///      (meme & channel pools are excluded from PnL capping entirely). The (pool target token, period)
    ///      is resolved by the internal fund-pool resolution (dataReader.getTargetIndexToken + current period).
    /// @param _indexToken The instrument token
    /// @param _collateralToken The collateral token (USDT is the only margin token)
    /// @param _amount The actual loss amount for the period
    function recordActualLoss(address _indexToken, address _collateralToken, uint256 _amount) external;

    /// @notice Get pool PnL data: uncapped PnL, max PnL cap, capped PnL and scale factor
    /// @dev Only regular (non-meme) fund pools are capped; for meme tokens this returns all zeros.
    ///      poolPnl aggregates the net-positive PnL of the given instrument — a single token
    ///      (belongTo == 1) or its whole member-token group (belongTo == 2).
    ///      Algorithm (BASE_RATE-scaled, 10000 = 100%):
    ///      poolPnl = Σ_k max(instrumentAgg_k, 0)  (sum of net-positive instrument PnL)
    ///      poolTokenUsd = tokenToUsdMin(_collateralToken, poolAmounts(target, _collateralToken) * setRate / BASE_RATE)
    ///        setRate = coinData.getCurrRate(_indexToken).rate (BASE_RATE-scaled) — scales the raw pool
    ///        token balance to the instrument's effective pool depth.
    ///      maxPnl = poolTokenUsd * maxPnlFactorForTraders / BASE_RATE  (effective pool value * cap ratio)
    ///      cappedPoolPnl = min(poolPnl, maxPnl)
    ///      scaleFactor = poolPnl > 0 ? cappedPoolPnl / poolPnl : 1  (scaled by BASE_RATE)
    /// @param _indexToken The index token of the pool
    /// @param _collateralToken The collateral token
    /// @return poolPnl The uncapped pool PnL (always >= 0)
    /// @return maxPnl The max PnL cap = poolTokenUsd * cap ratio
    /// @return cappedPoolPnl The capped pool PnL = min(poolPnl, maxPnl)
    /// @return scaleFactor The capped/uncapped PnL ratio scaled by BASE_RATE
    function getPnlData(address _indexToken, address _collateralToken) external view returns(
        uint256 poolPnl,
        uint256 maxPnl,
        uint256 cappedPoolPnl,
        uint256 scaleFactor
    );

    /// @notice Apply the pool PnL cap/scale logic to a single position's raw PnL
    /// @dev Meme tokens and losing positions are settled as-is (no cap). Only profitable regular-pool
    ///      positions are capped. Algorithm per requirement (BASE_RATE-scaled):
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
    ) external view returns (uint256);

    /// @notice Get a pool's effective hardtopRate, falling back to DEFAULT_HARDTOP_RATE if not set
    /// @dev Only regular (non-meme) pools are capped; meme tokens revert. The input token is
    ///      resolved to its pool target token via dataReader.getTargetIndexToken.
    /// @param _indexToken Token whose pool's hardtopRate to query
    /// @return The effective hardtop rate for the pool (scaled by BASE_RATE, 10000 = 100%)
    function getHardtopRate(address _indexToken) external view returns(uint256);

    /// @notice Get the remaining hardtop allowance for the current settlement period
    /// @dev Only regular (non-meme) fund pools are subject to the per-period hardtop; meme tokens revert.
    ///      USDT is the only margin token in this project, so all valuation uses the configured usdt address.
    ///      Computes:
    ///      (poolTargetToken, period, periodStartPoolUsd) = resolvePoolPeriod(_indexToken)
    ///      hardtopUsd = periodStartPoolUsd * getHardtopRate(_indexToken) / BASE_RATE
    ///      usedUsd = vault.tokenToUsdMin(usdt, actualLossAmount[period][poolTargetToken][usdt])
    ///      remainingUsd = usedUsd >= hardtopUsd ? 0 : hardtopUsd - usedUsd
    ///      periodStartPoolUsd is the fund-pool period-start deposit (USDT-denominated), the hardtop base.
    /// @param _indexToken The instrument token
    /// @return remainingUsd The remaining hardtop allowance in USD (0 if the hard cap is already reached)
    /// @return hardtopUsd The dynamic hard cap in USD
    /// @return usedUsd The current used loss amount in USD
    function getRemainingLossCapacity(address _indexToken) external view returns(uint256 remainingUsd, uint256 hardtopUsd, uint256 usedUsd);

    /// @notice Resolve a regular-pool instrument token to its pool target token, current fund-pool
    ///         period and period-start pool USD value
    /// @dev Only regular (non-meme) fund pools are supported; meme tokens revert (meme & channel pools
    ///      are excluded from PnL capping). periodStartPoolUsd is the period-start deposit of the fund
    ///      pool (getFoundState(tokenToPool(target), period).depositAmount), USDT-denominated — the
    ///      per-period hardtop base. Reverts if no active fund-pool period exists.
    /// @param _indexToken The instrument token
    /// @return _poolTargetToken The resolved pool target token
    /// @return _period The current fund-pool period ID (reverts if no active period)
    /// @return periodStartPoolUsd The pool value in USD at the start of the current settlement period (hardtop base)
    function resolvePoolPeriod(address _indexToken) external view returns(address _poolTargetToken, uint256 _period, uint256 periodStartPoolUsd);

    /// @notice Get the current fund-pool period ID for a pool target token
    /// @dev Only returns the currently active period. Completed (historical) periods are not included,
    ///      so losses from periods before this contract's deployment are never recorded.
    /// @param _poolTargetToken The pool target token
    /// @return The current period ID (reverts if no active period exists)
    function getCurrPeriodID(address _poolTargetToken) external view returns(uint256);

    /// @notice Aggregate net-positive long/short PnL of a single token or a whole member-token group
    /// @dev Only regular (non-meme) pools are supported; meme tokens revert.
    ///      poolPnl equivalent: Σ_k max(instrumentAgg_k, 0), where instrumentAgg_k = long_k + short_k.
    /// @param _indexToken The instrument token (single token, or any member token of the group)
    /// @return longValue Accumulated positive long PnL across instruments
    /// @return shortValue Accumulated positive short PnL across instruments
    /// @return totalValue longValue + shortValue, always >= 0
    function getPoolInstrumentAgg(address _indexToken) external view returns(int256 longValue, int256 shortValue, int256 totalValue);

    /// @notice Get the effective max PnL factor for a regular-pool instrument token
    /// @dev Only regular (non-meme) tokens are supported; meme tokens revert.
    ///      Routing by coinData.getTokenInfo(_indexToken).belongTo:
    ///      - belongTo == 1 (single token, not part of any collection): singleTokenMaxPnlFactorForTraders[poolTarget][indexToken]
    ///      - belongTo == 2 (member token of a pool collection): setMaxPnlFactorForTraders[poolTarget][memberTokenTargetID]
    ///      An unconfigured (0) value falls back to DEFAULT_MAX_PNL_FACTOR_FOR_TRADERS, so the returned
    ///      factor is always within the valid range.
    /// @param _indexToken The instrument token
    /// @return The effective max PnL factor (BASE_RATE-scaled, 10000 = 100%), never 0
    function getMaxPnlFactorForTraders(address _indexToken) external view returns(uint256);
}
