// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;


import "./IPhaseStruct.sol";

interface ICoinData is IPhaseStruct {
    function gov() external view returns(address);

    function isAddCoin(address token) external view returns(bool);  

    function getCoinType(address token) external view returns(uint8);

    function operator(address account) external view returns(bool);

    function getCurrRate(address token) external  view returns(uint256, uint256);

    function getTokenIsCanRemove(address token) external view returns(bool);
    
    function getSizeData(address _indexToken) external view returns(
        uint256 globalShortSizes,
        uint256 globalLongSizes,
        uint256 totalSize
    );
    function getPoolValue(address indexToken) external view returns(uint256, bool, bool);

    function getTokenInfo(
        address _token
    ) external view returns(address, uint256, uint256, uint8);

    // *********************************************
    function getPoolTargetTokenInfoSetNum(address _poolTargetToken) external view returns(uint256);

    function getMemberTokenTargetIDLength(address _poolTargetToken, uint256 _num) external view returns(uint256);
 
    function getMemberTokenTargetID(address _poolTargetToken, uint256 _num, uint256 _index) external view returns(uint256, uint256);

    function getMemberTokenTargetIDIsIn(address _poolTargetToken, uint256 _num, uint256 _memberTokenTargetID) external view returns(bool);

    function getCurrMemberTokenTargetIDLength(address _poolTargetToken) external view returns(uint256);

    function getCurrMemberTokenTargetID(address _poolTargetToken, uint256 _index) external view returns(uint256, uint256);

    function getCurrMemberTokenTargetIDIsIn(address _poolTargetToken, uint256 _memberTokenTargetID) external view returns(bool);

    //  **************************************************
    function getMemberTokensLength(
        address _poolTargetToken, 
        uint256 _num, 
        uint256 _memberTokenTargetID
    ) external view returns(uint256);

    function getMemberToken(
        address _poolTargetToken, 
        uint256 _num, 
        uint256 _memberTokenTargetID,
        uint256 _index
    ) external view returns(address);

    function getMemberTokenIsIn(
        address _token,
        address _poolTargetToken, 
        uint256 _num, 
        uint256 _memberTokenTargetID
    ) external view returns(bool);

    function getRemoveTokensLength(
        address _poolTargetToken, 
        uint256 _num
    ) external view returns(uint256);

    function getRemoveTokensMemberToken(
        address _poolTargetToken, 
        uint256 _num, 
        uint256 _index
    ) external view returns(address);

    function getRemoveTokenIsIn(
        address _token,
        address _poolTargetToken, 
        uint256 _num
    ) external view returns(bool);


    // *********************************
    function getTokenToPoolTargetToken(address _token) external view returns(address);
    
    function getSingleTokensLength(address _poolTargetToken, uint256 _num) external view returns(uint256);

    function getSingleToken(address _poolTargetToken, uint256 _num, uint256 _index) external view returns(address, uint256);

    function getSingleTokenIsIn(address _token, address _poolTargetToken, uint256 _num) external view returns(bool);

    function getCurrSingleTokensLength(address _poolTargetToken) external view returns(uint256);

    function getCurrSingleToken(address _poolTargetToken, uint256 _index) external view returns(address, uint256);

    function getCurrSingleTokenIsIn(address _token, address _poolTargetToken) external view returns(bool);

    function getTokenIsInPool(address _token) external view returns(bool);

    function getCurrRemoveTokensLength(address _poolTargetToken) external view returns(uint256);

    function getCurrRemoveToken(address _poolTargetToken, uint256 _index) external view returns(address);

    function getCurrRemoveTokenIsIn(address _poolTargetToken, address _token) external view returns(bool);
}
