// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "./IEventStruct.sol";

interface IVaultUtils is IEventStruct  {
    function validateLiquidation(address _account, address _collateralToken, address _indexToken, bool _isLong, bool _raise) external view returns (uint256, uint256);
    function getPositionFee(address _account, address _collateralToken, address _indexToken, bool _isLong, uint256 _sizeDelta) external view returns (uint256);
    function validatePositionFrom(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        uint256 _collateralDelta, 
        uint256 _sizeDelta, 
        bool _isLong, 
        address /*_receiver*/
    ) external view returns (bytes32, uint256);

    function collectMarginFees(
        address _account,
        address _collateralToken, 
        address _indexToken, 
        bool _isLong, 
        uint256 _sizeDelta
    ) external view returns (uint256, uint256);
    function positionRouter() external view returns (address);

    function validateLiquidationIncreasePositionRouter(
        bytes32 _key, 
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        uint256 _sizeDelta, 
        bool _isLong,
        uint256 _amount
    ) external returns(bool);

    function getCalculatePositionData(
        bytes32 _key, 
        address _collateralToken, 
        address _indexToken
    ) external view  returns (Position memory position, uint256 fee, uint256 feeTokens, uint256 price, uint256 collateralDeltaUsd);

    function validateLiquidationIncreaseOrderBook(
        bytes32 _key, 
        address _collateralToken, 
        address _indexToken, 
        uint256 _sizeDelta, 
        bool _isLong,
        uint256 _amount
    ) external returns(bool);

    function orderBook() external view returns (address);

    function getLiquidationFeeRate(address _indexToken) external view returns(uint256);

    function getLiquidationFee(address _indexToken, address _collateralToken, uint256 _sizeDelta) external view returns(uint256, uint256);

    /// @notice Passthrough: persist the current peak water level as the high watermark
    /// @param _indexToken Index token of the pool whose accounting changed
    function syncTrackedLp(address _indexToken) external returns(address);

    /// @notice Validate the reserved / pool ratio after a reserve or pool-amount change
    /// @dev Reverts directly with "reserve err" (legacy error codes 50 / 52 are no longer used).
    ///      Closing a main-pool position is exempt, so an exit can never be blocked by the ratio.
    ///      Read-only (audit L-11): the caller persists the water-level peak before lowering the
    ///      balance, so this check must not touch storage or call into TradingMining.
    /// @param _indexToken Index token / target token
    /// @param _collateralToken Collateral token
    /// @param _isIncrease true = reserve increase (open), false = pool decrease (close)
    function validateReserveRatio(address _indexToken, address _collateralToken, bool _isIncrease, uint256 _multiplier) external view;

    // ==================== TradingMining passthrough ====================

    /// @notice Report a realised PnL (profit or loss) to TradingMining
    /// @dev TradingMining prices the closing part with the same Phase call the Vault uses, so the
    ///      returned delta matches the settlement exactly.
    /// @param _indexToken Index token of the position
    /// @param _collateralToken Collateral token of the position
    /// @param _account Position owner (DER recipient on losses)
    /// @param _isLong True for a long position
    /// @param _sizeDelta Size being closed (USD 30 decimals)
    /// @param _price Execution price used by the Vault for this decrease (USD 30 decimals)
    /// @return hasProfit True for a profit, false for a loss
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

    /// @notice Report a liquidation to TradingMining
    /// @dev Raw values only; TradingMining reads the collateral from the vault as the mint base.
    /// @param _indexToken Index token of the position
    /// @param _collateralToken Collateral token of the position
    /// @param _account Position owner (DER recipient)
    /// @param _isLong True for a long position
    function recordLiquidation(
        address _indexToken,
        address _collateralToken,
        address _account,
        bool _isLong,
        uint256 _poolCredit
    ) external;
}
