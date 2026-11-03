// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../upgradeability/Synchron.sol";
import "../core/interfaces/IVault.sol";
import "../core/interfaces/IDataReader.sol";
import "../core/interfaces/IEventStruct.sol";
import "./interfaces/ISlippage.sol";

/// @title LiquidateBuffer
/// @notice Per-leverage liquidation buffer. Replaces the old "one global liquidation leverage for
///         every position" rule with a table keyed by the position's own opening leverage.
/// @dev Motivation: with a single global threshold (`remainingCollateral * maxLeverage < size`),
///      the implied buffer as a fraction of the trader's own collateral is `openLeverage / maxLeverage`,
///      so a 10x position gets a far wider relative buffer than a 500x one and is liquidated much
///      later than it should be. Here every leverage band gets its own `bufferBps` (the share of the
///      ORIGINAL collateral that must remain), and the final trigger is the stricter of:
///
///          remainingCollateral < max(size / liquidationLeverage, collateral * bufferBps)
///
///      The legacy `size / liquidationLeverage` term is still enforced by VaultUtils before this
///      contract is consulted, so a band can only make liquidation earlier, never later.
///
///      Bands are stored 1-based and must be strictly increasing. A leverage L falls into band i when
///      `cap[i-1] < L <= cap[i]`, with `cap[0]` implicitly 0. Leverage above the last cap keeps using
///      the last band, so a reconfiguration that stops short of the real maximum degrades gracefully
///      instead of reverting inside the liquidation path.
///
///      Channel tokens are resolved to their main-pool index token on every entry point, so a single
///      configuration covers a token and all of its channel pools.
contract LiquidateBuffer is Synchron {

    /// @notice Basis points denominator: 10000 == 1x for a leverage, 10000 == 100% for a buffer
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    /// @notice Hard ceiling for `bufferBps`. 50% means "liquidate once half of the collateral is
    ///         gone"; anything closer to 100% would make a freshly opened position immediately
    ///         liquidatable, because the opening fee alone already reduces the remaining collateral.
    uint256 public constant MAX_BUFFER_BPS = 5000;

    /// @notice Hard ceiling for the number of bands per token. `isForcedLiquidation` walks the band
    ///         list on every liquidation check, so this cap bounds the gas of that walk.
    uint256 public constant MAX_CONFIGS = 20;

    /// @notice One leverage band
    /// @param positionLeverage Upper bound of the band, in basis points (10000 == 1x). A position
    ///        with leverage L matches this band when `previousCap < L <= positionLeverage`.
    /// @param bufferBps Share of the ORIGINAL collateral that must remain, in basis points
    ///        (2500 == 25%). Liquidation fires once `remainingCollateral` drops below
    ///        `collateral * bufferBps / 10000`.
    struct BufferConfig {
        uint256 positionLeverage;
        uint256 bufferBps;
    }

    /// @notice Whether `initialize` has been called. The implementation contract sets it in the
    ///         constructor so the implementation itself can never be initialized.
    bool public initialized;

    /// @notice Governance address, the only one allowed to reconfigure the contract
    address public gov;

    /// @notice DataReader used to resolve a channel token to its main-pool index token
    address public dataReader;

    /// @notice Vault, read for the position snapshot and for MIN_LEVERAGE
    address public vault;

    /// @notice Slippage, read for the token's liquidation leverage
    address public slippage;

    /// @notice VaultUtils, the only caller allowed to use `isForcedLiquidation`
    address public vaultUtils;

    /// @dev Number of bands configured for a token (0 = not configured, the check is a no-op)
    mapping(address => uint256) tokenBufferCount;

    /// @dev token => band index (1-based) => band
    mapping(address => mapping(uint256 => BufferConfig)) tokenBufferConfigs;

    /// @notice Emitted when governance is transferred
    event GovSet(address indexed gov);

    /// @notice Emitted when the four dependency addresses are set in one go
    /// @dev Not indexed: four indexed addresses would exceed the three-topic limit, and filtering by
    ///      this event is rare compared to the buffer events below
    event ContractsSet(address dataReader, address vault, address slippage, address vaultUtils);

    /// @notice Emitted for every stored band
    /// @param token Main-pool index token the band belongs to
    /// @param index 1-based band index
    /// @param positionLeverage Upper bound of the band, in basis points
    /// @param bufferBps Required remaining-collateral share, in basis points
    event BufferConfigSet(address indexed token, uint256 indexed index, uint256 positionLeverage, uint256 bufferBps);

    /// @notice Emitted before a reconfiguration wipes the previous bands
    /// @param token Main-pool index token
    /// @param oldCount Number of bands that were removed
    event BufferConfigCleared(address indexed token, uint256 oldCount);

    /// @notice Emitted once a reconfiguration is fully stored
    /// @param token Main-pool index token
    /// @param count Number of bands now active
    event BufferConfigBatchSet(address indexed token, uint256 count);

    /// @dev Blocks `initialize` on the implementation contract itself. Proxy storage starts at zero,
    ///      so the proxy still passes the `initialized` check below.
    constructor() {
        initialized = true;
    }

    /// @dev Only governance may reconfigure this contract: it sits on the liquidation path
    modifier onlyGov() {
        if(msg.sender != gov) revert("gov err");
        _;
    }

    /// @notice Initialize the proxy and take governance
    /// @dev Callable once. Dependencies are NOT set here on purpose: they are configured with
    ///      `setContracts`, so a deployment script can batch `initialize` + `setContracts` and the
    ///      window in which the contract has no governance is as small as possible.
    function initialize() external {
        if(initialized) revert("has initialized");

        initialized = true;
        gov = msg.sender;
    }

    /// @notice Transfer governance
    /// @param _gov New governance address, must not be zero
    function setGov(address _gov) external onlyGov {
        if(_gov == address(0)) revert("gov err");
        gov = _gov;
        emit GovSet(_gov);
    }

    /// @notice Set every dependency in one call
    /// @dev Overwrites all four addresses: callers must pass the current values for the ones they do
    ///      not intend to change. All four must be non-zero, because every read path depends on them:
    ///      `dataReader` resolves the token, `vault` provides the position and MIN_LEVERAGE,
    ///      `slippage` provides the liquidation leverage, and `vaultUtils` is the only address
    ///      allowed to call `isForcedLiquidation`.
    /// @param _dataReader DataReader address
    /// @param _vault Vault address
    /// @param _slippage Slippage address
    /// @param _vaultUtils VaultUtils address (the PROXY address, not the implementation)
    function setContracts(
        address _dataReader,
        address _vault,
        address _slippage,
        address _vaultUtils
    ) external onlyGov {
        if(_dataReader == address(0) || _vault == address(0) || _slippage == address(0) || _vaultUtils == address(0)) {
            revert("addr err");
        }

        dataReader = _dataReader;
        vault = _vault;
        slippage = _slippage;
        vaultUtils = _vaultUtils;

        emit ContractsSet(_dataReader, _vault, _slippage, _vaultUtils);
    }

    /// @notice Replace the whole leverage band table of a token
    /// @dev Full replacement, not a merge: the previous bands are deleted first, so the new array
    ///      must describe the complete table. Requirements, checked in order:
    ///        - `_indexToken` non-zero and resolvable by DataReader
    ///        - 1 <= _configs.length <= MAX_CONFIGS
    ///        - band 1 leverage >= Vault.MIN_LEVERAGE
    ///        - each band leverage > the previous one (strictly increasing, no duplicates)
    ///        - last band leverage <= the token's liquidation leverage, so the legacy
    ///          `size / liquidationLeverage` term is never the only thing covering the top range
    ///        - 0 <= bufferBps <= MAX_BUFFER_BPS
    ///      A failing entry reverts the whole call, so a rejected reconfiguration leaves the previous
    ///      table untouched.
    /// @param _indexToken Index token (a channel token is resolved to its main-pool token)
    /// @param _configs Complete band table, ordered by ascending leverage
    function setBufferConfig(address _indexToken, BufferConfig[] memory _configs) external onlyGov {
        if(_indexToken == address(0)) revert("indexToken err");
        if(_configs.length == 0) revert("length err");
        if(_configs.length > MAX_CONFIGS) revert("too many configs");

        address token = IDataReader(dataReader).getIndexToken(_indexToken);

        // Wipe the previous table so a shorter array can never leave stale bands behind
        uint256 oldCount = tokenBufferCount[token];
        for(uint256 i = 1; i <= oldCount; i++) {
            delete tokenBufferConfigs[token][i];
        }
        if(oldCount > 0) {
            emit BufferConfigCleared(token, oldCount);
        }

        uint256 len = _configs.length;
        uint256 minLeverage = IVault(vault).MIN_LEVERAGE();
        // Second return value: the leverage that triggers liquidation. It is configurable per token
        // and may sit above the open leverage, so it is the correct ceiling for the last band.
        (, uint256 maxLeverage) = ISlippage(slippage).getTokenLeverage(token);

        uint256 prevLeverage = 0;
        for(uint256 i = 0; i < len; i++) {
            uint256 positionLeverage = _configs[i].positionLeverage;
            uint256 bufferBps = _configs[i].bufferBps;

            if(positionLeverage == 0) revert("leverage err");
            if(positionLeverage <= prevLeverage) revert("leverage order err");
            if(bufferBps > MAX_BUFFER_BPS) revert("bufferBps err");

            if(i == 0 && positionLeverage < minLeverage) revert("minLeverage err");
            if(i == len - 1 && positionLeverage > maxLeverage) revert("maxLeverage err");

            uint256 idx = i + 1;
            tokenBufferConfigs[token][idx] = BufferConfig(positionLeverage, bufferBps);
            prevLeverage = positionLeverage;

            emit BufferConfigSet(token, idx, positionLeverage, bufferBps);
        }

        tokenBufferCount[token] = len;

        emit BufferConfigBatchSet(token, len);
    }

    /// @notice Number of bands configured for a token
    /// @dev Resolves channel tokens, so a channel pool reports the main pool's count
    /// @param _indexToken Index token
    /// @return Number of bands (0 = not configured)
    function getBufferCount(address _indexToken) external view returns(uint256) {
        return tokenBufferCount[IDataReader(dataReader).getIndexToken(_indexToken)];
    }

    /// @notice Single band of a token
    /// @dev Resolves channel tokens. `_index` is 1-based and must be <= getBufferCount, otherwise a
    ///      zeroed struct is returned.
    /// @param _indexToken Index token
    /// @param _index 1-based band index
    /// @return The band (leverage ceiling + required buffer)
    function getBufferConfig(address _indexToken, uint256 _index) external view returns(BufferConfig memory) {
        return tokenBufferConfigs[IDataReader(dataReader).getIndexToken(_indexToken)][_index];
    }

    /// @notice Whole band table of a token
    /// @dev Resolves channel tokens. The returned array is 0-based while the stored keys are
    ///      1-based, so `list[0]` is band 1.
    /// @param _indexToken Index token
    /// @return list Bands ordered by ascending leverage
    function getBufferConfigs(address _indexToken) external view returns(BufferConfig[] memory list) {
        address token = IDataReader(dataReader).getIndexToken(_indexToken);
        uint256 len = tokenBufferCount[token];

        list = new BufferConfig[](len);
        for(uint256 i = 0; i < len; i++) {
            list[i] = tokenBufferConfigs[token][i + 1];
        }
    }

    /// @notice Everything a UI needs to display the liquidation state of one position
    /// @dev Reads the position itself (size / collateral), so callers do not have to supply them.
    ///      Only the collateral ratio is used: no current price and no remaining collateral are
    ///      involved, which is why this function answers "where would this position be liquidated"
    ///      rather than "is it liquidatable right now" (that is `isForcedLiquidation`, fed by the
    ///      Vault with the price-dependent remaining collateral).
    ///
    ///      Values are zero when the position does not exist (size and collateral both 0) or when the
    ///      token has no bands; use `threshold == 0` to detect that case, since `index` may still
    ///      report band 1 for a zero-leverage input.
    /// @param _account Position owner
    /// @param _collateralToken Collateral token
    /// @param _indexToken Index token
    /// @param _isLong true for a long position
    /// @return leverage Opening leverage of the position, in basis points (10000 == 1x)
    /// @return liquidationLeverage Liquidation leverage configured for the token, in basis points
    /// @return index Matched band, 1-based (0 = token not configured)
    /// @return prevLeverage Lower bound of the matched band (0 for the first band)
    /// @return curLeverage Upper bound of the matched band
    /// @return bufferBps Required remaining-collateral share of the matched band, in basis points
    /// @return threshold Liquidation threshold in USD (30 decimals):
    ///         max(size / liquidationLeverage, collateral * bufferBps)
    /// @return marginRatioWad Maintenance margin RATIO, i.e. the threshold as a share of the
    ///         notional: `threshold / size`, 1e18 fixed point (0.01e18 == 1%). This is NOT the
    ///         leverage at which the position dies; that would be `size / threshold`.
    function getLiquidationInfo(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    )
        external
        view
        returns (
            uint256 leverage,
            uint256 liquidationLeverage,
            uint256 index,
            uint256 prevLeverage,
            uint256 curLeverage,
            uint256 bufferBps,
            uint256 threshold,
            uint256 marginRatioWad
        )
    {
        uint256 size;
        uint256 collateral;
        (size, collateral) = _positionSize(_account, _collateralToken, _indexToken, _isLong);

        address token = IDataReader(dataReader).getIndexToken(_indexToken);

        (, liquidationLeverage) = ISlippage(slippage).getTokenLeverage(token);

        if(collateral > 0) {
            leverage = size * BASIS_POINTS_DIVISOR / collateral;
        }

        (index, prevLeverage, curLeverage, bufferBps) = _matchBuffer(token, leverage);

        // Legacy term: the whole position would be wiped out at this level
        if(liquidationLeverage > 0) {
            threshold = size * BASIS_POINTS_DIVISOR / liquidationLeverage;
        }
        // Band term: tighten it when this band demands more remaining collateral
        if(collateral * bufferBps / BASIS_POINTS_DIVISOR > threshold) {
            threshold = collateral * bufferBps / BASIS_POINTS_DIVISOR;
        }

        // Maintenance margin RATIO: the threshold as a share of the notional, not its inverse.
        // Guard on `size` (the divisor): a zero threshold simply yields a zero ratio.
        if(size > 0) {
            marginRatioWad = threshold * 1e18 / size;
        }
    }

    /// @notice Read the size and the ORIGINAL collateral of a position
    /// @dev Split out of `getLiquidationInfo` purely to keep that function within the stack limit
    ///      (4 parameters + 8 return values already consume 12 of the 16 available slots).
    ///      Returns zeros for a non-existent position.
    /// @param _account Position owner
    /// @param _collateralToken Collateral token
    /// @param _indexToken Index token
    /// @param _isLong true for a long position
    /// @return size Position size in USD (30 decimals)
    /// @return collateral Position collateral in USD (30 decimals), before any loss is applied
    function _positionSize(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) internal view returns (uint256 size, uint256 collateral) {
        IEventStruct.Position memory pos = IVault(vault).getPositionFrom(
            IVault(vault).getPositionKey(_account, _collateralToken, _indexToken, _isLong)
        );

        size = pos.size;
        collateral = pos.collateral;
    }

    /// @notice Find the band that covers a given leverage
    /// @dev Bands are strictly increasing, so a single pass is enough. `prevLeverage` tracks the
    ///      ceiling of the band BEFORE the matched one and is only advanced while another band
    ///      remains, otherwise a leverage above the last ceiling would end up with
    ///      `prevLeverage == curLeverage`.
    ///
    ///      Leverage above the last ceiling matches the last band (bufferBps of the last entry): the
    ///      liquidation path must never revert on an out-of-range input. With no bands configured the
    ///      loop does not run and every value stays 0, which callers read as "no buffer".
    /// @param _token Main-pool index token (already resolved)
    /// @param _leverage Position leverage in basis points
    /// @return index Matched band, 1-based (0 = not configured)
    /// @return prevLeverage Lower bound of the matched band (0 for the first band)
    /// @return curLeverage Upper bound of the matched band
    /// @return bufferBps Required remaining-collateral share of the matched band
    function _matchBuffer(address _token, uint256 _leverage)
        internal
        view
        returns (uint256 index, uint256 prevLeverage, uint256 curLeverage, uint256 bufferBps)
    {
        uint256 len = tokenBufferCount[_token];
        for(uint256 i = 1; i <= len; i++) {
            curLeverage = tokenBufferConfigs[_token][i].positionLeverage;
            bufferBps = tokenBufferConfigs[_token][i].bufferBps;
            index = i;
            if(_leverage <= curLeverage) break;
            if(i < len) { prevLeverage = curLeverage; }
        }
    }

    /// @notice Decide whether a position must be force-liquidated under its band
    /// @dev Callable only by VaultUtils, which runs this after the legacy leverage check, so the two
    ///      together implement
    ///          remainingCollateral < max(size / liquidationLeverage, collateral * bufferBps)
    ///
    ///      `_remainingCollateral` is supplied by the Vault: it is the position collateral minus the
    ///      unrealised loss, i.e. the price-dependent part only. Fees are NOT subtracted here; the
    ///      Vault applies its own `remainingCollateral < marginFees` and
    ///      `< marginFees + liquidationFee` checks separately, before this one.
    ///
    ///      Deliberately not wrapped in try/catch by the caller: if this contract or its dependencies
    ///      are misconfigured the liquidation path must fail loudly rather than silently fall back to
    ///      the legacy rule.
    /// @param _indexToken Index token (a channel token is resolved to its main-pool token)
    /// @param _size Position size in USD (30 decimals)
    /// @param _collateral Original position collateral in USD (30 decimals), must be non-zero
    /// @param _remainingCollateral Collateral left after the unrealised loss, in USD (30 decimals)
    /// @return true when the remaining collateral is strictly below the band's threshold
    function isForcedLiquidation(
        address _indexToken,
        uint256 _size,
        uint256 _collateral,
        uint256 _remainingCollateral
    ) external view returns (bool) {
        if(msg.sender != vaultUtils) revert("not vaultUtils");
        if(_collateral == 0) revert("collateral err");

        address token = IDataReader(dataReader).getIndexToken(_indexToken);

        // Only the band's bufferBps is needed; with no bands configured it stays 0 and the
        // comparison below is always false, which keeps the legacy behaviour unchanged
        (, , , uint256 bufferBps) = _matchBuffer(token, _size * BASIS_POINTS_DIVISOR / _collateral);

        return _remainingCollateral < _collateral * bufferBps / BASIS_POINTS_DIVISOR;
    }
}
