// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IMemeStruct.sol";
import "../core/interfaces/IERC20Metadata.sol";
import "./interfaces/IMemeFactory.sol";
import "./interfaces/IMemeErrorContract.sol";
import "./interfaces/IMemePool.sol";
import "../upgradeability/Synchron.sol";
import "../core/interfaces/IVault.sol";

contract MemeData is Synchron, IMemeStruct {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    IMemeFactory public memeFactory;
    IMemeErrorContract public memeErrorContract;  
    IVault public vault;

    address public usdt;
    address public glpRewardRouter;
    address public gov;

    uint256 public initMinAmount;
    uint256 public lockTime;

    bool public initialized;

    mapping (address => EnumerableSet.AddressSet) userPool;
    mapping(address => address) public poolToken;
    mapping(address => address) public tokenToPool;
    mapping(address => address) public startUser;
    mapping(address => uint256) public startTime;
    mapping(address => uint256) public initValue;
    mapping(address => bool) public isTokenCreate;
    mapping(address => bool) public isAddMeme;
    mapping(address => bool) public isPoolTokenClose;
    mapping(address => MemeState) memeState;
    mapping(address => mapping(address => MemeUserInfo)) memeUserInfo;
    mapping(address => mapping(address => uint256)) userWithDrawAmount;

    event Deposit(MemeEvent, bool isStake);
    event Withdraw(MemeEvent);
    event Claim(address user, address pool, uint256 glpAmount, uint256 amount);
    event SetLockTime(uint256 time);
    event SetInitMinAmount(uint256 amount);
    event SetIsPoolClose(address pool, bool isClose);

    modifier onlyGov() {
        require(gov == msg.sender, "gov err");
        _;
    }

    function createPool(address pool, address token) external {
        require(msg.sender == address(memeFactory), "init err");

        isAddMeme[token] = true;
        isTokenCreate[token] = true;
        poolToken[pool] = token;
        tokenToPool[token] = pool;
    }

    function initialize(address usdt_) external {
        require(!initialized, "has initialized");

        initialized = true;
        gov = msg.sender;
        usdt = usdt_;
        initMinAmount = 100000 * (10 ** IERC20Metadata(usdt).decimals()); 
        lockTime = 60 days;
    }

    function setGov(address account) external onlyGov {
        require(account != address(0), "_gov err");
        gov = account;
    }

    function setContract(
        address memeFactory_,
        address errContract_,
        address glpRewardRouter_,
        address vault_
    ) external onlyGov {
        memeFactory = IMemeFactory(memeFactory_);
        memeErrorContract = IMemeErrorContract(errContract_);
        glpRewardRouter = glpRewardRouter_;
        vault = IVault(vault_);
    }

    function deposit(address user, address pool, uint256 amount) external {
        uint256 glpAmount = memeErrorContract.validateDeposit(msg.sender, user, pool, amount);

        userPool[user].add(pool);
        memeState[pool].totalDepositAmount += amount;
        memeUserInfo[pool][user].depositAmount += amount;

        MemeEvent memory dEvent;
        dEvent.user = user;
        dEvent.pool = pool;
        dEvent.amount = amount;
        dEvent.lpTokenAmount = glpAmount;
        dEvent.beforeAmount = getAmount(usdt, user);
        dEvent.beforeValue = getAmount(usdt, pool);
        IERC20(usdt).safeTransferFrom(user, pool, amount);
        dEvent.afterAmount = getAmount(usdt, user);
        dEvent.afterValue = getAmount(usdt, pool);

        if(!memeState[pool].isStake) {
            if(memeState[pool].totalDepositAmount >= initMinAmount) {
                memeState[pool].isStake = true;
                startTime[pool] = block.timestamp;
                startUser[pool] = user;

                IMemePool(pool).mintAndStakeGlp(poolToken[pool], usdt, memeState[pool].totalDepositAmount, 0);
                _countValue(pool);
            }
        } else {
            glpAmount = IMemePool(pool).mintAndStakeGlp(poolToken[pool], usdt, amount, 0);
            _countValue(pool);
        }

        memeState[pool].totalGlpAmount += glpAmount;
        memeUserInfo[pool][user].glpAmount += glpAmount;

        emit Deposit(dEvent, memeState[pool].isStake);
    }

    function claim(address user, address pool, uint256 glpAmount) external {
        memeErrorContract.validateClaim(msg.sender, user, pool, glpAmount, memeState[pool].isStake);

        uint256 amount = IMemePool(pool).unstakeAndRedeemGlp(poolToken[pool], usdt, user, glpAmount, 0);
        _countValue(pool);
        memeState[pool].totalUnStakeAmount += amount;
        memeUserInfo[pool][user].unStakeAmount += amount;

        memeState[pool].totalGlpAmount -= glpAmount;
        memeUserInfo[pool][user].glpAmount -= glpAmount;
        if(memeUserInfo[pool][user].glpAmount == 0) {
            userPool[user].remove(pool);
        }

        emit Claim(user, pool, glpAmount, amount);
    }

    function withdraw(address user, address pool, uint256 amount) external {
        uint256 newGlp = memeErrorContract.validateWithdraw(msg.sender, user, pool, amount, memeUserInfo[pool][user].depositAmount, memeState[pool].isStake);

        MemeEvent memory cEvent;
        cEvent.user = user;
        cEvent.pool = pool;
        cEvent.amount = amount;
        cEvent.lpTokenAmount = newGlp;

        uint256 glpAmount = memeUserInfo[pool][user].glpAmount;
        memeState[pool].totalGlpAmount =  memeState[pool].totalGlpAmount - glpAmount + newGlp;
        memeUserInfo[pool][user].glpAmount = newGlp;

        memeState[pool].totalDepositAmount -= amount;
        memeUserInfo[pool][user].depositAmount -= amount;
        userWithDrawAmount[pool][user] += amount;
        if(memeUserInfo[pool][user].depositAmount == 0) {
            userPool[user].remove(pool);
        }

        cEvent.beforeAmount = getAmount(usdt, user);
        cEvent.beforeValue = getAmount(usdt, pool);
        IMemePool(pool).withdraw(usdt, user, amount);
        cEvent.afterAmount = getAmount(usdt, user);
        cEvent.afterValue = getAmount(usdt, pool);

        emit Withdraw(cEvent);
    }

    function setIsPoolTokenClose(address pool, bool isClose) external {
        memeErrorContract.validate(msg.sender, pool);

        isPoolTokenClose[pool] = isClose;
        isPoolTokenClose[poolToken[pool]] = isClose;

        emit SetIsPoolClose(pool, isClose);
    }

    function setInitMinAmount(uint256 amount) external {
        memeErrorContract.validateSetInitMinAmount(msg.sender, amount);

        initMinAmount = amount;

        emit SetInitMinAmount(amount);
    }

    function setLockTime(uint256 time) external {
        memeErrorContract.validateRouter(msg.sender);

        lockTime = time;

        emit SetLockTime(time);
    }

    function _countValue(address pool) internal {
        address memeToken = poolToken[pool];

        initValue[memeToken] = memeErrorContract.getTokenValue(usdt,  vault.poolAmounts(memeToken, usdt));
    }

    function getMemeState(address pool) external view returns(MemeState memory) {
        return memeState[pool];
    }

    function getMemeUserInfo(address pool, address user) external view returns(MemeUserInfo memory) {
        return memeUserInfo[pool][user];
    }

    function getAmount(address token, address account) public view returns(uint256) {
        return IERC20(token).balanceOf(account);
    }

    function getUserDepositPoolNum(address user) external view returns(uint256) {
        return userPool[user].length();
    }

    function getUserDepositPool(address user, uint256 index) external view returns(address) {
        return userPool[user].at(index);
    }

    function getUserDepositPoolisIn(address user, address pool) external view returns(bool) {
        return userPool[user].contains(pool);
    }
}
