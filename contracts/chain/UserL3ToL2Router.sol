// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "../core/interfaces/IMintable.sol";
import "../access/Governable.sol";
import "./interfaces/IL1GatewayRouter.sol";
import "../upgradeability/Synchron.sol";
import "./interfaces/IArbSys.sol";
import "../libraries/utils/ReentrancyGuard.sol";

pragma solidity ^0.8.0;

contract UserL3ToL2Router is Synchron, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using EnumerableSet for EnumerableSet.AddressSet;

    uint256 public constant BASERATE = 10000;
    uint256 public feeRate;
    uint256 public chainid;
    uint8 public chainType;

    bool public initialized;

    address public gov;
    address public l3Usdt;
    address public feeReceiver;

    IArbSys public arbSys;
    IL1GatewayRouter public gatewayRouter;

    EnumerableSet.AddressSet whitelistToken;
    EnumerableSet.AddressSet removelistToken;

    bytes32 private constant EIP712_DOMAIN_TYPE_HASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    bytes32 private constant Dex_Transaction_Withdraw =
        keccak256(
            "DexTransaction:Withdraw(string Transaction_Type,address From,address Token,address L2Token,address Destination,uint256 Amount,uint256 Deadline,string Chain)"
        );

    mapping(address => mapping(uint256 => TransferData)) transferData;
    mapping(address => mapping(address => mapping(uint256 => uint256))) public userIndexToTotalIndex;
    mapping(address => DepositInfo) totalDepositInfo;
    mapping(address => mapping(address => DepositInfo)) public userDepositInfo;
    mapping(address => uint256) public minTokenFee;
    mapping(bytes32 => bool) public isHashUse;

    mapping(address => uint256) public tokenRate;
    mapping(address => bool) public isSetRate;

    struct DepositInfo {
        uint256 totalIndex;
        uint256 totalAmount;
    }

    struct TransferData {
        address token;
        address l2Token;
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

    struct EIP712Domain {
        string name;   
        string version;       
        uint256 chainId;  
        address verifyingContract;        
    }

    struct Message {
        string transactionType;
        address from;
        address token;
        address l2Token;
        address destination;      
        uint256 amount;     
        uint256 deadline;      
        string chain;   
    }

    event L3ToL2RouterOutboundTransfer(
        address token, 
        address l2Token,
        uint256 tIndex, 
        uint256 uIndex, 
        TransferData tData
    );

    event TransferTo(address indexed token, address indexed account, uint256 amount);

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
        address _l3GatewayRouter,
        address _l3Usdt,
        address _arbSys,
        address _feeReceiver,
        address[] memory tokens,
        MinTokenFee[] memory _mFee,
        MinTokenFee[] memory _mRate,
        uint256 _chainid,
        uint8 _cType
    ) external {
        require(!initialized, "has initialized");
        require(
            _l3GatewayRouter != address(0) &&
            _l3Usdt != address(0) &&
            _arbSys != address(0) &&
            _feeReceiver != address(0),
            "addr err"            
        );

        initialized = true;
        gatewayRouter = IL1GatewayRouter(_l3GatewayRouter);
        gov = msg.sender;
        l3Usdt = _l3Usdt;
        arbSys = IArbSys(_arbSys);
        feeReceiver = _feeReceiver;
        chainid = _chainid;

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

    function outboundTransfer(
        bytes calldata _data,
        EIP712Domain memory domain,
        Message memory message,
        bytes memory signature
    ) external payable {
        require(whitelistToken.contains(message.token), "token err");
        require(block.timestamp <= message.deadline, "time err");
        require(domain.chainId == chainid && domain.verifyingContract == address(this), "para err");


        address from = message.from;
        (address user, bytes32 digest) = getSignatureUser(domain, message, signature);
        require(from == user && !isHashUse[digest], "signature err");

        isHashUse[digest] = true;

        address _token = message.token;
        address _l2Token = message.l2Token;
        address _to = message.destination;
        uint256 _amount = message.amount;

        IERC20(_token).safeTransferFrom(from, address(this), _amount);
        uint256 _fee;

        (_fee, _amount) = getValue(_token, _amount);

        if(_fee > 0) {
            IERC20(_token).safeTransfer(feeReceiver, _fee);
            emit TransferFee(_token, feeReceiver, _fee);
        }

        bytes calldata _dataVale = _data; 
        IERC20(_token).approve(address(gatewayRouter), _amount);
        gatewayRouter.outboundTransfer{ value: msg.value }(
                _l2Token,
                _to,
                _amount,
                _dataVale
        );
        _outboundTransfer(_token, _l2Token, _to, _amount, _fee);
        
    }

    function withdrawEth(address destination) external payable nonReentrant() {
        (uint256 _fee, uint256 _amount) = getValue(address(0), msg.value);
        if(_fee > 0) {
            (bool success, ) = feeReceiver.call{value : _fee}("");
            require(success, "Transfer failed.");

            emit TransferFee(address(0), feeReceiver, _fee);
        }
        
        arbSys.withdrawEth{ value: _amount }(destination);

        _outboundTransfer(address(0), address(0), destination, _amount, _fee);
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

    function setContract(address l3GatewayRouter_) external onlyGov() {
        require(l3GatewayRouter_ != address(0), "addr err");

        gatewayRouter = IL1GatewayRouter(l3GatewayRouter_);
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "account err");
        gov = _gov;
    }

    function transferTo(address token, address account, uint256 amount) external onlyGov {
        require(IERC20(token).balanceOf(address(this)) >= amount, "not enough");
        IERC20(token).safeTransfer(account, amount);
            
        emit TransferTo(token, account, amount);
    }

    receive() external payable { }


    function _outboundTransfer(
        address _tokenFor,
        address _l2TokenFor,
        address _addr,
        uint256 _mAmount,
        uint256 _fee
    ) internal {
        uint256 index = ++totalDepositInfo[_tokenFor].totalIndex;

        TransferData memory _tData = TransferData(
                _tokenFor,
                _l2TokenFor,
                msg.sender,
                _addr,
                _mAmount,
                _fee,
                block.timestamp
        );

        transferData[_tokenFor][index] = _tData;
        totalDepositInfo[_tokenFor].totalAmount += _mAmount;
        uint256 uIndex = ++userDepositInfo[_tokenFor][msg.sender].totalIndex;
        userIndexToTotalIndex[_tokenFor][msg.sender][uIndex] = index;
        userDepositInfo[_tokenFor][msg.sender].totalAmount += _mAmount;

        emit L3ToL2RouterOutboundTransfer(_tokenFor, _l2TokenFor, index, uIndex, _tData);
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


    function getValue(address _token,  uint256 _amount) public view returns(uint256, uint256) {
        uint256 _rate = isSetRate[_token] ? tokenRate[_token] : feeRate;
        uint256 _fee = _amount * _rate / BASERATE;
        _fee =  _fee > minTokenFee[_token] ? _fee :  minTokenFee[_token];
        require(_amount > _fee, "amount err");
        _amount = _amount - _fee;

        return(_fee, _amount);
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

    function hashData(bytes32 domainHash, bytes32 messageHash) public pure returns(bytes32) {
        return keccak256(
            abi.encodePacked("\x19\x01", domainHash, messageHash)
        );
    }

    function hashDomain(EIP712Domain memory domain) public pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    EIP712_DOMAIN_TYPE_HASH,
                    keccak256(bytes(domain.name)),
                    keccak256(bytes(domain.version)),
                    domain.chainId,
                    domain.verifyingContract                 
                )
            );
    }

    function hashMessage(Message memory message) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                Dex_Transaction_Withdraw,
                keccak256(bytes(message.transactionType)),
                message.from,
                message.token,
                message.l2Token,
                message.destination,
                message.amount,
                message.deadline,
                keccak256(bytes(message.chain))
            )
        );
    }

    function getSignatureUser(
        EIP712Domain memory domain,
        Message memory message,
        bytes memory signature
    ) public pure returns(address, bytes32) {
        bytes32 domainHash = hashDomain(domain);
        bytes32 messageHash = hashMessage(message);
        bytes32 digest = hashData(domainHash, messageHash);

        return (digest.recover(signature), digest);
    }

    function getMsgSender() external view returns(address) {
        return msg.sender;
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