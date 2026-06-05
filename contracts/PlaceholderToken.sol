// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title PlaceholderToken
 * @notice A standard ERC20 token whose sole purpose is to generate a unique contract address.
 * @dev This token has NO mint or burn capabilities, so total supply is permanently 0.
 *      It is NOT a real transferable asset — it exists only as an address placeholder
 *      for identifying and distinguishing token addresses and symbols across various pool types.
 *      No tokens are ever minted, transferred, or held.
 */
contract PlaceholderToken is ERC20 {
    constructor (
        string memory name_, string memory symbol_
    ) ERC20(name_,  symbol_) {
    }
}
