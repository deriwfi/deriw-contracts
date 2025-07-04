// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "../core/interfaces/IERC20Metadata.sol";
import "../core/interfaces/IVault.sol";
import "../fund-pool/v2/interfaces/IPoolDataV2.sol";
import "../fund-pool/v2/interfaces/IStruct.sol";
import "./interfaces/IPhase.sol";
import "../meme/interfaces/IMemeData.sol";
import "../upgradeability/Synchron.sol";

contract CoinData is Synchron, IStruct, IPhaseStruct {
    using EnumerableSet for EnumerableSet.AddressSet;

    IMemeData public memeData;
    address public gov;
    address public operator;
    uint256 public period; 
    address public usdt;

    uint256 public constant baseRate = 10000;

    bool public initialized;

    mapping(uint256 => uint256) public periodAddNum;
    mapping(uint256 => mapping(uint256 => mapping(address => TokenBase))) tokenBase;
    mapping(address => uint256) public lastTime;
    mapping(uint256 => mapping(uint256 => EnumerableSet.AddressSet)) periodToken;
    mapping(uint256 => mapping(uint256 => EnumerableSet.AddressSet)) coins;
    mapping(uint256 => mapping(uint256 => uint256)) public coninRate;
    mapping(address => bool) public isAddCoin;

    event AddCoin(uint256 id, uint256 num, address token);
    event RemoveCoin(uint256 id, uint256 num, address token);

    event CreateNewPeriodTokenBase(
        uint256 id,
        uint256 num,
        TokenBase[] _tokenBase,
        address[] _coins,
        uint256 _coinRate
    );

    event SetData(
        uint256 id,
        uint256 num,
        TokenBase[] _tokenBase,
        uint256 _coinRate
    ); 

    modifier onlyGov() {
        require(gov == msg.sender, "gov err");
        _;
    }

    modifier onlyAuth() {
        require(gov == msg.sender || operator == msg.sender, "no permission");
        _;
    }

    function initialize(address _usdt) external {
        require(!initialized, "has initialized");
        require(_usdt != address(0), "addr err");

        initialized = true;

        usdt = _usdt;
        gov = msg.sender;
    }


    function setGov(address account) external onlyGov {
        require(account != address(0), "account err");
        gov = account;
    }

    function setOperator(address account) external onlyGov {
        require(account != address(0), "account err");
        operator = account;
    }

    function setMemeData(address _memeData) external onlyGov {
        require(_memeData != address(0), "_memeData err");
        memeData = IMemeData(_memeData);
    }

    function createNewPeriodTokenBase(
        TokenBase[] memory _tokenBase,
        address[] memory _coins,
        uint256 _coinRate
    ) external onlyAuth {
        uint256 id = ++period;
        uint256 num = ++periodAddNum[id];

        _createNewPeriodTokenBase(id, num, _tokenBase, _coins, _coinRate);
    }

    function addOrRemoveCoins(address[] memory _coins, bool isAdd) external onlyAuth {
        uint256 id = period;
        uint256 num = periodAddNum[id];

        uint256 len = _coins.length;
        uint256 len1 = coins[id][num].length();
        require(len1 > 0 && len > 0, "length err");

        if(isAdd) {
            for(uint256 i = 0; i < len; i++) {
                address token = _coins[i];
                require(!coins[id][num].contains(token), "add err");
                coins[id][num].add(token);

                _setAdd(token);

                emit AddCoin(id, num, token);
            }
        } else {
            for(uint256 i = 0; i < len; i++) {
                address token = _coins[i];
                require(coins[id][num].contains(token), "remove err");
                coins[id][num].remove(token);

                emit RemoveCoin(id, num, token);
            }       
        }
    }

    function setSingleTokenRate(
        TokenBase[] memory _tokenBase,
        uint256 _coinRate
    ) external onlyAuth {
        _setData(_tokenBase, _coinRate, false);
    }

    function reset(
        TokenBase[] memory _tokenBase,
        uint256 _coinRate
    )  external onlyAuth {
        _setData(_tokenBase, _coinRate, true);
    }

    function _setData(
        TokenBase[] memory _tokenBase,
        uint256 _coinRate,
        bool isReset
    )  internal {
        uint256 id = period;
        uint256 num = periodAddNum[id];
        uint256 num1 = num + 1;
        uint256 len = _tokenBase.length;
        uint256 len1 = periodToken[id][num].length();

        if(isReset) {
            require(len == len1 && len > 0, "length err");
        } else {
            require(len > 0 && len1 > 0, "length err");
        }

        uint256 setNum;
        uint256 _totalRate;
        for(uint256 i = 0; i < len; i++) {
            ++setNum;
            address token = _tokenBase[i].token;
            uint256 rate = _tokenBase[i].rate;

            if(isReset) {
                if(!periodToken[id][num].contains(token)) {
                    revert("reset err");
                }
            }

            if(!periodToken[id][num].contains(token)) {
                lastTime[token] = block.timestamp;
            }

            if(periodToken[id][num1].contains(token)) {
                revert("has set");
            }

            _totalRate += rate;

            tokenBase[id][num1][token] = _tokenBase[i];
            periodToken[id][num1].add(token);

            _setAdd(token);
        }

        for(uint256 i = 0; i < coins[id][num].length(); i++) {
            address token = coins[id][num].at(i);
            coins[id][num1].add(token);
        }

        if(isReset) {
            require(setNum == len1, "set err");
        }

        coninRate[id][num1] = _coinRate;
        require(baseRate == _totalRate + _coinRate, "totalRate err");

        periodAddNum[id] = num1;

        emit SetData(id, num1, _tokenBase, _coinRate);
    }

    function _createNewPeriodTokenBase(
        uint256 id, 
        uint256 num, 
        TokenBase[] memory _tokenBase,
        address[] memory _coins,
        uint256 _coinRate
    ) internal {
        uint256 len = _tokenBase.length;
        uint256 len1 = _coins.length;

        require(len > 0 || len1 > 0, "length err");

        uint256 _totalRate = _addRate(id, num, _tokenBase);
        coninRate[id][num] = _coinRate;

        for(uint256 i = 0; i < len1; i++) {
            address token = _coins[i];
            if(periodToken[id][num].contains(token) || coins[id][num].contains(token)) {
                revert("_coins err");
            }
            lastTime[token] = block.timestamp;
            coins[id][num].add(token);
            _setAdd(token);
        }
        require(baseRate == _totalRate + _coinRate, "totalRate err");
    }

    // ***************************************************
    function _addRate(
        uint256 id,
        uint256 num,
        TokenBase[] memory _tokenBase
    ) internal returns(uint256 _totalRate) {
        for(uint256 i = 0; i < _tokenBase.length; i++) {
            address token = _tokenBase[i].token;
            uint256 rate = _tokenBase[i].rate;
            if(
                periodToken[id][num].contains(token) ||
                coins[id][num].contains(token) || 
                rate == 0
            ) {
                revert("set err");
            }

            _totalRate += rate;
            tokenBase[id][num][token] = _tokenBase[i];
            lastTime[token] = block.timestamp;
            periodToken[id][num].add(token);

            _setAdd(token);
        }
    }

    function _setAdd(address token) internal {
        require(!memeData.isAddMeme(token), "is meme token");

        if(!isAddCoin[token]) {
            isAddCoin[token] = true;
        }
    }

    function getCurrRate(address token) external view returns(uint256, uint256) {
        uint256 id = period;
        uint256 num = periodAddNum[id];

        if(periodToken[id][num].contains(token)) {
            return (tokenBase[id][num][token].rate, 1);
        }

        if(coins[id][num].contains(token)) {
            return (coninRate[id][num], 2);
        }
      
        return (0,3);
    }

    function getPidNum() external view returns(uint256 id, uint256 num) {
        id = period;
        num = periodAddNum[id];
    }

    function getTokenBase(uint256 pid, uint256 num, address token) external view returns(TokenBase memory) {
        return tokenBase[pid][num][token];
    }

    function getPeriodTokenLength(uint256 pid, uint256 num) external view returns(uint256) {
        return periodToken[pid][num].length();
    }

    function getPeriodToken(uint256 pid, uint256 num, uint256 index) external view returns(address) {
        return periodToken[pid][num].at(index);
    }

    function getPeriodTokenContains(uint256 pid, uint256 num, address token) external view returns(bool) {
        return periodToken[pid][num].contains(token);
    }

    function getCoinsLength(uint256 pid, uint256 num) external view returns(uint256) {
        return coins[pid][num].length();
    }

    function getCoin(uint256 pid, uint256 num, uint256 index) external view returns(address) {
        return coins[pid][num].at(index);
    }

    function getCoinContains(uint256 pid, uint256 num, address token) external view returns(bool) {
        return coins[pid][num].contains(token);
    }

    function getSizeData(address _vault) public view returns(
        uint256 globalShortSizes,
        uint256 globalLongSizes,
        uint256 totalSize
    ) {
        uint256 id = period;
        uint256 num = periodAddNum[id];
        IVault vaultFor = IVault(_vault);
        for(uint256 i = 0; i < coins[id][num].length(); i++) {
            address token = coins[id][num].at(i);
            globalShortSizes += vaultFor.globalShortSizes(token);
            globalLongSizes += vaultFor.globalLongSizes(token);
        }
        totalSize = globalShortSizes + globalLongSizes;
    }

    /// @notice return value == 1 Indicating that it is the indexToken set in the CoinData contract or USDT address
    /// @notice return value == 2 Indicating that it is the indexToken set in the MemeFactory contract(meme token)
    function getCoinType(address token) external view returns(uint8) {
        if(isAddCoin[token] || token == usdt) {
            return 1;
        }

        if(memeData.isAddMeme(token)) {
            return 2;
        }

        return 0;
    }

    function getPoolValue(address _vault, address indexToken) external view returns(uint256, bool, bool) {
        IVault vault = IVault(_vault);
        address USDT = vault.usdt();
        if(memeData.isAddMeme(indexToken)) {
            uint256 amount = vault.poolAmounts(indexToken, USDT);
            uint256 price = IPhase(vault.phase()).getTokenPrice(USDT);
            uint256 deciCounter = 10 ** IERC20Metadata(USDT).decimals();

            return (amount * price / deciCounter, true, false);
        } else {
            IPoolDataV2 poolDataV2 = IPoolDataV2(IPhase(vault.phase()).poolDataV2());
            address pool = poolDataV2.tokenToPool(USDT);
            uint256 pid = poolDataV2.currPeriodID(pool);
            FoundStateV2 memory fState = poolDataV2.getFoundState(pool, pid);

            return (fState.fundraisingValue * 1e12, fState.isFundraise, fState.isClaim);
        }
    }
}