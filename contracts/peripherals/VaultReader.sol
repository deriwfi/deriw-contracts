// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../core/interfaces/IVault.sol";
import "../core/interfaces/IVaultPriceFeed.sol";

interface IPositionRouter {
    function vault() external view returns (address);
}

contract VaultReader {
    function getVaultTokenInfoV4(address _vault, address _positionRouter, address _weth, address[] memory _tokens) public view returns (uint256[] memory) {
        uint256 propsLength = 12;

        IVault vaultFor = IVault(_vault);
        IVaultPriceFeed priceFeed = IVaultPriceFeed(vaultFor.priceFeed());
        address vault_ = IPositionRouter(_positionRouter).vault();
        require(vault_ == address(vaultFor), "vault err");
        
        address usdt = vaultFor.usdt();

        uint256[] memory amounts = new uint256[](_tokens.length * propsLength);
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            if (token == address(0)) {
                token = _weth;
            }

            amounts[i * propsLength] = vaultFor.poolAmounts(token, usdt);
            amounts[i * propsLength + 1] = vaultFor.reservedAmounts(token, usdt);
            amounts[i * propsLength + 2] = vaultFor.tokenWeights(token);
            amounts[i * propsLength + 3] = 0;
            amounts[i * propsLength + 4] = vaultFor.globalShortSizes(token);
            amounts[i * propsLength + 5] = 0;
            amounts[i * propsLength + 6] = 0;
            amounts[i * propsLength + 7] = vaultFor.getMinPrice(token);
            amounts[i * propsLength + 8] = vaultFor.getMaxPrice(token);
            amounts[i * propsLength + 9] = vaultFor.guaranteedUsd(token, usdt);
            amounts[i * propsLength + 10] = priceFeed.getPrimaryPrice(token, false);
            amounts[i * propsLength + 11] = priceFeed.getPrimaryPrice(token, true);
        }

        return amounts;
    }
}
