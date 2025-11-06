// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IADL {

    function increaseGlobalLongSize(address _indexToken, uint256 _amount) external returns(uint256 size);

    function decreaseGlobalLongSize(address _indexToken, uint256 _amount) external returns(uint256 _globalLongSize);

    function increaseGlobalShortSize(address _indexToken, uint256 _amount) external returns(uint256 size);

    function decreaseGlobalShortSize(address _indexToken, uint256 _amount) external returns(uint256 _globalShortSize);
}
