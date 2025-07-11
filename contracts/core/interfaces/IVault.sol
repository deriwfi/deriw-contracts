// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IVaultUtils.sol";


interface IVault is IEventStruct {
    function isLeverageEnabled() external view returns (bool);
    function setError(uint256 _errorCode, string calldata _error) external;

    function usdt() external view returns (address);
    function router() external view returns (address);
    function gov() external view returns (address);

    function maxLeverage() external view returns (uint256);

    function minProfitTime() external view returns (uint256);
    function totalTokenWeights() external view returns (uint256);
    function inPrivateLiquidationMode() external view returns (bool);
    function isLiquidator(address _account) external view returns (bool);
    function isManager(address _account) external view returns (bool);

    function minProfitBasisPoints(address _token) external view returns (uint256);
    function tokenBalances(address _indexToken, address _collateralToken) external view returns (uint256);
    function setMaxLeverage(uint256 _maxLeverage) external;
    function setManager(address _manager, bool _isManager) external;
    function setIsLeverageEnabled(bool _isLeverageEnabled) external;
    function setMaxGlobalShortSize(address _token, uint256 _amount) external;
    function setInPrivateLiquidationMode(bool _inPrivateLiquidationMode) external;
    function setLiquidator(address _liquidator, bool _isActive) external;

    function setFees(
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 _minProfitTime
    ) external;

    function setTokenConfig(
        address _token,
        uint256 _tokenDecimals,
        uint256 _redemptionBps,
        uint256 _minProfitBps,
        bool _isStable,
        bool _isShortable,
        bool _iswrapped,
        bool _isFrom
    ) external;

    function setPriceFeed(address _priceFeed) external;

    function directPoolDeposit(address _indexToken, address _collateralToken, uint256 _amount) external;
    function addTokenBalances(address _indexToken, address _collateralToken, uint256 _amount) external;
    
    
    function transferOut(
        address _indexToken, 
        address _collateralToken, 
        address _receiver, 
        uint256 amount
    ) external;

    function increasePosition(
        bytes32 _key, 
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        uint256 _sizeDelta, 
        bool _isLong,
        uint256 _amount
    ) external;

    function decreasePosition(
        bytes32 _key, 
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        uint256 _collateralDelta, 
        uint256 _sizeDelta, 
        bool _isLong, 
        address _receiver
    ) external returns (uint256);

    function validateLiquidation(
        address _account,
        address _collateralToken, 
        address _indexToken, 
        bool _isLong, 
        bool _raise
    ) external view returns (uint256, uint256);

    function liquidatePosition(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        bool _isLong, 
        address _feeReceiver
    ) external;
    
    function tokenToUsdMin(address _token, uint256 _tokenAmount) external view returns (uint256);

    function priceFeed() external view returns (address);
    function liquidationFeeUsd() external view returns (uint256);
    function marginFeeBasisPoints() external view returns (uint256);

    function allWhitelistedTokensLength() external view returns (uint256);
    function allWhitelistedTokens(uint256) external view returns (address);
    function whitelistedTokens(address _token) external view returns (bool);
    function stableTokens(address _token) external view returns (bool);
    function shortableTokens(address _token) external view returns (bool);
    function iswrapped(address _token) external view returns (bool);
    function isFrom(address _token) external view returns (bool);

    function globalShortSizes(address _token) external view returns (uint256);
    function globalLongSizes(address _token) external view returns (uint256);
    
    function globalShortAveragePrices(address _token) external view returns (uint256);
    function maxGlobalShortSizes(address _token) external view returns (uint256);
    function maxGlobalLongSizes(address _token) external view returns (uint256);
    function tokenDecimals(address _token) external view returns (uint256);
    function tokenWeights(address _token) external view returns (uint256);
    function guaranteedUsd(address _indexToken, address _token) external view returns (uint256);
    function poolAmounts(address _indexToken, address _token) external view returns (uint256);
    function reservedAmounts(address _indexToken, address _token) external view returns (uint256);

    function getMaxPrice(address _token) external view returns (uint256);
    function getMinPrice(address _token) external view returns (uint256);

    function getDelta(address _indexToken, uint256 _size, uint256 _averagePrice, bool _isLong, uint256 _lastIncreasedTime) external view returns (bool, uint256);
    function getPosition(address _account, address _collateralToken, address _indexToken, bool _isLong) external view returns (uint256, uint256, uint256, uint256, uint256, uint256, bool, uint256);
    function setSlippage(address slippage_, address phase_, address referralData_) external;
    
    function globalLongAveragePrices(address _token) external view returns (uint256);
    function validate(bool _condition, uint256 _errorCode) external view;
    function slippage() external view returns (address);

    function getPositionKey(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        bool _isLong
    ) external pure returns (bytes32);

    function getPositionFrom(bytes32 key) external view returns(Position memory);
    function usdToTokenMin(address _token, uint256 _usdAmount) external view returns (uint256);

    function MIN_LEVERAGE() external view returns (uint256);
    function MAX_LEVERAGE() external view returns (uint256);
    
    function phase() external view returns (address);
    function vaultUtils() external view returns (address);

    function autoDecreasePosition(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        bool _isLong
    ) external returns(uint256);

    function setData(
        address _router,
        uint256 _liquidationFeeUsd,
        uint256 _multiplier,
        IVaultUtils _vaultUtils,
        address _errorController
    ) external;
    
}
