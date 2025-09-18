// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../upgradeability/Synchron.sol";
import "../core/interfaces/ITransferAmountData.sol";
import "../meme/interfaces/IMemeRisk.sol";

contract ReferralData is Synchron, ITransferAmountData {
    using SafeERC20 for IERC20;

    uint256 public constant baseRate = 10000;

    uint256 public totalIndex;

    address public gov;
    address public USDT;

    bool public initialized;

    mapping(address => bool) public isOperator;
    mapping(address => bool) public isHandler;
    mapping(uint256 => uint256) public haveAllocate;
    mapping(uint256 => uint256) public indexFee;

    struct UserAmount {
        uint256 index;
        address user;
        uint256 amount;
    }

    struct FeeData {
        address user;
        address token;
        address indexToken;
        uint256 index;
        uint256 fee;
        bytes32 typeKey;
        bytes32 key;
        uint8 uType;
    }

    event SetOperator(address account, bool isAdd);
    event SetHandler(address handler, bool isActive);
    event Withdraw(UserAmount[] uAmount);
    event AddFee(FeeData fData);
    event TransferTo(
        address from,
        address account, 
        uint256 amount, 
        TransferAmountData tData
    );

    constructor() {
        initialized = true;
    }

    modifier onlyGov() {
        require(msg.sender == gov, "Governable: forbidden");
        _;
    }

    modifier onlyHander() {
        require(isHandler[msg.sender], "no permission");
        _;
    } 


    modifier onlyOperator() {
        require(isOperator[msg.sender], "no permission");
        _;
    } 

    function initialize(address usdt) external {
        require(!initialized, "has initialized");
        require(usdt != address(0), "usdt err");

        initialized = true;
        USDT = usdt;
        gov = msg.sender;
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "_gov err");
        gov = _gov;
    }

    function setHandler(address account, bool isAdd) external onlyGov {
        require(account != address(0), "account err");

        isHandler[account] = isAdd;
        
        emit SetHandler(account, isAdd);
    } 

    function setOperator(address account, bool isAdd) external onlyGov {
        require(account != address(0), "account err");

        isOperator[account] = isAdd;

        emit SetOperator(account, isAdd);
    }

    function addFee(
        uint8 uType, 
        bytes32 typeKey, 
        bytes32 key, 
        address user, 
        address token, 
        uint256 fee,
        address indexToken
    ) external onlyHander {
        require(token == USDT, "token err");

        uint256 index = ++totalIndex;  
        indexFee[index] = fee;
        indexToToken[index] = indexToken;

        FeeData memory fData = FeeData(
            user,
            token,
            indexToken,
            index,
            indexFee[index],
            typeKey,
            key,
            uType
        );

        emit AddFee(fData);
    }

    function withdraw(UserAmount[] memory uAmount) external onlyOperator {
        uint256 len = uAmount.length;

        for(uint256 i = 0; i < len; i++) {
            address user = uAmount[i].user;
            uint256 amount = uAmount[i].amount;
            uint256 index = uAmount[i].index;

            require(IERC20(USDT).balanceOf(address(this)) >= amount, "not enough");
            uint256 value = haveAllocate[index] + amount;
            require(indexFee[index] >= value, "allocate err");
            haveAllocate[index] = value;

            TransferAmountData memory tData;

            tData.beforeAmount = getAmount(USDT, address(this));
            tData.beforeValue = getAmount(USDT, user);
            IERC20(USDT).safeTransfer(user, amount);
            tData.afterAmount = getAmount(USDT, address(this));
            tData.afterValue = getAmount(USDT, user);

            emit TransferTo(address(this), user, amount, tData);
            
            if(user == address(memeRisk)) {
                memeRisk.addFeeAmount(indexToToken[index], index, amount);
            }
        }

        emit Withdraw(uAmount);
    }


    function getAmount(address token, address account) public view returns(uint256) {
        return IERC20(token).balanceOf(account);
    }

    // ******************************************************************
    IMemeRisk public memeRisk;
    mapping(uint256 => address) public indexToToken;
    function setMemeRisk(address _memeRisk) external onlyGov {
        require(_memeRisk != address(0), "_memeRisk err");

        memeRisk = IMemeRisk(_memeRisk);
    }
    
}