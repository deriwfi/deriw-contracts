// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "../../oracle/interfaces/ISecondaryPriceFeed.sol";

interface IFastPriceFeedFor is ISecondaryPriceFeed {
    function prices(address token) external view returns (uint256);
    function priceData(address token) external view returns (uint256 refPrice, uint256 refTime, uint256 cumulativeRefDelta, uint256 cumulativeFastDelta);
    function maxCumulativeDeltaDiffs(address token) external view returns (uint256);
    function favorFastPrice(address _token) external view returns (bool);
    function getPriceData(address _token) external view returns (uint256, uint256, uint256, uint256);
}
