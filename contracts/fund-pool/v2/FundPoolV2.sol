// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IFundFactoryV2.sol";
import "./interfaces/IPoolDataV2.sol";
import "../../staking/interfaces/IRewardRouterV2.sol";
import "../../core/interfaces/IGlpManager.sol";

contract FundPoolV2 is IStruct {
    using SafeERC20 for IERC20;

    IFundFactoryV2 public factoryV2;
    
    constructor() {
        factoryV2 = IFundFactoryV2(msg.sender);
    }

    modifier onlyPoolData {
        require(msg.sender == factoryV2.poolDataV2());
        _;
    }

    function mintAndStakeGlp(
        address token, 
        uint256 amount,
        uint256 _minGlp
    ) external onlyPoolData returns (uint256) {
        IERC20(token).approve(getGlpRewardRouter().glpManager(), amount);
        
        return getGlpRewardRouter().mintAndStakeGlp(token, token, amount, _minGlp);
    }

    function unstakeAndRedeemGlp(
        address token, 
        uint256 glpAmount, 
        uint256 minOut
    ) external onlyPoolData returns (uint256) {
        address glpManager = getGlpRewardRouter().glpManager();
        IERC20 glp = IERC20(IGlpManager(glpManager).glp());
        glp.approve(glpManager, glpAmount);

        return getGlpRewardRouter().unstakeAndRedeemGlp(token, token, glpAmount, minOut, msg.sender);
    }
    
    function getPoolDataV2() internal view returns(IPoolDataV2) {
        return IPoolDataV2(factoryV2.poolDataV2());
    }

    function getGlpRewardRouter() internal view returns(IRewardRouterV2) {
        return IRewardRouterV2(getPoolDataV2().glpRewardRouter());
    }
}