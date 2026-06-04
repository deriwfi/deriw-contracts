// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;


interface IMemeFactory {
    function memeErrorContract() external view returns(address);
    function memeData() external view returns(address);
    function poolOwner(address account) external view returns(address);   

    function setGov(address account) external;
    function setContract(
        address errContract_,
        address memeData_
    ) external;

    function isAddMeme(address token) external view returns(bool);  
    
    function getWhitelistNum() external view returns(uint256);

    function getWhitelist(uint256 index) external view returns(address);

    function getWhitelistIsIn(address account) external view returns(bool);

    function getRemovelistNum() external view returns(uint256);

    function getRemovelist(uint256 index) external view returns(address);

    function getRemovelistIsIn(address account) external view returns(bool);

    function operator(address account) external view returns(bool);

    function trader(address account) external view returns(bool);
    
    function gov() external view returns(address);

    function poolToChannelID(address pool) external view returns(uint256);

    function getChannelCreateFunds() external view returns(uint256);

    function getChannelBufferRate() external view returns(uint256);

    function getChannelBufferAmount() external view returns(uint256);
    
    function createChannelToken(address user, address indexToken, uint256 sizeDelta, bool isLong) external returns(address);

    function channelPoolSetID(address pool) external view returns(uint256);

    function poolCurrWithdrawalNumber(address pool) external view returns(uint256);

    function poolLastWithdrawalTime(address pool) external view returns(uint256);

    function getPoolWithdrawalInfo(address pool) external view returns(uint256 currWithdrawalNumber, uint256 lastWithdrawalTime);
    
    function channelSettings() external view returns(uint256 createFunds, uint256 bufferRate, uint256 minBufferAmount, uint256 channelFreezeTime, uint256 channelIntervalTime, uint256 channelID);

    function channelPoolConfig() external view returns(uint256 perWithdrawRate, uint256 withdrawalNumber, uint256 windowTime);

    function channelPoolFactorInfo(address pool) external view returns(uint256 shortFactor, uint256 longFactor, uint256 totalFactor);

    function setPoolFactor(address pool, uint256 shortFactor, uint256 longFactor, uint256 totalFactor) external;

    function channelIDToPool(uint256 id) external view returns(address);

    function channelOwnerPool(address account) external view returns(address);

    function channelPoolOwner(address pool) external view returns(address);

    function channelPoolIsPause(address pool) external view returns(bool);

    function channelPoolIsClose(address pool) external view returns(bool);

    function channelPoolToken(address pool) external view returns(address);

    function channelPoolMode(address indexToken) external view returns(uint256);

    function channelOperator(address account) external view returns(bool);

    function channelTokenCreator(address account) external view returns(bool);
    
    function setChannelTokenCreator(address account, bool isAdd) external;

    function blacklist(address pool, address account) external view returns(bool);

    function channelMappedIndexTokenIsIn(address pool, bytes32 key) external view returns(bool);

    function channelPoolCloseInfo(address pool) external view returns(uint256 startTime, uint256 freezeTime, uint256 endTime);

    function getChannelMappedTokenPoolInfo(address token) external view returns(address pool, address indexToken, address targetToken, address mappedTargetToken);

    function channelMappedTokenPool(address indexToken) external view returns(address pool);

    function channelMappedTargetToken(address pool) external view returns(address);

    function channelMappedIndexToken(address pool, address token) external view returns(address);

    function indexTokenChannelMapped(address indexToken, address pool) external view returns(address);

    function getChannelState(address user, address indexToken) external view returns(address pool, address owner, address mappedToken, uint256 freezeTime, bool isClose, bool isPause, bool isBlacklisted);
}