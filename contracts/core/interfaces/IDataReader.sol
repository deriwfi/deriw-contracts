// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IDataReader {
    function getTargetIndexToken(address _indexToken) external view returns(address);

    function getTargetMemeToken(address _indexToken) external view returns(address);

    function poolAmounts(address _indexToken, address _collateralToken) external view returns(uint256 _poolAmounts);

    function reservedAmounts(address _indexToken, address _collateralToken) external view returns(uint256 _reservedAmounts);

    function guaranteedUsd(address _indexToken, address _collateralToken) external view returns(uint256 _guaranteedUsd);

    function tokenBalances(address _indexToken, address _collateralToken) external view returns(uint256 _tokenBalances);
}
