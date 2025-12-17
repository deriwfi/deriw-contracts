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
}
