// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "../core/interfaces/IVault.sol";
import "../core/interfaces/IVaultPriceFeed.sol";
import "../core/interfaces/IDataReader.sol";
import "./interfaces/IFastPriceFeedFor.sol";
import "../oracle/interfaces/IPriceFeed.sol";
import "../access/Governable.sol";

/**
 * @title Reader
 * @notice Unified read layer aggregating data from Vault, VaultPriceFeed, FastPriceFeed, and PriceFeed
 * @dev All price/state queries first resolve tokens via dataReader.getIndexToken() for channel support.
 *      Inherits Governable for owner-only admin functions (setContract, setAdjustment, etc.).
 */
contract Reader is Governable {
    /// @notice Number of properties per position in getPositions return array
    uint256 public constant POSITION_PROPS_LENGTH = 9;

    /// @notice Vault contract for pool amounts and positions
    IVault public vault;
    /// @notice VaultPriceFeed for primary/secondary price data
    IVaultPriceFeed public vaultPriceFeed;
    /// @notice DataReader for index token resolution
    IDataReader public dataReader;
    /// @notice FastPriceFeed interface for fast price queries
    IFastPriceFeedFor public fastPriceFeed;
    /// @notice Chainlink PriceFeed for on-chain prices
    IPriceFeed public priceFeed;

    /**
     * @notice Set all dependent contract addresses
     * @param _vault Vault address
     * @param _vaultPriceFeed VaultPriceFeed address
     * @param _dataReader DataReader address
     * @param _fastPriceFeed FastPriceFeed address
     * @param _priceFeed Chainlink PriceFeed address
     */
    function setContract(
        address _vault,
        address _vaultPriceFeed,
        address _dataReader,
        address _fastPriceFeed,
        address _priceFeed
    ) external onlyGov {
        require(
            _vault != address(0) &&
            _vaultPriceFeed != address(0) &&
            _dataReader != address(0) &&
            _fastPriceFeed != address(0) &&
            _priceFeed != address(0),
            "addr err"
        );

        vault = IVault(_vault);
        vaultPriceFeed = IVaultPriceFeed(_vaultPriceFeed);
        dataReader = IDataReader(_dataReader);
        fastPriceFeed = IFastPriceFeedFor(_fastPriceFeed);
        priceFeed = IPriceFeed(_priceFeed);
    }

    /**
     * @notice Get token balances for an account
     * @param _account Account address
     * @param _tokens Array of token addresses (use address(0) for ETH balance)
     * @return balances Array of balances in same order as tokens
     */
    function getTokenBalances(address _account, address[] memory _tokens) public view returns (uint256[] memory) {
        uint256[] memory balances = new uint256[](_tokens.length);
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            if (token == address(0)) {
                balances[i] = _account.balance;
                continue;
            }
            balances[i] = IERC20(token).balanceOf(_account);
        }
        return balances;
    }

    /**
     * @notice Get comprehensive vault token info array
     * @dev Returns 8 properties per token: poolAmounts, reservedAmounts, tokenWeights,
     *      minPrice, maxPrice, guaranteedUsd, primaryPrice(bid), primaryPrice(ask)
     * @param _weth WETH address (used when token is address(0))
     * @param _tokens Array of tokens to query
     * @return amounts Flat array: [token0_prop0..prop7, token1_prop0..prop7, ...]
     */
    function getVaultTokenInfo(address /*_vault*/, address _weth, address[] memory _tokens) public view returns (uint256[] memory) {
        uint256 propsLength = 8;
        address usdt = vault.usdt();
   
        uint256[] memory amounts = new uint256[](_tokens.length * propsLength);
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            if (token == address(0)) {
                token = _weth;
            }
            address tokenFor = dataReader.getIndexToken(token);
            amounts[i * propsLength] = vault.poolAmounts(token, usdt);
            amounts[i * propsLength + 1] = vault.reservedAmounts(token, usdt);
            amounts[i * propsLength + 2] = vault.tokenWeights(tokenFor);
            amounts[i * propsLength + 3] = vault.getMinPrice(token);
            amounts[i * propsLength + 4] = vault.getMaxPrice(token);
            amounts[i * propsLength + 5] = vault.guaranteedUsd(token, usdt);
            amounts[i * propsLength + 6] = vaultPriceFeed.getPrimaryPrice(tokenFor, false);
            amounts[i * propsLength + 7] = vaultPriceFeed.getPrimaryPrice(tokenFor, true);
        }

        return amounts;
    }

    /**
     * @notice Get position details for multiple positions
     * @dev Returns 9 properties per position: size, collateral, avgPrice, entryFundingRate,
     *      hasRealisedProfit(0/1), realisedPnl, lastIncreasedTime, hasProfit(0/1), delta
     * @param _account Position owner
     * @param _collateralTokens Array of collateral tokens
     * @param _indexTokens Array of index tokens
     * @param _isLong Array of long/short flags
     * @return amounts Flat array of position properties
     */
    function getPositions(address /*_vault*/, address _account, address[] memory _collateralTokens, address[] memory _indexTokens, bool[] memory _isLong) public view returns(uint256[] memory) {
        uint256[] memory amounts = new uint256[](_collateralTokens.length * POSITION_PROPS_LENGTH);

        for (uint256 i = 0; i < _collateralTokens.length; i++) {
            {
            (uint256 _size,
             uint256 collateral,
             uint256 _averagePrice,
             uint256 entryFundingRate,
             /* reserveAmount */,
             uint256 realisedPnl,
             bool hasRealisedProfit,
             uint256 _lastIncreasedTime) = vault.getPosition(_account, _collateralTokens[i], _indexTokens[i], _isLong[i]);

            amounts[i * POSITION_PROPS_LENGTH] = _size;
            amounts[i * POSITION_PROPS_LENGTH + 1] = collateral;
            amounts[i * POSITION_PROPS_LENGTH + 2] = _averagePrice;
            amounts[i * POSITION_PROPS_LENGTH + 3] = entryFundingRate;
            amounts[i * POSITION_PROPS_LENGTH + 4] = hasRealisedProfit ? 1 : 0;
            amounts[i * POSITION_PROPS_LENGTH + 5] = realisedPnl;
            amounts[i * POSITION_PROPS_LENGTH + 6] = _lastIncreasedTime;
            }

            uint256 size = amounts[i * POSITION_PROPS_LENGTH];
            uint256 averagePrice = amounts[i * POSITION_PROPS_LENGTH + 2];
            uint256 lastIncreasedTime = amounts[i * POSITION_PROPS_LENGTH + 6];
            if (averagePrice > 0) {
                (bool hasProfit, uint256 delta) = vault.getDelta(_indexTokens[i], size, averagePrice, _isLong[i], lastIncreasedTime);
                amounts[i * POSITION_PROPS_LENGTH + 7] = hasProfit ? 1 : 0;
                amounts[i * POSITION_PROPS_LENGTH + 8] = delta;
            }
        }

        return amounts;
    }

    /// @notice Get current block timestamp
    function getCurrTime() external view returns(uint256) {
        return block.timestamp;
    }

    /// @notice Get current block number
    function getCurrBlockNumber()  external view returns(uint256) {
        return block.number;
    }

    // ======================== Vault Wrappers ========================

    /// @notice Check if token is whitelisted (resolved via getIndexToken)
    function whitelistedTokens(address token) external view returns(bool) {
        token = dataReader.getIndexToken(token);
        return vault.whitelistedTokens(token);
    }

    /// @notice Get token decimals (resolved via getIndexToken)
    function tokenDecimals(address token) external view returns(uint256) {
        token = dataReader.getIndexToken(token);
        return vault.tokenDecimals(token);
    }

    /// @notice Get token weight (resolved via getIndexToken)
    function tokenWeights(address token) external view returns(uint256) {
        token = dataReader.getIndexToken(token);
        return vault.tokenWeights(token);
    }

    /// @notice Get min profit basis points (resolved via getIndexToken)
    function minProfitBasisPoints(address token) external view returns(uint256) {
        token = dataReader.getIndexToken(token);
        return vault.minProfitBasisPoints(token);
    }

    /// @notice Check if token is stable (resolved via getIndexToken)
    function stableTokens(address token) external view returns(bool) {
        token = dataReader.getIndexToken(token);
        return vault.stableTokens(token);
    }

    /// @notice Check if token is shortable (resolved via getIndexToken)
    function shortableTokens(address token) external view returns(bool) {
        token = dataReader.getIndexToken(token);
        return vault.shortableTokens(token);
    }

    /// @notice Check if token is wrapped (resolved via getIndexToken)
    function iswrapped(address token) external view returns(bool) {
        token = dataReader.getIndexToken(token);
        return vault.iswrapped(token);
    }

    /// @notice Check if token is from (resolved via getIndexToken)
    function isFrom(address token) external view returns(bool) {
        token = dataReader.getIndexToken(token);
        return vault.isFrom(token);
    }

    // ======================== VaultPriceFeed Wrappers ========================

    /// @notice Get adjustment basis points (resolved via getIndexToken)
    function adjustmentBasisPoints(address token) external view returns(uint256) {
        token = dataReader.getIndexToken(token);
        return vaultPriceFeed.adjustmentBasisPoints(token);
    }

    /// @notice Check if adjustment is additive (resolved via getIndexToken)
    function isAdjustmentAdditive(address token) external view returns(bool) {
        token = dataReader.getIndexToken(token);
        return vaultPriceFeed.isAdjustmentAdditive(token);
    }

    /// @notice Set price adjustment (gov only)
    function setAdjustment(address token, bool _isAdditive, uint256 _adjustmentBps) external onlyGov {
        vaultPriceFeed.setAdjustment(token, _isAdditive, _adjustmentBps);
    }

    /// @notice Set spread basis points (gov only)
    function setSpreadBasisPoints(address token, uint256 _spreadBasisPoints) external onlyGov {
        vaultPriceFeed.setSpreadBasisPoints(token, _spreadBasisPoints);
    }

    /// @notice Get price from vaultPriceFeed (resolved via getIndexToken)
    function getPriceVaultPriceFeed(address token, bool _maximise, bool _includeAmmPrice, bool _useSwapPricing) external view returns(uint256) {
        token = dataReader.getIndexToken(token);
        return vaultPriceFeed.getPrice(token, _maximise, _includeAmmPrice, _useSwapPricing);
    }

    /// @notice Get latest primary price (resolved via getIndexToken)
    function getLatestPrimaryPrice(address token) external view returns(uint256) {
        token = dataReader.getIndexToken(token);
        return vaultPriceFeed.getLatestPrimaryPrice(token);
    }

    /// @notice Get primary price (resolved via getIndexToken)
    function getPrimaryPrice(address token, bool _maximise) external view returns(uint256) {
        token = dataReader.getIndexToken(token);
        return vaultPriceFeed.getPrimaryPrice(token, _maximise);
    }

    /// @notice Get price decimals (resolved via getIndexToken)
    function priceDecimals(address token) external view returns(uint256) {
        token = dataReader.getIndexToken(token);
        return vaultPriceFeed.priceDecimals(token);
    }

    /// @notice Get spread basis points (resolved via getIndexToken)
    function spreadBasisPoints(address token) external view returns(uint256) {
        token = dataReader.getIndexToken(token);
        return vaultPriceFeed.spreadBasisPoints(token);
    }

    /// @notice Check if strict stable token (resolved via getIndexToken)
    function strictStableTokens(address token) external view returns(bool) {
        token = dataReader.getIndexToken(token);
        return vaultPriceFeed.strictStableTokens(token);
    }

    /// @notice Get last adjustment timings (resolved via getIndexToken)
    function lastAdjustmentTimings(address token) external view returns(uint256) {
        token = dataReader.getIndexToken(token);
        return vaultPriceFeed.lastAdjustmentTimings(token);
    }

    /// @notice Get price v1 (resolved via getIndexToken)
    function getPriceV1(address token, bool _maximise) external view returns(uint256) {
        token = dataReader.getIndexToken(token);
        return vaultPriceFeed.getPriceV1(token, _maximise);
    }

    /// @notice Get secondary price (resolved via getIndexToken)
    function getSecondaryPrice(address token, uint256 _referencePrice, bool _maximise) external view returns(uint256) {
        token = dataReader.getIndexToken(token);
        return vaultPriceFeed.getSecondaryPrice(token, _referencePrice, _maximise);
    }

    // ======================== FastPriceFeed Wrappers ========================

    /// @notice Get fast price (resolved via getIndexToken)
    function getPrice(address token, uint256 _referencePrice, bool _maximise) external view returns(uint256) {
        token = dataReader.getIndexToken(token);
        return fastPriceFeed.getPrice(token, _referencePrice, _maximise);
    }

    /// @notice Get current prices (resolved via getIndexToken)
    function prices(address token) external view returns(uint256) {
        token = dataReader.getIndexToken(token);
        return fastPriceFeed.prices(token);
    }

    /// @notice Get price data item (resolved via getIndexToken)
    function priceData(address token) external view returns(uint256 refPrice, uint256 refTime, uint256 cumulativeRefDelta, uint256 cumulativeFastDelta) {
        token = dataReader.getIndexToken(token);
        return fastPriceFeed.priceData(token);
    }

    /// @notice Get max cumulative delta diffs (resolved via getIndexToken)
    function maxCumulativeDeltaDiffs(address token) external view returns(uint256) {
        token = dataReader.getIndexToken(token);
        return fastPriceFeed.maxCumulativeDeltaDiffs(token);
    }

    /// @notice Check if fast price is favored (resolved via getIndexToken)
    function favorFastPrice(address token) external view returns(bool) {
        token = dataReader.getIndexToken(token);
        return fastPriceFeed.favorFastPrice(token);
    }

    /// @notice Get price data tuple (resolved via getIndexToken)
    function getPriceData(address token) external view returns(uint256, uint256, uint256, uint256) {
        token = dataReader.getIndexToken(token);
        return fastPriceFeed.getPriceData(token);
    }

    // ======================== PriceFeed Wrappers ========================

    /// @notice Get latest chainlink answer (resolved via getIndexToken)
    function latestAnswer(address token) external view returns(int256) {
        token = dataReader.getIndexToken(token);
        return priceFeed.latestAnswer(token);
    }

    /// @notice Get latest chainlink round (resolved via getIndexToken)
    function latestRound(address token) external view returns(uint80) {
        token = dataReader.getIndexToken(token);
        return priceFeed.latestRound(token);
    }

    /// @notice Get chainlink answer by token (resolved via getIndexToken)
    function answer(address token) external view returns(int256) {
        token = dataReader.getIndexToken(token);
        return priceFeed.answer(token);
    }

    /// @notice Get chainlink round ID by token (resolved via getIndexToken)
    function roundId(address token) external view returns(uint80) {
        token = dataReader.getIndexToken(token);
        return priceFeed.roundId(token);
    }

    /// @notice Get chainlink answer by (token, roundId) (resolved via getIndexToken)
    function answers(address token, uint80 roundID) external view returns(int256) {
        token = dataReader.getIndexToken(token);
        return priceFeed.answers(token, roundID);
    }

    /// @notice Get full chainlink round data (resolved via getIndexToken)
    function getRoundData(address token, uint80 roundID) external view returns(uint80, int256, uint256, uint256, uint80) {
        token = dataReader.getIndexToken(token);
        return priceFeed.getRoundData(token, roundID);
    }
}
