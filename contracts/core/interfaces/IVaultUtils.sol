// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "./IEventStruct.sol";

interface IVaultUtils is IEventStruct  {
    function updateCumulativeFundingRate(address _collateralToken, address _indexToken) external returns (bool);
    function validateIncreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _sizeDelta, bool _isLong) external view;
    function validateDecreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver) external view;
    function validateLiquidation(address _account, address _collateralToken, address _indexToken, bool _isLong, bool _raise) external view returns (uint256, uint256);
    function getPositionFee(address _account, address _collateralToken, address _indexToken, bool _isLong, uint256 _sizeDelta) external view returns (uint256);
    function validatePositionFrom(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        uint256 _collateralDelta, 
        uint256 _sizeDelta, 
        bool _isLong, 
        address _receiver
    ) external view returns (bytes32, uint256);

    function collectMarginFees(
        address _account,
        address _collateralToken, 
        address _indexToken, 
        bool _isLong, 
        uint256 _sizeDelta
    ) external view returns (uint256, uint256);

    function getOrderValue(
        address user, 
        bool isLong
    ) external view returns(uint256, bool);

    function getValueFor(
        address user, 
        bool isLong,
        uint256 _min, 
        uint256 num
    ) external view returns(uint256, uint256);

    function increaseUserGlobalLongSize(
        address user, 
        address token, 
        address indexToken,  
        uint256 _amount
    ) external;

    function decreaseUserGlobalLongSize(address user, uint256 _amount) external;
    function decreaseUserGlobalShortSize(address user,  uint256 _amount) external;

    function increaseUserGlobalShortSize(
        address user, 
        address token, 
        address indexToken, 
        uint256 _amount
    ) external;

    function userGlobalLongSizes(address user) external view returns(uint256);
    function userGlobalShortSizes(address user) external view returns(uint256);


}
