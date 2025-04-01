// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;


import "./IPhaseStruct.sol";

interface ICoinData is IPhaseStruct {
    function gov() external view returns(address);
    function getCurrRate(address token) external  view returns(uint256, uint256);
    function lastTime(address token) external view returns(uint256);
    function getPeriodTokenContains(uint256 pid, uint256 num, address token) external view returns(bool);
    function getCoinContains(uint256 pid, uint256 num, address token) external view returns(bool);
    function period() external view returns(uint256);
    function periodAddNum(uint256 id) external view returns(uint256);
    function getPidNum() external view returns(uint256 id, uint256 num);

    function getSizeData(address _vault) external view returns(
        uint256 globalShortSizes,
        uint256 globalLongSizes,
        uint256 totalSize
    );
    function getCoinsLength(uint256 pid, uint256 num) external view returns(uint256);

    function getConin(uint256 pid, uint256 num, uint256 index) external view returns(address);

    function isAddCoin(address token) external view returns(bool);  

    function getCoinType(address token) external view returns(uint8);
    
    function getPoolValue(address _vault, address indexToken) external view returns(uint256, bool, bool);
}
