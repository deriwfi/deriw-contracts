// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../upgradeability/Synchron.sol";
import "../core/interfaces/IVault.sol";
import "../core/interfaces/IDataReader.sol";
import "./interfaces/ICoinData.sol";

/// @title BuybackTransfer
/// @notice Water-level driven split of realised trader losses into three destinations: the buyback
///         pool, the insurance fund and the main pool.
///
/// @dev The level (`H`) is the main pool balance reported by the Vault, read live:
///      `vault.poolAmounts(targetToken, usdt)`. It is NOT a running total, so it drops the moment
///      funds leave the pool.
///
///      A token is split by a table of bands. Each band carries two thresholds and three shares:
///
///        band i:  closeThreshold[i]  <  openThreshold[i]
///                 buybackBps + insuranceBps + mainBps == 10000
///                 mainBps > 0, while buybackBps and insuranceBps may each be zero
///
///      The two thresholds form a hysteresis region, so the split does not flap around a single
///      number:
///
///        - rising:  H must EXCEED openThreshold[i] to enter band i
///        - falling: H must DROP BELOW closeThreshold[i] to leave band i
///        - between: the stored band is kept
///
///      Example table (the product sheet, and the shipped default):
///
///        band 1: open 2,000,000  close 1,500,000  ->  30% /  0% / 70%
///        band 2: open 5,000,000  close 4,500,000  ->  80% / 10% / 10%
///
///      Band 1 leaves the insurance fund untouched (its share is zero) and only diverts into the
///      buyback pool. At H = 1,800,000 while band 1 is active, band 1 keeps splitting; it only
///      stops once H falls below 1,500,000. Band 2 behaves the same between 4,500,000 and
///      5,000,000.
///
///      WRITING a table requires a main-pool token. `setTiers` / `clearTiers` / `syncTier` run the
///      argument through `_mainPoolTarget`, which checks `coinData.getCoinType(token) == 1` and
///      emits `NonMainPoolSkipped` for anything else. A channel token is registered with its own
///      coin type, so it is rejected here; the table always lives under the resolved main-pool
///      token, and can only be written by naming that token.
///
///      READING resolves the token without the coin-type check: `getH` / `getCurrentTier` /
///      `getDivertRates` / `splitLoss` call `dataReader.getTargetIndexToken` directly, so passing a
///      channel token reports the table of its main pool. Reads and writes therefore agree on the
///      table contents, but only writes are restricted to the main-pool token.
///
///      This contract only decides HOW a loss is split. Moving the funds is `VaultUtils.divertLoss`,
///      which calls `syncTier` once to persist the band and receive the split, then calls
///      `Vault.transferOutFor` for each slice.
contract BuybackTransfer is Synchron {

    /// @notice Basis-point denominator (10000 == 100%)
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    /// @notice Hard ceiling on the number of bands per token, bounding the walk in `_resolveTier`
    uint256 public constant MAX_TIERS = 20;

    /// @notice Lower bound for the first band's openThreshold, in USDT (6 decimals)
    /// @dev 1,000,000 USDT. Guards against configuring a first band that opens immediately, which
    ///      would divert a slice of every loss from the very first trade.
    uint256 public constant MIN_FIRST_OPEN_THRESHOLD = 1000000 * 10 ** 6;

    /// @notice Lower bound for the first band's closeThreshold, in USDT (6 decimals)
    /// @dev 500,000 USDT
    uint256 public constant MIN_FIRST_CLOSE_THRESHOLD = 500000 * 10 ** 6;

    /// @notice One split band
    /// @param openThreshold Level that must be strictly exceeded to enter this band
    /// @param closeThreshold Level that must be strictly undercut to leave this band
    /// @param buybackBps Share sent to the buyback pool, in basis points. May be zero and has no
    ///        ordering rule relative to other bands
    /// @param insuranceBps Share sent to the insurance fund, in basis points. May be zero and has
    ///        no ordering rule relative to other bands
    /// @param mainBps Share left in the main pool, in basis points. Must be non-zero together with
    ///        the other two adding up to 10000
    struct DivertTier {
        uint256 openThreshold;
        uint256 closeThreshold;
        uint256 buybackBps;
        uint256 insuranceBps;
        uint256 mainBps;
    }

    /// @notice Result of splitting one loss, receivers included so the caller needs a single call
    /// @param buybackReceiver Receiver of the buyback slice
    /// @param buybackAmount Amount for the buyback pool
    /// @param insuranceReceiver Receiver of the insurance slice
    /// @param insuranceAmount Amount for the insurance fund
    /// @param mainReceiver Receiver of the main slice
    /// @param mainAmount Amount left in the main pool
    struct LossSplit {
        address buybackReceiver;
        uint256 buybackAmount;
        address insuranceReceiver;
        uint256 insuranceAmount;
        address mainReceiver;
        uint256 mainAmount;
    }

    /// @notice True once `initialize` has run; the implementation contract starts initialized so it
    ///         can never be initialized through a direct call
    bool public initialized;

    /// @notice Governance
    address public gov;

    /// @notice DataReader used to resolve channel tokens to their main-pool token
    IDataReader public dataReader;

    /// @notice Vault providing the water level
    IVault public vault;

    /// @notice Receiver of the buyback slice
    address public buybackPool;

    /// @notice Receiver of the insurance slice
    address public insuranceFund;

    /// @notice Receiver of the main slice; set it to the Vault address to keep the slice in the pool
    address public mainPool;

    /// @notice Number of bands configured for a main-pool token (0 == not configured)
    mapping(address => uint256) public tierCount;

    /// @notice Bands of a main-pool token, 1-based
    mapping(address => mapping(uint256 => DivertTier)) public tiers;

    /// @notice Band the token is currently in (0 == no band active). The hysteresis comparison reads
    ///         this value, so it is what keeps a band alive inside its buffer region.
    mapping(address => uint256) public currentTier;

    /// @notice CoinData resolving the coin type of an index token. Appended after `currentTier` so
    ///         the storage layout of an already deployed proxy stays untouched.
    ICoinData public coinData;

    /// @notice Emitted when governance is transferred
    event GovSet(address indexed gov);

    /// @notice Emitted when CoinData, DataReader and Vault are set
    event ContractsSet(address coinData, address dataReader, address vault);

    /// @notice Emitted when the three receivers are set
    event PoolsSet(address buybackPool, address insuranceFund, address mainPool);

    /// @notice Emitted for every stored band
    event TierSet(address indexed token, uint256 indexed index, DivertTier tier);

    /// @notice Emitted whenever bands are removed, by `setTiers` (before the new table is written)
    ///         or by `clearTiers` (removal only). Never emitted for a token that had no bands.
    event TiersCleared(address indexed token, uint256 oldCount);

    /// @notice Emitted once a table is fully stored
    event TiersBatchSet(address indexed token, uint256 count);

    /// @notice Emitted when a band transition is persisted
    event CurrentTierUpdated(address indexed token, uint256 oldTier, uint256 newTier);

    /// @notice Emitted when a token is skipped because it is not a main pool
    event NonMainPoolSkipped(address sender, address indexToken, uint8 coinType);

    constructor() {
        initialized = true;
    }

    modifier onlyGov() {
        if(msg.sender != gov) revert("gov err");
        _;
    }

    /// @notice Initialize the contract, take governance and set the three receivers
    /// @dev Callable once; `setContracts` must be called separately before any read works
    /// @param _buybackPool Receiver of the buyback slice
    /// @param _insuranceFund Receiver of the insurance slice
    /// @param _mainPool Receiver of the main slice (pass the Vault address to keep it in the pool)
    function initialize(address _buybackPool, address _insuranceFund, address _mainPool) external {
        if(initialized) revert("has initialized");
        if(_buybackPool == address(0) || _insuranceFund == address(0) || _mainPool == address(0)) {
            revert("pool err");
        }

        initialized = true;
        gov = msg.sender;
        buybackPool = _buybackPool;
        insuranceFund = _insuranceFund;
        mainPool = _mainPool;

        emit PoolsSet(_buybackPool, _insuranceFund, _mainPool);
    }

    /// @notice Transfer governance
    /// @param _gov New governance address, cannot be zero
    function setGov(address _gov) external onlyGov {
        if(_gov == address(0)) revert("gov err");
        gov = _gov;
        emit GovSet(_gov);
    }

    /// @notice Set the CoinData, the DataReader and the Vault
    /// @param _coinData CoinData address, used to read the coin type of an index token
    /// @param _dataReader DataReader address, used to resolve channel tokens
    /// @param _vault Vault address, used for the water level
    function setContracts(address _coinData, address _dataReader, address _vault) external onlyGov {
        if(_coinData == address(0) || _dataReader == address(0) || _vault == address(0)) {
            revert("addr err");
        }

        coinData = ICoinData(_coinData);
        dataReader = IDataReader(_dataReader);
        vault = IVault(_vault);

        emit ContractsSet(_coinData, _dataReader, _vault);
    }

    /// @notice Set the three receivers in one call
    /// @dev No partial update: all three must be non-zero, so a half-configured split is impossible
    /// @param _buybackPool Receiver of the buyback slice
    /// @param _insuranceFund Receiver of the insurance slice
    /// @param _mainPool Receiver of the main slice
    function setPools(address _buybackPool, address _insuranceFund, address _mainPool) external onlyGov {
        if(_buybackPool == address(0) || _insuranceFund == address(0) || _mainPool == address(0)) {
            revert("pool err");
        }

        buybackPool = _buybackPool;
        insuranceFund = _insuranceFund;
        mainPool = _mainPool;

        emit PoolsSet(_buybackPool, _insuranceFund, _mainPool);
    }

    /// @notice Replace the whole band table of a token
    /// @dev Full replacement, not a merge: the previous bands are dropped first, so the array must
    ///      describe the complete table. Requirements:
    ///        - `_indexToken` non-zero and resolvable as a main pool
    ///        - 1 <= _tiers.length <= MAX_TIERS
    ///        - openThreshold strictly increases across the table
    ///        - closeThreshold strictly increases across the table
    ///        - closeThreshold < openThreshold inside a band
    ///        - closeThreshold >= the previous band's openThreshold, so buffer regions never overlap
    ///        - buybackBps and insuranceBps may be zero and have no ordering rule: a higher band is
    ///          free to point less into the buyback pool than a lower one
    ///        - mainBps must be non-zero, so a band always leaves something in the main pool
    ///        - the three shares sum to exactly 10000
    ///        - band 1 openThreshold >= MIN_FIRST_OPEN_THRESHOLD (1,000,000 USDT)
    ///        - band 1 closeThreshold >= MIN_FIRST_CLOSE_THRESHOLD (500,000 USDT)
    ///      A failing entry reverts the whole call, so a rejected reconfiguration leaves the previous
    ///      table untouched. A non-main pool also reverts: `NonMainPoolSkipped` is emitted by
    ///      `_mainPoolTarget` and then rolled back with the rest of the call, so a batch script has
    ///      to filter the index tokens itself instead of relying on the event.
    /// @param _indexToken Main-pool index token. A channel token carries its own coin type and is
    ///        rejected with `NonMainPoolSkipped`, so the main-pool token has to be named to write
    ///        the table it owns
    /// @param _tiers Complete band table, 1-based after storage
    function setTiers(address _indexToken, DivertTier[] calldata _tiers) external onlyGov {
        if(_indexToken == address(0)) revert("indexToken err");
        uint256 len = _tiers.length;
        if(len == 0) revert("length err");
        if(len > MAX_TIERS) revert("too many tiers");

        address token = _mainPoolTarget(_indexToken);
        if(token == address(0)) revert();

        _clearTiers(token);

        uint256 prevOpen = 0;
        uint256 prevClose = 0;

        for(uint256 i = 0; i < len; i++) {
            DivertTier memory tier = _tiers[i];

            if(tier.openThreshold == 0) revert("openThreshold err");
            if(tier.openThreshold <= prevOpen) revert("openThreshold order err");
            if(tier.closeThreshold == 0) revert("closeThreshold err");
            if(tier.closeThreshold <= prevClose) revert("closeThreshold order err");
            if(tier.closeThreshold >= tier.openThreshold) revert("closeThreshold err");
            if(tier.closeThreshold < prevOpen) revert("closeThreshold overlap err");
            // The buyback and insurance shares may be zero and carry no ordering rule: a higher band
            // is allowed to point less into the buyback pool than a lower one. The main share may
            // not be zero, so a band can never divert the whole loss out of the main pool.
            if(tier.mainBps == 0) revert("mainBps err");
            if(tier.buybackBps + tier.insuranceBps + tier.mainBps != BASIS_POINTS_DIVISOR) revert("bps sum err");

            if(i == 0) {
                if(tier.openThreshold < MIN_FIRST_OPEN_THRESHOLD) revert("openThreshold min err");
                if(tier.closeThreshold < MIN_FIRST_CLOSE_THRESHOLD) revert("closeThreshold min err");
            }

            uint256 idx = i + 1;
            tiers[token][idx] = tier;

            prevOpen = tier.openThreshold;
            prevClose = tier.closeThreshold;

            emit TierSet(token, idx, tier);
        }

        tierCount[token] = len;

        emit TiersBatchSet(token, len);
    }

    /// @notice Remove every band of a token, disabling the split for it only
    /// @dev Also resets the stored band, so a later reconfiguration starts from "no band active".
    ///      Idempotent: a token without bands is a no-op and emits nothing.
    /// @param _indexToken Main-pool index token. A channel token carries its own coin type and is
    ///        rejected with `NonMainPoolSkipped`, so the main-pool token has to be named to write
    ///        the table it owns
    function clearTiers(address _indexToken) external onlyGov {
        address token = _mainPoolTarget(_indexToken);
        if(token == address(0)) revert();

        _clearTiers(token);
    }

    /// @notice Persist the band implied by the current level and split this loss in one call
    /// @dev The hysteresis comparison needs the previously stored band, so this write is what makes
    ///      the buffer regions work. Callers that only read (`getCurrentTier`) do not persist.
    ///      Restricted to VaultUtils (the loss diversion path, which calls this on every losing
    ///      close) and governance. A public entry point would let anyone pin the stored band inside
    ///      a buffer region: push H above an open threshold, sync, pull the liquidity back, and the
    ///      higher band stays active until H drops below its close threshold. Governance keeps
    ///      access because it is already the highest privilege here and recovery needs it.
    ///      Doing the split here as well removes one external call plus one `getTargetIndexToken`
    ///      and one `poolAmounts` round trip from every losing close.
    ///      A non-main pool returns an all-zero split and emits `NonMainPoolSkipped`, so the caller
    ///      moves nothing.
    /// @param _indexToken Main-pool index token. A channel token carries its own coin type and is
    ///        rejected with `NonMainPoolSkipped`, so the main-pool token has to be named to write
    ///        the table it owns
    /// @param _amount Loss amount to split
    /// @return lossSplit Per-slice receivers and amounts for this loss
    function syncTier(address _indexToken, uint256 _amount)
        external
        returns (LossSplit memory lossSplit)
    {
        if(msg.sender != vault.vaultUtils() && msg.sender != gov) revert("auth err");
        if(_indexToken == address(0)) revert("indexToken err");

        address token = _mainPoolTarget(_indexToken);
        if(token == address(0)) return lossSplit;

        uint256 oldTier = currentTier[token];
        uint256 newTier = _resolveTier(token, getH(token), oldTier);

        if(newTier != oldTier) {
            currentTier[token] = newTier;
            emit CurrentTierUpdated(token, oldTier, newTier);
        }

        // No band in force: nothing is diverted, so return an all-zero split. That differs from
        // `splitLoss`, which reports the whole amount as "kept in the main pool"; here an empty
        // struct is what tells the caller there is nothing to transfer.
        if(newTier == 0) return lossSplit;

        return _buildSplit(token, newTier, _amount);
    }

    /// @notice Water level of a token: the main pool balance held by the Vault
    /// @dev Read live, never accumulated, so a loss that leaves the pool lowers it immediately.
    /// @param _indexToken Index token, a channel token is resolved to its main-pool token
    /// @return Main pool balance of the token in USDT
    function getH(address _indexToken) public view returns (uint256) {
        address token = dataReader.getTargetIndexToken(_indexToken);
        return vault.poolAmounts(token, vault.usdt());
    }

    /// @notice Number of bands configured for a token
    /// @param _indexToken Index token, a channel token is resolved to its main-pool token
    function getTierCount(address _indexToken) external view returns (uint256) {
        return tierCount[_resolve(_indexToken)];
    }

    /// @notice One band by 1-based index; returns a zeroed band for index 0 or out of range
    /// @param _indexToken Index token, a channel token is resolved to its main-pool token
    /// @param _index 1-based band index
    function getTier(address _indexToken, uint256 _index) external view returns (DivertTier memory) {
        return tiers[_resolve(_indexToken)][_index];
    }

    /// @notice The complete band table, from band 1 to `tierCount`
    /// @param _indexToken Index token, a channel token is resolved to its main-pool token
    function getTiers(address _indexToken) external view returns (DivertTier[] memory list) {
        address token = _resolve(_indexToken);
        uint256 len = tierCount[token];

        list = new DivertTier[](len);
        for(uint256 i = 0; i < len; i++) {
            list[i] = tiers[token][i + 1];
        }
    }

    /// @notice Band the token would be in at the current level
    /// @dev Reads the stored band to apply the hysteresis, but does not persist the result. Use
    ///      `syncTier` when the storage must match.
    /// @param _indexToken Index token, a channel token is resolved to its main-pool token
    function getCurrentTier(address _indexToken) external view returns (uint256) {
        address token = _resolve(_indexToken);
        if(tierCount[token] == 0) return 0;

        return _resolveTier(token, getH(token), currentTier[token]);
    }

    /// @notice Shares of the active band
    /// @dev All zeros when no band is configured or no band is active, which means "no diversion".
    ///      Only meaningful for a main-pool token: a channel token is resolved to its main pool
    ///      here, so the figures describe that pool, while the write path (syncTier) rejects a
    ///      channel token outright and no diversion actually happens for it.
    /// @param _indexToken Index token, a channel token is resolved to its main-pool token
    /// @return tier Active band (0 == none)
    /// @return buybackBps Share for the buyback pool, in basis points
    /// @return insuranceBps Share for the insurance fund, in basis points
    /// @return mainBps Share for the main pool, in basis points
    function getDivertRates(address _indexToken)
        external
        view
        returns (uint256 tier, uint256 buybackBps, uint256 insuranceBps, uint256 mainBps)
    {
        address token = _resolve(_indexToken);
        if(tierCount[token] == 0) return (0, 0, 0, 0);

        tier = _resolveTier(token, getH(token), currentTier[token]);
        if(tier == 0) return (0, 0, 0, 0);

        DivertTier memory t = tiers[token][tier];
        buybackBps = t.buybackBps;
        insuranceBps = t.insuranceBps;
        mainBps = t.mainBps;
    }

    /// @notice Split one loss by the active band, receivers included
    /// @dev The buyback and insurance shares are floored, and the main share takes whatever is left,
    ///      so the three always add up to `_amount` exactly. A dust amount can therefore end up
    ///      entirely in the main pool.
    ///      When no band is configured or no band is active, the whole amount goes to the main
    ///      receiver: the caller can rely on `mainAmount == _amount` and skip every transfer.
    ///      The receivers are returned whether or not the corresponding amount is zero; a receiver
    ///      equal to the Vault means "keep this slice in the pool".
    ///      Only meaningful for a main-pool token: a channel token is resolved to its main pool
    ///      here, so the figures describe that pool, while the write path (syncTier) rejects a
    ///      channel token outright and no diversion actually happens for it.
    /// @param _indexToken Index token, a channel token is resolved to its main-pool token
    /// @param _amount Loss amount
    /// @return lossSplit Per-slice receivers and amounts
    function splitLoss(address _indexToken, uint256 _amount) external view returns (LossSplit memory) {
        address token = _resolve(_indexToken);
        if(tierCount[token] == 0) return _buildSplit(token, 0, _amount);

        return _buildSplit(token, _resolveTier(token, getH(token), currentTier[token]), _amount);
    }

    /// @dev Fill a LossSplit for an already resolved token and band
    /// @dev Shared by `splitLoss` (view) and `syncTier` (which already resolved both), so the band
    ///      decision is not repeated. With no active band the whole amount stays in the main pool.
    /// @param _token Main-pool token (already resolved)
    /// @param _tier Band in force (0 == none)
    /// @param _amount Loss amount
    /// @return lossSplit Per-slice receivers and amounts
    function _buildSplit(address _token, uint256 _tier, uint256 _amount)
        internal
        view
        returns (LossSplit memory lossSplit)
    {
        lossSplit.buybackReceiver = buybackPool;
        lossSplit.insuranceReceiver = insuranceFund;
        lossSplit.mainReceiver = mainPool;

        if(_tier == 0 || _amount == 0) {
            lossSplit.mainAmount = _amount;
            return lossSplit;
        }

        DivertTier memory t = tiers[_token][_tier];
        lossSplit.buybackAmount = _amount * t.buybackBps / BASIS_POINTS_DIVISOR;
        lossSplit.insuranceAmount = _amount * t.insuranceBps / BASIS_POINTS_DIVISOR;
        lossSplit.mainAmount = _amount - lossSplit.buybackAmount - lossSplit.insuranceAmount;
    }

    /// @dev Band decision with hysteresis.
    ///      - the stored band can only be left by falling strictly below its closeThreshold
    ///      - when it is left, the band walks down ONE step at a time and stops at the highest
    ///        band whose closeThreshold is still satisfied. A level that falls through several
    ///        bands therefore lands on the highest band that is still in force, instead of being
    ///        reset to 0 and skipping the buffer regions of the bands in between.
    ///      - after that, the highest band whose openThreshold is strictly exceeded wins
    ///      Entering and leaving therefore use different thresholds, which is what prevents a level
    ///      hovering on a boundary from flipping the split every block.
    /// @param _token Main-pool token (already resolved)
    /// @param _h Water level
    /// @param _current Currently stored band
    /// @return Band after the decision (0 == none active)
    function _resolveTier(address _token, uint256 _h, uint256 _current) internal view returns (uint256) {
        uint256 len = tierCount[_token];
        if(len == 0) return 0;

        uint256 tier = _current;

        if(tier > len) tier = len;

        // Step down instead of jumping straight to 0. With bands 1..n this walks at most n times,
        // and the strict increase of closeThreshold guarantees it stops at the first band whose
        // buffer still covers _h.
        while(tier > 0 && _h < tiers[_token][tier].closeThreshold) {
            tier--;
        }

        for(uint256 i = len; i > tier; i--) {
            if(_h > tiers[_token][i].openThreshold) {
                return i;
            }
        }

        return tier;
    }

    /// @dev Delete every band of a token and reset its stored band
    /// @param _token Main-pool token (already resolved)
    function _clearTiers(address _token) internal {
        delete currentTier[_token];

        uint256 oldCount = tierCount[_token];
        if(oldCount == 0) return;

        for(uint256 i = 1; i <= oldCount; i++) {
            delete tiers[_token][i];
        }
        delete tierCount[_token];

        emit TiersCleared(_token, oldCount);
    }

    /// @dev Resolve a channel token to its main-pool token for reads
    /// @param _indexToken Index token
    function _resolve(address _indexToken) internal view returns (address) {
        return dataReader.getTargetIndexToken(_indexToken);
    }

    /// @dev Resolve a token and reject anything that is not a main pool.
    ///      The coin type comes from CoinData: `IDataReader` declares `getCoinType` but `DataReader`
    ///      does not implement it, so reading it there reverts with an unknown selector.
    /// @param _indexToken Index token
    /// @return Main-pool token, or address(0) when the token is not a main pool
    function _mainPoolTarget(address _indexToken) internal returns (address) {
        uint8 coinType = coinData.getCoinType(_indexToken);
        if(coinType != 1) {
            emit NonMainPoolSkipped(msg.sender, _indexToken, coinType);
            return address(0);
        }
        return dataReader.getTargetIndexToken(_indexToken);
    }
}
