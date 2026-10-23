// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IChainBlacklist {
    function addBlacklistTxFrom(address addr) external;

    /// @notice Add a address tx.to is blacklist transaction
    function addBlacklistTxTo(address addr) external;

    function removeBlacklistTxFrom(address addr) external;

    /// @notice Add a address tx.to is blacklist transaction
    function removeBlacklistTxTo(address addr) external;

    function addBlacklistTxFromWithFlag(address addr, uint64 flag) external;

    function addBlacklistTxToWithFlag(address addr, uint64 flag) external;


    function removeBlacklistTxToWithFlag(address addr, uint64 flag) external;

    function removeBlacklistTxFromWithFlag(address addr, uint64 flag) external;

    function isBlacklistTxTo(address to) external view returns (bool);

    function isBlacklistTxFrom(address from) external view returns (bool);
}