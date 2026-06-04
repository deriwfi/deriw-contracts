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
import "../Pendant/interfaces/ICoinData.sol";
import "../core/interfaces/IGlpManager.sol";
import "../staking/interfaces/IRewardRouterV2.sol";
import "../Pendant/interfaces/IPhase.sol";
import "../Pendant/interfaces/ISlippage.sol";
import "../core/interfaces/IMintable.sol";
import "./interfaces/IChannelPool.sol";
import "../core/interfaces/IADL.sol";
import "../core/interfaces/IDataReader.sol";
import "../referrals/interfaces/IReferralData.sol";

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

    constructor() {
        initialized = true;
    }

    modifier onlyGov() {
        require(gov == msg.sender, "gov err");
        _;
    }

    function createPool(address pool, address token) external {
        require(msg.sender == address(memeFactory), "init err");
        require(pool != address(0), "pool err");

        isAddMeme[token] = true;
        isTokenCreate[token] = true;
        poolToken[pool] = token;
        tokenToPool[token] = pool;
    }

    function initialize(address usdt_) external {
        require(!initialized, "has initialized");
        require(usdt_ != address(0), "usdt_ err");

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
        require(
            memeFactory_ != address(0) &&
            errContract_ != address(0) &&
            glpRewardRouter_ != address(0) &&
            vault_ != address(0),
            "addr err"
        );

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

    // ************************************************************
    function addMemeState(address indexToken) external {
        require(memeErrorContract.coinData() == msg.sender || msg.sender == address(memeFactory), "caller err");

        isAddMeme[indexToken] = true;
    }

    // ************************************Channel mode***********************************************
    /// @notice Channel user deposit/GLP tracking by (pool, user, setID)
    mapping(address => mapping(address => mapping(uint256 => MemeUserInfo))) public channelUserInfo;
    
    /// @notice Emitted when a channel user deposits USDT and mints GLP
    event AddLiquidity(
        address account,
        address pool,
        address to,
        address token,
        uint256 amount,
        uint256 mintGlpAmount,
        uint256 totalSupply
    );

    /// @notice Emitted when a channel user withdraws USDT by burning GLP
    event RemoveLiquidity(
        address account,
        address pool,
        address from,
        address to,
        address token,
        uint256 amount,
        uint256 outAmount,
        uint256 burnGlpAmount,
        uint256 totalSupply
    );

    /**
     * @notice Deposit USDT into a channel pool and mint GLP
     * @dev Only callable by MemeFactory.
     *      Reverts if:
     *      - Caller is not MemeFactory ("No permission")
     *      - Pool address is zero, pool is closed, or pool is paused ("cannot deposit")
     *      - Pool has entered freeze period (freezeTime set AND freezeTime <= now) ("cannot deposit")
     *      Once freezeTime has passed, deposits are permanently blocked for this pool.
     *      Execution:
     *      1. Get current set ID for the pool
     *      2. Increment user's depositAmount in channelUserInfo
     *      3. Mint GLP via _mintAndStakeGlp (USDT → GLP)
     *      4. Add glpAmount to user's channelUserInfo
     * @param user Depositor address
     * @param pool Channel pool address
     * @param amount USDT amount (6 decimals)
     */
    function depositChannel(address user, address pool, uint256 amount) external {
        if(msg.sender != address(memeFactory)) revert("No permission");
        (,uint256 freezeTime,) = memeFactory.channelPoolCloseInfo(pool);
        if(pool == address(0) || memeFactory.channelPoolIsClose(pool) || memeFactory.channelPoolIsPause(pool) || (freezeTime != 0 && freezeTime <= block.timestamp)) revert("cannot deposit");
 
        uint256 cID = memeFactory.channelPoolSetID(pool);
        channelUserInfo[pool][user][cID].depositAmount += amount;
        uint256 glpAmount = _mintAndStakeGlp(pool, user, memeFactory.channelPoolToken(pool), usdt, amount);

        channelUserInfo[pool][user][cID].glpAmount += glpAmount;
    }

    /**
     * @notice Redeem channel pool GLP back to USDT
     * @dev Only callable by MemeFactory.
     *      Reverts if:
     *      - Caller is not MemeFactory ("No permission")
     *      - Pool address is zero, pool is closed, or pool is paused ("cannot claim")
     *      - Pool is within the close freeze window (freezeTime < now < endTime) ("time err")
     *      - EndTime has passed but open positions still exist (silent revert, longSize or shortSize non-zero)
     *
     *      Two withdrawal paths depending on pool close state:
     *      1. Normal withdrawal (freezeTime not set or not yet reached):
     *         GLP is redeemed proportionally, capped by perWithdrawRate (enforced in DataReader).
     *      2. Full withdrawal (freezeTime passed AND endTime passed AND no open positions):
     *         Entire pool value is redeemable, all GLP burned.
     *
     *      Execution:
     *      1. Validate caller is MemeFactory, pool is not closed/paused
     *      2. If freezeTime has passed:
     *         - Revert if still within close window (endTime > now)
     *         - Revert if positions remain after endTime (protection against undeleted positions)
     *      3. Delegate to _unstakeAndRedeemGlp which:
     *         - Calculates outAmount/burnGlpAmount via getChannelOutAmount
     *         - Burns GLP from pool, transfers USDT from Vault to user
     *         - Updates channelUserInfo state (deduct glpAmount, add unStakeAmount)
     * @param user Claimer address (USDT receiver)
     * @param pool Channel pool address
     * @param amount GLP amount to redeem (18 decimals)
     */
    function claimChannel(address user, address pool, uint256 amount) external {
        if(msg.sender != address(memeFactory)) revert("No permission");
        if(pool == address(0) || memeFactory.channelPoolIsClose(pool) || memeFactory.channelPoolIsPause(pool)) revert("cannot claim");

        (,uint256 freezeTime, uint256 endTime) = memeFactory.channelPoolCloseInfo(pool);
        if(freezeTime != 0 && freezeTime < block.timestamp) {
            if(endTime > block.timestamp) {
                revert("time err");
            } else {
                IADL adl = IADL(IReferralData(vault.referralData()).adlContract());
                (uint256 longSize, uint256 shortSize) = adl.getGlobalLongAndShortSizes(memeFactory.channelPoolToken(pool));
                if(longSize != 0 || shortSize != 0) revert("size err");
            }
        }
        _unstakeAndRedeemGlp(user, pool, poolToken[pool], usdt, amount, user);
    }

    /**
     * @notice Mint GLP tokens from USDT deposit into a channel pool
     * @dev Execution order:
     *      1. Validate: amount > 0, collateralToken == USDT
     *      2. Calculate GLP amount via _getChannelGlpAmount:
     *         - If glpSupply == 0 → 1:1 exchange (amount * glpDecimals / usdtDecimals)
     *         - If glpSupply > 0 → proportional (glpSupply * amount / poolAmounts)
     *      3. Update Vault: addTokenBalances → _increasePoolAmount (tracking)
     *      4. Update Slippage: addGlpAmount → increase GLP supply tracking
     *      5. Mint GLP: mint(pool, glpAmount) → GLP sent to pool address
     *      6. Transfer: USDT from user → Vault (safeTransferFrom)
     *      7. Emit AddLiquidity event with updated GLP supply
     * @param pool Channel pool receiving GLP
     * @param user Depositor (USDT source)
     * @param indexToken Index token for pool amount / GLP supply lookups
     * @param collateralToken Collateral (must be USDT)
     * @param amount USDT amount (6 decimals)
     * @return glpAmount GLP tokens minted (18 decimals)
     */
    function _mintAndStakeGlp(
        address pool,
        address user,
        address indexToken,
        address collateralToken, 
        uint256 amount
    ) internal returns (uint256) {
        if(amount == 0) revert("amount err");
        if(collateralToken != usdt) revert("collateralToken err");
        uint256 glpAmount = _getChannelGlpAmount(indexToken, collateralToken, amount);
        if(glpAmount == 0) revert("glpAmount err");

        vault.addTokenBalances(indexToken, collateralToken, amount);
        slippage().addGlpAmount(indexToken, collateralToken, glpAmount);
        IMintable(GLP()).mint(pool, glpAmount);
        IERC20(collateralToken).safeTransferFrom(user, address(vault), amount);

        emit AddLiquidity(user, pool, address(vault), collateralToken, amount, glpAmount, slippage().glpTokenSupply(indexToken, collateralToken));
        
        return glpAmount;
    }

    /**
     * @notice Burn GLP and withdraw USDT from a channel pool
     * @dev Execution order:
     *      1. Validate: amount > 0, receiver != address(0)
     *      2. Calculate via getChannelOutAmount → outAmount (USDT), burnGlpAmount (GLP)
     *         - Full withdrawal: all positions closed + past close time → entire pool
     *         - Partial withdrawal: capped by perWithdrawRate and time window checks
     *      3. Slippage: subGlpAmount → decrease GLP supply tracking
     *      4. Approve + burn: pool approves GLP, then burn(pool, burnGlpAmount)
     *      5. Transfer: vault.transferOut → USDT from Vault to receiver
     *      6. Update user state: channelUserInfo.glpAmount -= burnGlpAmount,
     *                              channelUserInfo.unStakeAmount += outAmount
     *      7. Emit RemoveLiquidity event
     * @param user Claimer address (state update target)
     * @param pool Channel pool address (GLP holder)
     * @param indexToken Index token for getChannelOutAmount lookup
     * @param tokenOut Output token (must be USDT)
     * @param amount Requested withdrawal (USDT)
     * @param receiver USDT recipient address
     * @return outAmount USDT actually withdrawn (after caps)
     * @return burnGlpAmount GLP tokens burned
     */
    function _unstakeAndRedeemGlp(
        address user,
        address pool,
        address indexToken, 
        address tokenOut, 
        uint256 amount, 
        address receiver
    ) internal returns (uint256, uint256) {
        if(amount == 0 || receiver == address(0)) revert("claim err");

        (uint256 outAmount, uint256 burnGlpAmount,,) = getChannelOutAmount(indexToken, tokenOut, amount);
        if(outAmount == 0) revert("outAmount err");
        slippage().subGlpAmount(indexToken, tokenOut, burnGlpAmount);
        uint256 totalSupply = slippage().glpTokenSupply(indexToken, tokenOut);
        address glp = GLP();
        IChannelPool(pool).approve(address(this), glp, burnGlpAmount);
        IMintable(glp).burn(pool, burnGlpAmount);
        vault.transferOut(indexToken, tokenOut, receiver, outAmount);

        uint256 cID = memeFactory.channelPoolSetID(pool);
        channelUserInfo[pool][user][cID].glpAmount -= burnGlpAmount;
        channelUserInfo[pool][user][cID].unStakeAmount += outAmount;

        emit RemoveLiquidity(user, pool, address(vault), receiver, tokenOut, amount, outAmount, burnGlpAmount, totalSupply);
        
        return (outAmount, burnGlpAmount);
    }

    /**
     * @notice Calculate GLP amount for a USDT deposit
     * @dev Returns 0 if collateral is not USDT or amount is 0
     * @param indexToken Index token address
     * @param collateralToken Collateral token (must be USDT)
     * @param amount USDT amount
     * @return GLP amount that would be minted
     */
    function getChannelGlpAmount(address indexToken, address collateralToken, uint256 amount) external view returns(uint256) {
        (address pool,, address targetToken,) = memeFactory.getChannelMappedTokenPoolInfo(indexToken);
        if(collateralToken != usdt || amount == 0 || pool == address(0)) {
            return 0;
        }   
        return _getChannelGlpAmount(targetToken, collateralToken, amount);
    }

    /**
     * @notice Calculate GLP amount internally
     * @dev If glpSupply=0 uses 1:1 ratio adjusted for decimals; otherwise proportional
     * @param indexToken Index token address
     * @param collateralToken Collateral token (USDT)
     * @param amount USDT amount
     * @return glpAmount Calculated GLP amount
     */
    function _getChannelGlpAmount(address indexToken, address collateralToken, uint256 amount) internal view returns(uint256) {
        uint256 deci = getTokenDecimals(usdt);
        uint256 glpDeci = getTokenDecimals(GLP());
        uint256 glpSupply = slippage().glpTokenSupply(indexToken, collateralToken);
        if(glpSupply == 0) {
            return  amount * glpDeci / deci;
        } else {
            return glpSupply * amount / vault.poolAmounts(indexToken, collateralToken);
        }
    }

    /**
     * @notice Get GLP token address through contract chain
     * @return GLP token address
     */
    function GLP() public view returns(address) {
        return IGlpManager(IRewardRouterV2(glpRewardRouter).glpManager()).glp();
    }

    /**
     * @notice Get Slippage contract instance
     * @return ISlippage interface instance
     */
    function slippage() public view returns(ISlippage) {
        return ISlippage(vault.slippage());
    }

    /**
     * @notice Get decimal precision factor for a token
     * @return 10**decimals (e.g., USDT 6→10^6)
     */
    function getTokenDecimals(address token) public view returns(uint256) {
        return 10 ** IERC20Metadata(token).decimals();
    }

    /**
     * @notice Calculate channel withdrawal amount
     * @dev Two withdrawal paths:
     *      1. Full withdrawal: all positions closed (longSize==0 && shortSize==0)
     *         AND pool past close endTime → return entire pool value, burn all GLP
     *      2. Partial withdrawal (default): positions still open or pool still active
     *         → delegate to DataReader for capped calculation with risk buffer
     *      Returns all zeros if indexToken has no channel pool or tokenOut != USDT.
     * @param indexToken Index token (channel-mapped)
     * @param tokenOut Output token (must be USDT)
     * @param amount Requested withdrawal amount
     * @return outAmount Actual withdrawable amount (after capping)
     * @return burnGlpAmount GLP tokens to burn proportionally
     * @return totalOutAmount Total withdrawable pool value
     * @return riskBuffer Risk buffer deducted from total
     */
    function getChannelOutAmount(address indexToken, address tokenOut, uint256 amount) public view returns(uint256 outAmount, uint256 burnGlpAmount, uint256 totalOutAmount, uint256 riskBuffer) {
        (address pool,, address targetToken,) = memeFactory.getChannelMappedTokenPoolInfo(indexToken);
        if(pool == address(0) || tokenOut != usdt) {
            return (0,0,0,0);
        }
        {
            uint256 totalGlpSupply = ISlippage(vault.slippage()).glpTokenSupply(targetToken, tokenOut);
            totalOutAmount = IPhase(vault.phase()).getOutAmount(targetToken, tokenOut, totalGlpSupply);
            IADL adl = IADL(IReferralData(vault.referralData()).adlContract());
            (uint256 longSize, uint256 shortSize) = adl.getGlobalLongAndShortSizes(targetToken);
            (,, uint256 endTime) = memeFactory.channelPoolCloseInfo(pool);
            if(longSize == 0 && shortSize == 0 && endTime > 0 && block.timestamp > endTime) {
                outAmount = totalOutAmount;
                burnGlpAmount = totalGlpSupply;
            } else {
                (outAmount, burnGlpAmount, riskBuffer) = IDataReader(vault.dataReader()).getChannelOutAmount(indexToken, tokenOut, amount);
            }
        }
    }
}
