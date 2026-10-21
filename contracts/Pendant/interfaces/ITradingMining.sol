// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Reporting interface of the trading-mining + payout-queue contract
/// @dev All USD amounts use 30 decimals (parameters expressed in USDT 6 decimals are marked
///      explicitly). The water level is read live from Vault.poolAmounts, therefore no cumulative
///      values are passed in.
interface ITradingMining {
    /// @notice Report the realised PnL of a position close
    /// @dev The implementation prices the closing part itself (same Phase call the Vault uses),
    ///      returns the settlement delta for the Vault's bookkeeping, and pays / enqueues profits.
    ///      A loss triggers the DER payout inside the implementation.
    /// @param _indexToken Index token of the position
    /// @param _collateralToken Collateral token
    /// @param _account Position owner (DER receiver on losses)
    /// @param _isLong true for a long position
    /// @param _sizeDelta Size being closed (USD 30 decimals)
    /// @param _price Execution price used by the Vault for this decrease (USD 30 decimals)
    /// @return hasProfit true = profit (no DER payout), false = loss (DER payout)
    /// @return adjustedDelta Realised PnL of the closing part (USD 30 decimals, absolute value)
    /// @return payableUsd Profit payable immediately (USD 30 decimals); any remainder was enqueued
    function recordPnl(
        address _indexToken,
        address _collateralToken,
        address _account,
        bool _isLong,
        uint256 _sizeDelta,
        uint256 _price
    ) external returns (bool hasProfit, uint256 adjustedDelta, uint256 payableUsd);

    /// @notice Persist the current peak water level as the high watermark
    /// @dev Called by the Vault through VaultUtils on every pool-amount change (M-15).
    ///      H only moves up, so redundant calls are harmless.
    /// @param _indexToken Index token of the pool whose accounting changed
    /// @return targetToken Resolved main-pool targetToken; also returned for non-main pools and
    ///         unconfigured curves, so the caller can use it as the pool index either way
    function syncTrackedLp(address _indexToken) external returns(address);

    /// @notice Report a liquidation (payout base = full collateral, the liquidation fee is not deducted)
    /// @param _indexToken Index token of the position
    /// @param _collateralToken Collateral token
    /// @param _account Position owner (DER receiver)
    /// @param _isLong true for a long position
    function recordLiquidation(
        address _indexToken,
        address _collateralToken,
        address _account,
        bool _isLong,
        uint256 _poolCredit
    ) external;

    /// @notice Settle the queue head in batches (authorized address / keeper)
    /// @dev Records are processed from the current processed id onwards; the head record must be
    ///      fully paid before the next one is touched (no skipping).
    /// @param _indexToken Main-pool index token
    /// @param _maxCount Maximum number of records handled in this call
    /// @return processed Number of records handled (including partial payments)
    /// @return paidTotal Total amount paid in this call (USDT 6 decimals)
    function settleQueue(address _indexToken, uint256 _maxCount)
        external
        returns (uint256 processed, uint256 paidTotal);
}
