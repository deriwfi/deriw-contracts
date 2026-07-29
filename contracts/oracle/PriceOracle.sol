// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../core/interfaces/IDataReader.sol";
import "../upgradeability/Synchron.sol";

/**
 * @title   PriceOracle
 * @notice  Oracle contract for managing index token prices with multi-ID versioning
 * @dev     Inherits Synchron for upgradeable proxy pattern. Prices are stored per indexToken
 *          with auto-incrementing priceId. Channel tokens are resolved to underlying index tokens
 *          via DataReader before storage. Each price record includes ask/bid/mid and an update timestamp.
 *          Freshness is validated through two time windows:
 *          - maxTimeDeviation: backend-generated timestamp must be within ±N seconds of block.timestamp
 *          - maxPriceTime: latest price must not be older than N seconds when queried
 */
contract PriceOracle is Synchron {

    // ============ Config Variables ============

    /// @notice Maximum allowed deviation (seconds) between backend _timestamp and block.timestamp
    /// @dev Used in batchSetPrices to reject stale backend data. Default: 30s
    uint256 public maxTimeDeviation;

    /// @notice Maximum age (seconds) of the latest price before it's considered expired (inclusive)
    /// @dev Used in getPrice to reject stale oracle data when age >= maxPriceTime. Default: 30s
    uint256 public maxPriceTime;

    // ============ State Variables ============

    /// @notice Whether the contract has been initialized
    /// @dev Prevents re-initialization attacks on upgradeable proxy pattern.
    ///      Set to true in constructor (implementation) and initialize() (proxy storage)
    bool public initialized;

    /// @notice Address of the governance account
    /// @dev Only gov can call admin functions. Set during initialize()
    address public gov;

    /// @notice DataReader contract for channel token → index token resolution
    /// @dev Must be set via setContract() after proxy deployment
    IDataReader public dataReader;

    // ============ Mappings ============

    /// @notice Tracks which addresses are authorized to call batchSetPrices
    /// @dev Managed by gov via setUpdater()
    mapping(address => bool) public isUpdater;

    /// @notice Current price ID for each index token (auto-incremented on each update)
    /// @dev ID 0 means "never set"; first update assigns ID 1
    mapping(address => uint256) priceId;

    /// @notice Price records: indexToken → priceId → PriceInfo
    mapping(address => mapping(uint256 => PriceInfo)) price;

    /// @notice Last update timestamp: indexToken → priceId → unix timestamp
    /// @dev Stores block.timestamp at the moment of on-chain recording
    mapping(address => mapping(uint256 => uint256)) lastUpdateTime;

    // ============ Structs ============

    /**
     * @notice Price information for a single index token record
     * @dev   Mid price must equal (ask + bid) / 2 (integer division, truncated toward zero).
     *        For odd sums, the caller must set priceMid to the truncated result.
     * @param indexToken  Index token address (resolved from channel token if applicable)
     * @param priceAsk    Ask price (max price, used for long entry / short exit)
     * @param priceBid    Bid price (min price, used for short entry / long exit, must be > 0)
     * @param priceMid    Mid price = (ask + bid) / 2, used as oracle reference
     */
    struct PriceInfo {
        address indexToken;  // Resolved index token address
        uint256 priceAsk;    // Ask price
        uint256 priceBid;    // Bid price
        uint256 priceMid;    // Mid price
    }

    // ============ Events ============

    /// @notice Emitted when an updater is added or removed
    /// @param account  Address of the updater
    /// @param isActive Whether the account is now an active updater
    event SetUpdater(address account, bool isActive);

    /// @notice Emitted when a price is successfully set for an index token
    /// @param indexToken Resolved index token address
    /// @param priceId    Assigned price ID (auto-incremented)
    /// @param priceAsk   Ask price
    /// @param priceBid   Bid price
    /// @param priceMid   Mid price
    /// @param timestamp  Block timestamp of recording
    event SetPrice(address indexToken, uint256 priceId, uint256 priceAsk, uint256 priceBid, uint256 priceMid, uint256 timestamp);

    /// @notice Emitted when maxTimeDeviation is updated
    /// @param oldValue Previous maxTimeDeviation in seconds
    /// @param newValue Updated maxTimeDeviation in seconds
    event SetMaxTimeDeviation(uint256 oldValue, uint256 newValue);

    /// @notice Emitted when maxPriceTime is updated
    /// @param oldValue Previous maxPriceTime in seconds
    /// @param newValue Updated maxPriceTime in seconds
    event SetMaxPriceTime(uint256 oldValue, uint256 newValue);

    /// @notice Emitted when a price in batchSetPrices fails validation and is skipped
    /// @param indexToken Resolved index token address
    /// @param priceAsk   Invalid ask price
    /// @param priceBid   Invalid bid price
    /// @param priceMid   Invalid mid price
    /// @param timestamp  Block timestamp when the error occurred
    event PriceErr(address indexToken, uint256 priceAsk, uint256 priceBid, uint256 priceMid, uint256 timestamp);

    // ============ Constructor ============

    /**
     * @notice Lock the implementation contract against direct initialization
     * @dev    Sets initialized = true on the implementation's own storage.
     *         When the proxy delegatecalls initialize(), the proxy's storage is used
     *         (where initialized is still false), allowing one-time init via proxy.
     *         Direct calls to initialize() on the implementation contract will revert.
     */
    constructor() {
        initialized = true;
    }

    // ============ Modifiers ============

    /// @notice Restricts function access to governance only
    /// @dev    Reverts silently if caller is not gov
    modifier onlyGov() {
        if(gov != msg.sender) revert("not gov");
        _;
    }

    // ============ Initialization ============

    /**
     * @notice Initialize the contract with caller as governance
     * @dev    Called once during deployment via proxy pattern.
     *         Sets msg.sender as initial governance address and default time parameters.
     *         Contract addresses must be set separately via setContract().
     *         Reverts if already initialized.
     */
    function initialize() external {
        if(initialized) revert();
        initialized = true;
        gov = msg.sender;
        maxTimeDeviation = 30;
        maxPriceTime = 30;
    }

    // ============ Admin Functions ============

    /**
     * @notice Transfer governance to a new account
     * @dev    Only callable by current governance. Reverts if account is address(0).
     * @param account New governance address (must be non-zero)
     */
    function setGov(address account) external onlyGov {
        if(account == address(0)) revert();
        gov = account;
    }

    /**
     * @notice Add or remove an address as price updater
     * @dev    Only callable by governance. Reverts if account is address(0).
     * @param account  Address to update
     * @param isActive true to authorize, false to revoke
     */
    function setUpdater(address account, bool isActive) external onlyGov {
        if(account == address(0)) revert();
        isUpdater[account] = isActive;
        emit SetUpdater(account, isActive);
    }

    /**
     * @notice Set the maximum allowed deviation between backend timestamp and block.timestamp
     * @dev    Only callable by governance. Used in batchSetPrices timestamp validation.
     * @param _maxTimeDeviation Maximum deviation in seconds
     */
    function setMaxTimeDeviation(uint256 _maxTimeDeviation) external onlyGov {
        if(_maxTimeDeviation > 3600) revert("max 3600s");
        uint256 oldValue = maxTimeDeviation;
        maxTimeDeviation = _maxTimeDeviation;
        emit SetMaxTimeDeviation(oldValue, _maxTimeDeviation);
    }

    /**
     * @notice Set the maximum age of the latest price before it's considered expired
     * @dev    Only callable by governance. Used in getPrice to reject stale oracle data.
     * @param _maxPriceTime Maximum price age in seconds
     */
    function setMaxPriceTime(uint256 _maxPriceTime) external onlyGov {
        if(_maxPriceTime > 3600) revert("max 3600s");
        uint256 oldValue = maxPriceTime;
        maxPriceTime = _maxPriceTime;
        emit SetMaxPriceTime(oldValue, _maxPriceTime);
    }

    /**
     * @notice Set the DataReader contract address for channel token resolution
     * @dev    Only callable by governance. Reverts if _dataReader is address(0).
     *         Must be called after proxy deployment and before price operations.
     * @param _dataReader DataReader contract address
     */
    function setContract(address _dataReader) external onlyGov {
        if(_dataReader == address(0)) revert();
        dataReader = IDataReader(_dataReader);
    }

    // ============ Price Writing ============

    /**
     * @notice Batch set prices for multiple index tokens
     * @dev    Only callable by isUpdater. Validates:
     *         - Backend _timestamp is within ±maxTimeDeviation of block.timestamp
     *         - priceBid > 0, priceAsk >= priceBid, priceMid == (priceAsk + priceBid) / 2 (truncated)
     *         Invalid entries emit PriceErr and are skipped without reverting the batch.
     *         Auto-increments priceId per token, records block.timestamp as lastUpdateTime.
     * @param _prices    Array of PriceInfo structs; indexToken auto-resolved for channel tokens via DataReader
     * @param _timestamp Backend-generated timestamp to validate freshness
     */
    function batchSetPrices(PriceInfo[] calldata _prices, uint256 _timestamp) external {
        uint256 len = _prices.length;
        if(len == 0) revert("empty array");
        if(!isUpdater[msg.sender]) revert("not updater");

        // Validate backend timestamp is within acceptable deviation
        {
            uint256 dev = block.timestamp > _timestamp ? block.timestamp - _timestamp : _timestamp - block.timestamp;
            if(dev > maxTimeDeviation) revert("time deviation too large");
        }

        for(uint256 i = 0; i < len; i++) {
            // Resolve channel token → underlying index token via DataReader
            address indexToken = dataReader.getIndexToken(_prices[i].indexToken);
            uint256 _priceAsk = _prices[i].priceAsk;
            uint256 _priceBid = _prices[i].priceBid;
            uint256 _priceMid = _prices[i].priceMid;

            // Validate prices: bid>0, ask>=bid, mid==(ask+bid)/2 (integer division truncated)
            if(_priceBid == 0 || _priceAsk < _priceBid || _priceMid != (_priceAsk + _priceBid) / 2) {
                emit PriceErr(indexToken, _priceAsk, _priceBid, _priceMid, block.timestamp);
                continue;
            }

            // Auto-increment priceId (first record gets ID 1, 0 means "never set")
            uint256 newId = ++priceId[indexToken];
            price[indexToken][newId] = PriceInfo({
                indexToken: indexToken,
                priceAsk:   _priceAsk,
                priceBid:   _priceBid,
                priceMid:   _priceMid
            });

            // Record on-chain confirmation time (not backend _timestamp)
            lastUpdateTime[indexToken][newId] = block.timestamp;
            emit SetPrice(indexToken, newId, _priceAsk, _priceBid, _priceMid, block.timestamp);
        }
    }

    // ============ Price Reading ============

    /**
     * @notice Get the latest priceId for an index token
     * @dev    Returns 0 if no price has ever been set for this token.
     *         Channel tokens are auto-resolved via DataReader.
     * @param _indexToken The index token (or channel token) address to query
     * @return Current priceId (0 if never set)
     */
    function getPriceId(address _indexToken) external view returns(uint256) {
        _indexToken = dataReader.getIndexToken(_indexToken);
        return priceId[_indexToken];
    }

    /**
     * @notice Get historical price data by indexToken and priceId
     * @dev    Channel tokens are auto-resolved. Returns default (zero) values for unset IDs.
     * @param _indexToken The index token (or channel token) address to query
     * @param _id         Price ID to query
     * @return indexToken Resolved index token address
     * @return priceAsk   Ask price (0 if ID not set)
     * @return priceBid   Bid price (0 if ID not set)
     * @return priceMid   Mid price (0 if ID not set)
     */
    function getPriceInfo(address _indexToken, uint256 _id) external view returns(address indexToken, uint256 priceAsk, uint256 priceBid, uint256 priceMid) {
        _indexToken = dataReader.getIndexToken(_indexToken);
        return _getPriceInfo(_indexToken, _id);
    }

    /**
     * @dev Internal helper to read PriceInfo from storage
     * @param _indexToken Resolved index token address
     * @param _id         Price ID
     * @return indexToken Resolved index token address
     * @return priceAsk   Ask price
     * @return priceBid   Bid price
     * @return priceMid   Mid price
     */
    function _getPriceInfo(address _indexToken, uint256 _id) internal view returns(address indexToken, uint256 priceAsk, uint256 priceBid, uint256 priceMid) {
        PriceInfo memory p = price[_indexToken][_id];
        return (p.indexToken, p.priceAsk, p.priceBid, p.priceMid);
    }

    /**
     * @notice Get the block timestamp when a specific price record was written
     * @dev    Channel tokens are auto-resolved. Returns 0 for unset IDs.
     * @param _indexToken The index token (or channel token) address to query
     * @param _id         Price ID to query
     * @return Unix timestamp (seconds) of the last update, or 0 if never set
     */
    function getLastUpdateTime(address _indexToken, uint256 _id) external view returns(uint256) {
        _indexToken = dataReader.getIndexToken(_indexToken);
        return lastUpdateTime[_indexToken][_id];
    }

    /**
     * @notice Get the latest (current priceId) price for an index token
     * @dev    Channel tokens are auto-resolved. Reverts if:
     *         - "not set": no price has ever been set (priceId == 0)
     *         - "price expired": latest price age >= maxPriceTime
     * @param _indexToken The index token (or channel token) address to query
     * @return indexToken Resolved index token address
     * @return priceAsk   Latest ask price
     * @return priceBid   Latest bid price
     * @return priceMid   Latest mid price
     */
    function getPrice(address _indexToken) public view returns(address indexToken, uint256 priceAsk, uint256 priceBid, uint256 priceMid) {
        _indexToken = dataReader.getIndexToken(_indexToken);
        uint256 _id = priceId[_indexToken];
        if(_id == 0) revert("not set");
        if(block.timestamp - lastUpdateTime[_indexToken][_id] >= maxPriceTime) revert("price expired");
        return _getPriceInfo(_indexToken, _id);
    }

    /**
     * @notice Get the latest ask (max) price for an index token
     * @dev    Convenience wrapper around getPrice(). Inherits all freshness checks.
     * @param _indexToken The index token (or channel token) address to query
     * @return Latest ask price
     */
    function getMaxPrice(address _indexToken) external view returns (uint256) {
        (, uint256 priceAsk, , ) = getPrice(_indexToken);
        return priceAsk;
    }

    /**
     * @notice Get the latest bid (min) price for an index token
     * @dev    Convenience wrapper around getPrice(). Inherits all freshness checks.
     * @param _indexToken The index token (or channel token) address to query
     * @return Latest bid price
     */
    function getMinPrice(address _indexToken) external view returns (uint256) {
        (, , uint256 priceBid, ) = getPrice(_indexToken);
        return priceBid;
    }
}