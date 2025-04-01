// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../core/interfaces/IMintable.sol";
import "../access/Governable.sol";
import "./interfaces/IL1GatewayRouter.sol";
import "../upgradeability/Synchron.sol";

pragma solidity ^0.8.0;

contract UserL2ToL3Router is Synchron {
    using SafeERC20 for IERC20;

    uint256 public constant BASERATE = 10000;
    uint256 public feeRate;

    bool public initialized;

    IL1GatewayRouter public l2GatewayRouter;
    IERC20 public deriwCoin;

    address public l2Usdt;
    address public gov;

    mapping(address => mapping(uint256 => TransferData)) transferData;
    mapping(address => mapping(address => mapping(uint256 => uint256))) public userIndexToTotalIndex;
    mapping(address => DepositInfo) totalDepositInfo;
    mapping(address => mapping(address => DepositInfo)) public userDepositInfo;
    mapping(address => uint256) public minTokenFee;
    mapping(address => uint256) public tokenFee;

    struct DepositInfo {
        uint256 totalIndex;
        uint256 totalAmount;
    }

    struct TransferData {
        address token;
        address from;
        address to;
        uint256 amount;
        uint256 fee;
        uint256 time;
    }

    struct MinTokenFee {
        address token;
        uint256 minFeeAmount;
    }


    event ClaimFee(address token, address account, uint256 amount);
    event TransferTo(address indexed token, address indexed account, uint256 amount);

    event L2ToL3RouterOutboundTransfer(
        address token, 
        uint256 tIndex, 
        uint256 uIndex, 
        TransferData tData
    );

    modifier onlyGov() {
        require(msg.sender == gov, "no permission");
        _;
    }
    
    function initialize(
        address _deriwCoin,
        address _l2Usdt,
        address _l2GatewayRouter,
        MinTokenFee[] memory _mFee
    ) external {
        require(!initialized, "has initialized");
        initialized = true;

        l2GatewayRouter = IL1GatewayRouter(_l2GatewayRouter);
        gov = msg.sender;
        deriwCoin = IERC20(_deriwCoin);
        l2Usdt = _l2Usdt;
        feeRate = 200; 
        setMinTokenFee(_mFee);
    }

    function transferTo(address token, address account, uint256 amount) external onlyGov {
        require(IERC20(token).balanceOf(address(this)) >= amount, "not enough");
        IERC20(token).safeTransfer(account, amount);
            
        emit TransferTo(token, account, amount);
    }

    function outboundTransfer(
        address _token,
        address _to,
        uint256 _amount,
        uint256 _maxGas,
        uint256 _gasPriceBid,
        bytes calldata _data
    ) external payable {
        require(_token == l2Usdt, "token err");
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        uint256 _fee = _amount * feeRate / BASERATE;
        _fee =  _fee > minTokenFee[_token] ? _fee :  minTokenFee[_token];
        require(_amount > _fee, "amount err");

        tokenFee[_token] += _fee;
        _amount = _amount - _fee;
        address getWay = l2GatewayRouter.getGateway(_token);
        IERC20(_token).approve(getWay, _amount);
        IERC20(_token).approve(address(l2GatewayRouter), _amount);
        deriwCoin.approve(address(l2GatewayRouter), 1e20);
        deriwCoin.approve(getWay, 1e20);

        l2GatewayRouter.outboundTransfer{ value: msg.value }(
                _token,
                _to,
                _amount,
                _maxGas,
                _gasPriceBid,
                _data
        );

        uint256 index = ++totalDepositInfo[_token].totalIndex;
        TransferData memory _tData = TransferData(
                _token,
                msg.sender,
                _to,
                _amount,
                _fee,
                block.timestamp
        );

        transferData[_token][index] = _tData;
        totalDepositInfo[_token].totalAmount += _amount;
        uint256 uIndex = ++userDepositInfo[_token][msg.sender].totalIndex;
        userIndexToTotalIndex[_token][msg.sender][uIndex] = index;
        userDepositInfo[_token][msg.sender].totalAmount += _amount;

        emit L2ToL3RouterOutboundTransfer(_token, index, uIndex, _tData);
    }

    function claimFee(address token, address account, uint256 amount) external onlyGov() {
        require(account != address(0), "account err");
        require(
            IERC20(token).balanceOf(address(this)) >= amount &&
            tokenFee[token] >= amount, 
            "amount err"
        );

        tokenFee[token] -= amount;
        IERC20(token).safeTransfer(account, amount);
        emit ClaimFee(token, account, amount);
    }

    function setFeeRate(uint256 _rate) external onlyGov() {
        require(_rate< BASERATE, "rate err");

        feeRate = _rate;
    }

    function setMinTokenFee(MinTokenFee[] memory mFee) public onlyGov() {
        uint256 len = mFee.length;
        require(len > 0, "length err");
        for(uint256 i = 0; i < len; i++) {
            minTokenFee[mFee[i].token] = mFee[i].minFeeAmount;
        }
    }

    function setContract(address _l2GatewayRouter) external onlyGov() {
        l2GatewayRouter = IL1GatewayRouter(_l2GatewayRouter);
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "account err");
        gov = _gov;
    }

    function getTotalDepositInfo(address token) external view returns(DepositInfo memory) {
        return totalDepositInfo[token];
    }

    function getTransferData(address token, uint256 index) public view returns(TransferData memory) {
        return transferData[token][index];
    }

    function getUserDepositInfo(address token, address user) external view returns(DepositInfo memory) {
        return userDepositInfo[token][user];
    }

    function getUserTransferData(
        address token, 
        address user, 
        uint256 index
    ) external view returns(TransferData memory) {
        return getTransferData(token, userIndexToTotalIndex[token][user][index]);
    }
}