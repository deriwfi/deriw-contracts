// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IPositionRouter {
    function executeIncreasePositions(uint256 _count) external;
    function executeDecreasePositions(uint256 _count) external;
    function getIncreasePositionRequestPath(bytes32 _key) external view returns (address[] memory);
    function getDecreasePositionRequestPath(bytes32 _key) external view returns (address[] memory);
    function createIncreasePosition(
        address[] memory _path,
        address _indexToken,
        uint256 _amountIn,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _acceptablePrice,
        bytes32 _referralCode,
        address _callbackTarget
    ) external returns (bytes32);
    
    function createDecreasePosition(
        address[] memory _path,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _acceptablePrice,
        address _callbackTarget
    ) external  returns (bytes32);
}
