// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface ISlippage {
    function getVaultPrice(
        address indexToken, 
        uint256 size, 
        bool isLong, 
        uint256 price
    ) external view returns(uint256);

    function validatePrice(
        address _vault, 
        address _indexToken, 
        bool _isLong, 
        uint256 _price
    ) external view returns(uint256);

    function validateMaxGlobalSize(
        address pRouter,
        address _indexToken, 
        bool _isLong, 
        uint256 _sizeDelta
    ) external view;

    function validatePriceDecreasePosition(
        address _vault, 
        address _indexToken, 
        bool _isLong, 
        uint256 _price
    ) external view returns(uint256);

    function validateExecutionOrCancellation(
        address _operater,
        address _contract,
        uint256 _positionBlockNumber, 
        uint256 _positionBlockTime, 
        address _account
    ) external view returns (bool);

    function getValue(
        address user, 
        address indexToken, 
        uint256 poolTotalValue,
        uint256 _poolValue,
        uint256 min, 
        bool isLong
    ) external view returns(uint256, uint256);

    function validateOrderValue(
        address user, 
        uint256 size,
        bool isLong
    ) external view returns(bool);

    function validateLever(
        address user,       
        address token,  
        address indexToken,  
        uint256 _amountIn,
        uint256 _sizeDelta,
        bool isLong
    ) external view returns(bool);

    function getMinOrderValueFor(
        uint256 maxSize, 
        uint256 globalSizes,
        bool isSet
    ) external view returns(uint256, bool);

    function getMinValueFor(
        uint256 min,
        uint256 num,
        uint256 maxSize, 
        uint256 globalSizes,
        bool isSet
    ) external view returns(uint256, uint256);

    function getPhaseMinValue(address indexToken) external view returns(uint256, uint256);

    function getEndTime(address token) external view returns(uint256);

    function validateRemoveTime(address token) external view returns(bool);

    function validateCreate(address token) external view returns(bool);

    function getSizeData(address indexToken) external view returns(
        uint256 globalShortSizes,
        uint256 globalLongSizes,
        uint256 totalSize
    );

    function glpTokenSupply(address _indexToken, address _collateralToken) external view returns(uint256);
    
    function addGlpAmount(address _indexToken, address _collateralToken, uint256 _amount) external;
    
    function subGlpAmount(address _indexToken, address _collateralToken, uint256 _amount) external;

    function getIndexTokensLength() external view returns(uint256);

    function getIndexToken(uint256 index) external view returns(address);

    function addTokens(address indexToken) external;

}