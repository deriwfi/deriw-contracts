// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "../core/interfaces/IVault.sol";
import "../upgradeability/Synchron.sol";

contract FeeBonus is Synchron {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    uint256 public constant BASERATE = 10000;

    EnumerableSet.AddressSet feeAccounts;
    EnumerableSet.AddressSet histtoryFeeAccounts;
    EnumerableSet.AddressSet memeFeeAccounts;
    EnumerableSet.AddressSet memeHisttoryFeeAccounts;

    address public memeData;
    address public memeSwapAccount;
    address public poolDataV2;
    address public swapAccount;
    address public operator;
    address public usdt;
    address public vault;
    address public gov;

    bool public initialized;

    mapping(address => uint256) public feeRate;
    mapping(address => bool) public isHandler;
    mapping(address => bool) public isFeeAddAccount;
    mapping(address => uint256) public feeAmount;
    mapping(address => uint256) public feeMemeAmount;
    mapping(address => uint256) public phasefeeAmount;

    struct FeeAccountInfo {
        address account;
        uint256 rate;
    }

    event TransferTo(
        address token, 
        address from, 
        address to, 
        uint256 amount, 
        uint256 beforeAmount, 
        uint256 afterAmount,
        uint256 beforeValue,
        uint256 afterValue
    );

    event ClaimFeeAmount(address handler, address account, uint256 fee1, uint256 fee2);
    event ClaimMemeFeeAmount(address handler, address account, uint256 fee);

    constructor() {
        initialized = true;
    }

    modifier onlyGov() {
        require(gov == msg.sender, "gov err");
        _;
    }

    modifier onlyAuth() {
        require(msg.sender == operator || gov == msg.sender, "no permission");
        _;
    }

    function initialize(
        address _usdt,
        address _poolDataV2,
        address _swapAccount,
        address _memeData,
        address _memeSwapAccount,
        address _vault
    ) external {
        require(!initialized, "has initialized");
        require(
            _usdt != address(0) &&
            _poolDataV2 != address(0) &&
            _swapAccount != address(0) &&
            _memeData != address(0) &&
            _memeSwapAccount != address(0) &&
            _vault != address(0),
            "addr err"
        );



        initialized = true;
        
        gov = msg.sender;
        usdt = _usdt;
        _setVault(_vault);
        _init(_poolDataV2, _swapAccount, 7000, 3000);
        _initMeme(_memeData, _memeSwapAccount, 7000, 3000);
    }

    function setGov(address account) external onlyGov {
        require(account != address(0), "account err");
        gov = account;
    }

    function setOperator(address _operator) external onlyGov {
        operator = _operator;
    }

    function setVault(address _vault) external onlyGov {
        _setVault(_vault);
    }

    function setHandler(address account, bool isAdd) external onlyAuth() {
        isHandler[account] = isAdd;
    }

    function setFeeAddAccount(address account, bool isAdd) external onlyAuth() {
        isFeeAddAccount[account] = isAdd;
    }

    function setAllocateRate(
        address _poolDataV2,
        address _swapAccount,
        uint256 _poolDataV2Rate,
        uint256 _swapAccountRate,
        FeeAccountInfo[] memory fInfo
    ) external onlyAuth {
        uint256 len = feeAccounts.length();
        for(uint256 i = 0; i < len; i++) {
            address addr = feeAccounts.at(0);
            feeRate[addr] = 0;
            feeAccounts.remove(addr);
        }

        uint256 _amount = feeAmount[swapAccount];
        feeAmount[swapAccount] = 0;
        feeAmount[_swapAccount] = _amount;

        _init(_poolDataV2, _swapAccount, _poolDataV2Rate, _swapAccountRate);


        uint256 _totalRate;
        for(uint256 i = 0; i < fInfo.length; i++) {
            address account = fInfo[i].account;
            uint256 _rate  = fInfo[i].rate;
            require(account != address(0) && _rate != 0, "para err");
            _totalRate += _rate;

            feeRate[account] = _rate;
            feeAccounts.add(account);
            histtoryFeeAccounts.add(account);
            isHandler[account] = true;
        }

        require(_poolDataV2Rate + _swapAccountRate + _totalRate == BASERATE, "rate err");

    }

    function setMemeAllocateRate(
        address _memeData,
        address _memeSwapAccount,
        uint256 _memeDataRate,
        uint256 _memeSwapAccountRate,
        FeeAccountInfo[] memory fInfo
    ) external onlyAuth {
        uint256 len = memeFeeAccounts.length();
        for(uint256 i = 0; i < len; i++) {
            address addr = memeFeeAccounts.at(0);
            feeRate[addr] = 0;
            memeFeeAccounts.remove(addr);
        }
        uint256 _amount = feeMemeAmount[memeSwapAccount];
        feeMemeAmount[memeSwapAccount] = 0;
        feeMemeAmount[_memeSwapAccount] = _amount;

        _initMeme(_memeData, _memeSwapAccount, _memeDataRate, _memeSwapAccountRate);

        uint256 _totalRate;
        for(uint256 i = 0; i < fInfo.length; i++) {
            address account = fInfo[i].account;
            uint256 _rate  = fInfo[i].rate;
            require(account != address(0) && _rate != 0, "para err");
            _totalRate += _rate;

            feeRate[account] = _rate;
            memeFeeAccounts.add(account);
            memeHisttoryFeeAccounts.add(account);
            isHandler[account] = true;
        }

        require(_memeDataRate + _memeSwapAccountRate + _totalRate == BASERATE, "meme rate err");
    }

    function transferTo(address token, address account, uint256 amount) external onlyGov {
        _transferTo(token, token, account, amount);
    }

    function addFeeAmount(address indexToken, uint8 addType, uint256 amount) external {
        require(isFeeAddAccount[msg.sender], "no permission");

        if(addType == 1) {
            uint256 fee;
            uint256 len = feeAccounts.length();
            for(uint256 i = 0; i < len-1 ; i++) {
                address account = feeAccounts.at(i);
                uint256 _fee = amount * feeRate[account] / BASERATE;
                feeAmount[account] += _fee;
                fee += _fee;
            }
            feeAmount[feeAccounts.at(len-1)] += (amount - fee);
            
        } else if(addType == 2) {
            phasefeeAmount[poolDataV2] += amount;
        } else if(addType == 3) {
            uint256 fee;
            uint256 lenMeme = memeFeeAccounts.length();

            for(uint256 i = 0; i < lenMeme-1 ; i++) {
                address account = memeFeeAccounts.at(i);
                uint256 _fee = amount * feeRate[account] / BASERATE;
                feeMemeAmount[account] += _fee;
                fee += _fee;
            }
            feeMemeAmount[memeFeeAccounts.at(lenMeme-1)] += (amount - fee);

            uint256 feeMeme = feeMemeAmount[memeData];
            feeMemeAmount[memeData] = 0;
            if(feeMeme > 0) {
                _transferTo(indexToken, usdt, vault, feeMeme);
            }
        } else {
            revert("add err");
        }
    }

    function claimFeeAmount(address account) external returns(uint256, uint256) {
        if(!isHandler[msg.sender]) {
            return (0, 0);
        }

        uint256 fee1 = feeAmount[msg.sender];
        uint256 fee2 = phasefeeAmount[msg.sender];

        feeAmount[msg.sender] = 0;
        phasefeeAmount[msg.sender] = 0;

        if(fee1 + fee2 > 0) {
            _transferTo(usdt, usdt, account,  fee1 + fee2);
        }

        emit ClaimFeeAmount(msg.sender, account, fee1, fee2);

        return(fee1, fee2);
    }

    function claimMemeFeeAmount(address account) external returns(uint256) {
        if(!isHandler[msg.sender]) {
            return 0;
        }

        uint256 fee = feeMemeAmount[msg.sender];
        feeMemeAmount[msg.sender] = 0;

        _transferTo(usdt, usdt, account,  fee);

        emit ClaimMemeFeeAmount(msg.sender, account, fee);

        return fee;
    }

    function _init(
        address _poolDataV2,
        address _swapAccount,
        uint256 _poolDataV2Rate,
        uint256 _swapAccountRate
    ) internal {
        require(_swapAccount != address(0) && _poolDataV2 != address(0), "address err");

        isHandler[_poolDataV2] = true;
        isHandler[_swapAccount] = true;

        poolDataV2 = _poolDataV2;
        swapAccount = _swapAccount;

        feeAccounts.add(_poolDataV2);
        feeAccounts.add(_swapAccount);

        histtoryFeeAccounts.add(_poolDataV2);
        histtoryFeeAccounts.add(_swapAccount);

        feeRate[poolDataV2] = _poolDataV2Rate;
        feeRate[swapAccount] = _swapAccountRate;
    }

    function _initMeme(
        address _memeData,
        address _memeSwapAccount,
        uint256 _memeDataRate,
        uint256 _memeSwapAccountRate
    ) internal {
        require(_memeData != address(0) && _memeSwapAccount != address(0), "address err");

        isHandler[_memeData] = true;
        isHandler[_memeSwapAccount] = true;

        memeData = _memeData;
        memeSwapAccount = _memeSwapAccount;

        memeFeeAccounts.add(_memeData);
        memeFeeAccounts.add(_memeSwapAccount);

        memeHisttoryFeeAccounts.add(_memeData);
        memeHisttoryFeeAccounts.add(_memeSwapAccount);

        feeRate[memeData] = _memeDataRate;
        feeRate[memeSwapAccount] = _memeSwapAccountRate;
    }

    function _setVault(address _vault) internal {
        require(_vault != address(0), "_vault err");
        vault = _vault;
    }

   function _transferTo(address indexToken, address token, address account, uint256 amount) internal {
        require(account != address(0), "account err");
        uint256 beforeAmount = getAmount(token, address(this));
        uint256 beforeValue = getAmount(token, account);
        IERC20(token).safeTransfer(account, amount);
        uint256 afterAmount = getAmount(token, address(this));
        uint256 afterValue = getAmount(token, account);

        if(account == vault) {
            IVault(vault).directPoolDeposit(indexToken, token, amount);
        }

        emit TransferTo(
            token, 
            address(this), 
            account, 
            amount, 
            beforeAmount, 
            afterAmount,
            beforeValue,
            afterValue
        );
    } 

    function getAmount(address token, address account) public view returns(uint256) {
        return IERC20(token).balanceOf(account);
    }

    function getAccountsLength(uint8 num) external view returns(uint256) {
        if(num == 1) {
            return feeAccounts.length();
        }

        if(num == 2) {
            return histtoryFeeAccounts.length();
        }

        if(num == 3) {
            return memeFeeAccounts.length();
        }

        if(num == 4) {
            return memeHisttoryFeeAccounts.length();
        }

        return 0;
    }

    function getAccount(uint8 num, uint256 index) external view returns(address) {
        if(num == 1) {
            return feeAccounts.at(index);
        }

        if(num == 2) {
            return histtoryFeeAccounts.at(index);
        }


        if(num == 3) {
            return memeFeeAccounts.at(index);
        }

        if(num == 4) {
            return memeHisttoryFeeAccounts.at(index);
        }

        return address(0);
    }
}