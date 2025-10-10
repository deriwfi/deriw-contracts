// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../core/interfaces/ITransferAmountData.sol";
import "../upgradeability/Synchron.sol";
import "../core/interfaces/IVault.sol";
import "./interfaces/IMemeData.sol";
import "../Pendant/interfaces/ICoinData.sol";

/**
 * @title MemeRisk Contract
 * @notice A risk management contract for meme token deposits and fee tracking
 * @dev Inherits from Synchron and implements ITransferAmountData interface
 */
contract MemeRisk is Synchron, ITransferAmountData {
    using SafeERC20 for IERC20;

    /**
     * @notice CoinData contract interface
     * @dev Used for token to pool mappings
     */
    ICoinData public coinData;

    /**
     * @notice MemeData contract interface
     * @dev Used for meme token validations
     */
    IMemeData public memeData;

    /**
     * @notice Address of Vault contract
     */
    IVault public vault;

    /**
     * @notice Address of referralData contract
     */
    address public referralData;

    /**
     * @notice Governance address
     */
    address public gov;

    /**
     * @notice USDT token address
     */
    address public usdt;

    /**
     * @notice Fund deposit index counter
     */
    uint256 public fundIndex;

    /**
     * @notice Initialization status flag
     */
    bool public initialized;

    /**
     * @notice Mapping of operator addresses
     * @dev Tracks which addresses have operator privileges
     */
    mapping(address => bool) public operator;

    /**
     * @notice Mapping of fund deposit data by index
     */
    mapping(uint256 => DepositData) fundDepositData;

    /**
     * @notice Mapping of token fees by index token and index
     */
    mapping(address => mapping(uint256 => IndexTokenFee)) public indexTokenFee;


    /**
     * @notice Deposit data structure
     * @dev Contains complete deposit information
     * @param from Sender address
     * @param to Recipient address (vault)
     * @param indexToken Meme token address
     * @param collateralToken USDT address
     * @param mData MemeData contract address
     * @param pool Target liquidity pool
     * @param index Deposit reference index
     * @param amount Deposit amount
     * @param time Deposit timestamp
     */
    struct DepositData {
        address from;
        address to;
        address indexToken;
        address collateralToken;
        address mData;
        address pool;
        uint256 index;
        uint256 amount;
        uint256 time;
    }

    /**
     * @notice Index token fee structure
     * @dev Tracks added and used fees for index tokens
     * @param addFee Added fees
     * @param useFee The fee that has already been deposited
     */
    struct IndexTokenFee {
        uint256 addFee;
        uint256 useFee;
    }

    /**
     * @notice Amount information structure
     * @dev Contains index and amount pairs
     * @param index The fee index
     * @param amount The quantity of fees
     */
    struct AmountInfo {
        uint256 index;
        uint256 amount;
    }

    /**
     * @notice Fund deposit data structure
     * @dev Contains index token, collateral token and amount info array
     * @param indexToken The indexToken address
     * @param collateralToken The collateralToken address
     * @param AmountInfo The data of AmountInfo
     */
    struct FundDepositData {
        address indexToken;
        address collateralToken;
        AmountInfo[] amountInfo;
    }

    /**
     * @notice Emitted when fee amount is added
     * @param indexToken The index token address
     * @param index The fee index
     * @param fee The fee amount added
     */
    event AddFeeAmount(address indexToken, uint256 index, uint256 fee);

    /**
     * @notice Emitted when operator status is changed
     * @param account The operator address
     * @param isAdd True if added, false if removed
     */
    event SetOperator(address account, bool isAdd);

    /**
     * @notice Emitted when multiple fund deposits occur
     * @param fundData Array of fund deposit data
     */
    event BatchFundDeposit(FundDepositData[] fundData);

    /**
     * @notice Emitted when a fund deposit occurs
     * @param dData The deposit data
     */
    event FundDeposit(DepositData dData);


    constructor() {
        initialized = true;
    }

    /**
     * @notice Modifier for governance-only functions
     */
    modifier onlyGov() {
        require(gov == msg.sender, "gov err");
        _;
    }

    /**
     * @notice Initializes contract with USDT address
     * @dev Can only be called once
     * @param _usdt The USDT token address
     */
    function initialize(address _usdt) external {
        require(!initialized, "has initialized");
        require(_usdt != address(0), "addr err");

        initialized = true;

        gov = msg.sender;
        usdt = _usdt;
    }

    /**
     * @notice Sets governance address
     * @dev Can only be called by governance
     * @param account The new governance address
     * @custom:require Account must not be zero address
     */
    function setGov(address account) external onlyGov {
        require(account != address(0), "account err");
        gov = account;
    }

    /**
     * @notice Sets required contract addresses
     * @dev Can only be called by governance
     * @param _vault The vault contract address
     * @param _memeData The memeData contract address
     * @param _coinData The coinData contract address
     * @param _referralData The referralData contract address
     */
    function setContract(
        address _vault,
        address _memeData,
        address _coinData,
        address _referralData
    ) external onlyGov {
        require(
            _vault != address(0) &&
            _memeData != address(0) &&
            _coinData != address(0) &&
            _referralData != address(0),
            "addr err"
        );

        vault = IVault(_vault);
        memeData = IMemeData(_memeData);
        coinData = ICoinData(_coinData);
        referralData = _referralData;
    }

    /**
     * @notice Sets operator status for an address
     * @dev Can only be called by governance
     * @param account The operator address
     * @param isAdd True to add operator, false to remove
     */
    function setOperator(address account, bool isAdd) external onlyGov {
        require(account != address(0), "account err");

        operator[account] = isAdd;

        emit SetOperator(account, isAdd);
    }

    /**
     * @notice Adds fee amount for index token
     * @dev Can only be called by referralData contract
     * @param _indexToken The index token address
     * @param _index The fee index
     * @param _fee The fee amount to add
     */
    function addFeeAmount(address _indexToken, uint256 _index, uint256 _fee) external {
        require(msg.sender == referralData, "not referralData");

        indexTokenFee[_indexToken][_index].addFee += _fee;
        emit AddFeeAmount(_indexToken, _index, _fee);
    }

    /**
     * @notice Processes multiple fund deposits
     * @dev Can only be called by operators
     * @param _fundDepositData Array of fund deposit data
     * @custom:require Caller must be operator
     * @custom:require Input array must not be empty
     */
    function batchFundDeposit(FundDepositData[] memory _fundDepositData) external {
        require(operator[msg.sender], "operator err");

        uint256 _len = _fundDepositData.length;
        require(_len > 0, "length err");
        for(uint256 i = 0; i < _len; i++) {
            FundDepositData memory _fData = _fundDepositData[i];
            _batchDeposit(_fData.indexToken, _fData.collateralToken, _fData.amountInfo);
        }

        emit BatchFundDeposit(_fundDepositData);
    } 

    /**
     * @notice Internal function to process batch deposits
     * @dev Validates tokens and processes each amount info
     * @param _indexToken The index token address
     * @param _collateralToken The collateral token address
     * @param _amountInfo Array of amount information
     */
    function _batchDeposit(address _indexToken, address _collateralToken, AmountInfo[] memory _amountInfo) internal {
        address _pool = validateToken(_indexToken, _collateralToken);
        uint256 _lenAmountInfo = _amountInfo.length;
        for(uint256 j = 0; j < _lenAmountInfo; j++) {
            _fundDeposit(_indexToken, _collateralToken, _pool, _amountInfo[j].index, _amountInfo[j].amount);
        }
    }

    /**
     * @notice Internal function to process single fund deposit
     * @dev Validates deposit, updates fees, and records deposit
     * @param _indexToken The index token address
     * @param _collateralToken The collateral token address
     * @param _pool The pool address
     * @param _index The deposit index
     * @param _amount The deposit amount
     */
    function _fundDeposit(address _indexToken, address _collateralToken, address _pool, uint256 _index, uint256 _amount) internal {
        validate(_indexToken, _index, _amount);

        indexTokenFee[_indexToken][_index].useFee += _amount;
        IERC20(_collateralToken).safeTransfer(address(vault), _amount);
        uint256 _fIndex = ++fundIndex;

        fundDepositData[_fIndex] = _deposit(address(this), _pool, _indexToken, _collateralToken, _index, _amount);
        emit FundDeposit(fundDepositData[_fIndex]);
    }

    /**
     * @notice Internal function to execute deposit
     * @dev Performs actual vault deposit and returns deposit data
     * @param _from The sender address
     * @param _pool The pool address
     * @param _indexToken The index token address
     * @param _collateralToken The collateral token address
     * @param _index The deposit index
     * @param _amount The deposit amount
     * @return DepositData The created deposit data
     */
    function _deposit(
        address _from,
        address _pool, 
        address _indexToken, 
        address _collateralToken, 
        uint256 _index,
        uint256 _amount
    ) internal returns(DepositData memory) {
        vault.directPoolDeposit(_indexToken, _collateralToken, _amount);

        return DepositData(
            _from,
            address(vault),
            _indexToken,
            _collateralToken,
            address(memeData),
            _pool,
            _index,
            _amount,
            block.timestamp
        );
    }

    /**
     * @notice Validates token pair for deposit
     * @dev Checks collateral token, meme status and whitelist
     * @param _indexToken The index token address
     * @param _collateralToken The collateral token address
     * @return pool The validated pool address
     * @custom:require Collateral must be USDT
     * @custom:require _indexToken must be valid meme
     * @custom:require _indexToken must be whitelisted
     * @custom:require Pool must exist for token
     */
    function validateToken(address _indexToken, address _collateralToken) public view returns(address) {
        require(
            _collateralToken == usdt &&
            memeData.isAddMeme(_indexToken) &&
            vault.whitelistedTokens(_indexToken),
            "token err"
        );

        address _targetToken = coinData.getTokenToPoolTargetToken(_indexToken);
        address pool = memeData.tokenToPool(_targetToken);
        require(pool != address(0), "pool err");

        return pool;
    }

    /**
     * @notice Validates deposit amount
     * @dev Checks amount is positive and within fee limits
     * @param _indexToken The index token address
     * @param _index The deposit index
     * @param _amount The deposit amount
     * @return bool True if validation passes
     * @custom:require Amount must be positive
     * @custom:require Available fees must cover amount
     */
    function validate(
        address _indexToken, 
        uint256 _index, 
        uint256 _amount
    ) public view returns(bool) {
        require(
            _amount > 0 && 
            (indexTokenFee[_indexToken][_index].addFee >= _amount + indexTokenFee[_indexToken][_index].useFee), 
            "amount err"
        );

        return true;
    }

    /**
     * @notice Gets fund deposit data by index
     * @param fIndex The fund deposit index
     * @return DepositData The deposit data
     */
    function getFundDepositData(uint256 fIndex) external view returns(DepositData memory) {
        return fundDepositData[fIndex];
    }

}  