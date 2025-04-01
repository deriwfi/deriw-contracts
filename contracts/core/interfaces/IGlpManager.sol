// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IVault.sol";

interface IGlpManager {
    function glp() external view returns (address);
    function vault() external view returns (IVault);
    function cooldownDuration() external returns (uint256);
    function lastAddedAt(address _account) external returns (uint256);
    function addLiquidityForAccount(address _indexToken, address _fundingAccount, address _account, address _collateralToken, uint256 _amount, uint256 _minGlp) external returns (uint256);
    function removeLiquidityForAccount(address _indexToken, address _account, address _tokenOut, uint256 _glpAmount, uint256 _minOut, address _receiver) external returns (uint256);
    function setCooldownDuration(uint256 _cooldownDuration) external;
}
