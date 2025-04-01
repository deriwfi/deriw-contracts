
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./IStruct.sol";

interface IFundRouterV2 is IStruct {
  function setContract(
        address auth_,
        address factory_,
        address poolData_
    ) external;
}
