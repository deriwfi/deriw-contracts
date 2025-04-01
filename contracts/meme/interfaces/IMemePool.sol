// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IMemePool {
    function mintAndStakeGlp(
        address _indexToken, 
        address _collateralToken, 
        uint256 amount,
        uint256 _minGlp
    ) external returns (uint256);

    function unstakeAndRedeemGlp(
        address _indexToken, 
        address _collateralToken, 
        address receiver,
        uint256 glpAmount, 
        uint256 minOut
    ) external returns (uint256);

    function withdraw(address token, address user, uint256 amount) external;
}