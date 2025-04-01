// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IMemeFactory.sol";
import "./interfaces/IMemeData.sol";
import "./interfaces/IMemeStruct.sol";
import "../staking/interfaces/IRewardRouterV2.sol";
import "../core/interfaces/IGlpManager.sol";

contract MemePool is IMemeStruct {
    using SafeERC20 for IERC20;

    IMemeFactory public memeFactory;
    
    constructor() {
        memeFactory = IMemeFactory(msg.sender);
    }

    modifier onlyPoolData {
        require(msg.sender == memeFactory.memeData());
        _;
    }

    function mintAndStakeGlp(
        address _indexToken, 
        address token, 
        uint256 amount,
        uint256 _minGlp
    ) external onlyPoolData returns (uint256) {
        IERC20(token).approve(getGlpRewardRouter().glpManager(), amount);
        return getGlpRewardRouter().mintAndStakeGlp(_indexToken, token, amount, _minGlp);
    }

    function unstakeAndRedeemGlp(
        address _indexToken, 
        address token, 
        address receiver,
        uint256 glpAmount, 
        uint256 minOut
    ) external onlyPoolData returns (uint256) {
        address glpManager = getGlpRewardRouter().glpManager();
        IERC20 glp = IERC20(IGlpManager(glpManager).glp());
        glp.approve(glpManager, glpAmount);

        return getGlpRewardRouter().unstakeAndRedeemGlp(_indexToken, token, glpAmount, minOut, receiver);
    }

    function withdraw(address token, address user, uint256 amount) external onlyPoolData {
        IERC20(token).safeTransfer(user, amount);
    }
    
    function getMemeData() internal view returns(IMemeData) {
        return IMemeData(memeFactory.memeData());
    }

    function getGlpRewardRouter() internal view returns(IRewardRouterV2) {
        return IRewardRouterV2(getMemeData().glpRewardRouter());
    }
}