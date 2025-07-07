// SPDX-License-Identifier: MIT
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import "../upgradeability/Synchron.sol";
import "../libraries/utils/ReentrancyGuard.sol";


pragma solidity ^0.8.0;

contract TokenHelper is Synchron, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    address public gov;

    uint256 public chainid;
    bool public initialized;

    bytes32 private constant EIP712_DOMAIN_TYPE_HASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    bytes32 private constant Dex_Transaction_TransferFrom =
        keccak256(
            "DexTransaction:TransferFrom(string Transaction_Type,address Token,address From,address Destination,uint256 Amount,uint256 Deadline,string Chain)"
        );

    mapping(bytes32 => bool) public isHashUse;

    struct EIP712Domain {
        string name;   
        string version;       
        uint256 chainId;  
        address verifyingContract;        
    }

    struct Message {
        string transactionType;
        address token;
        address from;
        address destination;      
        uint256 amount;     
        uint256 deadline;        
        string chain;   
    }

    event TransferData(        
        address token,
        address from,
        address to,
        uint256 amount
    );
    
    modifier onlyGov() {
        require(msg.sender == gov, "no permission");
        _;
    }

    function initialize(uint256 _chainId) external {
        require(!initialized, "has initialized");
        initialized = true;

        chainid = _chainId;
        gov = msg.sender;
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "account err");
        gov = _gov;
    }

    function transferFrom(
        EIP712Domain memory domain,
        Message memory message,
        bytes memory signature
    ) external payable {
        uint256 amount= message.amount;
        address to = message.destination;
        require(domain.chainId == chainid && domain.verifyingContract == address(this), "para err");
        require(
            block.timestamp <= message.deadline &&
            to != address(0) &&
            amount > 0, 
            "data err"
        );

        address token = message.token;
        address from = message.from;

        (address user, bytes32 digest) = getSignatureUser(domain, message, signature);

        require(from == user && !isHashUse[digest], "signature err");
        isHashUse[digest] = true;

        if(token != address(0)) {
            require(msg.value == 0, "value err");
            IERC20(token).safeTransferFrom(from, to, amount);
        } else {
            require(msg.value == amount, "amount err");

            (bool success, ) = to.call{value : amount}("");
            require(success, "Transfer failed.");

            emit TransferData(token, from, to, amount);
        }
    }


    receive() external payable { }


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
                Dex_Transaction_TransferFrom,
                keccak256(bytes(message.transactionType)),
                message.token,
                message.from,
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

    function getTokenBalance(address token, address account) external view returns(uint256) {
        if(token != address(0)) {
            return IERC20(token).balanceOf(account);
        } else {
            return account.balance;
        }
    }

    function withdrawETH(address account, uint256 amount) external onlyGov() nonReentrant() {
        require(account != address(0), "account err");
        require(address(this).balance >= amount, "amount err");

        (bool success, ) = account.call{value : amount}("");
        require(success, "Transfer failed.");
    }
}