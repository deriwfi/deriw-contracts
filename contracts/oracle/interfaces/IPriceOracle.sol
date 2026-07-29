// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IPriceOracle {
    function getPriceId(address _indexToken) external view returns(uint256);

    function getPriceInfo(address _indexToken, uint256 _id) external view returns(address indexToken, uint256 priceAsk, uint256 priceBid, uint256 priceMid);

    function getLastUpdateTime(address _indexToken, uint256 _id) external view returns(uint256);

    function getPrice(address _indexToken) external view returns(address indexToken, uint256 priceAsk, uint256 priceBid, uint256 priceMid);

    function getMaxPrice(address _indexToken) external view returns(uint256);

    function getMinPrice(address _indexToken) external view returns(uint256);
}
