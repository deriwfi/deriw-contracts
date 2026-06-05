// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./interfaces/IVault.sol";
import "../Pendant/interfaces/ICoinData.sol";
import "../meme/interfaces/IMemeData.sol";
import "../Pendant/interfaces/ISlippage.sol";
import "../Pendant/interfaces/IPhase.sol"; 
import "../referrals/interfaces/IReferralStorage.sol";
import "../meme/interfaces/IMemeFactory.sol";
import "../core/interfaces/IERC20Metadata.sol";
import "../upgradeability/Synchron.sol";
import "../core/interfaces/IADL.sol";

/**
 * @title DataReader
 * @notice Central data aggregation contract for reading token, pool, and position information
 * @dev Acts as a unified read layer that resolves channel-mapped tokens before delegating
 *      to the underlying vault, coinData, memeFactory, and other protocol contracts.
 *      Inherits Synchron for upgradeable proxy pattern support.
 *
 * Key Concepts:
 * - getIndexToken(): Resolves a token to its base index token (same if not channel-mapped)
 * - getTargetIndexToken(): Resolves to the target pool token for value calculations
 * - Channel fallback: Most coinData functions first check if the token belongs to a §1channel
 *   pool; if yes, delegate to the mapped underlying token; if no, call coinData directly
 * - Only Phase contract can call validatePool() and getValue() for security
 *
 * Security:
 * - onlyGov modifier protects admin functions (setContract, setGov)
 * - validatePool/getValue restricted to Phase contract via msg.sender check
 * - Zero address validation on all contract setup parameters
 */
contract DataReader is Synchron {
    // ============ Storage Variables ============

    /// @notice Whether the contract has been initialized
    /// @dev Prevents re-initialization attacks on upgradeable pattern
    bool public initialized;

    /// @notice Address of the governance account
    /// @dev Only gov can call admin functions. Set during initialize()
    address public gov;

    /// @notice The vault contract for pool amount and position data
    IVault public vault;

    /// @notice The coinData contract for token configuration and pool info
    ICoinData public coinData;

    /// @notice The MemeFactory contract for channel pool lookups
    IMemeFactory public memeFactory;

    /// @notice The MemeData contract for meme token state queries
    IMemeData public memeData;

    /// @notice The Slippage contract for price and GLP calculations
    ISlippage public slippage;

    /// @notice The Phase contract for rate and value calculations
    IPhase public phase;

    /// @notice The referral storage for referral-based pool ownership lookup
    IReferralStorage public referralStorage;

    constructor() {
        initialized = true;
    }

    // ============ Modifiers ============

    /// @notice Restricts function access to governance only
    modifier onlyGov() {
        require(gov == msg.sender, "no permission");
        _;
    }

    // ============ Initialization ============

    /**
     * @notice Initialize the contract with caller as governance
     * @dev Called once during deployment via proxy pattern.
     *      Sets msg.sender as initial governance address.
     *      Contract addresses must be set separately via setContract().
     */
    function initialize() external {
        require(!initialized, "has initialized");
        initialized = true;
        gov = msg.sender;
    }

    /**
     * @notice Set all dependent contract addresses
     * @dev Only callable by governance. All addresses must be non-zero.
     *      Must be called before any read functions can operate.
     *
     * @param _coinData Address of the coinData contract
     * @param _vault Address of the vault contract
     * @param _memeFactory Address of the MemeFactory contract
     * @param _memeData Address of the MemeData contract
     * @param _slippage Address of the Slippage contract
     * @param _phase Address of the Phase contract
     * @param _referralStorage Address of the ReferralStorage contract
     */
    function setContract(
        address _coinData,
        address _vault,
        address _memeFactory,
        address _memeData,
        address _slippage,
        address _phase,
        address _referralStorage
    ) external onlyGov {
        if (
            _coinData == address(0) ||
            _vault == address(0) ||
            _memeFactory == address(0) ||
            _memeData == address(0) ||
            _slippage == address(0) ||
            _phase == address(0) ||
            _referralStorage == address(0)
        ) revert("addr err");

        coinData = ICoinData(_coinData);
        vault = IVault(_vault);
        memeFactory = IMemeFactory(_memeFactory);
        memeData = IMemeData(_memeData);
        slippage = ISlippage(_slippage);
        phase = IPhase(_phase);
        referralStorage = IReferralStorage(_referralStorage);
    }

    /**
     * @notice Transfer governance to a new account
     * @dev Only callable by current governance
     * @param account New governance address (must be non-zero)
     */
    function setGov(address account) external onlyGov {
        require(account != address(0), "_gov err");
        gov = account;
    }

    // ============ Token Resolution Functions ============

    /**
     * @notice Resolve an index token to its target token for value calculations
     * @dev Returns USDT if input is USDT, otherwise resolves through channel pool mapping.
     *      Used by vault for pool amount calculations.
     * @param _indexToken Token address to resolve
     * @return token Resolved target token address
     */
    function getTargetIndexToken(address _indexToken) public view returns(address) {   
        address _usdt = vault.usdt();
        if(_indexToken == _usdt) {
            return _usdt;
        }
        address token = getTokenToPoolTargetToken(_indexToken);
        require(token != address(0), "_indexToken err");
        return token;
    }

    /**
     * @notice Resolve a token to its base index token
     * @dev If token is channel-mapped, returns the underlying index token.
     *      Otherwise returns the input token unchanged.
     * @param _indexToken Token address to resolve
     * @return Resolved index token address
     */
    function getIndexToken(address _indexToken) public view returns(address) {
        (address pool, address indexToken,,) = memeFactory.getChannelMappedTokenPoolInfo(_indexToken);
        if(pool == address(0)) {
            return _indexToken;
        }
        return indexToken;
    }

    // ============ Vault Data Functions ============

    /**
     * @notice Get pool amounts for a token pair
     * @dev Resolves input token via getTargetIndexToken before querying vault
     * @param _indexToken Index token address
     * @param _collateralToken Collateral token address
     * @return _poolAmounts Current pool amount from vault
     */
    function poolAmounts(address _indexToken, address _collateralToken) external view returns(uint256 _poolAmounts) {
        (_poolAmounts,,,) = vault.getTokenData(getTargetIndexToken(_indexToken), _collateralToken);
    }

    /**
     * @notice Get reserved amounts for a token pair
     * @param _indexToken Index token address
     * @param _collateralToken Collateral token address
     * @return _reservedAmounts Current reserved amount
     */
    function reservedAmounts(address _indexToken, address _collateralToken) external view returns(uint256 _reservedAmounts) {
        (,_reservedAmounts,,) = vault.getTokenData(getTargetIndexToken(_indexToken), _collateralToken);
    }

    /**
     * @notice Get guaranteed USD value for a token pair
     * @param _indexToken Index token address
     * @param _collateralToken Collateral token address
     * @return _guaranteedUsd Current guaranteed USD value
     */
    function guaranteedUsd(address _indexToken, address _collateralToken) external view returns(uint256 _guaranteedUsd) {
        (,,_guaranteedUsd,) = vault.getTokenData(getTargetIndexToken(_indexToken), _collateralToken);
    }

    /**
     * @notice Get token balances for a token pair
     * @param _indexToken Index token address
     * @param _collateralToken Collateral token address
     * @return _tokenBalances Current token balances
     */
    function tokenBalances(address _indexToken, address _collateralToken) external view returns(uint256 _tokenBalances) {
        (,,,_tokenBalances) = vault.getTokenData(getTargetIndexToken(_indexToken), _collateralToken);
    }

    /**
     * @notice Get global short/long sizes for a token
     * @param _indexToken Token address
     * @return globalShortSizes Total short positions size
     * @return globalLongSizes Total long positions size
     */
    function getGlobalSize(address _indexToken) public view returns(uint256 globalShortSizes, uint256 globalLongSizes) {
        globalShortSizes = vault.globalShortSizes(_indexToken);
        globalLongSizes = vault.globalLongSizes(_indexToken);
    }

    // ============ Token Info Functions ============

    /**
     * @notice Get comprehensive token information
     * @dev If the token is channel-mapped and differs from its index token,
     *      resolves through coinData for the underlying index token.
     * @param _token Token address to query
     * @return tokenToPoolTargetToken The pool target token address
     * @return memberTokenTargetID Member token target ID
     * @return lastTime Last update timestamp
     * @return belongTo Token category (0=none, 1=single, 2=member)
     */
    function getTokenInfo(
        address _token
    ) public view returns(address tokenToPoolTargetToken, uint256 memberTokenTargetID, uint256 lastTime, uint8 belongTo) {
        (address pool, address indexToken, ,) = memeFactory.getChannelMappedTokenPoolInfo(_token);
        if(pool == address(0)) {
            return coinData.getTokenInfo(_token);   
        }
        (, memberTokenTargetID, lastTime, belongTo) = coinData.getTokenInfo(indexToken);
        tokenToPoolTargetToken = memeFactory.channelPoolToken(pool);
    }

    /**
     * @notice Get position size data for an index token
     * @dev Supports both single-type (type 1) and member-type (type 2) tokens.
     *      For member tokens, iterates all member tokens and aggregates sizes.
     * @param _indexToken Index token address
     * @return globalShortSizes Aggregated global short sizes
     * @return globalLongSizes Aggregated global long sizes
     * @return totalSize Total position size (short + long)
     */
    function getSizeData(address _indexToken) public view returns(
        uint256 globalShortSizes,
        uint256 globalLongSizes,
        uint256 totalSize
    ) {
        (address pool, address indexToken,, address mappedTargetToken) = memeFactory.getChannelMappedTokenPoolInfo(_indexToken);
        if(pool == address(0)) {
            return coinData.getSizeData(_indexToken);
        }

        (, uint256 _memberTokenTargetID, , uint8 _belongTo) = getTokenInfo(indexToken);
        if(_belongTo == 1) {
            (globalShortSizes, globalLongSizes) = getGlobalSize(_indexToken);
            totalSize = globalLongSizes + globalShortSizes;
        }
        
        if(_belongTo == 2) {
            uint256 _len = coinData.getCurrMemberTokensLength(mappedTargetToken, _memberTokenTargetID);
            for(uint256 i = 0; i < _len; i++) {
                address token = coinData.getCurrMemberToken(mappedTargetToken, _memberTokenTargetID, i);
                address channelToken = memeFactory.indexTokenChannelMapped(token, pool);
                if(channelToken != address(0)) {
                    globalShortSizes += vault.globalShortSizes(channelToken);
                    globalLongSizes += vault.globalLongSizes(channelToken);
                }
            }
            totalSize = globalShortSizes + globalLongSizes;
        }
    } 

    /**
     * @notice Get pool value for an index token
     * @dev Returns coinData value if not channel-mapped.
     *      For channel pools, calculates value as (poolAmount * price / decimals).
     * @param indexToken Index token address
     * @return poolValue Calculated pool value in USD
     * @return isMeme Whether the token is a meme/channel token
     * @return isFundraise Whether the token is in fundraising state
     */
    function getPoolValue(address indexToken) public view returns(uint256, bool, bool) {
        (address pool,, address targetToken,) = memeFactory.getChannelMappedTokenPoolInfo(indexToken);
        if(pool == address(0)) {
            return coinData.getPoolValue(indexToken);
        }
        address usdt = vault.usdt();
        uint256 amount = getUsePoolAmounts(targetToken, vault.usdt());
        uint256 price = phase.getTokenPrice(usdt);
        uint256 deciCounter = 10 ** IERC20Metadata(usdt).decimals();

        return (amount * price / deciCounter, true, false);
    }

    /**
     * @notice Get current rate for a token
     * @dev Resolves via getIndexToken first, then queries coinData
     * @param token Token address
     * @return rate Current rate from coinData
     */
    function getCurrRate(address token) public view returns(uint256 rate) {        
        (address pool, address indexToken,,) = memeFactory.getChannelMappedTokenPoolInfo(token);
        if(pool == address(0)) {
            (rate, ) = coinData.getCurrRate(token);
        } else {
            (rate, ) = coinData.getCurrRate(indexToken);
        }
    }

    // ============ Pool Target Token Functions ============

    /**
     * @notice Get the pool target token for a token
     * @dev Returns coinData's mapping if no channel pool, otherwise returns the channel target token.
     *      The "target token" is the base token (e.g., USDT) that the channel pool wraps.
     * @param _token Token address to look up
     * @return The pool target token address
     */
    function getTokenToPoolTargetToken(address _token) public view returns(address) {
        (address pool,, address targetToken,) = memeFactory.getChannelMappedTokenPoolInfo(_token);
        return pool == address(0) ? coinData.getTokenToPoolTargetToken(_token) : targetToken;
    }

    /**
     * @notice Get the current set number for a pool target token
     * @param _poolTargetToken Pool target token address
     * @return The current set number from coinData
     */
    function getPoolTargetTokenInfoSetNum(address _poolTargetToken) public view returns(uint256) {
        (address pool,,, address mappedTargetToken) = memeFactory.getChannelMappedTokenPoolInfo(_poolTargetToken);
        return pool == address(0) ? coinData.getPoolTargetTokenInfoSetNum(_poolTargetToken) : coinData.getPoolTargetTokenInfoSetNum(mappedTargetToken);
    }

    // ============ Member Token Functions ============

    /**
     * @notice Get the number of member token target IDs
     * @param _poolTargetToken Pool target token address
     * @return Number of member token target IDs
     */
    function getCurrMemberTokenTargetIDLength(address _poolTargetToken) external view returns(uint256) {
        (address pool,,, address mappedTargetToken) = memeFactory.getChannelMappedTokenPoolInfo(_poolTargetToken);
        return pool == address(0) ? coinData.getCurrMemberTokenTargetIDLength(_poolTargetToken) : coinData.getCurrMemberTokenTargetIDLength(mappedTargetToken);
    }

    /**
     * @notice Get a member token target ID and its rate
     * @param _poolTargetToken Pool target token address
     * @param _index Index of the member token target ID
     * @return memberTokenTargetID The member token target ID
     * @return rate The rate for this member token target
     */
    function getCurrMemberTokenTargetID(address _poolTargetToken, uint256 _index) external view returns(uint256, uint256) {
        (address pool,,, address mappedTargetToken) = memeFactory.getChannelMappedTokenPoolInfo(_poolTargetToken);
        return pool == address(0) ? coinData.getCurrMemberTokenTargetID(_poolTargetToken, _index) : coinData.getCurrMemberTokenTargetID(mappedTargetToken, _index);
    }

    /**
     * @notice Check if a member token target ID exists
     * @param _poolTargetToken Pool target token address
     * @param _memberTokenTargetID Member token target ID to check
     * @return True if the member token target ID exists
     */
    function getCurrMemberTokenTargetIDIsIn(address _poolTargetToken, uint256 _memberTokenTargetID) external view returns(bool) {
        (address pool,,, address mappedTargetToken) = memeFactory.getChannelMappedTokenPoolInfo(_poolTargetToken);
        return pool == address(0) ? coinData.getCurrMemberTokenTargetIDIsIn(_poolTargetToken, _memberTokenTargetID) : coinData.getCurrMemberTokenTargetIDIsIn(mappedTargetToken, _memberTokenTargetID);
    }

    /**
     * @notice Get the number of member tokens for a target ID
     * @param _poolTargetToken Pool target token address
     * @param _memberTokenTargetID Member token target ID
     * @return Number of member tokens
     */
    function getCurrMemberTokensLength(address _poolTargetToken, uint256 _memberTokenTargetID) external view returns(uint256) {
        (address pool,,, address mappedTargetToken) = memeFactory.getChannelMappedTokenPoolInfo(_poolTargetToken);
        return pool == address(0) ? coinData.getCurrMemberTokensLength(_poolTargetToken, _memberTokenTargetID) : coinData.getCurrMemberTokensLength(mappedTargetToken, _memberTokenTargetID);
    }

    /**
     * @notice Get a specific member token address
     * @param _poolTargetToken Pool target token address
     * @param _memberTokenTargetID Member token target ID
     * @param _index Index of the member token
     * @return Member token address
     */
    function getCurrMemberToken(address _poolTargetToken, uint256 _memberTokenTargetID, uint256 _index) external view returns(address) {
        (address pool,,, address mappedTargetToken) = memeFactory.getChannelMappedTokenPoolInfo(_poolTargetToken);
        if(pool == address(0)) {
            return coinData.getCurrMemberToken(_poolTargetToken, _memberTokenTargetID, _index);
        }

        address indexToken = coinData.getCurrMemberToken(mappedTargetToken, _memberTokenTargetID, _index);
        return memeFactory.indexTokenChannelMapped(indexToken, pool);
    }

    /**
     * @notice Check if a token exists in member tokens
     * @dev First resolves the token's channel pool, then checks membership.
     *      If channel-mapped, checks against the underlying index token.
     * @param _token Token address to check
     * @param _poolTargetToken Pool target token address
     * @param _memberTokenTargetID Member token target ID
     * @return True if the token exists in member tokens
     */
    function getCurrMemberTokenIsIn(address _token, address _poolTargetToken, uint256 _memberTokenTargetID) external view returns(bool) {
        (address pool, address indexToken, address targetToken, address mappedTargetToken) = memeFactory.getChannelMappedTokenPoolInfo(_token);
        if(pool == address(0)) {
            return coinData.getCurrMemberTokenIsIn(_token, _poolTargetToken, _memberTokenTargetID);
        }
        
        if(_poolTargetToken == targetToken) {
            return coinData.getCurrMemberTokenIsIn(indexToken, mappedTargetToken, _memberTokenTargetID);
        }

        return false;
    }

    // ============ Single Token Functions ============

    /**
     * @notice Get the number of single tokens
     * @param _poolTargetToken Pool target token address
     * @return Number of single tokens
     */
    function getCurrSingleTokensLength(address _poolTargetToken) external view returns(uint256) {
        (address pool,,, address mappedTargetToken) = memeFactory.getChannelMappedTokenPoolInfo(_poolTargetToken);
        return pool == address(0) ? coinData.getCurrSingleTokensLength(_poolTargetToken) : coinData.getCurrSingleTokensLength(mappedTargetToken);
    }

    /**
     * @notice Get a single token and its rate
     * @dev If channel-mapped, resolves the single token through channel mapping.
     *      Sets rate to 0 if the channel token mapping doesn't exist.
     * @param _poolTargetToken Pool target token address
     * @param _index Index of the single token
     * @return singleToken The single token address (channel-mapped if applicable)
     * @return rate The token rate (0 if channel mapping missing)
     */
    function getCurrSingleToken(address _poolTargetToken, uint256 _index) external view returns(address, uint256) {
        (address pool,,, address mappedTargetToken) = memeFactory.getChannelMappedTokenPoolInfo(_poolTargetToken);
        if(pool == address(0)) {
            return coinData.getCurrSingleToken(_poolTargetToken, _index);
        }
        (address singleToken, uint256 tokenRate) = coinData.getCurrSingleToken(mappedTargetToken, _index);
        address indexTokenChannelMapped = memeFactory.indexTokenChannelMapped(singleToken, pool);
        return (indexTokenChannelMapped, tokenRate);
    }

    /**
     * @notice Check if a token exists in single tokens
     * @param _token Token address to check
     * @param _poolTargetToken Pool target token address
     * @return True if the token exists in single tokens
     */
    function getCurrSingleTokenIsIn(address _token, address _poolTargetToken) external view returns(bool) {
        (address pool, address indexToken, address targetToken, address mappedTargetToken) = memeFactory.getChannelMappedTokenPoolInfo(_token);
        return pool == address(0) ? coinData.getCurrSingleTokenIsIn(_token, _poolTargetToken) : (_poolTargetToken == targetToken ? coinData.getCurrSingleTokenIsIn(indexToken, mappedTargetToken) : false);
    }

    // ============ Remove Token Functions ============

    /**
     * @notice Get the number of removed tokens
     * @param _poolTargetToken Pool target token address
     * @return Number of removed tokens
     */
    function getCurrRemoveTokensLength(address _poolTargetToken) external view returns(uint256) {
        (address pool,,, address mappedTargetToken) = memeFactory.getChannelMappedTokenPoolInfo(_poolTargetToken);
        return pool == address(0) ? coinData.getCurrRemoveTokensLength(_poolTargetToken) : coinData.getCurrRemoveTokensLength(mappedTargetToken);
    }

    /**
     * @notice Get a removed token address
     * @dev If channel-mapped, resolves the token through channel index mapping.
     * @param _poolTargetToken Pool target token address
     * @param _index Index of the removed token
     * @return Removed token address
     */
    function getCurrRemoveToken(address _poolTargetToken, uint256 _index) external view returns(address) {
        (address pool, , , address mappedTargetToken) = memeFactory.getChannelMappedTokenPoolInfo(_poolTargetToken);
        if(pool == address(0)) {
            return coinData.getCurrRemoveToken(_poolTargetToken, _index);
        }
        address token = coinData.getCurrRemoveToken(mappedTargetToken, _index);
        return memeFactory.indexTokenChannelMapped(token, pool);
    }

    /**
     * @notice Check if a token exists in removed tokens
     * @param _poolTargetToken Pool target token address
     * @param _token Token address to check
     * @return True if the token exists in removed tokens
     */
    function getCurrRemoveTokenIsIn(address _poolTargetToken, address _token) public view returns(bool) {
        (address pool, address indexToken, address targetToken, address mappedTargetToken) = memeFactory.getChannelMappedTokenPoolInfo(_token);
        return pool == address(0) ? coinData.getCurrRemoveTokenIsIn(_poolTargetToken, _token) : (_poolTargetToken == targetToken ? coinData.getCurrRemoveTokenIsIn(mappedTargetToken, indexToken) : false);
    }

    /**
     * @notice Check if a token can be removed
     * @dev Resolves through getIndexToken before querying coinData
     * @param token Token address to check
     * @return True if the token can be removed
     */
    function getTokenIsCanRemove(address token) external view returns(bool) {
        token = getIndexToken(token);
        return coinData.getTokenIsCanRemove(token);
    }

    // ============ Pool Validation ============

    /**
     * @notice Validate a pool state for trading
     * @dev Only callable by Phase contract. Validates that:
     *      - Non-channel tokens: Check if meme token is closed
     *      - Channel tokens: Check pause, close, blacklist, freeze time, and referral ownership
     * @param user Address of the user attempting to trade
     * @param indexToken Index token address
     * @return indexToken The validated token (unchanged, for return compatibility)
     */
    function validatePool(address user, address indexToken) external view returns(address) {
        if(msg.sender != address(phase)) revert("not phase");
        (address pool, address owner,, uint256 freezeTime, bool isClose, bool isPause, bool isBlacklisted) = memeFactory.getChannelState(user, indexToken);
        if(pool == address(0)) {
            if(memeData.isAddMeme(indexToken) && memeData.isPoolTokenClose(indexToken)) revert("meme err");
        } else {
            if(isClose || isPause || isBlacklisted || (freezeTime != 0 && freezeTime <= block.timestamp) || referralStorage.referral(user) != owner) revert("pool state err");
        }
        return indexToken;
    }

    // ============ Value Calculation ============

    /**
     * @notice Calculate pool total value and side-specific value
     * @dev Only callable by Phase contract. Calculates position values using:
     *      - Pool value from getPoolValue()
     *      - Factor rates from channelPoolFactorInfo (if channel) or Phase rates
     *      - Current token rate from getCurrRate()
     *      Formula: value = poolValue * factorRate * tokenRate / 1e8
     *
     * @param _indexToken Index token address
     * @param _isLong Whether calculating for long or short side
     * @return poolTotalValue Total pool value for this token
     * @return sidePoolValue Pool value for the specific side (long/short)
     */
    function getValue(address _indexToken, bool _isLong) external view returns(uint256 poolTotalValue, uint256 sidePoolValue) {
        if(msg.sender != address(phase)) revert("not phase");

        (uint256 poolValue,,) = getPoolValue(_indexToken);
        address pool = memeFactory.channelMappedTokenPool(_indexToken);
        uint256 totalRate;
        uint256 sideRate;
        if(pool == address(0)) {
            totalRate = phase.totalRate();
            sideRate = phase.sideRate();
        } else {
            (uint256 shortFactor, uint256 longFactor, uint256 totalFactor) = memeFactory.channelPoolFactorInfo(pool);
            totalRate = totalFactor;
            sideRate = _isLong ? longFactor : shortFactor;
        }

        uint256 _tokenCurrRate = getCurrRate(_indexToken);
        poolTotalValue = poolValue * totalRate * _tokenCurrRate / 1e8;
        sidePoolValue = poolValue * sideRate * _tokenCurrRate / 1e8;
    }

    // ============ Vault Wrapper Functions ============

    /**
     * @notice Check if a token is whitelisted in the vault
     * @dev Resolves via getIndexToken before querying vault
     * @param token Token address to check
     * @return True if whitelisted
     */
    function whitelistedTokens(address token) external view returns(bool) {
        token = getIndexToken(token);
        return vault.whitelistedTokens(token);
    }

    /**
     * @notice Get the usable pool amount for a given index/collateral token pair
     * @dev For channel pools in principal mode (mode == 1), caps the pool amount at the
     *      aggregated channelPoolDepositAmount (total USDT deposited across all users),
     *      preventing usage of unrealized PnL beyond principal. Non-channel pools and
     *      non-principal mode always return the full Vault pool amount.
     * @param _indexToken The index token address
     * @param _collateralToken The collateral token address
     * @return uint256 The usable pool amount (capped for principal mode)
     */
    function getUsePoolAmounts(address _indexToken, address _collateralToken) public view returns(uint256) {
        address pool = memeFactory.channelMappedTokenPool(_indexToken);
        uint256 currAmounts = getPoolAmount(_indexToken, _collateralToken);
        if(pool != address(0)){
            uint256 mode = memeFactory.channelPoolMode(pool);
            if(mode == 1) {
                uint256 id = memeFactory.channelPoolSetID(pool);
                uint256 depositAmount = memeData.channelPoolDepositAmount(pool, id);
                return depositAmount > currAmounts ? currAmounts : depositAmount;
            }
        }
        return currAmounts;
    }

    /**
     * @notice Calculate channel withdrawal amount with per-withdraw rate and window capping
     * @dev Only callable by MemeData. Applies risk buffer deduction, perWithdrawRate cap,
     *      and withdrawal number/window time checks. Returns zero amounts if within
     *      a restricted window or exceeding free withdrawal count.
     * @param indexToken The index token address
     * @param tokenOut The output token address
     * @param amount The requested withdrawal amount
     * @return outAmount The actual withdrawable amount after caps
     * @return burnGlpAmount The amount of GLP to burn
     * @return riskBuffer The risk buffer deducted
     */
    function getChannelOutAmount(address indexToken, address tokenOut, uint256 amount) external view returns(uint256 outAmount, uint256 burnGlpAmount, uint256 riskBuffer) {
        if(msg.sender != address(memeData)) revert("not memeData");
        (address pool,, address targetToken,) = memeFactory.getChannelMappedTokenPoolInfo(indexToken);
        uint256 totalGlpSupply = slippage.glpTokenSupply(targetToken, tokenOut);
        uint256 totalOutAmount = IPhase(vault.phase()).getOutAmount(targetToken, tokenOut, totalGlpSupply);

        riskBuffer = _getRiskBuffer(totalOutAmount);
        if(totalOutAmount <= riskBuffer) return (outAmount, burnGlpAmount, riskBuffer);

        return _computeChannelOut(pool, targetToken, tokenOut, amount, totalOutAmount, totalGlpSupply, riskBuffer);
    }

    /**
     * @notice Compute channel withdrawal amounts with rate capping and time window logic
     * @dev Algorithm:
     *      1. Deduct riskBuffer from totalOutAmount → netWithdrawable
     *      2. maxOut = netWithdrawable * perWithdrawRate / 10000 (single-claim cap)
     *      3. Free mode: currNum < withdrawalNumber OR past cooldown (lastTime + windowTime)
     *         → outAmount = min(amount, maxOut)
     *      4. Restricted mode: neither free → outAmount = 0, burnGlpAmount = 0
     *      5. burnGlpAmount = outAmount * totalGlpSupply / poolAmounts(targetToken, tokenOut)
     *         (GLP burned proportional to withdrawn share of pool)
     * @param pool Channel pool address
     * @param targetToken Resolved target token for pool amount lookups
     * @param tokenOut Output token (USDT)
     * @param amount Requested withdrawal amount
     * @param totalOutAmount Total withdrawable pool value
     * @param totalGlpSupply GLP total supply for the target token pair
     * @param rb Risk buffer amount (pre-computed by _getRiskBuffer)
     * @return outAmount Actual withdrawable after capping (0 if restricted)
     * @return burnGlpAmount GLP tokens to burn proportionally
     * @return riskBuffer Applied risk buffer (same as input rb)
     */
    function _computeChannelOut(
        address pool, address targetToken, address tokenOut, uint256 amount,
        uint256 totalOutAmount, uint256 totalGlpSupply, uint256 rb
    ) internal view returns(uint256 outAmount, uint256 burnGlpAmount, uint256 riskBuffer) {
        riskBuffer = rb;
        uint256 currNum = memeFactory.poolCurrWithdrawalNumber(pool);
        uint256 lastTime = memeFactory.poolLastWithdrawalTime(pool);
        (uint256 perWithdrawRate, uint256 withdrawalNumber, uint256 windowTime) = memeFactory.channelPoolConfig();
        uint256 maxOut = (totalOutAmount - riskBuffer) * perWithdrawRate / 10000;
        if(currNum < withdrawalNumber || block.timestamp >= lastTime + windowTime) {
            outAmount = amount > maxOut ? maxOut : amount;
            burnGlpAmount = outAmount * totalGlpSupply / getPoolAmount(targetToken, tokenOut);
        }
    }

    function getPoolAmount(address _indexToken, address _tokenOut) public view returns(uint256) {
        return this.poolAmounts(_indexToken, _tokenOut);
    }

    /**
     * @notice Calculate risk buffer amount (internal)
     * @param amount Base amount
     * @return Buffer amount (rate% or min, whichever larger)
     */
    function _getRiskBuffer(uint256 amount) internal view returns(uint256) {
        uint256 bufferRate = memeFactory.getChannelBufferRate();
        uint256 minBufferAmount = memeFactory.getChannelBufferAmount();
        uint256 bufferAmount = amount * bufferRate / 10000;

        return bufferAmount > minBufferAmount ? bufferAmount : minBufferAmount;
    }
}
