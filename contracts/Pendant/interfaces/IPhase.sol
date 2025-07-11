// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;


import "./IPhaseStruct.sol";

interface IPhase is IPhaseStruct {
    function setKey(
        address user, 
        address collateralToken, 
        address indexToken, 
        bytes32 key, 
        bool isLong
    ) external;

    function getNextGlobalShortAveragePrice(
        address _indexToken, 
        uint256 _nextPrice, 
        uint256 _sizeDelta
    ) external view returns (uint256);

    function getNextGlobalLongAveragePrice(
        address _indexToken, 
        uint256 _nextPrice, 
        uint256 _sizeDelta
    ) external view returns (uint256);

    function usdToToken(address _token, uint256 _usdAmount, uint256 _price) external view returns (uint256);

    function tokenToUsdMin(address _token, uint256 _tokenAmount) external  view returns (uint256);

    function getNextAveragePrice(
        address _indexToken, 
        uint256 _size, 
        uint256 _averagePrice, 
        bool _isLong, 
        uint256 _nextPrice, 
        uint256 _sizeDelta, 
        uint256 _lastIncreasedTime
    ) external view returns (uint256);

    function getGlobalShortDelta(address _token) external view returns (bool, uint256);

    function getDelta(
        address _indexToken, 
        uint256 _size, 
        uint256 _averagePrice, 
        bool _isLong, 
        uint256 _lastIncreasedTime
    ) external view returns (bool, uint256);

    function validateTokens(address _collateralToken, address _indexToken) external view;

    function getValue(address user, address indexToken, bool isLong) external view returns(uint256);
    function validateSizeDelta(address user, address indexToken, uint256 sizeDelta, bool isLong) external view returns(bool);

    function getOutAmount(address _indexToken, address tokenOut, uint256 glpAmount) external view returns(uint256);

    function calculatePrice(address _indexToken, address _token) external;

    function getGlpAmount(address _indexToken, address token, uint256 amount) external view returns(uint256);

    function setPoolDataV2(address _poolDataV2) external;

    function setVault(address valut_) external;

    function setOperator(address account, bool isAdd) external;

    function transferTo(address token, address account, uint256 amount) external;

    function setTotalRate(uint256 totalRate_) external;

    function setSideRate(uint256 sideRate_) external;

    function collectFees(
        address pool, 
        address collateralToken, 
        address indexToken, 
        uint256 pid, 
        address[] memory lUsers,
        address[] memory sUsers,
        uint256 longRate,
        uint256 shortRate
    ) external;

    function typeCode(uint8 cType) external view returns(bytes32);
    function codeType(bytes32 code) external view returns(uint8);
    function getIndextokenValue(address indexToken) external view returns(uint256);

    function getLongShortValue(address indexToken) external view returns(int256 longValue, int256 shortValue);

    function gov() external view returns(address);
    function coinData() external view returns(address);
    function memeData() external view returns(address);
    function poolDataV2() external view returns(address);
    function getTokenPrice(address token) external view returns(uint256); 
    
}
