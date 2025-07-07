// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../core/interfaces/IVault.sol";
import "../core/interfaces/IVaultPriceFeed.sol";

contract Reader {
    using SafeMath for uint256;

    uint256 public constant POSITION_PROPS_LENGTH = 9;

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

    function getVaultTokenInfo(address _vault, address _weth, address[] memory _tokens) public view returns (uint256[] memory) {
        uint256 propsLength = 8;

        IVault vault = IVault(_vault);

        address usdt = vault.usdt();
        IVaultPriceFeed priceFeed = IVaultPriceFeed(vault.priceFeed());

        uint256[] memory amounts = new uint256[](_tokens.length * propsLength);
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            if (token == address(0)) {
                token = _weth;
            }
            amounts[i * propsLength] = vault.poolAmounts(token, usdt);
            amounts[i * propsLength + 1] = vault.reservedAmounts(token, usdt);
            amounts[i * propsLength + 2] = vault.tokenWeights(token);
            amounts[i * propsLength + 3] = vault.getMinPrice(token);
            amounts[i * propsLength + 4] = vault.getMaxPrice(token);
            amounts[i * propsLength + 5] = vault.guaranteedUsd(token, usdt);
            amounts[i * propsLength + 6] = priceFeed.getPrimaryPrice(token, false);
            amounts[i * propsLength + 7] = priceFeed.getPrimaryPrice(token, true);
        }

        return amounts;
    }

    function getPositions(address _vault, address _account, address[] memory _collateralTokens, address[] memory _indexTokens, bool[] memory _isLong) public view returns(uint256[] memory) {
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
             uint256 _lastIncreasedTime) = IVault(_vault).getPosition(_account, _collateralTokens[i], _indexTokens[i], _isLong[i]);

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
                (bool hasProfit, uint256 delta) = IVault(_vault).getDelta(_indexTokens[i], size, averagePrice, _isLong[i], lastIncreasedTime);
                amounts[i * POSITION_PROPS_LENGTH + 7] = hasProfit ? 1 : 0;
                amounts[i * POSITION_PROPS_LENGTH + 8] = delta;
            }
        }

        return amounts;
    }

    function getCurrTime() external view returns(uint256) {
        return block.timestamp;
    }

    function getCurrBlockNumber()  external view returns(uint256) {
        return block.number;
    }
}
