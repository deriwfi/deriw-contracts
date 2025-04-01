// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IRewardRouterV2 {
    function mintAndStakeGlp(address _indexToken, address _collateralToken, uint256 _amount, uint256 _minGlp) external returns (uint256);
    
    function unstakeAndRedeemGlp(address _indexToken, address _tokenOut, uint256 _glpAmount, uint256 _minOut, address _receiver) external  returns (uint256);

    function glpManager() external view returns(address);

    function setGov(address account) external;
}
