// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILiquidateBuffer {
    function isForcedLiquidation(
        address _indexToken,
        uint256 _size,
        uint256 _collateral,
        uint256 _remainingCollateral
    ) external view returns (bool);
}
