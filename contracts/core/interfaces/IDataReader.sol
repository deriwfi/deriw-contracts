// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IDataReader {
    function getTargetIndexToken(address _indexToken) external view returns(address);

    function getTargetMemeToken(address _indexToken) external view returns(address);

    function poolAmounts(address _indexToken, address _collateralToken) external view returns(uint256 _poolAmounts);

    function reservedAmounts(address _indexToken, address _collateralToken) external view returns(uint256 _reservedAmounts);

    function guaranteedUsd(address _indexToken, address _collateralToken) external view returns(uint256 _guaranteedUsd);

    function tokenBalances(address _indexToken, address _collateralToken) external view returns(uint256 _tokenBalances);

    function getTokenInfo(address _token) external view returns(address poolTargetToken, uint256 memberTokenTargetID, uint256 lastTime, uint8 belongTo);

    function getSizeData(address _indexToken) external view returns(uint256 globalShortSizes, uint256 globalLongSizes, uint256 totalSize);

    function getPoolValue(address indexToken) external view returns(uint256 poolValue, bool isMeme, bool isFundraise);

    function getCurrRate(address token) external view returns(uint256 rate);

    function getPoolTargetTokenInfoSetNum(address _poolTargetToken) external view returns(uint256);

    function getCurrMemberTokenTargetIDLength(address _poolTargetToken) external view returns(uint256);

    function getCurrMemberTokenTargetID(address _poolTargetToken, uint256 _index) external view returns(uint256 memberTokenTargetID, uint256 rate);

    function getCurrMemberTokenTargetIDIsIn(address _poolTargetToken, uint256 _memberTokenTargetID) external view returns(bool);

    function getCurrMemberTokensLength(address _poolTargetToken, uint256 _memberTokenTargetID) external view returns(uint256);

    function getCurrMemberToken(address _poolTargetToken, uint256 _memberTokenTargetID, uint256 _index) external view returns(address);

    function getCurrMemberTokenIsIn(address _token, address _poolTargetToken, uint256 _memberTokenTargetID) external view returns(bool);

    function getTokenToPoolTargetToken(address _token) external view returns(address);

    function getCurrSingleTokensLength(address _poolTargetToken) external view returns(uint256);

    function getCurrSingleToken(address _poolTargetToken, uint256 _index) external view returns(address singleToken, uint256 rate);

    function getCurrSingleTokenIsIn(address _token, address _poolTargetToken) external view returns(bool);

    function getCoinType(address token) external view returns(uint8);

    function getCurrRemoveTokensLength(address _poolTargetToken) external view returns(uint256);

    function getCurrRemoveToken(address _poolTargetToken, uint256 _index) external view returns(address);

    function getCurrRemoveTokenIsIn(address _poolTargetToken, address _token) external view returns(bool);

    function getIndexToken(address _indexToken) external view returns(address);

    function vault() external view returns(address);

    function coinData() external view returns(address);

    function memeFactory() external view returns(address);

    function memeData() external view returns(address);

    function slippage() external view returns(address);

    function phase() external view returns(address);

    function referralStorage() external view returns(address);

    function validatePool(address user, address indexToken) external view returns(address);

    function getValue(address _indexToken, bool _isLong) external view returns(uint256 poolTotalValue, uint256 sidePoolValue);

    function getTokenIsCanRemove(address token) external view returns(bool);

    function whitelistedTokens(address token) external view returns(bool);

    function getUsePoolAmounts(address _indexToken, address _collateralToken) external view returns(uint256);

    function getChannelOutAmount(address indexToken, address tokenOut, uint256 amount) external view returns(uint256 outAmount, uint256 burnGlpAmount, uint256 riskBuffer);

    function getPoolAmount(address _indexToken, address _tokenOut) external view returns(uint256);
}
