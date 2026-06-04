// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IMemeFactory.sol";

contract channelPool {
    IMemeFactory public memeFactory;
    
    constructor() {
        memeFactory = IMemeFactory(msg.sender);
    }

    function approve(address account, address token, uint256 amount) external {
        if(msg.sender != memeFactory.memeData()) revert("not memeData");

        IERC20(token).approve(account, amount);
    }
}