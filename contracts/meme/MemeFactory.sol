// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./MemePool.sol";
import "../libraries/utils/ReentrancyGuard.sol";
import "./interfaces/IMemeErrorContract.sol";
import "./interfaces/IMemeData.sol";
import "../upgradeability/Synchron.sol";
import "./ChannelPool.sol";
import "../Pendant/interfaces/ICoinData.sol";
import "../core/interfaces/IVault.sol";
import "../PlaceholderToken.sol";
import "../referrals/interfaces/IReferralStorage.sol";
import "../core/interfaces/IDataReader.sol";
import "../Pendant/interfaces/IPhase.sol";
import "../Pendant/interfaces/ISlippage.sol";

contract MemeFactory is Synchron, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    event CreatePool(address creator, address pool, address token, string symbol);
    event AddWhitelist(address indexed account);
    event RemoveWhitelist(address indexed account);

    EnumerableSet.AddressSet Whitelist;
    EnumerableSet.AddressSet removelist;
    IMemeErrorContract public memeErrorContract;
    IMemeData public memeData;

    address public coinData;
    address public gov;

    uint256 public poolID;

    bool public initialized;

    mapping(uint256 => address) public idToPool;
    mapping(address => address[]) public ownerPool;
    mapping(address => address) public poolOwner;
    mapping(address => bool) public operator;
    mapping(address => bool) public trader;

    constructor() {
        initialized = true;
    }

    modifier onlyGov() {
        require(gov == msg.sender, "no permission");
        _;
    }

    modifier onlyAuth() {
        require(gov == msg.sender || trader[msg.sender], "no permission");
        _;
    }

    function initialize() external {
        require(!initialized, "has initialized");
        initialized = true;

        gov = msg.sender;
    }


    function setGov(address account) external onlyGov {
        require(account != address(0), "_gov err");
        gov = account;
    }

    function setTrader(address account, bool isAdd) external onlyGov {
        require(account != address(0), "account err");

        trader[account] = isAdd;
    }

    function setOperator(address account, bool isAdd) external onlyAuth {
        require(account != address(0), "account err");

        operator[account] = isAdd;
    }

    function setContract(
        address errContract_,
        address memeData_,
        address coinData_
    ) external onlyAuth {
        require(
            errContract_ != address(0) &&
            memeData_ != address(0) &&
            coinData_ != address(0),
            "addr err"
        );

        memeData = IMemeData(memeData_);
        memeErrorContract = IMemeErrorContract(errContract_);
        coinData = coinData_;
    }


    function addOremoveWhitelist(address[] memory accounts, bool isAdd) external onlyAuth {
        if(isAdd) {
            _addWhitelist(accounts);
        } else {
            _removeWhitelist(accounts);
        }
    }

    function createPool(address token) external nonReentrant {
        memeErrorContract.validateCreatePool(address(this), msg.sender, token);

        uint256 id = ++poolID;
        address pool = address(new MemePool{salt: keccak256(abi.encode(id, token))}());
       
        memeData.createPool(pool, token);

        idToPool[id] = pool;
        ownerPool[msg.sender].push(pool);
        poolOwner[pool] = msg.sender;
        string memory _symbol = IERC20Metadata(token).symbol();

        emit CreatePool(msg.sender, pool, token, _symbol);
    }  

    function _addWhitelist(address[] memory accounts) internal {
        for (uint256 i = 0; i < accounts.length; i++) {
            if(!Whitelist.contains(accounts[i])) {
                require(accounts[i] != address(0), "account err");
                Whitelist.add(accounts[i]);
                removelist.remove(accounts[i]);
                emit AddWhitelist(accounts[i]);
            }
        }
    }

    function _removeWhitelist(address[] memory accounts) internal  {
        for (uint256 i = 0; i < accounts.length; i++) {
            if(Whitelist.contains(accounts[i])) {
                require(accounts[i] != address(0), "account err");
                Whitelist.remove(accounts[i]);
                removelist.add(accounts[i]);
                emit RemoveWhitelist(accounts[i]);
            }
        }
    }

    function getWhitelistNum() external view returns(uint256) {
        return Whitelist.length();
    }

    function getWhitelist(uint256 index) external view returns(address) {
        return Whitelist.at(index);
    }

    function getWhitelistIsIn(address account) external view returns(bool) {
        return Whitelist.contains(account);
    }

    function getRemovelistNum() external view returns(uint256) {
        return removelist.length();
    }

    function getRemovelist(uint256 index) external view returns(address) {
        return removelist.at(index);
    }

    function getRemovelistIsIn(address account) external view returns(bool) {
        return removelist.contains(account);
    }

    function getInList(address account) external view returns(bool) {
        if(Whitelist.contains(account) || removelist.contains(account)) {
            return true;
        }
        return false;
    }

    function getPoolNum(address account) external view returns(uint256) {
        return ownerPool[account].length;
    }

    // ************************************Channel mode***********************************************
    using Strings for uint256;

    /// @notice Global channel settings (create funds, buffer, time)
    ChannelSettings public channelSettings;
    /// @notice Global pool config (withdrawal rate/number/window)
    ChannelPoolConfig public channelPoolConfig;
    /// @notice Channel ID to pool address
    mapping(uint256 => address) public channelIDToPool;
    /// @notice Pool address to channel ID
    mapping(address => uint256) public poolToChannelID;
    /// @notice User to owned channel pool address
    mapping(address => address) public channelOwnerPool;
    /// @notice Pool address to its creator/owner
    mapping(address => address) public channelPoolOwner;

    /// @notice Current withdrawal number per pool
    mapping(address => uint256) public poolCurrWithdrawalNumber;
    /// @notice Last withdrawal timestamp per pool
    mapping(address => uint256) public poolLastWithdrawalTime;
    /// @notice Whether a pool is paused
    mapping(address => bool) public channelPoolIsPause;
    /// @notice Whether a pool is closed
    mapping(address => bool) public channelPoolIsClose;
    /// @notice Pool's channel token
    mapping(address => address) public channelPoolToken;
    /// @notice Token to channel pool mapping
    mapping(address => address) public channelMappedTokenPool;
    /// @notice Channel operator accounts
    mapping(address => bool) public channelOperator;
    /// @notice Blacklist by (pool, user)
    mapping(address => mapping(address => bool)) public blacklist;
    /// @notice Pool's mapped target token (internal)
    mapping(address => address) public channelMappedTargetToken;
    /// @notice Pool to (token to channel token) mapping
    mapping(address => mapping(address => address)) public channelMappedIndexToken;
    /// @notice Index token to (pool to channel token) reverse mapping
    mapping(address => mapping(address => address)) public indexTokenChannelMapped;
    /// @notice Whether a (pool, symbol key) is taken
    mapping(address => mapping(bytes32 => bool)) public channelMappedIndexTokenIsIn;
    /// @notice Current set ID per pool (increments on reopen)
    mapping(address => uint256) public channelPoolSetID;
    /// @notice Close time info per pool
    mapping(address => ChannelCloseTime) public channelPoolCloseInfo;
    /// @notice Per-pool factor (short/long/total)
    mapping(address => ChannelPoolFactor) public channelPoolFactorInfo;
    /// @notice Authorized channel token creators
    mapping(address => bool) public channelTokenCreator;
    /// @notice Channel pool operating mode. 1 = principal mode, 2 = total equity mode
    mapping(address => uint256) public channelPoolMode;

    /**
     * @notice Global channel configuration parameters
     * @param createFunds Minimum USDT amount required to create a channel pool
     * @param bufferRate Risk buffer rate in basis points (e.g., 500 = 5%)
     * @param minBufferAmount Minimum buffer amount in USDT
     * @param channelFreezeTime Duration in seconds before close takes effect after startTime
     * @param channelIntervalTime Total close interval in seconds (from startTime to endTime)
     * @param channelID Auto-incrementing counter for channel pool IDs
     */
    struct ChannelSettings {
        uint256 createFunds;          // Minimum USDT to create a pool
        uint256 bufferRate;           // Risk buffer rate (basis points)
        uint256 minBufferAmount;      // Minimum buffer amount (USDT)
        uint256 channelFreezeTime;    // Freeze duration before close (seconds)
        uint256 channelIntervalTime;  // Total close interval (seconds)
        uint256 channelID;            // Auto-incrementing pool ID counter
    }

    /**
     * @notice Per-pool factor configuration for value calculations
     * @param shortFactor Short position factor in basis points (default 20000)
     * @param longFactor Long position factor in basis points (default 20000)
     * @param totalFactor Total position factor in basis points (default 50000)
     */
    struct ChannelPoolFactor {
        uint256 shortFactor;          // Short position factor (basis points)
        uint256 longFactor;           // Long position factor (basis points)
        uint256 totalFactor;          // Total position factor (basis points)
    }

    /**
     * @notice Global pool withdrawal configuration
     * @param perWithdrawRate Maximum withdrawal ratio per claim in basis points
     * @param withdrawalNumber Number of unrestricted withdrawals before time window applies
     * @param windowTime Cooldown window in seconds between restricted withdrawals
     */
    struct ChannelPoolConfig {
        uint256 perWithdrawRate;      // Max withdrawal ratio per claim (basis points)
        uint256 withdrawalNumber;     // Free withdrawal count before window applies
        uint256 windowTime;           // Cooldown window between withdrawals (seconds)
    }

    /**
     * @notice Pool close time window configuration
     * @param startTime Timestamp when the close window begins
     * @param freezeTime Timestamp after which cancellation is no longer allowed
     * @param endTime Timestamp when the close window ends
     */
    struct ChannelCloseTime {
        uint256 startTime;            // Close window start timestamp
        uint256 freezeTime;           // Freeze deadline (cancellation blocked after this)
        uint256 endTime;              // Close window end timestamp
    }

    /// @notice Restricts to channel operators
    modifier onlyChannelOperator() {
        if(!channelOperator[msg.sender]) revert("not channel operator");
        _;
    }

    /// @notice Emitted when channel create funds are updated
    event SetChannelCreateFunds(uint256 funds);
    /// @notice Emitted when buffer rate is updated
    event SetChannelBufferRate(uint256 rate);
    /// @notice Emitted when min buffer amount is updated
    event SetChannelBufferAmount(uint256 amount);
    /// @notice Emitted when freeze/interval times are updated
    event SetChannelTime(uint256 freezeTime, uint256 intervalTime);
    /// @notice Emitted when pool config (withdrawal rate/number/window) is updated
    event SetChannelPoolConfig(uint256 perWithdrawRate, uint256 withdrawalNumber, uint256 windowTime);
    /// @notice Emitted when pool close time is set
    event SetChannelPoolCloseTime(address pool, ChannelCloseTime timeInfo);
    /// @notice Emitted when pool close time is cancelled
    event CancelChannelPoolCloseTime(address pool);
    /// @notice Emitted when channel operator is set
    event SetChannelOperator(address account, bool isOperator);
    /// @notice Emitted when pool pause state changes
    event SetChannelPoolIsPause(address pool, bool isPause);
    /// @notice Emitted when pool is closed
    event SetChannelPoolClose(address pool);
    /// @notice Emitted when pool is reopened
    event SetChannelPoolOpen(address pool, uint256 id, uint256 mode);
    /// @notice Emitted when pool factor is set
    event SetPoolFactor(address pool, uint256 shortFactor, uint256 longFactor, uint256 totalFactor);
    /// @notice Emitted when blacklist is modified
    event SetBlacklist(address pool, address account, bool isAdd);
    /// @notice Emitted when a channel token is created
    event CreateChannelToken(address pool, address indexToken, address mappedIndexToken, address poolTargetToken, uint256 time, string symbol);
    /// @notice Emitted when withdrawal time is updated
    event UpdateTime(address pool, uint256 number, uint256 time);
    /// @notice Emitted when token creator permission is set
    event SetChannelTokenCreator(address account, bool isAdd);
    /// @notice Emitted when a channel pool is created
    event CreateChannelPool(
        address indexed user, 
        address indexed indexToken, 
        address indexed channelIndexToken, 
        address pool, 
        uint256 amount,
        uint256 time,
        uint256 mode,
        string symbol
    );

    /**
     * @notice Set minimum create funds for channel pools
     * @param funds Minimum USDT amount (6 decimals)
     */
    function setChannelCreateFunds(uint256 funds) external onlyGov {
        if(funds == 0) revert("funds err");
        channelSettings.createFunds = funds;

        emit SetChannelCreateFunds(funds);
    }

    /**
     * @notice Set buffer rate for risk calculation
     * @param rate Buffer rate in basis points (1-9999)
     */
    function setChannelBufferRate(uint256 rate) external onlyGov {
        if(rate == 0 || rate >= 10000) revert("rate err");
        channelSettings.bufferRate = rate;

        emit SetChannelBufferRate(rate);
    }

    /**
     * @notice Set minimum buffer amount
     * @param amount Minimum USDT buffer
     */
    function setChannelBufferAmount(uint256 amount) external onlyGov {
        if(amount == 0) revert("amount err");
        channelSettings.minBufferAmount = amount;

        emit SetChannelBufferAmount(amount);
    }

    /**
     * @notice Set freeze and interval times for pool close
     * @param freezeTime Freeze duration before close takes effect
     * @param intervalTime Total close interval
     */
    function setChannelTime(uint256 freezeTime, uint256 intervalTime) external onlyGov {
        if(freezeTime == 0 || intervalTime == 0 || freezeTime > intervalTime) revert("time err");
        channelSettings.channelFreezeTime = freezeTime;
        channelSettings.channelIntervalTime = intervalTime;

        emit SetChannelTime(freezeTime, intervalTime);
    }

    /**
     * @notice Set global channel pool withdrawal config
     * @param perWithdrawRate Maximum withdrawal ratio per claim (basis points)
     * @param withdrawalNumber Unrestricted withdrawal count before window applies
     * @param windowTime Cooldown window between restricted withdrawals (seconds)
     */
    function setChannelPoolConfig(uint256 perWithdrawRate, uint256 withdrawalNumber, uint256 windowTime) external onlyGov {
        if(perWithdrawRate > 10000 || perWithdrawRate == 0) revert("perWithdrawRate err");  
        channelPoolConfig.perWithdrawRate = perWithdrawRate;
        channelPoolConfig.withdrawalNumber = withdrawalNumber;
        channelPoolConfig.windowTime = windowTime;

        emit SetChannelPoolConfig(perWithdrawRate, withdrawalNumber, windowTime);
    }

    /**
     * @notice Set a channel operator account
     * @param account Account address
     * @param isOperator Whether to grant operator role
     */
    function setChannelOperator(address account, bool isOperator) external onlyGov {
        if(account == address(0)) revert("account err");
        channelOperator[account] = isOperator;

        emit SetChannelOperator(account, isOperator);
    }

    /**
     * @notice Set a channel token creator
     * @param account Account address
     * @param isAdd Whether to grant creator permission
     */
    function setChannelTokenCreator(address account, bool isAdd) external onlyGov {
        if(account == address(0)) revert("account err");
        channelTokenCreator[account] = isAdd;

        emit SetChannelTokenCreator(account, isAdd);
    }

    /**
     * @notice Pause or unpause a channel pool
     * @param pool Pool address
     * @param isPause New pause state
     */
    function setChannelPoolIsPause(address pool, bool isPause) external onlyChannelOperator {
        if(channelPoolIsPause[pool] == isPause) revert("set err");
        channelPoolIsPause[pool] = isPause;

        emit SetChannelPoolIsPause(pool, isPause);
    }

    /**
     * @notice Schedule a close window starting immediately (now) for the caller's channel pool
     * @dev Uses block.timestamp as startTime. Three-phase window:
     *      now → now+freezeTime → (now+freezeTime)+intervalTime.
     *      Pool owner may later call setChannelPoolFreezeNow to skip to freezeTime immediately.
     */
    function setChannelPoolCloseCurrTime() external {
        _setChannelPoolCloseTime(block.timestamp);
    }

    /**
     * @notice Force the caller's channel pool to enter the freeze period immediately
     * @dev Sets freezeTime to current block.timestamp (permanently blocking deposits)
     *      and resets endTime to freezeTime + channelIntervalTime.
     *      Effectively restarts the close window from now, skipping the original startTime→freezeTime
     *      waiting period so the pool owner can accelerate closure.
     *      Conditions:
     *      - Caller must own a pool (pool != address(0))
     *      - Pool must have an active close window (endTime != 0)
     *      - freezeTime must not yet be reached (not already frozen)
     *      - Pool must not be closed
     */
    function setChannelPoolFreezeNow() external {
        address pool = channelOwnerPool[msg.sender];
        ChannelCloseTime storage info = channelPoolCloseInfo[pool];
        if(pool == address(0) || info.endTime == 0 || channelPoolIsClose[pool]) revert("pool err");
        if(info.freezeTime <= block.timestamp) revert("time err");

        info.freezeTime = block.timestamp;
        info.endTime = info.freezeTime + channelSettings.channelIntervalTime;

        emit SetChannelPoolCloseTime(pool, info);
    }

    /**
     * @notice Advance a channel pool's endTime to now (operator only)
     * @dev Calls _updateCloseTime with block.timestamp. If poolEndTime == 0, creates
     *      a new close window from now. If in freeze window and no open positions,
     *      shortens endTime to now, allowing immediate pool closure.
     * @param pool Channel pool address
     */
    function setChannelPoolEndNow(address pool) external onlyChannelOperator {
        _updateCloseTime(pool, block.timestamp);
    }

    /**
     * @notice Close a channel pool (operator only)
     * @dev Conditions:
     *      - Caller must be channel operator (onlyChannelOperator)
     *      - Pool owner's glpAmount must be 0 (all funds withdrawn)
     *      - Close window must not be expired (endTime > now)
     *      - Pool must not already be closed
     *      Effect: marks pool as closed, clears close time info.
     * @param pool Channel pool address
     */
    function setChannelPoolClose(address pool) external onlyChannelOperator {
        if(channelPoolCloseInfo[pool].endTime > block.timestamp) revert("time err");
        if(channelPoolIsClose[pool]) revert("set err");
        uint256 totalGlpSupply = ISlippage(vault().slippage()).glpTokenSupply(channelPoolToken[pool], vault().usdt());
        if(totalGlpSupply != 0) revert("glp err");

        channelPoolIsClose[pool] = true;
        delete channelPoolCloseInfo[pool];

        emit SetChannelPoolClose(pool);
    }

    /**
     * @notice Reopen a previously closed channel pool
     * @dev Steps:
     *      1. Caller must be the pool owner (channelOwnerPool[msg.sender])
     *      2. Pool must be closed, mode must be 1 or 2, amount >= createFunds
     *      3. Reset close flag, set new mode, clear withdrawal counters
     *      4. Increment poolSetID (new deposit cycle)
     *      5. Re-deposit initial funds via depositChannel
     */
    function setChannelPoolOpen(uint256 mode, uint256 amount) external {
        address pool = channelOwnerPool[msg.sender];
        if(pool == address(0) || !channelPoolIsClose[pool]) revert("set err"); 
        if(mode != 1 && mode != 2) revert("mode err");
        if(amount < getChannelCreateFunds()) revert("amount err");

        channelPoolIsClose[pool] = false;
        channelPoolMode[pool] = mode;
        poolCurrWithdrawalNumber[pool] = 0;
        poolLastWithdrawalTime[pool] = 0;
        emit SetChannelPoolOpen(pool, ++channelPoolSetID[pool], mode);

        memeData.depositChannel(msg.sender, pool, amount);
    }

    /**
     * @notice Cancel a pending pool close window
     * @dev Only possible before the freeze time is reached (info.freezeTime).
     *      After freeze, the close is irrevocable and can only proceed to completion.
     *      Reverts if: past freeze time, or no close window set (startTime == 0).
     */
    function cancelChannelPoolCloseTime() external {
        address pool = channelOwnerPool[msg.sender];
        ChannelCloseTime memory info = channelPoolCloseInfo[pool];
        if(block.timestamp >= info.freezeTime || info.startTime == 0) revert("cancel err");
        delete channelPoolCloseInfo[pool];
        emit CancelChannelPoolCloseTime(pool);
    }

    /**
     * @notice Set pool factor (short/long/total)
     * @param pool Pool address
     * @param shortFactor Short factor in basis points
     * @param longFactor Long factor in basis points
     * @param totalFactor Total factor in basis points
     */
    function setPoolFactor(address pool, uint256 shortFactor, uint256 longFactor, uint256 totalFactor) external onlyGov {
        if(shortFactor == 0 || longFactor == 0 || totalFactor == 0) revert("factor err");
        channelPoolFactorInfo[pool] = ChannelPoolFactor(shortFactor, longFactor, totalFactor);

        emit SetPoolFactor(pool, shortFactor, longFactor, totalFactor);
    }

    /**
     * @notice Batch add/remove accounts from pool blacklist
     * @param accounts Array of addresses
     * @param isAdd True to blacklist, false to unblacklist
     */
    function batchSetBlacklist(address[] memory accounts, bool isAdd) external {
        address pool = channelOwnerPool[msg.sender];
        if(pool == address(0)) revert("pool err");
        if(channelPoolIsClose[pool]) revert("set err");

        for(uint256 i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            if(!blacklist[pool][account] == isAdd) {
                blacklist[pool][account] = isAdd;
                emit SetBlacklist(pool, account, isAdd);
            }
        }
    }

    /**
     * @notice Create a new channel pool with initial USDT deposit
     * @dev Execution order:
     *      1. Init defaults on first pool: channelPoolConfig(1000,5,24h), channelSettings(1000USDT,1000bp,500USDT,2h,7d,0)
     *      2. Validate: amount >= createFunds, mode in [1,2], caller has no existing pool
     *      3. Deploy ChannelPool via CREATE2 (salt = hash(caller, id, timestamp))
     *      4. Create USDT-based ChannelToken placeholder (_createChannelToken)
     *      5. Register in memeData (createPool) and set cross-mappings
     *      6. Set channel ID/pool mappings, owner, factor, mode
     *      7. Initial deposit via depositChannel → mints GLP to pool
     *      Mode 1 = principal mode, Mode 2 = total equity mode
     * @param amount Initial USDT deposit (6 decimals, >= channelSettings.createFunds)
     * @param mode 1 = principal mode, 2 = total equity mode
     */
    function createChannelPool(uint256 amount, uint256 mode) external nonReentrant {
        if(channelPoolConfig.perWithdrawRate == 0) {
            channelPoolConfig = ChannelPoolConfig(1000, 5, 24 hours);
        }
        if(channelSettings.createFunds == 0) {
            channelSettings = ChannelSettings(1000e6, 1000, 500e6, 2 hours, 7 days, 0);
        }
        if(amount < getChannelCreateFunds()) revert("amount err");
        if(mode != 1 && mode != 2) revert("mode err");
        if(channelOwnerPool[msg.sender] != address(0)) revert("has pool");

        uint256 id = ++channelSettings.channelID;
        address pool = address(new channelPool{salt: keccak256(abi.encode(msg.sender, id, block.timestamp))}());
        address usdt = IVault(memeData.vault()).usdt();
        string memory str = string(abi.encodePacked("Channel", id.toString()));
        address token = _createChannelToken(pool, usdt, str, str);

        memeData.createPool(pool, token);
        channelIDToPool[id] = pool;
        poolToChannelID[pool] = id;
        channelOwnerPool[msg.sender] = pool;
        channelPoolOwner[pool] = msg.sender;
        channelPoolFactorInfo[pool] = ChannelPoolFactor(20000, 20000, 50000);
        channelPoolMode[pool] = mode;
        memeData.depositChannel(msg.sender, pool, amount);

        emit CreateChannelPool(msg.sender, usdt, token, pool, amount, block.timestamp, mode, IERC20Metadata(token).symbol());
    }  

    /**
     * @notice Create or resolve a channel-mapped token for trading
     * @dev Called by OrderBook/PositionRouter during order creation.
     *      Resolution logic (returns early on any fallback condition):
     *      1. Only channelTokenCreator callers (OrderBook/PositionRouter) → "cannot create"
     *      2. If indexToken coinType != 1 → return indexToken (pair token, trade on main pool)
     *      3. Look up user's referrer → find referrer's channel pool
     *      4. If no pool / already mapped / user blacklisted → return indexToken (main pool)
     *      5. If indexToken has no maxPrice → revert "create err"
     *      6. _createChannelToken: deploy PlaceholderToken + set cross-mappings
     *      7. Check channel pool available value via getValue(user, _indexToken, isLong):
     *         - min >= sizeDelta → return _indexToken (trade on channel pool)
     *         - min < sizeDelta  → return indexToken (fall back to main pool)
     * @param user Trader address (used to look up referral)
     * @param indexToken The index token to trade (e.g., BTC)
     * @param sizeDelta Position size delta (USD, 30 decimals)
     * @param isLong Whether the position is long (true) or short (false)
     * @return Resolved token: channel token or original indexToken
     */
    function createChannelToken(address user, address indexToken, uint256 sizeDelta, bool isLong) external returns(address) {
        if(!channelTokenCreator[msg.sender]) revert("cannot create");

        if(ICoinData(coinData).getCoinType(indexToken) != 1) {
            return indexToken;
        }

        IReferralStorage referralStorage = IReferralStorage(IDataReader(vault().dataReader()).referralStorage());
        address ref = referralStorage.referral(user);
        address pool = channelOwnerPool[ref];
        if(pool == address(0) || indexTokenChannelMapped[indexToken][pool] != address(0) || blacklist[pool][user]) {
            return indexToken;
        }
        if(vault().getMaxPrice(indexToken) == 0) revert("create err");

        address _indexToken = _createChannelToken(pool, indexToken, IERC20Metadata(indexToken).name(), IERC20Metadata(indexToken).symbol());
        (uint256 min,) = IPhase(vault().phase()).getValue(user, _indexToken, isLong);
        return min >= sizeDelta ? _indexToken : indexToken;
    }

    /**
     * @notice Deposit USDT into user's channel pool
     * @param amount USDT amount (6 decimals)
     */
    function depositChannel(uint256 amount) external {
        address pool = channelOwnerPool[msg.sender];
        memeData.depositChannel(msg.sender, pool, amount);
    }

    /**
     * @notice Claim/withdraw USDT from caller's channel pool
     * @dev Execution order:
     *      1. Get pool owned by msg.sender, require not paused and pool exists
     *      2. Delegate to memeData.claimChannel → _unstakeAndRedeemGlp:
     *         - Calculate outAmount/burnGlpAmount via getChannelOutAmount
     *         - Burn GLP from pool, transfer USDT from Vault to caller
     *         - Update channelUserInfo state (deduct glpAmount, add unStakeAmount)
     *      3. Increment poolCurrWithdrawalNumber (affects free-withdrawal-count check)
     *      4. Record poolLastWithdrawalTime = now (affects cooldown window check)
     *      5. Emit UpdateTime event
     *      Withdrawal limits (enforced in getChannelOutAmount → DataReader):
     *      - Capped by perWithdrawRate per claim
     *      - Free claims up to withdrawalNumber; after that, cooldown windowTime applies
     * @param amount Requested USDT withdrawal amount (may exceed user's actual share; capped proportionally)
     */
    function claimChannel(uint256 amount) external {
        address pool = channelOwnerPool[msg.sender];
        memeData.claimChannel(msg.sender, pool, amount);
        poolCurrWithdrawalNumber[pool]++;
        poolLastWithdrawalTime[pool] = block.timestamp;
        
        emit UpdateTime(pool, poolCurrWithdrawalNumber[pool], poolLastWithdrawalTime[pool]);
    }

    /**
     * @notice Deploy a PlaceholderToken and register it as a channel-mapped token
     * @dev Internal, called by createChannelPool or createChannelToken.
     *      Mapping setup:
     *      - If indexToken == USDT: set channelPoolToken[pool] = token (pool's primary token)
     *        and channelMappedTargetToken[pool] = USDT (for downstream lookups)
     *      - Otherwise: call memeData.addMemeState(token) for meme pool registration
     *      Always sets:
     *      - channelMappedTokenPool[token] = pool (reverse: token → pool)
     *      - indexTokenChannelMapped[indexToken][pool] = token (forward: indexToken+pool → token)
     *      - channelMappedIndexToken[pool][token] = indexToken (reverse: pool+token → indexToken)
     *      Note: channelPoolToken[pool] is only set for USDT pools;
     *      for other tokens (BTC etc.), it remains address(0), and getChannelMappedTokenPoolInfo
     *      returns underlying indexToken as fallback.
     */
    function _createChannelToken(address pool, address indexToken, string memory name, string memory symbol) internal returns(address) {
        bytes32 key = getChannelPoolTokenKey(pool, symbol);
        if(channelMappedIndexTokenIsIn[pool][key]) revert("token exist");
        channelMappedIndexTokenIsIn[pool][key] = true;

        address token = address(new PlaceholderToken(name, symbol));
        address usdt = vault().usdt();
        if(indexToken == usdt) {
            channelPoolToken[pool] = token;
            channelMappedTargetToken[pool] = usdt;
        } else {
            memeData.addMemeState(token);
        }

        channelMappedTokenPool[token] = pool;
        indexTokenChannelMapped[indexToken][pool] = token;
        channelMappedIndexToken[pool][token] = indexToken;

        emit CreateChannelToken(pool, token, indexToken, channelPoolToken[pool], block.timestamp, symbol);

        return token;
    }

    /**
     * @notice Internal: schedule a close window for `msg.sender`'s channel pool
     * @dev Resolves pool via channelOwnerPool[msg.sender], then delegates to
     *      _updateCloseTime → memeData.validateChanneTime for actual time calculation.
     *      Reverts via validateChanneTime:
     *      - channelFreezeTime == 0          → "not set time"
     *      - pool closed or pool == 0        → "cannot set"
     *      - endTime != 0 and cannot advance → "set err"
     *      Emits SetChannelPoolCloseTime.
     * @param currTime The reference timestamp (usually block.timestamp)
     */
    function _setChannelPoolCloseTime(uint256 currTime) internal {
        _updateCloseTime(channelOwnerPool[msg.sender], currTime);
    }

    /**
     * @notice Internal: update close time via MemeData validation and emit event
     * @dev Delegates time calculation to memeData.validateChanneTime(pool, currTime),
     *      which handles both initial window creation and endTime advancement.
     *      Results are written directly to channelPoolCloseInfo[pool] storage.
     * @param pool Channel pool address
     * @param currTime Reference timestamp
     */
    function _updateCloseTime(address pool, uint256 currTime) internal {
        (
            channelPoolCloseInfo[pool].startTime,
            channelPoolCloseInfo[pool].freezeTime,
            channelPoolCloseInfo[pool].endTime
        ) = memeData.validateChanneTime(pool, currTime);

        emit SetChannelPoolCloseTime(pool, channelPoolCloseInfo[pool]);
    }

    /**
     * @notice Get channel mapping info for a token
     * @param token Token address
     * @return pool Pool address
     * @return indexToken Underlying index token
     * @return targetToken Pool target token
     * @return mappedTargetToken Mapped target token
     */
    function getChannelMappedTokenPoolInfo(address token) external view returns(address pool, address indexToken, address targetToken, address mappedTargetToken) {
        pool = channelMappedTokenPool[token];
        indexToken = channelMappedIndexToken[pool][token];
        targetToken = channelPoolToken[pool];
        mappedTargetToken = channelMappedTargetToken[pool];
    }

    /**
     * @notice Get channel create funds (with default)
     * @return Minimum USDT to create a pool
     */
    function getChannelCreateFunds() public view returns(uint256) {
        return channelSettings.createFunds;
    }

    /**
     * @notice Get channel buffer rate (with default)
     * @return Buffer rate in basis points
     */
    function getChannelBufferRate() public view returns(uint256) {
        return channelSettings.bufferRate;
    }

    /**
     * @notice Get channel buffer amount (with default)
     * @return Min buffer in USDT
     */
    function getChannelBufferAmount() public view returns(uint256) {
        return channelSettings.minBufferAmount;
    }

    /**
     * @notice Get pool withdrawal info
     * @param pool Pool address
     * @return currWithdrawalNumber Current withdrawal count
     * @return lastWithdrawalTime Last withdrawal timestamp
     */
    function getPoolWithdrawalInfo(address pool) external view returns(uint256 currWithdrawalNumber, uint256 lastWithdrawalTime) {
        currWithdrawalNumber = poolCurrWithdrawalNumber[pool];
        lastWithdrawalTime = poolLastWithdrawalTime[pool];
    }

    /**
     * @notice Get deterministic key for pool token mapping
     * @param pool Pool address
     * @param symbol Token symbol
     * @return keccak256 hash
     */
    function getChannelPoolTokenKey(address pool, string memory symbol) public pure returns(bytes32) {
        return keccak256(abi.encodePacked(pool, symbol));
    }

    /**
     * @notice Get pool's target token info
     * @param _pool Pool address
     * @return poolTargetToken Pool's channel token
     * @return mappedPoolTargetToken USDT address
     */
    function getChannelPoolTargetToken(address _pool) external view returns(address poolTargetToken, address mappedPoolTargetToken) {
        address token = channelPoolToken[_pool];
        if(token != address(0)) {
            poolTargetToken = token;
            mappedPoolTargetToken = vault().usdt();
        }
    }

    /**
     * @notice Get vault contract instance
     * @return IVault interface
     */
    function vault() public view returns(IVault) {
        return IVault(memeData.vault());
    }

    /**
     * @notice Get comprehensive channel pool state
     * @param user User address (for blacklist check)
     * @param indexToken Index token
     * @return pool Pool address
     * @return owner Pool owner
     * @return mappedToken Mapped channel token
     * @return freezeTime Close freeze time
     * @return isClose Whether pool is closed
     * @return isPause Whether pool is paused
     * @return isBlacklisted Whether user is blacklisted
     */
    function getChannelState(address user, address indexToken) external view returns(address pool, address owner, address mappedToken, uint256 freezeTime, bool isClose, bool isPause, bool isBlacklisted) {
        pool = channelMappedTokenPool[indexToken];
        owner = channelPoolOwner[pool];
        mappedToken = channelMappedIndexToken[pool][indexToken];
        freezeTime = channelPoolCloseInfo[pool].freezeTime;
        isClose = channelPoolIsClose[pool];
        isPause = channelPoolIsPause[pool];
        isBlacklisted = blacklist[pool][user];
    }
}
