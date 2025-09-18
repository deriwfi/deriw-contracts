// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IVault.sol";
import "../Pendant/interfaces/ICoinData.sol";
import "../meme/interfaces/IMemeData.sol";
import "../access/Governable.sol";

/**
 * @title DataReader Contract
 * @notice A governance-enabled contract for reading token data from vault and coinData contracts
 * @dev Inherits from Governable and interacts with IVault and ICoinData interfaces
 */
contract DataReader is Governable {

    /**
     * @notice Address of the vault contract
     * @dev Used for accessing token data from the vault
     */
    IVault public vault;

    /**
     * @notice Address of the coinData contract
     * @dev Used for getting token to pool mapping information
     */
    ICoinData public coinData;

    /**
     * @notice Sets the required contract addresses
     * @dev Can only be called by governance
     * @param _coinData Address of the coinData contract
     * @param _vault Address of the vault contract
     */
    function setContract(
        address _coinData,
        address _vault
    ) external onlyGov {
        require(
            _coinData != address(0) &&
            _vault != address(0),
            "addr err"
        );

        coinData = ICoinData(_coinData);
        vault = IVault(_vault);
    }

    /**
     * @notice Gets the target index token address
     * @dev Returns USDT address if input is USDT, otherwise queries coinData
     * @param _indexToken The index token address to check
     * @return The corresponding target token address
     * @custom:require Input token must have a valid mapping in coinData
     */
    function getTargetIndexToken(address _indexToken) public view returns(address) {   
        address _usdt = vault.usdt();
        if(_indexToken == _usdt) {
            return _usdt;
        }
        address token = coinData.getTokenToPoolTargetToken(_indexToken);
        require(token != address(0), "_indexToken err");

        return token;
    }

    /**
     * @notice Gets pool amounts for token pair
     * @param _indexToken The index token address
     * @param _collateralToken The collateral token address
     * @return _poolAmounts The current pool amount
     */
    function poolAmounts(address _indexToken, address _collateralToken) external view returns(uint256 _poolAmounts) {
        (_poolAmounts,,,) = vault.getTokenData(getTargetIndexToken(_indexToken), _collateralToken);
    }

    /**
     * @notice Gets reserved amounts for token pair
     * @param _indexToken The index token address
     * @param _collateralToken The collateral token address
     * @return _reservedAmounts The current reserved amount
     */
    function reservedAmounts(address _indexToken, address _collateralToken) external view returns(uint256 _reservedAmounts) {
        (,_reservedAmounts,,) = vault.getTokenData(getTargetIndexToken(_indexToken), _collateralToken);
    }


    /**
     * @notice Gets guaranteed USD value for token pair
     * @param _indexToken The index token address
     * @param _collateralToken The collateral token address
     * @return _guaranteedUsd The current guaranteed USD value
     */
    function guaranteedUsd(address _indexToken, address _collateralToken) external view returns(uint256 _guaranteedUsd) {
        (,,_guaranteedUsd,) = vault.getTokenData(getTargetIndexToken(_indexToken), _collateralToken);
    }

    /**
     * @notice Gets token balances for token pair
     * @param _indexToken The index token address
     * @param _collateralToken The collateral token address
     * @return _tokenBalances The current token balances
     */
    function tokenBalances(address _indexToken, address _collateralToken) external view returns(uint256 _tokenBalances) {
        (,,,_tokenBalances) = vault.getTokenData(getTargetIndexToken(_indexToken), _collateralToken);
    }
}