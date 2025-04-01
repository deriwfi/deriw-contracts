// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IOStruct.sol";

interface IOB is IOStruct  {
    function getIncreaseOrderData(address _account, uint256 _orderIndex) external view returns(IncreaseOrder memory);
}