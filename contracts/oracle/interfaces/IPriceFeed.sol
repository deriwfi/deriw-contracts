// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IPriceFeed {
    function description() external view returns (string memory);
    function aggregator() external view returns (address);
    function latestAnswer(address _token) external view returns (int256);
    function latestRound(address _token) external view returns (uint80);
    function getRoundData(address _token, uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80);
}
