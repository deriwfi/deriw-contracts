// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "../core/interfaces/IMintable.sol";
import "../access/Governable.sol";
import "./interfaces/IL1GatewayRouter.sol";
import "../upgradeability/Synchron.sol";
import "./interfaces/IInbox.sol";
import "./interfaces/IERC20Inbox.sol";
import "../libraries/utils/ReentrancyGuard.sol";

pragma solidity ^0.8.0;

contract UserL2ToL3Router is Synchron, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant BASERATE = 10000;
    uint256 public feeRate;
    uint8 public chainType;

    bool public initialized;

    IL1GatewayRouter public l2GatewayRouter;
    IERC20 public dCoin;
    address public inbox;

    address public l2Usdt;
    address public gov;
    address public feeReceiver;

    EnumerableSet.AddressSet whitelistToken;
    EnumerableSet.AddressSet removelistToken;

    mapping(address => mapping(uint256 => TransferData)) transferData;
    mapping(address => mapping(address => mapping(uint256 => uint256))) public userIndexToTotalIndex;
    mapping(address => DepositInfo) totalDepositInfo;
    mapping(address => mapping(address => DepositInfo)) userDepositInfo;
    mapping(address => uint256) public minTokenFee;
    mapping(address => uint256) public tokenRate;
    mapping(address => bool) public isSetRate;

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

    event SetTokenRate(MinTokenFee[] mRate);
    event SetMinTokenFee(MinTokenFee[] mFee);

    event AddWhitelist(address token);
    event RemoveWhitelist(address token); 
    event TransferFee(address token, address to, uint256 fee);

    constructor() {
        initialized = true;
    }

    modifier onlyGov() {
        require(msg.sender == gov, "no permission");
        _;
    }
    
    function initialize(
        address _dCoin,
        address _l2Usdt,
        address _l2GatewayRouter,
        address _inbox,
        address _feeReceiver,
        address[] memory tokens,
        MinTokenFee[] memory _mFee,
        MinTokenFee[] memory _mRate,
        uint8 _cType
    ) external {
        require(!initialized, "has initialized");

        require(
            _l2Usdt != address(0) &&
            _l2GatewayRouter != address(0) &&
            _inbox != address(0) &&
            _feeReceiver != address(0),
            "addr err"            
        );

        if(_cType == 1) {
            require(_dCoin != address(0), "_dCoin err");
            dCoin = IERC20(_dCoin);
        }


        initialized = true;

        l2GatewayRouter = IL1GatewayRouter(_l2GatewayRouter);
        gov = msg.sender;

        l2Usdt = _l2Usdt;
        inbox = _inbox;
        feeReceiver = _feeReceiver;

        chainType = _cType;
        addOremoveWhitelist(tokens, true);


        if(chainType == 1 || chainType == 2) {
            if(_mFee.length > 0) {
                setMinTokenFee(_mFee);
            }

            if(_mRate.length > 0) {
                setTokenRate(_mRate);
            }
        }
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
        require(whitelistToken.contains(_token), "token err");
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 _fee;
        address getWay = l2GatewayRouter.getGateway(_token);
        if(chainType == 1) {
            (_fee, _amount) = _addFee(getWay, _token, _amount);
            if(_fee > 0) {
                IERC20(_token).safeTransfer(feeReceiver, _fee);
                emit TransferFee(_token, feeReceiver, _fee);
            }
        } else if(chainType == 2) {
            _fee = 0;
        } else {
            revert("type err");
        }

        IERC20(_token).approve(getWay, _amount);
        IERC20(_token).approve(address(l2GatewayRouter), _amount);

        l2GatewayRouter.outboundTransfer{ value: msg.value }(
                _token,
                _to,
                _amount,
                _maxGas,
                _gasPriceBid,
                _data
        );

        _outboundTransfer(_token, _to, _amount, _fee);
    }


    function createRetryableTicket(
        address to,
        uint256 l2CallValue,
        uint256 maxSubmissionCost,
        address excessFeeRefundAddress,
        address callValueRefundAddress,
        uint256 gasLimit,
        uint256 maxFeePerGas,
        uint256 tokenTotalFeeAmount,
        bytes calldata data
    ) external payable {
        address _token;
        uint256 _fee;
        if(chainType == 1) {
            _token = address(dCoin);
            require(whitelistToken.contains(_token), "token err");

            IERC20(dCoin).safeTransferFrom(msg.sender, address(this), l2CallValue);

            address getWay = l2GatewayRouter.getGateway(_token);
            (_fee, l2CallValue) = _addFee(getWay, _token, l2CallValue); 
            IERC20(dCoin).approve(inbox, l2CallValue+1e20);
            IERC20Inbox(inbox).createRetryableTicket(
                to, 
                l2CallValue, 
                maxSubmissionCost,
                excessFeeRefundAddress, 
                callValueRefundAddress,
                gasLimit, 
                maxFeePerGas, 
                tokenTotalFeeAmount, 
                data
            );
        } else if(chainType == 2) {
            IInbox(inbox).createRetryableTicket{ value: msg.value }(
                to, 
                l2CallValue, 
                maxSubmissionCost, 
                excessFeeRefundAddress, 
                callValueRefundAddress, 
                gasLimit, 
                maxFeePerGas, 
                data
            );
        } else {
            revert("type err");
        }

        _outboundTransfer(_token, to, l2CallValue, _fee);
    }


    function setFeeReceiver(address _feeReceiver) external onlyGov() {
        require(_feeReceiver != address(0), "_feeReceiver err");

        feeReceiver = _feeReceiver;
    }


    function setFeeRate(uint256 _rate) external onlyGov() {
        require(_rate <= 2000, "rate err");

        feeRate = _rate;
    }

    function setMinTokenFee(MinTokenFee[] memory mFee) public onlyGov() {
        uint256 len = mFee.length;
        require(len > 0, "length err");
        for(uint256 i = 0; i < len; i++) {
            minTokenFee[mFee[i].token] = mFee[i].minFeeAmount;
        }
        emit SetMinTokenFee(mFee);
    }


    function setTokenRate(MinTokenFee[] memory mRate) public onlyGov() {
        uint256 len = mRate.length;
        require(len > 0, "length err");
        for(uint256 i = 0; i < len; i++) {
            address token = mRate[i].token;
            uint256 rate = mRate[i].minFeeAmount;

            require(rate <= 2000, "rate err");
            tokenRate[token] = rate;
            if(!isSetRate[token]) {
                isSetRate[token] = true;
            }
        }
        emit SetTokenRate(mRate);
    }

    function addOremoveWhitelist(address[] memory tokens, bool isAdd) public onlyGov {
        if(isAdd) {
            _addWhitelist(tokens);
        } else {
            _removeWhitelist(tokens);
        }
    }


    function setContract(address _l2GatewayRouter) external onlyGov() {
        require(_l2GatewayRouter != address(0), "addr err");

        l2GatewayRouter = IL1GatewayRouter(_l2GatewayRouter);
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "account err");
        gov = _gov;
    }

    receive() external payable { }


    function _addFee(address getWay, address _token,  uint256 _amount) internal returns(uint256, uint256) {
        uint256 _fee = getFee(_token, _amount);
        _amount = _amount - _fee;
        dCoin.approve(address(l2GatewayRouter), 1e20);
        dCoin.approve(getWay, 1e20);

        return(_fee, _amount);
    }

    function _outboundTransfer(
        address _token,
        address _to,
        uint256 _amount,
        uint256 _fee
    ) internal {
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



    function _addWhitelist(address[] memory tokens) internal {
        for (uint256 i = 0; i < tokens.length; i++) {
            if(!whitelistToken.contains(tokens[i])) {
                whitelistToken.add(tokens[i]);
                removelistToken.remove(tokens[i]);
                emit AddWhitelist(tokens[i]);
            }
        }
    }

    function _removeWhitelist(address[] memory tokens) internal  {
        for (uint256 i = 0; i < tokens.length; i++) {
            if(whitelistToken.contains(tokens[i])) {
                whitelistToken.remove(tokens[i]);
                removelistToken.add(tokens[i]);
                emit RemoveWhitelist(tokens[i]);
            }
        }
    }

    function getFee(address _token,  uint256 _amount) public view returns(uint256) {
        uint256 _rate = isSetRate[_token] ? tokenRate[_token] : feeRate;
        uint256 _fee = _amount * _rate / BASERATE;
        _fee =  _fee > minTokenFee[_token] ? _fee :  minTokenFee[_token];
        require(_amount > _fee, "amount err");

        return _fee;
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

    function getWhitelistTokenLength() external view returns(uint256) {
        return whitelistToken.length();
    }

    function getTokenIsIn(address token) external view returns(bool) {
        return whitelistToken.contains(token);
    }

    function getWhitelistToken(uint256 index) external view returns(address) {
        return whitelistToken.at(index);
    }

    function getRemovelistNum() external view returns(uint256) {
        return removelistToken.length();
    }

    function getRemovelist(uint256 index) external view returns(address) {
        return removelistToken.at(index);
    }

    function getRemovelistIsIn(address token) external view returns(bool) {
        return removelistToken.contains(token);
    }

    function getTokenFeeData(address token) external view returns(uint256 rate, uint256 value) {
        rate = isSetRate[token] ? tokenRate[token] : feeRate;
        value =  minTokenFee[token];
    }

    function withdrawETH(address account, uint256 amount) external onlyGov() nonReentrant() {
        require(account != address(0), "account err");
        require(address(this).balance >= amount, "amount err");

        (bool success, ) = account.call{value : amount}("");
        require(success, "Transfer failed.");
    }
}