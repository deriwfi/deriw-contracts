// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISlippageControl {

    // ============ Read ============

    function getDefaultSlippageParams(address _indexToken)
        external view returns(uint256 defaultBaseCapRate, uint256 defaultImpactFactorK, uint256 defaultExponentN, uint256 defaultSoftThresholdRate);

    function getIndexTokenSlippageParams(address _indexToken)
        external view returns(uint256 baseCapRate, uint256 impactFactorK, uint256 exponentN, uint256 softThresholdRate);

    function getSlipCapMultiplier() external view returns(uint256);

    function getSlipData(address _indexToken, address _collateralToken, uint256 _sizeDelta, bool _isLong)
        external view returns(uint256 baseSlip, uint256 finalSlip, int256 skewAdjustment);

    function getSkewAdjustment(address _indexToken, address _collateralToken, uint256 _sizeDelta, bool _isLong, uint256 _baseSlip)
        external view returns(int256 skewAdjustment);

    function getDecreaseSlipPrice(address indexToken, uint256 size, bool isLong) external view returns(uint256, uint256, uint256);

    /// @notice Mark-to-market decrease price that skips request-scoped execution caches.
    /// @dev Used for health checks of the remaining position after a partial decrease.
    function getLiquidationPrice(address indexToken, uint256 size, bool isLong) external view returns(uint256, uint256, uint256);
    
    // ============ Public State Getters ============

    function MUTI() external view returns(uint256);
    function BASE_RATE_DIVISOR() external view returns(uint256);
    function DEFAULT_BASE_CAP_RATE() external view returns(uint256);
    function DEFAULT_IMPACT_FACTOR_K() external view returns(uint256);
    function DEFAULT_EXPONENT_N() external view returns(uint256);
    function DEFAULT_SLIP_CAP_MULTIPLIER() external view returns(uint256);
    function maxSkewRatio() external view returns(uint256);
    function discountFactor() external view returns(uint256);
    function slipCapMultiplier() external view returns(uint256);
    function initialized() external view returns(bool);
    function gov() external view returns(address);
    function vault() external view returns(address);
    function dataReader() external view returns(address);
}
