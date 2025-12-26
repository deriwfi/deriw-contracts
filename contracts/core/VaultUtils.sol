// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./interfaces/IVault.sol";
import "../access/Governable.sol";
import "./interfaces/IEventStruct.sol";
import "../Pendant/interfaces/ISlippage.sol";
import "../Pendant/interfaces/IPhase.sol";
import "./interfaces/IPositionRouter.sol";
import "./interfaces/IOrderBook.sol";
import "../upgradeability/Synchron.sol";
import "../peripherals/interfaces/ITimelock.sol";

/**
 * @title VaultUtils
 * @dev Utility contract for vault operations including position validation, liquidation checks, and fee calculations
 * @notice This contract provides helper functions for the vault system including position management and liquidation validation
 */
contract VaultUtils is Synchron, IEventStruct {
    /// @notice Basis points divisor used for percentage calculations
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    /// @notice Vault contract interface
    IVault public vault;
    /// @notice Position router contract interface
    IPositionRouter public positionRouter;
    /// @notice Order book contract interface
    IOrderBook public orderBook;
    /// @notice Slippage calculation contract interface
    ISlippage public slippage;
    /// @notice Phase management contract interface
    IPhase public phase;

    /// @notice Governance address
    address public gov;

    /// @notice Initialization status
    bool public initialized;

    /// @notice Market data mapping by position key
    mapping(bytes32 => CalculatePositionData) marketData;
    /// @notice Limit order data mapping by user and order index
    mapping(address => mapping(uint256 => CalculatePositionData)) limitData;

    /**
     * @dev Struct for storing position calculation data
     * @param position The position details
     * @param fee The fee amount in USD
     * @param feeTokens The fee amount in tokens
     * @param price The execution price
     * @param collateralDeltaUsd The collateral delta in USD
     */
    struct CalculatePositionData {
        Position position;
        uint256 fee;
        uint256 feeTokens;
        uint256 price;
        uint256 collateralDeltaUsd;
    }

    /**
     * @dev Struct for validation data
     * @param account The account address
     * @param collateralToken The collateral token address
     * @param indexToken The index token address
     * @param isLong Whether the position is long
     * @param isLiqu Whether the position is liquidated
     */
    struct ValidateData {
        address account; 
        address collateralToken; 
        address indexToken; 
        bool isLong;
        bool isLiqu;
    }

    /**
     * @dev Struct for increase position data
     * @param key The position key
     * @param account The account address
     * @param collateralToken The collateral token address
     * @param indexToken The index token address
     * @param sizeDelta The change in position size
     * @param isLong Whether the position is long
     * @param amount The token amount
     * @param price The sliding price
     */
    struct IncreaseData {
        bytes32 key;
        address account;
        address collateralToken;
        address indexToken;
        uint256 sizeDelta;
        bool isLong;
        uint256 amount;
        uint256 price;
    }

    /**
     * @dev Struct for liquidation validation data
     * @param account The account address
     * @param collateralToken The collateral token address
     * @param indexToken The index token address
     * @param isLong Whether the position is long
     * @param raise Whether to raise errors on validation failure
     */
    struct ValidateLiquidationData {
        address account;
        address collateralToken;
        address indexToken;
        bool isLong; 
        bool raise;
    }

    /// @notice Event emitted when governance address is changed
    event SetGov(address oldGov, address newGov);

    /**
     * @dev Constructor that sets initialized to true
     */
    constructor() {
        initialized = true;
    }

    /// @dev Modifier to restrict access to governance only
    modifier onlyGov() {
        require(msg.sender == gov, "Governable: forbidden");
        _;
    }

    /// @dev Modifier to restrict access to vault only
    modifier onlyVault() {
        require(address(vault) == msg.sender, "not vault");
        _;
    }

    /**
     * @notice Initializes the contract
     * @dev Can only be called once
     */
    function initialize() external {
        require(!initialized, "INIT");
        initialized = true;
        gov = msg.sender;
    }

    /**
     * @notice Sets the governance address
     * @dev Only callable by governance
     * @param _gov The new governance address
     */
    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "_gov err");
        address oldGov = gov;
        gov = _gov;

        emit SetGov(oldGov, _gov);
    }

    /**
     * @notice Sets the required contract addresses
     * @dev Only callable by governance
     * @param _vault The vault contract address
     * @param _positionRouter The position router contract address
     * @param _orderBook The order book contract address
     * @param _slippage The slippage contract address
     * @param _phase The phase contract address
     */
    function setContract(
        address _vault,
        address _positionRouter,
        address _orderBook,
        address _slippage,
        address _phase
    ) external onlyGov {
        require(
            _vault != address(0) &&
            _positionRouter != address(0) &&
            _orderBook != address(0) &&
            _slippage != address(0) &&
            _phase != address(0), 
            "addr err"
        );
        vault = IVault(_vault);
        positionRouter = IPositionRouter(_positionRouter);
        orderBook = IOrderBook(_orderBook);
        slippage = ISlippage(_slippage);
        phase = IPhase(_phase);
    }

    /**
     * @notice Validates liquidation for position increase from position router
     * @dev Only callable by position router
     * @param _key The position key
     * @param _account The account address
     * @param _collateralToken The collateral token address
     * @param _indexToken The index token address
     * @param _sizeDelta The change in position size
     * @param _isLong Whether the position is long
     * @param _amount The token amount
     * @return bool Whether validation passed
     */
    function validateLiquidationIncreasePositionRouter(
        bytes32 _key, 
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        uint256 _sizeDelta, 
        bool _isLong,
        uint256 _amount
    ) external returns(bool) {
        require(msg.sender == address(positionRouter), "not positionRouter");
        uint256 index = positionRouter.increasePositionKeyToIndex(_key);

        IncreaseData memory iData = IncreaseData(_key, _account, _collateralToken, _indexToken, _sizeDelta, _isLong, _amount, 0);
        uint256 price = positionRouter.getSlippagePrice(iData.key, iData.indexToken, iData.sizeDelta, iData.isLong);
        iData.price = price;

        _validateFeeRate();
        (Position memory position, uint256 fee, uint256 feeTokens, uint256 collateralDeltaUsd) = _getIncreaseData(iData);
        marketData[iData.key].position = position;
        marketData[iData.key].fee = fee;
        marketData[iData.key].feeTokens = feeTokens;        
        marketData[iData.key].price = iData.price;
        marketData[iData.key].collateralDeltaUsd = collateralDeltaUsd;

        ValidateLiquidationData memory vData = ValidateLiquidationData(iData.account, iData.collateralToken, iData.indexToken, iData.isLong, false);

        (uint256 liquidationState,) = _validateLiquidation(position, vData);
        if(liquidationState != 0) {
            positionRouter.setErrState(index, 2);
            return false;
        }
        return true;
    }

    /**
     * @notice Validates liquidation for position increase from order book
     * @dev Only callable by order book
     * @param _key The position key
     * @param _collateralToken The collateral token address
     * @param _indexToken The index token address
     * @param _sizeDelta The change in position size
     * @param _isLong Whether the position is long
     * @param _amount The token amount
     * @return bool Whether validation passed
     */
    function validateLiquidationIncreaseOrderBook(
        bytes32 _key, 
        address _collateralToken, 
        address _indexToken, 
        uint256 _sizeDelta, 
        bool _isLong,
        uint256 _amount
    ) external returns(bool) {
        require(msg.sender == address(orderBook), "not orderBook");
        (address user, uint256 orderIndex, uint256 price) = orderBook.getCurrUserOrderIndex();

        IncreaseData memory iData = IncreaseData(_key, user, _collateralToken, _indexToken, _sizeDelta, _isLong, _amount, price);
        
        _validateFeeRate();
        (Position memory position, uint256 fee, uint256 feeTokens, uint256 collateralDeltaUsd) = _getIncreaseData(iData);

        limitData[user][orderIndex].position = position;
        limitData[user][orderIndex].fee = fee;
        limitData[user][orderIndex].feeTokens = feeTokens;        
        limitData[user][orderIndex].price = price;
        limitData[user][orderIndex].collateralDeltaUsd = collateralDeltaUsd;

        ValidateLiquidationData memory vData = ValidateLiquidationData(iData.account, iData.collateralToken, iData.indexToken, iData.isLong, true);

        _validateLiquidation(position, vData);

        return true;
    }

    /**
     * @notice Gets position details for an account
     * @dev Internal view function
     * @param _account The account address
     * @param _collateralToken The collateral token address
     * @param _indexToken The index token address
     * @param _isLong Whether the position is long
     * @return position The position details
     */
    function getPosition(address _account, address _collateralToken, address _indexToken, bool _isLong) internal view returns (Position memory) {
        IVault _vault = vault;
        Position memory position;
        {
            (uint256 size, uint256 collateral, uint256 averagePrice, , /* reserveAmount */, /* realisedPnl */, /* hasProfit */, uint256 lastIncreasedTime) = _vault.getPosition(_account, _collateralToken, _indexToken, _isLong);
            position.size = size;
            position.collateral = collateral;
            position.averagePrice = averagePrice;
            position.lastIncreasedTime = lastIncreasedTime;
        }
        return position;
    }

    
    /**
     * @notice Validates if a position can be liquidated
     * @dev Checks various liquidation conditions including losses, fees, and leverage
     * @param _account The account address
     * @param _collateralToken The collateral token address
     * @param _indexToken The index token address
     * @param _isLong Whether the position is long
     * @param _raise Whether to revert on validation failure or return error code
     * @return liquidationState 0 = safe, 1 = liquidatable, 2 = max leverage exceeded
     * @return marginFees The calculated margin fees for the position
     */
    function validateLiquidation(address _account, address _collateralToken, address _indexToken, bool _isLong, bool _raise) public view returns (uint256, uint256) {
        Position memory position = getPosition(_account, _collateralToken, _indexToken, _isLong);
        ValidateLiquidationData memory vData = ValidateLiquidationData(_account, _collateralToken, _indexToken, _isLong, _raise);

        return _validateLiquidation(position, vData);
    }

    /**
     * @notice Internal liquidation validation logic
     * @dev Performs detailed checks on position health including PnL, fees, and leverage ratios
     * @param position The position data
     * @param vData Validation parameters and flags
     * @return liquidationState 0 = safe, 1 = liquidatable, 2 = max leverage exceeded
     * @return marginFees The calculated margin fees
     */
    function _validateLiquidation(
        Position memory position,
        ValidateLiquidationData memory vData
    ) internal view returns (uint256, uint256) {
        IVault _vault = vault;
        (bool hasProfit, uint256 delta) = _vault.getDelta(vData.indexToken, position.size, position.averagePrice, vData.isLong, position.lastIncreasedTime);

        uint256 marginFees = getPositionFee(vData.account, vData.collateralToken, vData.indexToken, vData.isLong, position.size);

        if (!hasProfit && position.collateral < delta) {
            if (vData.raise) { revert("Vault: losses exceed collateral"); }
            return (1, marginFees);
        }

        uint256 remainingCollateral = position.collateral;
        if (!hasProfit) {
            remainingCollateral = position.collateral - delta;
        }

        if (remainingCollateral < marginFees) {
            if (vData.raise) { revert("Vault: fees exceed collateral"); }
            // cap the fees to the remainingCollateral
            return (1, remainingCollateral);
        }

        if (remainingCollateral < marginFees + _vault.liquidationFeeUsd()) {
            if (vData.raise) { revert("Vault: liquidation fees exceed collateral"); }
            return (1, marginFees);
        }

        uint256 maxLeverage = slippage.getTokenMaxLeverage(vData.indexToken);
        if (remainingCollateral * maxLeverage < position.size * BASIS_POINTS_DIVISOR) {
            if (vData.raise) { revert("Vault: maxLeverage exceeded"); }
            return (2, marginFees);
        }

        return (0, marginFees);
    }

    /**
     * @notice Calculates position fees based on size delta
     * @dev Applies margin fee basis points to calculate the fee amount
     * @param _sizeDelta The change in position size
     * @return feeAmount The calculated fee amount
     */
    function getPositionFee(address /* _account */, address /* _collateralToken */, address /* _indexToken */, bool /* _isLong */, uint256 _sizeDelta) public view returns (uint256) {
        if (_sizeDelta == 0) { return 0; }
        // _sizeDelta * (10000 - 2) / 10000
        uint256 afterFeeUsd = _sizeDelta * (BASIS_POINTS_DIVISOR - vault.marginFeeBasisPoints()) / BASIS_POINTS_DIVISOR;
        return _sizeDelta - afterFeeUsd;//2%
    }

    /**
     * @notice Validates position parameters for modification operations
     * @dev Checks position existence and sufficient size/collateral for the requested delta
     * @param _account The account address
     * @param _collateralToken The collateral token address
     * @param _indexToken The index token address
     * @param _collateralDelta The requested collateral change
     * @param _sizeDelta The requested position size change
     * @param _isLong Whether the position is long
     * @return key The position key
     * @return reserveDelta The calculated reserve amount delta
     */
    function validatePositionFrom(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        uint256 _collateralDelta, 
        uint256 _sizeDelta, 
        bool _isLong, 
        address /*_receiver*/
    ) external onlyVault view returns (bytes32, uint256) {
        bytes32 key = vault.getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = vault.getPositionFrom(key);

        require(
            position.size > 0 && 
            position.size >= _sizeDelta && 
            position.collateral >= _collateralDelta, 
            "size err"
        );

        uint256 reserveDelta = position.reserveAmount * _sizeDelta / position.size;

        return (key, reserveDelta);        
    }

    /**
     * @notice Calculates margin fees in both USD and token amounts
     * @dev Converts USD fee amount to minimum token equivalent
     * @param _account The account address
     * @param _collateralToken The collateral token address
     * @param _indexToken The index token address
     * @param _isLong Whether the position is long
     * @param _sizeDelta The position size change
     * @return feeUsd The fee amount in USD
     * @return feeTokens The fee amount in tokens (minimum conversion)
     */
    function collectMarginFees(
        address _account,
        address _collateralToken, 
        address _indexToken, 
        bool _isLong, 
        uint256 _sizeDelta
    ) public view returns (uint256, uint256) {
        uint256 feeUsd = getPositionFee(_account, _collateralToken, _indexToken, _isLong, _sizeDelta);

        uint256 feeTokens = vault.usdToTokenMin(_collateralToken, feeUsd);

        return (feeUsd, feeTokens);
    }

    /**
     * @notice Batch validates liquidation status for multiple positions
     * @dev Processes an array of positions and returns their liquidation status
     * @param vData Array of validation data for multiple positions
     * @return data Array with updated liquidation flags
     */
    function batchValidateLiquidation(ValidateData[] memory vData) external view returns (ValidateData[] memory) {
        uint256 len = vData.length;
        ValidateData[] memory data = new ValidateData[](len);

        for(uint256 i = 0; i < len; i++) {
            ValidateData memory _data = vData[i];
            (uint256 liquidationState,) = validateLiquidation(
                _data.account, 
                _data.collateralToken, 
                _data.indexToken, 
                _data.isLong, 
                false    
            );

            data[i] = _data;
            if(liquidationState != 0) {
                data[i].isLiqu = true;
            }
        }
        return data;
    }

    // ***************************************
    /**
     * @notice Retrieves calculated position data for a given position key
     * @dev Fetches position details including fees and collateral data from storage
     * @param _key The position key identifier
     * @param _collateralToken The collateral token address
     * @param _indexToken The index token address
     * @return position The position data
     * @return fee The fee amount
     * @return feeTokens The fee in tokens
     * @return price The current price
     * @return collateralDeltaUsd The collateral change in USD
     */
    function getCalculatePositionData(
        bytes32 _key, 
        address _collateralToken, 
        address _indexToken
    ) external onlyVault view returns (Position memory position, uint256 fee, uint256 feeTokens, uint256 price, uint256 collateralDeltaUsd) {
        require(vault.isFrom(_collateralToken) && _collateralToken == vault.usdt(), "TOKEN");
        slippage.validateRemoveTime(_indexToken);
        require(vault.isLeverageEnabled(), "Vault: leverage not enabled");
        phase.validateTokens(_collateralToken, _indexToken);

        uint256 index = positionRouter.increasePositionKeyToIndex(_key);
        if(index != 0) {
            position = marketData[_key].position;
            fee = marketData[_key].fee;
            feeTokens = marketData[_key].feeTokens;
            price = marketData[_key].price;
            collateralDeltaUsd = marketData[_key].collateralDeltaUsd;
        } else{
            (address user, uint256 orderIndex,) = orderBook.getCurrUserOrderIndex();
            if(user == address(0)) {
                revert("unknown");
            }
            position = limitData[user][orderIndex].position;
            fee = limitData[user][orderIndex].fee;
            feeTokens = limitData[user][orderIndex].feeTokens;
            price = limitData[user][orderIndex].price;
            collateralDeltaUsd = limitData[user][orderIndex].collateralDeltaUsd;
        }
        require(position.size > 0 && position.size >= position.collateral, "position size err");
    }

    /**
     * @notice Internal function to calculate increase position data
     * @dev Updates position parameters and calculates fees for position increase
     * @param iData Increase position data parameters
     * @return position Updated position data
     * @return fee Calculated fee amount
     * @return feeTokens Fee amount in tokens
     * @return collateralDeltaUsd Collateral change in USD
     */
    function _getIncreaseData(
        IncreaseData memory iData
    ) internal view returns (Position memory, uint256, uint256, uint256) {
        bytes32 key = vault.getPositionKey(iData.account, iData.collateralToken, iData.indexToken, iData.isLong);
        Position memory position = vault.getPositionFrom(key);

        if (position.size == 0) {
            position.averagePrice = iData.price;
        }

        if (position.size > 0 && iData.sizeDelta > 0) {
            position.averagePrice = phase.getNextAveragePrice(iData.indexToken, position.size, position.averagePrice, iData.isLong, iData.price, iData.sizeDelta, position.lastIncreasedTime);
        }

        (uint256 fee, uint256 feeTokens) = collectMarginFees(iData.account, iData.collateralToken, iData.indexToken, iData.isLong, iData.sizeDelta);
        uint256 collateralDeltaUsd = phase.tokenToUsdMin(iData.collateralToken, iData.amount);
        position.collateral += collateralDeltaUsd;
        require(position.collateral >= fee, "Vault: insufficient collateral for fees");
        position.collateral -= fee;
        position.size += iData.sizeDelta;
        position.lastIncreasedTime = block.timestamp;

        return (position, fee, feeTokens, collateralDeltaUsd);
    }

    function _validateFeeRate() internal view {
        ITimelock timelock = ITimelock(vault.gov());
        uint256 mRate = vault.marginFeeBasisPoints();
        require(
            mRate == timelock.marginFeeBasisPoints() && mRate == timelock.maxMarginFeeBasisPoints(),
            "fee rate err"
        );
    }
}