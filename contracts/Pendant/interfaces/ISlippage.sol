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
        address /*user*/, 
        address indexToken, 
        uint256 poolTotalValue,
        uint256 _poolValue,
        uint256 min, 
        bool isLong
    ) external view returns(uint256, uint256);

    function validateLever(
        address user,       
        address token,  
        address indexToken,  
        uint256 _amountIn,
        uint256 _sizeDelta,
        bool isLong
    ) external view returns(bool);

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

    function getDecreasePositionNextGlobalLongShortData(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _nextPrice,
        uint256 _sizeDelta,
        bool _isLong
    ) external view returns (uint256, uint256);

    /// @notice Returns the liquidation leverage threshold for a token
    /// @dev    Per current design, tokenMaxLeverage stores the liquidation leverage
    ///         (set via setTokenLeverageConfig), falling back to vault.maxLeverage() when unset.
    /// @param indexToken The token to query (auto-resolved to its underlying index token)
    function getTokenMaxLeverage(address indexToken) external view returns(uint256);

    function dataReader() external view returns(address);

    function getLongNetAmount(address indexToken, uint256 size) external view returns(uint256, uint256);

    function getShortNetAmount(address indexToken, uint256 size) external view returns(uint256, uint256);

    function getMaxPrice(address _indexToken) external view returns(uint256);

    function getMinPrice(address _indexToken) external view returns(uint256);

    function getRate(address indexToken, uint256 size, bool isLong) external view returns(uint256);

    function getDecreaseSlipPrice(address indexToken, uint256 size, bool isLong) external view returns(uint256, uint256, uint256);

    /// @notice Mark-to-market decrease price that skips request-scoped execution caches.
    /// @dev Used for health checks of the remaining position after a partial decrease.
    function getLiquidationPrice(address indexToken, uint256 size, bool isLong) external view returns(uint256, uint256, uint256);

    function slippageControl() external view returns(address);

    function getLongRate(address indexToken, uint256 size) external view returns(uint256);

    function getShortRate(address indexToken, uint256 size) external view returns(uint256);

    /// @notice Returns the (openLeverage, liquidationLeverage) for a token
    /// @dev    openLeverage defaults to liquidationLeverage / 2 when unset.
    /// @param  _indexToken The token to query (auto-resolved to its underlying index token)
    /// @return openLeverage         The effective open leverage (defaults to liquidationLeverage / 2 if unset)
    /// @return liquidationLeverage  The effective liquidation leverage (falls back to vault.maxLeverage() if unset)
    function getTokenLeverage(address _indexToken) external view returns(uint256, uint256);
}