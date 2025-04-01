// SPDX-License-Identifier: MIT

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "../core/interfaces/IMintable.sol";
import "../access/Governable.sol";
import "./interfaces/IL1GatewayRouter.sol";
import "../upgradeability/Synchron.sol";

pragma solidity ^0.8.0;

contract UserL3ToL2Router is Synchron {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    uint256 public constant BASERATE = 10000;
    uint256 public feeRate;

    bool public initialized;

    address public gov;
    address public l3Usdt;
    
    IL1GatewayRouter public gatewayRouter;

    bytes32 private constant EIP712_DOMAIN_TYPE_HASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    bytes32 private constant Dex_Transaction_Withdraw =
        keccak256(
            "DexTransaction:Withdraw(string Transaction_Type,address Destination,string Amount,uint256 Deadline,string Chain)"
        );

    mapping(address => mapping(uint256 => TransferData)) transferData;
    mapping(address => mapping(address => mapping(uint256 => uint256))) public userIndexToTotalIndex;
    mapping(address => DepositInfo) totalDepositInfo;
    mapping(address => mapping(address => DepositInfo)) public userDepositInfo;
    mapping(address => uint256) public minTokenFee;
    mapping(address => uint256) public tokenFee;
    mapping(bytes32 => bool) public isHashUse;

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
        address destination;      
        string amount;     
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
    event ClaimFee(address token, address account, uint256 amount);

    modifier onlyGov() {
        require(msg.sender == gov, "no permission");
        _;
    }
    
    function initialize(
        address _l3GatewayRouter,
        address _l3Usdt,
        MinTokenFee[] memory _mFee
    ) external {
        require(!initialized, "has initialized");

        initialized = true;
        gatewayRouter = IL1GatewayRouter(_l3GatewayRouter);
        gov = msg.sender;
        l3Usdt = _l3Usdt;
        feeRate = 200; 
        setMinTokenFee(_mFee);
    }

    function outboundTransfer(
        address _token,
        address _l2Token,
        address _to,
        uint256 _amount,
        bytes calldata _data,
        EIP712Domain memory domain,
        Message memory message,
        bytes memory signature
    ) external payable {
        require(_token == l3Usdt, "token err");
        require(block.timestamp <= message.deadline, "time err");

        (address user, bytes32 digest) = getSignatureUser(domain, message, signature);
        require(msg.sender == user, "signature addr err");
        require(!isHashUse[digest], "hash err");
        isHashUse[digest] = true;

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        uint256 _fee = _amount * feeRate / BASERATE;
        _fee =  _fee > minTokenFee[_token] ? _fee :  minTokenFee[_token];
        require(_amount > _fee, "amount err");

        _amount = _amount - _fee;
        tokenFee[_token] += _fee;
        IERC20(_token).approve(address(gatewayRouter), _amount);

        gatewayRouter.outboundTransfer{ value: msg.value }(
                _l2Token,
                _to,
                _amount,
                _data
        );

        uint256 index = ++totalDepositInfo[_token].totalIndex;
        address _tokenFor = _token;
        address _l2TokenFor = _l2Token;
        TransferData memory _tData = TransferData(
                _tokenFor,
                _l2TokenFor,
                msg.sender,
                _to,
                _amount,
                _fee,
                block.timestamp
        );

        transferData[_tokenFor][index] = _tData;
        totalDepositInfo[_tokenFor].totalAmount += _amount;
        uint256 uIndex = ++userDepositInfo[_tokenFor][msg.sender].totalIndex;
        userIndexToTotalIndex[_tokenFor][msg.sender][uIndex] = index;
        userDepositInfo[_tokenFor][msg.sender].totalAmount += _amount;

        emit L3ToL2RouterOutboundTransfer(_tokenFor, _l2TokenFor, index, uIndex, _tData);
    }

    function claimFee(address token, address account, uint256 amount) external onlyGov() {
        require(account != address(0), "account err");
        require(
            IERC20(token).balanceOf(address(this)) >= amount &&
            tokenFee[token] >= amount
            , "amount err"
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

    function setContract(address l3GatewayRouter_) external onlyGov() {
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
                message.destination,
                keccak256(bytes(message.amount)),
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
}