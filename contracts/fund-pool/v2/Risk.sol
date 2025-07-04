// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../../core/interfaces/ITransferAmountData.sol";
import "../../upgradeability/Synchron.sol";
import "../../core/interfaces/IVault.sol";
import "./interfaces/IPoolDataV2.sol";

contract Risk is Synchron, ITransferAmountData {
    using SafeERC20 for IERC20;

    uint256 public constant baseRate = 10000;

    IVault public vault;
    IPoolDataV2 public poolDataV2;
    address public gov;
    address public usdt;
    address public profitAccount;

    uint256 public riskIndex;
    uint256 public fundIndex;

    bool public initialized;

    ProfitData[] public profitData;

    mapping(address => bool) public operator;
    mapping(address => bool) public adminFor;
    mapping(uint256 => DepositData) riskDepositData;
    mapping(uint256 => DepositData) fundDepositData;
    mapping(address => mapping(address => mapping(address => mapping(uint256 => uint256)))) public totalRiskDeposit;
    mapping(address => mapping(address => mapping(address => mapping(uint256 => uint256)))) public totalFundDeposit;

    struct DepositData{
        address from;
        address to;
        address indexToken;
        address collateralToken;
        address poolData;
        address pool;
        uint256 pid;
        uint256 amount;
        uint256 time;
    }

    struct ProfitData{
        address account;
        uint256 rate;
    }

    event SetOperator(address account, bool isAdd);
    event SetAuth(address account, bool isAdd);
    event TransferTo(address indexed token, address indexed account, uint256 amount);
    event RiskDeposit(DepositData dData);
    event FundDeposit(DepositData dData);
    event SetProfitData(ProfitData[] pData);

    modifier onlyGov() {
        require(gov == msg.sender, "gov err");
        _;
    }

    modifier onlyAuth() {
        require(gov == msg.sender ||  adminFor[msg.sender], "not auth");
        _;
    }
  
    function initialize(address _usdt) external {
        require(!initialized, "has initialized");
        require(_usdt != address(0), "addr err");

        initialized = true;

        gov = msg.sender;
        usdt = _usdt;
    }

    function setGov(address account) external onlyGov {
        require(account != address(0), "account err");
        gov = account;
    }

    function setData(
        address _vault,
        address _poolData,
        address _profitAccount
    ) external onlyAuth {
        require(
            _vault != address(0) &&
            _poolData != address(0) &&
            _profitAccount != address(0),
            "addr err"
        );

        vault = IVault(_vault);
        poolDataV2 = IPoolDataV2(_poolData);
        require(address(0) != _profitAccount, "_profitAccount err");
        profitAccount = _profitAccount;
    }

    function setAuth(address account, bool isAdd) external onlyGov {
        require(account != address(0), "account err");

        adminFor[account] = isAdd;

        emit SetAuth(account, isAdd);
    }

    function setOperator(address account, bool isAdd) external onlyAuth {
        require(account != address(0), "account err");

        operator[account] = isAdd;

        emit SetOperator(account, isAdd);
    }

    function setProfitData(ProfitData[] memory pData) external onlyAuth {
        uint256 len = pData.length;
        require(len > 0, "length err");
        delete profitData;

        uint256 total;
        for(uint256 i = 0; i < len; i++) {
            address account = pData[i].account;
            uint256 rate = pData[i].rate;
            total += rate;   
            require(account != address(0) && rate > 0 && total < baseRate, "data err");
            profitData.push(pData[i]);
        }

        emit SetProfitData(pData);
    }

    function transferTo(address token, address account, uint256 amount) external onlyGov {
        require(account != address(0), "account err");

        require(IERC20(token).balanceOf(address(this)) >= amount, "not enough");
        IERC20(token).safeTransfer(account, amount);
            
        emit TransferTo(token, account, amount);
    }

    function riskDeposit(address _indexToken, address _collateralToken, uint256 _amount) external {
        address pool = validate(msg.sender, _indexToken, _collateralToken, _amount);
        IERC20(_collateralToken).safeTransferFrom(msg.sender, address(vault), _amount);

        uint256 index = ++riskIndex;
        uint256 pid = poolDataV2.currPeriodID(pool);
        riskDepositData[index] = _deposit(msg.sender, pool, _indexToken, _collateralToken, pid, _amount);

      
        totalRiskDeposit[address(poolDataV2)][pool][_collateralToken][pid] += _amount;

        emit RiskDeposit(riskDepositData[index]);
    }

    function fundDeposit(address _indexToken, address _collateralToken, uint256 _amount) external {
        address pool = validate(msg.sender, _indexToken, _collateralToken, _amount);

        IERC20(_collateralToken).safeTransfer(address(vault), _amount);
        uint256 index = ++fundIndex;
        uint256 pid = poolDataV2.currPeriodID(pool);

        fundDepositData[index] = _deposit(address(this), pool, _indexToken, _collateralToken, pid, _amount);
        totalFundDeposit[address(poolDataV2)][pool][_collateralToken][pid] += _amount;


        emit FundDeposit(fundDepositData[index]);
    }

    function _deposit(
        address _from,
        address _pool, 
        address _indexToken, 
        address _collateralToken, 
        uint256 _pid,
        uint256 _amount
    ) internal returns(DepositData memory) {
        vault.directPoolDeposit(_indexToken, _collateralToken, _amount);

        return DepositData(
            _from,
            address(vault),
            _indexToken,
            _collateralToken,
            address(poolDataV2),
            _pool,
            _pid,
            _amount,
            block.timestamp
        );

    }

    function validate(address _account, address _indexToken, address _collateralToken, uint256 _amount) public view returns(address) {
        require(_account == gov || operator[_account], "no permission");
        
        require(_collateralToken == usdt, "_collateralToken err");
        require(_amount > 0, "amount err");
        require(vault.whitelistedTokens(_indexToken) && vault.whitelistedTokens(_collateralToken), "not whitelistedToken");

        address pool = poolDataV2.currPool();
        require(pool != address(0), "deposit err");

        return pool;
    }

    function getRiskDepositData(uint256 index) external view returns(DepositData memory) {
        return riskDepositData[index];
    }

    function getFundDepositData(uint256 index) external view returns(DepositData memory) {
        return fundDepositData[index];
    }

    function getProfitData() external view returns(ProfitData[] memory) {
        return profitData;
    }

    function getProfitDataLength() external view returns(uint256) {
        return profitData.length;
    }
}  