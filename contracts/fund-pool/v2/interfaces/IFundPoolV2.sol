// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IFundPoolV2 {
    function mintAndStakeGlp(
        address token, 
        uint256 amount,
        uint256 _minGlp
    ) external returns (uint256);

    function unstakeAndRedeemGlp(
        address token, 
        uint256 glpAmount, 
        uint256 minOut
    ) external returns (uint256);

}