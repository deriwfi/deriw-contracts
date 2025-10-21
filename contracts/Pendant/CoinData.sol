// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "../core/interfaces/IERC20Metadata.sol";
import "../core/interfaces/IVault.sol";
import "../fund-pool/v2/interfaces/IPoolDataV2.sol";
import "../fund-pool/v2/interfaces/IFundFactoryV2.sol";
import "../fund-pool/v2/interfaces/IStruct.sol";
import "./interfaces/ISlippage.sol";
import "./interfaces/IPhaseStruct.sol";
import "./interfaces/IPhase.sol";
import "../meme/interfaces/IMemeData.sol";
import "../upgradeability/Synchron.sol";

/**
 * @title CoinData
 * @dev A contract for managing token data and allocations within a pool system
 * @notice This contract handles token initialization, rate allocation, and membership management
 * for both single tokens and member token groups in a pool target system
 */
contract CoinData is Synchron, IStruct, IPhaseStruct {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;


    /**
     * @dev Base rate constant used for percentage calculations (10000 = 100%)
     */
    uint256 public constant BASERATE = 10000;

    /**
     * @dev Interface for MemeData contract
     */
    IMemeData public memeData;

    /**
     * @dev Interface for PoolDataV2 contract
     */
    IPoolDataV2 public poolDataV2;

    /**
     * @dev Interface for FundFactoryV2 contract
     */
    IFundFactoryV2 public fundFactoryV2;

    /**
     * @dev Interface for Slippage contract
     */
    ISlippage public slippage;

    /**
     * @dev Interface for Vault contract
     */
    IVault public vault;

    /**
     * @dev Address of governance account
     */
    address public gov;
    /**
     * @dev Address of USDT token
     */
    address public usdt;

    /**
     * @dev Initialization status of the contract
     */
    bool public initialized;

    /**
     * @dev Mapping to track if a token is added as a main pool coin
     */
    mapping(address => bool) public isAddCoin;
    /**
     * @dev Mapping to track operator addresses and their status
     */
    mapping(address => bool) public operator;
    /**
     * @dev Mapping to store TokenInfo for each token
     */
    mapping(address => TokenInfo) tokenInfo;
    /**
     * @dev Mapping to store PoolTargetTokenInfo for each pool target token
     */
    mapping(address => PoolTargetTokenInfo) poolTargetTokenInfo;

    /**
     * @dev Struct for pool target token information
     * @param setNumber Current configuration set number
     * @param coinType Type of coin (1 for main pool token, 2 for meme pool token)
     * @param singleTokenRate Mapping of single token rates
     * @param singleTokens Set of single tokens
     * @param memberTokenTargetID Set of member token target IDs
     * @param memberTokens Nested mapping of member tokens
     * @param memberTargetTokenRate Mapping of member target token rates
     * @param currRemoveTokens Current set of tokens marked for removal
     */
    struct PoolTargetTokenInfo {
        uint256 setNumber;
        uint8 coinType;
        mapping(address => mapping(uint256 => uint256)) singleTokenRate;
        mapping(uint256 => EnumerableSet.AddressSet) singleTokens;
        mapping(uint256 => EnumerableSet.UintSet) memberTokenTargetID;
        mapping(uint256 => mapping(uint256 => EnumerableSet.AddressSet)) memberTokens;
        mapping(uint256 => mapping(uint256 => uint256)) memberTargetTokenRate;

        EnumerableSet.AddressSet currRemoveTokens;
    }

    /**
     * @dev Struct for token information
     * @param tokenToPoolTargetToken The pool target token this token belongs to
     * @param memberTokenTargetID The member token target ID (if applicable)
     * @param lastTime Last update timestamp
     * @param belongTo Belonging type (0=none, 1=single, 2=member)
     */
    struct TokenInfo {
        address tokenToPoolTargetToken;
        uint256 memberTokenTargetID;
        uint256 lastTime;
        uint8 belongTo;
    }

    /**
     * @dev Struct for member token information
     * @param memberTokens Array of member tokens
     * @param memberTokenTargetID Target ID for member tokens
     * @param memberTargetTokenRate Rate allocation for member tokens
     */
    struct MemberToken {
        address[] memberTokens;
        uint256 memberTokenTargetID;
        uint256 memberTargetTokenRate;
    }

    /**
     * @dev Struct for member rate information
     * @param memberTokenTargetID Target ID for member tokens
     * @param rate Allocation rate
     */
    struct MemberRate {
        uint256 memberTokenTargetID;
        uint256 rate;
    }

    /**
     * @dev Struct for new token information
     * @param memberTokenTargetID Target ID for new member tokens
     * @param memberTokens Array of new member tokens
     */
    struct NewToken {
        uint256 memberTokenTargetID;
        address[] memberTokens;
    }

    /**
     * @dev Emitted when an operator is added or removed
     * @param account Address of the operator
     * @param isAdd Boolean indicating if operator is being added (true) or removed (false)
     */
    event SetOperator(address account, bool isAdd);

    /**
     * @dev Emitted when a pool token is initialized
     * @param poolTargetToken Address of the pool target token
     * @param singleTokens Array of single tokens being initialized
     * @param _memberTokens Array of member tokens being initialized
     * @param isMeme Boolean indicating if this is a meme token pool
     */
    event InitializePoolToken(
        address poolTargetToken,
        TokenBase[]  singleTokens,
        MemberToken[] _memberTokens,
        bool isMeme
    );

    /**
     * @dev Emitted when token information is updated
     * @param poolTargetToken Address of the pool target token
     * @param token Address of the token being updated
     * @param memberTokenTargetID Member token target ID (if applicable)
     * @param lastTime Timestamp of the update
     * @param belongTo Belonging type (0=none, 1=single, 2=member)
     * @param isMeme Boolean indicating if this is a meme token
     */
    event Update(
        address poolTargetToken, 
        address token,
        uint256 memberTokenTargetID,
        uint256 lastTime,
        uint8 belongTo,
        bool isMeme
    );

    /**
     * @dev Emitted when token rates are allocated
     * @param poolTargetToken Address of the pool target token
     * @param singleTokens Array of single tokens with their rates
     * @param memberTargetTokenRate Array of member token rates
     * @param isSingleReset Boolean indicating if single tokens are being reset. true:reset，false:add on to the original basis
     * @param isMemberReset Boolean indicating if member tokens are being reset. true:reset，false:add on to the original basis
     */
    event AllocateTokenRate(
        address poolTargetToken,
        TokenBase[] singleTokens,
        MemberRate[] memberTargetTokenRate,
        bool isSingleReset,
        bool isMemberReset
    );

    /**
     * @dev Emitted when new member tokens are added
     * @param poolTargetToken Address of the pool target token
     * @param newMemberTokensTokens Array of new member tokens being added
     */
    event AddMemberTokens(
        address poolTargetToken,
        NewToken[] newMemberTokensTokens
    );

    /**
     * @dev Emitted when tokens are removed
     * @param poolTargetToken Address of the pool target token
     * @param removeSingleTokens Array of single tokens being removed
     * @param removeMemberTokens Array of member tokens being removed
     * @param removeMemberTokenTargetIDs Array of member token target IDs being removed
     */
    event RemoveTokens(
        address poolTargetToken,
        address[] removeSingleTokens,
        address[] removeMemberTokens,
        uint256[] removeMemberTokenTargetIDs
    );


    /**
     * @dev Emitted when tokens are reallocated between single and member token groups
     * @notice This event logs the movement of tokens between different categories (single to member, member to single, and member to member)
     * @param poolTargetToken The address of the pool target token being modified
     * @param memberTokenToSingleToken Array of member tokens being converted to single tokens
     * @param singleTokenToMemberToken Array of single tokens being converted to member tokens (with their new target group IDs)
     * @param memberTokenToMemberToken Array of member tokens being moved between member groups
     */
    event ReallocateTokenLocation(
        address poolTargetToken,
        address[] memberTokenToSingleToken,
        NewToken[] singleTokenToMemberToken,
        NewToken[] memberTokenToMemberToken
    );

    constructor() {
        initialized = true;
    }

    /**
     * @dev Modifier to restrict access to governance only
     */
    modifier onlyGov() {
        require(gov == msg.sender, "gov err");
        _;
    }

    /**
     * @dev Modifier to restrict access to authorized accounts (governance or operators)
     */
    modifier onlyAuth() {
        require(gov == msg.sender || operator[msg.sender], "no permission");
        _;
    }

    /**
     * @dev Modifier to ensure pool token is initialized
     * @param _poolTargetToken Address of the pool target token to check
     */
    modifier onlyInitializePoolToken(address _poolTargetToken) {
        require(getPoolTargetTokenInfoSetNum(_poolTargetToken) > 0, "not initialize");
        _;
    }

    /**
     * @notice Initializes the contract with USDT address
     * @dev Can only be called once, sets the initial governance to the sender
     * @param _usdt Address of the USDT token
     */
    function initialize(address _usdt) external {
        require(!initialized, "has initialized");
        require(_usdt != address(0), "addr err");

        initialized = true;

        usdt = _usdt;
        gov = msg.sender;
    }

    /**
     * @notice Sets the governance address
     * @dev Only callable by current governance
     * @param account Address of the new governance account
     */
    function setGov(address account) external onlyGov {
        require(account != address(0), "account err");
        gov = account;
    }

    /**
     * @notice Adds or removes an operator
     * @dev Only callable by governance
     * @param account Address of the operator
     * @param isAdd Boolean indicating if operator is being added (true) or removed (false)
     */
    function setOperator(address account, bool isAdd) external onlyGov {
        require(account != address(0), "account err");

        operator[account] = isAdd;

        emit SetOperator(account, isAdd);
    }

    /**
     * @notice Sets the required contract interfaces
     * @dev Only callable by governance
     * @param _memeData Address of MemeData contract
     * @param _poolDataV2 Address of PoolDataV2 contract
     * @param _fundFactoryV2 Address of FundFactoryV2 contract
     * @param _slippage Address of Slippage contract
     * @param _vault Address of Vault contract
     */
    function setContract(
        address _memeData, 
        address _poolDataV2,
        address _fundFactoryV2,
        address _slippage,
        address _vault
    ) external onlyGov {
        require(
            _memeData != address(0) && 
            _poolDataV2 != address(0) &&
            _fundFactoryV2 != address(0) &&
            _slippage != address(0) &&
            _vault != address(0),  
            "addr err"
        );
        memeData = IMemeData(_memeData);
        poolDataV2 = IPoolDataV2(_poolDataV2);
        fundFactoryV2 = IFundFactoryV2(_fundFactoryV2);
        slippage = ISlippage(_slippage);
        vault = IVault(_vault);
    }

    /**
     * @notice Initializes a pool token with single and member tokens
     * @dev Only callable by authorized accounts
     * @param _poolTargetToken Address of the pool target token
     * @param _singleTokens Array of single tokens to initialize
     * @param _memberTokens Array of member tokens to initialize
     * @param isMeme Boolean indicating if this is a meme token pool or main token pool
     */
    function initializePoolToken(
        address _poolTargetToken,
        TokenBase[] memory _singleTokens,
        MemberToken[] memory _memberTokens,
        bool isMeme
    ) external onlyAuth {
        require(getPoolTargetTokenInfoSetNum(_poolTargetToken) == 0, "has initialize");
        if(isMeme) {
            require(memeData.isTokenCreate(_poolTargetToken), "meme token pool not create");
            poolTargetTokenInfo[_poolTargetToken].coinType = 2;
        } else {
            require(fundFactoryV2.isTokenCreate(_poolTargetToken), "token pool not create");
            poolTargetTokenInfo[_poolTargetToken].coinType = 1;
        }

        uint256 _num = ++poolTargetTokenInfo[_poolTargetToken].setNumber;  
        _initializePoolToken(_num, _poolTargetToken, _singleTokens, _memberTokens);

        emit InitializePoolToken(_poolTargetToken, _singleTokens, _memberTokens, isMeme);
    } 

    /**
     * @notice Allocates token rates for single and member tokens
     * @dev Only callable by authorized accounts for initialized pool tokens
     * @param _poolTargetToken Address of the pool target token
     * @param _singleTokens Array of single tokens with their rates
     * @param _memberTargetTokenRate Array of member token rates
     * @param _isSingleReset Boolean indicating if single tokens are being reset. true:reset，false:add on to the original basis
     * @param _isMemberReset Boolean indicating if member tokens are being reset. true:reset，false:add on to the original basis
     */
    function allocateTokenRate(
        address _poolTargetToken,
        TokenBase[] memory _singleTokens,
        MemberRate[] memory _memberTargetTokenRate,
        bool _isSingleReset,
        bool _isMemberReset
    ) public onlyAuth onlyInitializePoolToken(_poolTargetToken) {
        _setData(_poolTargetToken, _singleTokens, _memberTargetTokenRate, _isSingleReset, _isMemberReset, false);

        emit AllocateTokenRate(_poolTargetToken, _singleTokens, _memberTargetTokenRate, _isSingleReset, _isMemberReset);
    }

    /**
     * @notice Add the new member token to the pool's collection coins
     * @dev Only callable by authorized accounts for initialized pool tokens
     * @param _poolTargetToken Address of the pool target token
     * @param _newMemberTokens Array of new member tokens to add
     */
    function addMemberTokens(
        address _poolTargetToken,
        NewToken[] memory _newMemberTokens
    ) external onlyAuth onlyInitializePoolToken(_poolTargetToken) {
        uint256 _len = _newMemberTokens.length;
        require(_len > 0, "length err");

        for(uint256 i = 0; i < _len; i++) {
            NewToken memory _nToken = _newMemberTokens[i];
    
            uint256 _num = getPoolTargetTokenInfoSetNum(_poolTargetToken);

            require(
                _getMemberTokenTargetIDIsIn(_poolTargetToken, _num, _nToken.memberTokenTargetID),
                "memberTokenTargetID err"
            );
            
            uint256 _lenMemberTokens = _nToken.memberTokens.length;
            for(uint256 j = 0; j < _lenMemberTokens; j++) {
                _addMemberTokenFor(_num, _nToken.memberTokenTargetID, _poolTargetToken, _nToken.memberTokens[j]);
            }
        }
        emit AddMemberTokens(_poolTargetToken, _newMemberTokens);
    }

    /**
     * @notice Removes tokens and allocates new rates in a single transaction
     * @dev Only callable by authorized accounts for initialized pool tokens
     * @param _poolTargetToken Address of the pool target token
     * @param _removeSingleTokens Array of single tokens to remove
     * @param _removeMemberTokens Array of member tokens to remove
     * @param _removeMemberTokenTargetIDs Array of member token target IDs to remove
     * @param _singleTokens Array of single tokens with new rates
     * @param _memberTargetTokenRate Array of member token rates
     * @param _isSingleReset Boolean indicating if single tokens are being reset. true:reset，false:add on to the original basis
     * @param _isMemberReset Boolean indicating if member tokens are being reset. true:reset，false:add on to the original basis
     */
    function removeAndAllocateTokenRate(
        address _poolTargetToken,
        address[] memory _removeSingleTokens,
        address[] memory _removeMemberTokens,
        uint256[] memory _removeMemberTokenTargetIDs,
        TokenBase[] memory _singleTokens,
        MemberRate[] memory _memberTargetTokenRate,
        bool _isSingleReset,
        bool _isMemberReset
    )  external onlyAuth onlyInitializePoolToken(_poolTargetToken) {
        uint256 _num = getPoolTargetTokenInfoSetNum(_poolTargetToken);  
        
        uint256 _len = _removeSingleToken(_poolTargetToken, _removeSingleTokens, _num);
        _removeMemberToken(_poolTargetToken, _removeMemberTokens, _num);
        _len += _removeMemberTokenTargetID(_poolTargetToken, _removeMemberTokenTargetIDs, _num);
        
        emit RemoveTokens(_poolTargetToken, _removeSingleTokens, _removeMemberTokens, _removeMemberTokenTargetIDs);
        
        if(_len > 0) {
            allocateTokenRate(_poolTargetToken, _singleTokens, _memberTargetTokenRate, _isSingleReset, _isMemberReset);
        }
    }

    /**
     * @notice Reallocates tokens between single and member token groups
     * @dev Only callable by authorized accounts for initialized pool tokens
     * @param _poolTargetToken Address of the pool target token
     * @param _memberTokenToSingleToken Array of member tokens to convert to single tokens
     * @param _singleTokenToMemberToken Array of single tokens to convert to member tokens
     * @param _memberTokenToMemberToken Array of member tokens to move between member groups
     * @param _singleTokens Array of single tokens with updated rates
     * @param _memberTargetTokenRate Array of member token target rates
     */
    function reallocateTokenLocation(
        address _poolTargetToken,
        address[] memory _memberTokenToSingleToken,
        NewToken[] memory _singleTokenToMemberToken,
        NewToken[] memory _memberTokenToMemberToken,
        TokenBase[] memory _singleTokens,
        MemberRate[] memory _memberTargetTokenRate
    ) external onlyAuth onlyInitializePoolToken(_poolTargetToken) {
        uint256 _num = getPoolTargetTokenInfoSetNum(_poolTargetToken);

        uint256 _memberTokenToSingleTokenNum = _dealMemberTokenToSingleToken(_poolTargetToken, _memberTokenToSingleToken, _num);
        uint256 _singleTokenToMemberTokenNum = _dealSingleTokenToMemberToken(_poolTargetToken, _singleTokenToMemberToken, _num);
        _dealMemberTokenToMemberToken(_poolTargetToken, _memberTokenToMemberToken, _num);

        emit ReallocateTokenLocation(_poolTargetToken, _memberTokenToSingleToken, _singleTokenToMemberToken, _memberTokenToMemberToken);
        
        if(_memberTokenToSingleTokenNum + _singleTokenToMemberTokenNum > 0) {
            _setData(_poolTargetToken, _singleTokens, _memberTargetTokenRate, true, true, true);
        }
    }

    /**
     * @dev Internal function to move member tokens between member groups
     * @param _poolTargetToken Address of the pool target token
     * @param _memberTokenToMemberToken Array of member tokens to move between groups
     * @param _num Current set number
     */
    function _dealMemberTokenToMemberToken(
        address _poolTargetToken,
        NewToken[] memory _memberTokenToMemberToken,
        uint256 _num
    ) internal {
        uint256 _lenMemberTokenToMemberToken = _memberTokenToMemberToken.length;
        {
            for(uint256 i = 0; i < _lenMemberTokenToMemberToken; i++) {
                uint256 _memberTokenTargetID = _memberTokenToMemberToken[i].memberTokenTargetID;
                require(_memberTokenTargetID != 0 && _getMemberTokenTargetIDIsIn(_poolTargetToken, _num, _memberTokenTargetID), "move _memberTokenToMemberToken err");
                uint256 _lenToken = _memberTokenToMemberToken[i].memberTokens.length;
                for(uint256 j = 0; j < _lenToken; j++) {
                    address _token = _memberTokenToMemberToken[i].memberTokens[j];
                    require(
                        tokenInfo[_token].belongTo == 2 && 
                        tokenInfo[_token].tokenToPoolTargetToken == _poolTargetToken, 
                        "_memberTokenToMemberToken err"
                    );
                    uint256 _memberTokenTargetIDFor = tokenInfo[_token].memberTokenTargetID;
                    require(_memberTokenTargetIDFor != _memberTokenTargetID, "move err");
                    poolTargetTokenInfo[_poolTargetToken].memberTokens[_memberTokenTargetIDFor][_num].remove(_token);
                    poolTargetTokenInfo[_poolTargetToken].memberTokens[_memberTokenTargetID][_num].add(_token);
                    _updateToken(_token, _memberTokenTargetID, 2);
                }
            }
        }
    }

    /**
     * @dev Internal function to convert single tokens to member tokens
     * @param _poolTargetToken Address of the pool target token
     * @param _singleTokenToMemberToken Array of single tokens to convert to member tokens
     * @param _num Current set number
     * @return _singleTokenToMemberTokenNum Count of converted tokens
     */
    function _dealSingleTokenToMemberToken(
        address _poolTargetToken,
        NewToken[] memory _singleTokenToMemberToken,
        uint256 _num
    ) internal returns(uint256 _singleTokenToMemberTokenNum) {
        uint256 _lenSingleTokenToMemberToken = _singleTokenToMemberToken.length;
        {
            for(uint256 i = 0; i < _lenSingleTokenToMemberToken; i++) {
                uint256 _memberTokenTargetID = _singleTokenToMemberToken[i].memberTokenTargetID;
                require(_memberTokenTargetID != 0 && _getMemberTokenTargetIDIsIn(_poolTargetToken, _num, _memberTokenTargetID), "move _singleTokenToMemberToken err");
                uint256 _lenToken = _singleTokenToMemberToken[i].memberTokens.length;
                for(uint256 j = 0; j < _lenToken; j++) {
                    address _token = _singleTokenToMemberToken[i].memberTokens[j];
                    require(
                        tokenInfo[_token].belongTo == 1 && 
                        tokenInfo[_token].tokenToPoolTargetToken == _poolTargetToken, 
                        "_singleTokenToMemberToken err"
                    );
                    poolTargetTokenInfo[_poolTargetToken].singleTokens[_num].remove(_token);
                    poolTargetTokenInfo[_poolTargetToken].memberTokens[_memberTokenTargetID][_num].add(_token);
                    _updateToken(_token, _memberTokenTargetID, 2);
                    ++_singleTokenToMemberTokenNum;
                }
            }
        }

    }

    /**
     * @dev Internal function to convert member tokens to single tokens
     * @param _poolTargetToken Address of the pool target token
     * @param _memberTokenToSingleToken Array of member tokens to convert to single tokens
     * @param _num Current set number
     * @return _memberTokenToSingleTokenNum Count of converted tokens
     */
    function _dealMemberTokenToSingleToken(
        address _poolTargetToken,
        address[] memory _memberTokenToSingleToken,
        uint256 _num
    ) internal returns(uint256 _memberTokenToSingleTokenNum) {
        uint256 _lenMemberTokenToSingleToken = _memberTokenToSingleToken.length;
        {
            for(uint256 i = 0; i < _lenMemberTokenToSingleToken; i++) {
                address _token = _memberTokenToSingleToken[i];
                require(
                    tokenInfo[_token].belongTo == 2 && 
                    tokenInfo[_token].tokenToPoolTargetToken == _poolTargetToken, 
                    "_memberTokenToSingleToken err"
                );
                uint256 _memberTokenTargetID = tokenInfo[_token].memberTokenTargetID;
                poolTargetTokenInfo[_poolTargetToken].memberTokens[_memberTokenTargetID][_num].remove(_token);
                poolTargetTokenInfo[_poolTargetToken].singleTokens[_num].add(_token);
                _updateToken(_token, 0, 1);
                ++_memberTokenToSingleTokenNum;
            }
        }
    }


    /**
     * @dev Internal function to initialize pool token
     * @param _num Current set number
     * @param _poolTargetToken Address of the pool target token
     * @param _singleTokens Array of single tokens
     * @param _memberTokens Array of member tokens
     */
    function _initializePoolToken(
        uint256 _num, 
        address _poolTargetToken,
        TokenBase[] memory _singleTokens,
        MemberToken[] memory _memberTokens
    ) internal {
        uint256 len = _singleTokens.length;
        uint256 len1 = _memberTokens.length;

        uint256 _totalRate;
        if(len > 0) {
            _totalRate = _addSingleToken(_num, _poolTargetToken, _singleTokens);
        }

        if(len1 > 0) {
            for(uint256 i = 0; i < len1; i++) {
                MemberToken memory _memberToken = _memberTokens[i];
                _addMemberToken(_num, _poolTargetToken, _memberToken);

                _totalRate += _memberToken.memberTargetTokenRate;
            }
        }

        require(BASERATE == _totalRate, "totalRate err");
    }


    /**
     * @dev Internal function to add member token
     * @param _num Current set number
     * @param _poolTargetToken Address of the pool target token
     * @param _memberToken Member token information
     */
    function _addMemberToken(
        uint256 _num, 
        address _poolTargetToken, 
        MemberToken memory _memberToken
    ) internal {
        uint256 _len = _memberToken.memberTokens.length;
        uint256 _memberTokenTargetID = _memberToken.memberTokenTargetID;
        
        require(
            !_getMemberTokenTargetIDIsIn(_poolTargetToken, _num, _memberTokenTargetID) && 
            _memberToken.memberTargetTokenRate > 0, 
            "has add memberTokenTargetID"
        );
        poolTargetTokenInfo[_poolTargetToken].memberTokenTargetID[_num].add(_memberTokenTargetID);
        poolTargetTokenInfo[_poolTargetToken].memberTargetTokenRate[_memberTokenTargetID][_num] = _memberToken.memberTargetTokenRate;

        for(uint256 i = 0; i < _len; i++) {
            _addMemberTokenFor(_num, _memberToken.memberTokenTargetID, _poolTargetToken, _memberToken.memberTokens[i]);
        }
    }


    /**
     * @dev Internal function to add single token
     * @param _num Current set number
     * @param _poolTargetToken Address of the pool target token
     * @param _singleTokens Array of single tokens
     * @return _totalRate Total rate after adding single tokens
     */
    function _addSingleToken(
        uint256 _num,
        address _poolTargetToken, 
        TokenBase[] memory _singleTokens
    ) internal returns(uint256 _totalRate) {
        uint256 _len = _singleTokens.length;
        for(uint256 i = 0; i < _len; i++) {
            address _token = _singleTokens[i].token;
            uint256 _rate = _singleTokens[i].rate;
            require(_rate > 0, "_addSingleToken rate err");

            _totalRate += _rate;
            poolTargetTokenInfo[_poolTargetToken].singleTokenRate[_token][_num] = _rate;
            poolTargetTokenInfo[_poolTargetToken].singleTokens[_num].add(_token);

            _update(_poolTargetToken, _token, 0, 1, false);
        }
    }

    /**
     * @dev Internal function to update token information
     * @param _poolTargetToken Address of the pool target token
     * @param _token Token address being updated
     * @param _memberTokenTargetID ID of member token target
     * @param _belongTo Belonging type (1 for single, 2 for member)
     * @param _isReallocateInterface Is it calling reallocateTokenLocation interface
     */
    function _update(
        address _poolTargetToken, 
        address _token,
        uint256 _memberTokenTargetID,
        uint8 _belongTo,
        bool _isReallocateInterface
    ) internal {
        {
            validateToken(_poolTargetToken, _token, _isReallocateInterface);

            poolTargetTokenInfo[_poolTargetToken].currRemoveTokens.remove(_token);
            uint8 _coinType = poolTargetTokenInfo[_poolTargetToken].coinType;

            if(_coinType == 1) {
                if(!isAddCoin[_token]) {
                    isAddCoin[_token] = true;
                }
            }

            if(_coinType == 2) {
                if(!memeData.isAddMeme(_token)) {
                    memeData.addMemeState(_token);
                }
            }
        }

        {
            tokenInfo[_token].tokenToPoolTargetToken = _poolTargetToken;
            tokenInfo[_token].lastTime = block.timestamp;
            _updateToken(_token, _memberTokenTargetID, _belongTo);
        }

        emit Update(_poolTargetToken, _token, _memberTokenTargetID, tokenInfo[_token].lastTime, _belongTo, memeData.isAddMeme(_token));
    }


    function _updateToken(
        address _token,
        uint256 _memberTokenTargetID,
        uint8 _belongTo
    ) internal {
        tokenInfo[_token].memberTokenTargetID = _memberTokenTargetID;
        tokenInfo[_token].belongTo = _belongTo;
    }


    /**
     * @dev Internal function to set token data including rates
     * @param _poolTargetToken Address of the pool target token
     * @param _singleTokens Array of single tokens
     * @param _memberTargetTokenRate Array of member token target rates
     * @param _isSingleReset Boolean indicating if single tokens are reset. true:reset，false:add on to the original basis
     * @param _isMemberReset Boolean indicating if member tokens are reset. true:reset，false:add on to the original basis
     * @param _isReallocateInterface Is it calling reallocateTokenLocation interface
     */
    function _setData(
        address _poolTargetToken,
        TokenBase[] memory _singleTokens,
        MemberRate[] memory _memberTargetTokenRate,
        bool _isSingleReset,
        bool _isMemberReset,
        bool _isReallocateInterface
    )  internal {
        {
            uint256 _totalRate = _setSingleTokenRate(_poolTargetToken, _singleTokens, _isSingleReset, _isReallocateInterface);
            _totalRate += _setMemberTargetTokenRate(_poolTargetToken, _memberTargetTokenRate, _isMemberReset);

            require(BASERATE == _totalRate, "totalRate err");

            ++poolTargetTokenInfo[_poolTargetToken].setNumber;
        }
    }

    /**
     * @dev Internal function to set single token rates
     * @param _poolTargetToken Address of the pool target token
     * @param _singleTokens Array of single tokens
     * @param _isSingleReset Boolean indicating if single tokens are reset. true:reset，false:add on to the original basis
     * @param _isReallocateInterface Is it calling reallocateTokenLocation interface
     * @return _totalRate Total rate after setting single tokens
     */
    function _setSingleTokenRate(     
        address _poolTargetToken,
        TokenBase[] memory _singleTokens,
        bool _isSingleReset,
        bool _isReallocateInterface
    ) internal returns(uint256 _totalRate) {
        uint256 _lenSingleToken1 =  _singleTokens.length;

        uint256 _setNum;
        uint256 _usedNum;
        uint256 _num = getPoolTargetTokenInfoSetNum(_poolTargetToken);
        uint256 _num1 = _num + 1;
        address _pToken = _poolTargetToken;
        bool _isReallocate = _isReallocateInterface;
        {
            for(uint256 i = 0; i < _lenSingleToken1; i++) {
                ++_setNum;
                address _token = _singleTokens[i].token;
                uint256 _rate = _singleTokens[i].rate;

                bool _isSingle = _getSingleTokenIsIn(_token, _pToken, _num);
                if(_isSingleReset) {
                    require(_isSingle, "single token err");
                } else {
                    if(!_isSingle) {
                        _update(_pToken, _token, 0, 1, _isReallocate);
                    } else {
                        ++_usedNum;
                    }
                }

                require(_rate > 0, "rate err");

                if(_getSingleTokenIsIn(_token, _pToken, _num1)) {
                    revert("already reset");
                }

                _totalRate += _rate;
                poolTargetTokenInfo[_pToken].singleTokenRate[_token][_num1] = _rate;
                poolTargetTokenInfo[_pToken].singleTokens[_num1].add(_token);
            }
        }
        {
            uint256 _lenSingleToken = _getSingleTokensLength(_poolTargetToken, _num);
            if(_isSingleReset) {
                require(_setNum == _lenSingleToken, "single token rate reset err");
            } else {
                require(_setNum > _lenSingleToken && _usedNum == _lenSingleToken, "single token rate add err");
            }
        }

    }

    /**
     * @dev Internal function to set member token target rates
     * @param _poolTargetToken Address of the pool target token
     * @param _memberTargetTokenRate Array of member token target rates
     * @param _isMemberReset Boolean indicating if member tokens are reset. true:reset，false:add on to the original basis
     * @return _totalRate Total rate after setting member tokens
     */
    function _setMemberTargetTokenRate(       
        address _poolTargetToken,
        MemberRate[] memory _memberTargetTokenRate,
        bool _isMemberReset
    ) internal returns(uint256 _totalRate) {
        uint256 _lenMemberToken1 = _memberTargetTokenRate.length;

        uint256 _setNum;
        uint256 _usedNum;
        uint256 _num = getPoolTargetTokenInfoSetNum(_poolTargetToken);
        uint256 _num1 = _num + 1;
        address _pToken = _poolTargetToken;
        {
            for(uint256 i = 0; i < _lenMemberToken1; i++) {
                ++_setNum;
                uint256 _memberTokenTargetID = _memberTargetTokenRate[i].memberTokenTargetID;
                uint256 _rate = _memberTargetTokenRate[i].rate;

                bool _isMemberID = _getMemberTokenTargetIDIsIn(_poolTargetToken, _num, _memberTokenTargetID);
                if(_isMemberReset) {
                    require(_isMemberID, "member token err");            
                } else {
                    require(_memberTokenTargetID != 0, "_memberTokenTargetID err");
                    if(_isMemberID) {
                        ++_usedNum;
                    }
                }

                require(_rate > 0, "member target token rate err");
                if(_getMemberTokenTargetIDIsIn(_poolTargetToken, _num1, _memberTokenTargetID)) {
                    revert("member target token already reset");
                }

                _totalRate += _rate;
                poolTargetTokenInfo[_pToken].memberTargetTokenRate[_memberTokenTargetID][_num1] = _rate;
                poolTargetTokenInfo[_pToken].memberTokenTargetID[_num1].add(_memberTokenTargetID);
                _addMemberTokenToNew(_poolTargetToken, _memberTokenTargetID, _num, _num1);
            }

            uint256 _lenMemberToken = _getMemberTokenTargetIDLength(_pToken, _num);
            if(_isMemberReset) {
                require(_setNum == _lenMemberToken, "target token rate reset err");
            } else {
                require(_setNum > _lenMemberToken && _usedNum == _lenMemberToken, "target token rate add err");
            }
        }
    }

    function _addMemberTokenToNew(
        address _poolTargetToken,
        uint256 _memberTokenTargetID,
        uint256 _num,
        uint256 _num1
    ) internal {
        uint256 _len = _getMemberTokensLength(_poolTargetToken, _num, _memberTokenTargetID);
        if(_len > 0) {
            for(uint256 i = 0; i < _len; i++) {
                address _token = poolTargetTokenInfo[_poolTargetToken].memberTokens[_memberTokenTargetID][_num].at(i);
                poolTargetTokenInfo[_poolTargetToken].memberTokens[_memberTokenTargetID][_num1].add(_token);
            }
        }
    }

    /**
     * @dev Internal function to add member token
     * @param _num Current set number
     * @param _memberTokenTargetID ID of member token target
     * @param _poolTargetToken Address of the pool target token
     * @param _memberToken Member token address
     */
    function _addMemberTokenFor(
        uint256 _num, 
        uint256 _memberTokenTargetID,
        address _poolTargetToken, 
        address _memberToken
    ) internal {
        _update(_poolTargetToken, _memberToken, _memberTokenTargetID, 2, false);

        poolTargetTokenInfo[_poolTargetToken].memberTokens[_memberTokenTargetID][_num].add(_memberToken);
    }


    /**
     * @dev Internal function to remove member token target ID
     * @param _poolTargetToken Address of the pool target token
     * @param _removeMemberTokenTargetIDs Array of member token target IDs to remove
     * @param _num Current set number
     * @return Number of removed member token target IDs
     */
    function _removeMemberTokenTargetID(        
        address _poolTargetToken,
        uint256[] memory _removeMemberTokenTargetIDs,
        uint256 _num
    ) internal returns(uint256)  {
        uint256 _len = _removeMemberTokenTargetIDs.length;
        
        for(uint256 i = 0; i < _len; i++) {
            uint256 _memberTokenTargetID = _removeMemberTokenTargetIDs[i];
            require(
                _getMemberTokenTargetIDIsIn(_poolTargetToken, _num, _memberTokenTargetID) &&
                _getMemberTokensLength(_poolTargetToken, _num, _memberTokenTargetID) == 0,
                "_removeMemberTokenTargetID err"
            );
        
            poolTargetTokenInfo[_poolTargetToken].memberTokenTargetID[_num].remove(_memberTokenTargetID);
        }

        return _len;
    }


    /**
     * @dev Internal function to remove member token
     * @param _poolTargetToken Address of the pool target token
     * @param removeMemberTokens Array of member tokens to remove
     * @param _num Current set number
     */
    function _removeMemberToken(        
        address _poolTargetToken,
        address[] memory removeMemberTokens,
        uint256 _num
    ) internal {
        uint256 _len = removeMemberTokens.length;
        for(uint256 i = 0; i < _len; i++) {
            address _token = removeMemberTokens[i];
            uint256 _memberTokenTargetID = tokenInfo[_token].memberTokenTargetID;
            
            require(
                tokenInfo[_token].tokenToPoolTargetToken == _poolTargetToken &&
                _memberTokenTargetID != 0 &&
                _getMemberTokenIsIn(_token, _poolTargetToken, _num, _memberTokenTargetID) &&
                validateRemoveTime(_token),
                "_removeMemberToken err"
            );
            validateAllDecreasePosition(_token);
            
            poolTargetTokenInfo[_poolTargetToken].memberTokens[_memberTokenTargetID][_num].remove(_token);
            tokenInfo[_token].memberTokenTargetID = 0;
            _addRemoveTokens(_poolTargetToken, _token);
        }
    }

    /**
     * @dev Internal function to remove single token
     * @param _poolTargetToken Address of the pool target token
     * @param removeSingleTokens Array of single tokens to remove
     * @param _num Current set number
     * @return Number of removed single tokens
     */
    function _removeSingleToken(        
        address _poolTargetToken,
        address[] memory removeSingleTokens,
        uint256 _num
    ) internal returns(uint256) {
        uint256 _len = removeSingleTokens.length;
        
        for(uint256 i = 0; i < _len; i++) {
            address _token = removeSingleTokens[i];
            require(
                _getSingleTokenIsIn(_token, _poolTargetToken, _num) &&
                validateRemoveTime(_token),
                "_removeSingleToken err"
            );
            validateAllDecreasePosition(_token);
            poolTargetTokenInfo[_poolTargetToken].singleTokens[_num].remove(_token);
            poolTargetTokenInfo[_poolTargetToken].singleTokenRate[_token][_num] = 0;
            _addRemoveTokens(_poolTargetToken, _token);
            
        }
        return _len;
    }

    /**
     * @dev Internal function to add token to remove list
     * @param _poolTargetToken Address of the pool target token
     * @param _token Token address to remove
     */
    function _addRemoveTokens(address _poolTargetToken, address _token) internal {
        poolTargetTokenInfo[_poolTargetToken].currRemoveTokens.add(_token);
        tokenInfo[_token].belongTo = 0;
    }

    // *********************************************************
    /**
     * @notice Validates if all positions for a token are decreased
     * @param _token Token address to validate
     * @return True if all positions are decreased
    */
    function validateAllDecreasePosition(address _token) public view returns(bool) {
        require(
            vault.globalShortSizes(_token) == 0 && 
            vault.globalLongSizes(_token) == 0,
            "decreasePosition err"
        );

        return true;
    }

    /**
     * @notice Validates if token can be removed based on time
     * @param _token Token address to validate
     * @return True if token can be removed
     */
    function validateRemoveTime(address _token) public view returns(bool) {
        uint256 endTime = slippage.getEndTime(_token);
        require(endTime <= block.timestamp && endTime != 0, "time err");

        return true;
    }

    /**
     * @notice Verify if the token has been whitewashed and not the stable token
     * @param _poolTargetToken Address of the pool target token
     * @param _token Token address to validate
     * @param _isReallocateInterface Is it calling reallocateTokenLocation interface
     * @return True if token is valid
     */
    function validateToken(address _poolTargetToken, address _token, bool _isReallocateInterface) public view returns(bool) {
        address _pToken = getTokenToPoolTargetToken(_token);
        if(_isReallocateInterface) {
            require(_pToken == _poolTargetToken && tokenInfo[_token].belongTo != 0, "belongTo err");
        } else {
            require(
                _pToken == address(0) || 
                (_pToken == _poolTargetToken && getCurrRemoveTokenIsIn(_poolTargetToken, _token)), 
                "_poolTargetToken err"
            );
        }

        require(vault.whitelistedTokens(_token) && !vault.stableTokens(_token), "_token err");

        return true;
    }

    /**
     * @notice Checks if token can be removed
     * @param token Token address to check
     * @return True if token can be removed
     */
    function getTokenIsCanRemove(address token) external view returns(bool) {
        if(
            tokenInfo[token].tokenToPoolTargetToken != address(0) && 
            tokenInfo[token].belongTo != 0
        ) {
            return true;
        }
        return false;
    }

    /**
     * @notice Gets token information
     * @param _token Token address
     * @return poolTargetToken Address of the pool target token
     * @return memberTokenTargetID ID of member token target
     * @return lastTime Last update time
     * @return belongTo Belonging type (1 for single, 2 for member)
     */
    function getTokenInfo(
        address _token
    ) public view returns(address, uint256, uint256, uint8) {
        return (
            tokenInfo[_token].tokenToPoolTargetToken,
            tokenInfo[_token].memberTokenTargetID,
            tokenInfo[_token].lastTime,
            tokenInfo[_token].belongTo
        );
    }


    /**
     * @notice Gets size data for index token
     * @param _indexToken Index token address
     * @return globalShortSizes Total short sizes
     * @return globalLongSizes Total long sizes
     * @return totalSize Total sizes (short + long)
     */
    function getSizeData(address _indexToken) public view returns(
        uint256 globalShortSizes,
        uint256 globalLongSizes,
        uint256 totalSize
    ) {
        address _poolTargetToken = tokenInfo[_indexToken].tokenToPoolTargetToken;
        uint8 _belongTo = tokenInfo[_indexToken].belongTo;
        if(_belongTo == 1) {
            globalShortSizes = vault.globalShortSizes(_indexToken);
            globalLongSizes = vault.globalLongSizes(_indexToken);
            totalSize = globalShortSizes + globalLongSizes;
        }

        if(_belongTo == 2) {
            uint256 _num = getPoolTargetTokenInfoSetNum(_poolTargetToken); 
            uint256 _memberTokenTargetID = tokenInfo[_indexToken].memberTokenTargetID;
            
            uint256 _len = _getMemberTokensLength(_poolTargetToken, _num, _memberTokenTargetID);
            for(uint256 i = 0; i < _len; i++) {
                address token = _getMemberToken(_poolTargetToken, _num, _memberTokenTargetID, i);

                globalShortSizes += vault.globalShortSizes(token);
                globalLongSizes += vault.globalLongSizes(token);
            }
            totalSize = globalShortSizes + globalLongSizes;
        }
    } 

    /**
     * @notice Gets the pool value for an index token
     * @param indexToken The address of the index token
     * @return poolValue The calculated pool value
     * @return isMeme Boolean indicating if token is a meme token
     * @return isFundraise Boolean indicating if token is in fundraising state
     */
    function getPoolValue(address indexToken) external view returns(uint256, bool, bool) {
        if(memeData.isAddMeme(indexToken)) {
            address _poolTargetToken = tokenInfo[indexToken].tokenToPoolTargetToken;

            uint256 amount = vault.poolAmounts(_poolTargetToken, usdt);
            uint256 price = IPhase(vault.phase()).getTokenPrice(usdt);
            uint256 deciCounter = 10 ** IERC20Metadata(usdt).decimals();

            return (amount * price / deciCounter, true, false);
        } else {
            address pool = poolDataV2.tokenToPool(usdt);
            uint256 pid = poolDataV2.currPeriodID(pool);
            FoundStateV2 memory fState = poolDataV2.getFoundState(pool, pid);

            return (fState.fundraisingValue * 1e12, fState.isFundraise, fState.isClaim);
        }
    }

    /**
     * @notice Gets the current rate for a token
     * @param token The address of the token
     * @return rate The current rate of the token
     * @return tokenType The type of token (1 for single, 2 for member，3 for none)
     */
    function getCurrRate(address token) external view returns(uint256, uint256) {        
        address _poolTargetToken = tokenInfo[token].tokenToPoolTargetToken;
        uint8 _belongTo = tokenInfo[token].belongTo;
        uint256 _num = getPoolTargetTokenInfoSetNum(_poolTargetToken);
        if(_belongTo == 1) {
            return (poolTargetTokenInfo[_poolTargetToken].singleTokenRate[token][_num], 1);
        }

        if(_belongTo == 2) {
            uint256 _memberTokenTargetID = tokenInfo[token].memberTokenTargetID;
            return (poolTargetTokenInfo[_poolTargetToken].memberTargetTokenRate[_memberTokenTargetID][_num], 2);
        }
        return (0, 3);
    }

    /**
     * @notice Gets the current set number for a pool target token
     * @param _poolTargetToken The address of the pool target token
     * @return The current set number
     */
    function getPoolTargetTokenInfoSetNum(address _poolTargetToken) public view returns(uint256) {
        return poolTargetTokenInfo[_poolTargetToken].setNumber;
    }


    /**
     * @notice Gets the length of member token target IDs for a pool
     * @param _poolTargetToken The address of the pool target token
     * @param _num The set number
     * @return The number of member token target IDs
     */
    function _getMemberTokenTargetIDLength(address _poolTargetToken, uint256 _num) internal view returns(uint256) {
        return poolTargetTokenInfo[_poolTargetToken].memberTokenTargetID[_num].length();
    }
 
    /**
     * @notice Gets a specific member token target ID and its rate
     * @param _poolTargetToken The address of the pool target token
     * @param _num The set number
     * @param _index The index of the member token target ID
     * @return memberTokenTargetID The ID of the member token target
     * @return rate The rate of the member token target
     */
    function _getMemberTokenTargetID(
        address _poolTargetToken, 
        uint256 _num, 
        uint256 _index
    ) internal view returns(uint256, uint256) {
        uint256 _memberTokenTargetID = poolTargetTokenInfo[_poolTargetToken].memberTokenTargetID[_num].at(_index);
        return (
            _memberTokenTargetID,
            poolTargetTokenInfo[_poolTargetToken].memberTargetTokenRate[_memberTokenTargetID][_num]
        );
    }

    /**
     * @notice Checks if a member token target ID exists in a pool
     * @param _poolTargetToken The address of the pool target token
     * @param _num The set number
     * @param _memberTokenTargetID The ID to check
     * @return True if the member token target ID exists
     */
    function _getMemberTokenTargetIDIsIn(address _poolTargetToken, uint256 _num, uint256 _memberTokenTargetID) internal view returns(bool) {
        return poolTargetTokenInfo[_poolTargetToken].memberTokenTargetID[_num].contains(_memberTokenTargetID);
    }

    /**
     * @notice Gets the current length of member token target IDs
     * @param _poolTargetToken The address of the pool target token
     * @return The number of current member token target IDs
     */
    function getCurrMemberTokenTargetIDLength(address _poolTargetToken) external view returns(uint256) {
        return _getMemberTokenTargetIDLength(_poolTargetToken, getPoolTargetTokenInfoSetNum(_poolTargetToken));
    }

    /**
     * @notice Gets a current member token target ID and its rate
     * @param _poolTargetToken The address of the pool target token
     * @param _index The index of the member token target ID
     * @return memberTokenTargetID The ID of the member token target
     * @return rate The rate of the member token target
     */
    function getCurrMemberTokenTargetID(
        address _poolTargetToken, 
        uint256 _index
    ) external view returns(uint256, uint256) {
        return _getMemberTokenTargetID(_poolTargetToken, getPoolTargetTokenInfoSetNum(_poolTargetToken), _index);
    }

    /**
     * @notice Checks if a member token target ID exists in current set
     * @param _poolTargetToken The address of the pool target token
     * @param _memberTokenTargetID The ID to check
     * @return True if the member token target ID exists
     */
    function getCurrMemberTokenTargetIDIsIn(address _poolTargetToken, uint256 _memberTokenTargetID) external view returns(bool) {
        return _getMemberTokenTargetIDIsIn(_poolTargetToken, getPoolTargetTokenInfoSetNum(_poolTargetToken), _memberTokenTargetID);
    }

    /**
     * @notice Gets the number of member tokens for a specific target ID
     * @param _poolTargetToken The address of the pool target token
     * @param _memberTokenTargetID The ID of the member token target
     * @return The number of member tokens
     */
    function getCurrMemberTokensLength(
        address _poolTargetToken, 
        uint256 _memberTokenTargetID
    ) external view returns(uint256) {
        return _getMemberTokensLength(_poolTargetToken, getPoolTargetTokenInfoSetNum(_poolTargetToken), _memberTokenTargetID);
    }

    function _getMemberTokensLength(
        address _poolTargetToken, 
        uint256 _num, 
        uint256 _memberTokenTargetID
    ) internal view returns(uint256) {
        return poolTargetTokenInfo[_poolTargetToken].memberTokens[_memberTokenTargetID][_num].length();
    }

    /**
     * @notice Gets a specific member token address
     * @param _poolTargetToken The address of the pool target token
     * @param _memberTokenTargetID The ID of the member token target
     * @param _index The index of the member token
     * @return The address of the member token
     */
    function getCurrMemberToken(
        address _poolTargetToken, 
        uint256 _memberTokenTargetID,
        uint256 _index
    ) external view returns(address) {
        return _getMemberToken(_poolTargetToken, getPoolTargetTokenInfoSetNum(_poolTargetToken), _memberTokenTargetID, _index);
    }



    function _getMemberToken(
        address _poolTargetToken, 
        uint256 _num, 
        uint256 _memberTokenTargetID,
        uint256 _index
    ) internal view returns(address) {
        return poolTargetTokenInfo[_poolTargetToken].memberTokens[_memberTokenTargetID][_num].at(_index);
    }

    /**
     * @notice Checks if a token exists in member tokens
     * @param _token The token address to check
     * @param _poolTargetToken The address of the pool target token
     * @param _memberTokenTargetID The ID of the member token target
     * @return True if the token exists in member tokens
     */
    function getCurrMemberTokenIsIn(
        address _token,
        address _poolTargetToken, 
        uint256 _memberTokenTargetID
    ) external view returns(bool) {
        return _getMemberTokenIsIn(_token, _poolTargetToken, getPoolTargetTokenInfoSetNum(_poolTargetToken), _memberTokenTargetID);
    }

    function _getMemberTokenIsIn(
        address _token,
        address _poolTargetToken, 
        uint256 _num, 
        uint256 _memberTokenTargetID
    ) internal view returns(bool) {
        return poolTargetTokenInfo[_poolTargetToken].memberTokens[_memberTokenTargetID][_num].contains(_token);
    }


    /**
     * @notice Gets the pool target token for a given token
     * @param _token The token address
     * @return The address of the pool target token
     */
    function getTokenToPoolTargetToken(address _token) public view returns(address) {
        return tokenInfo[_token].tokenToPoolTargetToken;
    }

    /**
     * @notice Gets the number of single tokens in a pool
     * @param _poolTargetToken The address of the pool target token
     * @param _num The set number
     * @return The number of single tokens
     */
    function _getSingleTokensLength(address _poolTargetToken, uint256 _num) internal view returns(uint256) {
        return poolTargetTokenInfo[_poolTargetToken].singleTokens[_num].length();
    }


    /**
     * @notice Checks if a token exists in single tokens
     * @param _token The token address to check
     * @param _poolTargetToken The address of the pool target token
     * @param _num The set number
     * @return True if the token exists in single tokens
     */
    function _getSingleTokenIsIn(address _token, address _poolTargetToken, uint256 _num) internal view returns(bool) {
        return poolTargetTokenInfo[_poolTargetToken].singleTokens[_num].contains(_token);
    }


    /**
     * @notice Gets the current number of single tokens
     * @param _poolTargetToken The address of the pool target token
     * @return The current number of single tokens
     */
    function getCurrSingleTokensLength(address _poolTargetToken) external view returns(uint256) {
        return _getSingleTokensLength(_poolTargetToken, getPoolTargetTokenInfoSetNum(_poolTargetToken));
    }

    /**
     * @notice Gets a current single token and its rate
     * @param _poolTargetToken The address of the pool target token
     * @param _index The index of the single token
     * @return singleToken The address of the single token
     * @return rate The rate of the single token
     */
    function getCurrSingleToken(address _poolTargetToken, uint256 _index) external view returns(address, uint256) {
        uint256 _num = getPoolTargetTokenInfoSetNum(_poolTargetToken);
        address _singleToken = poolTargetTokenInfo[_poolTargetToken].singleTokens[_num].at(_index);
        return (
            _singleToken,
            poolTargetTokenInfo[_poolTargetToken].singleTokenRate[_singleToken][_num]
        );
    }

    /**
     * @notice Checks if a token exists in current single tokens
     * @param _token The token address to check
     * @param _poolTargetToken The address of the pool target token
     * @return True if the token exists in current single tokens
     */
    function getCurrSingleTokenIsIn(address _token, address _poolTargetToken) external view returns(bool) {
        return _getSingleTokenIsIn(_token, _poolTargetToken, getPoolTargetTokenInfoSetNum(_poolTargetToken));
    }

    /**
     * @notice Gets the coin type of a token
     * @dev return value == 1: IndexToken set in CoinData contract or USDT address
     * @dev return value == 2: IndexToken set in MemeFactory contract (meme token)
     * @param token The token address
     * @return The coin type (0, 1, or 2)
     */
    function getCoinType(address token) external view returns(uint8) {
        if(isAddCoin[token] || token == usdt) {
            return 1;
        }

        if(memeData.isAddMeme(token)) {
            return 2;
        }

        return 0;
    }
    
    /**
     * @notice Gets the current number of removed tokens
     * @param _poolTargetToken The address of the pool target token
     * @return The current number of removed tokens
     */
    function getCurrRemoveTokensLength(address _poolTargetToken) external view returns(uint256) {
        return poolTargetTokenInfo[_poolTargetToken].currRemoveTokens.length();
    }

    /**
     * @notice Gets a current removed token address
     * @param _poolTargetToken The address of the pool target token
     * @param _index The index of the removed token
     * @return The address of the removed token
     */
    function getCurrRemoveToken(address _poolTargetToken, uint256 _index) external view returns(address) {
        return poolTargetTokenInfo[_poolTargetToken].currRemoveTokens.at(_index);
    }

    /**
     * @notice Checks if a token exists in current removed tokens
     * @param _poolTargetToken The address of the pool target token
     * @param _token The token address to check
     * @return True if the token exists in current removed tokens
     */
    function getCurrRemoveTokenIsIn(address _poolTargetToken, address _token) public view returns(bool) {
        return poolTargetTokenInfo[_poolTargetToken].currRemoveTokens.contains(_token);
    }
}