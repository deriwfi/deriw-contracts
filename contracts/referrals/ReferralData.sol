// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IInviteStruct.sol";
import "./interfaces/IValidateReferral.sol";
import "./interfaces/IReferralStorage.sol";
import "./interfaces/IFeeBonus.sol";
import "../upgradeability/Synchron.sol";
import "../meme/interfaces/IMemeData.sol";
import "../core/interfaces/IVault.sol";
import "../Pendant/interfaces/IPhase.sol";
import "../core/interfaces/ITransferAmountData.sol";

contract ReferralData is Synchron, IInviteStruct, ITransferAmountData {
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    ProFee proFee;

    IValidateReferral public validateReffral;
    IReferralStorage public referralStorage;
    IVault public vault;
    Target[] defaultTarget;

    address public gov;
    address public USDT;
    address public feeBonus;

    uint256 public totalReferralDataFee;
    uint256 public constant baseRate = 10000;

    bool public initialized;

    mapping(address => bool) public adminFor;
    mapping(address => UserAllocateInfo) defaultUserAllocateRate;
    mapping(address => bool) public isHander;
    mapping(address => mapping(address => UserAllocateInfo)) userAllocateInfo;
    mapping(address => EnumerableSet.AddressSet) tradeAccount;
    mapping(address => EnumerableSet.AddressSet) currFeeAccount;
    mapping(address => uint8) userLevel;
    mapping(address => UserTransactionInfo) userTransactionInfo;
    mapping(address => EnumerableSet.AddressSet) pastFeeAccount;
    mapping(address => EnumerableSet.AddressSet) remainAccount;
    mapping(address => mapping(address => uint256)) public remianFee;
    mapping(address => mapping(address => uint8)) public lastLevel;
    
    event AccFee(TransferEvent tEvent);
    event SetAdmin(address account, bool isAdd);
    event SetDefaultTarget(Target[] _target);
    event Promoted(address user,address referral, uint256 level);
    event AddSizeDelta(address user, address referral,  address token, uint256 sizeDelta);
    event AddFee(address user, address referral, address token, uint256 fee, uint8 cType);
    event SetDefaultUserAllocateRate(address user,uint256 rate);
    event SetIsDefaultUserAllocateRate(address account, bool isOpen);
    event SetUserAllocateRate( address account, address user, uint256 rate);
    event SetIsUseAllocateRate(address account, address user, bool isOpen);
    event TransferFee(address user, uint256 fee, uint256 userFee, uint256 pFee);
    event ReplaceInvitation(address oldReferral, address newReferral, address user, uint256 fee);

    event Withdraw(
        address form,
        address account, 
        uint256 amount,
        uint256 beforeAmount, 
        uint256 afterAmount,
        uint256 beforeValue,
        uint256 afterValue
    );

    event WithdrawFee(
        address from,
        address account, 
        uint256 amount, 
        uint256 act,
        uint256 beforeAmount, 
        uint256 afterAmount,
        uint256 beforeValue,
        uint256 afterValue
    );

    event Settlement(
        address user, 
        address referral,
        uint256 userFee, 
        uint256 refFee, 
        uint256 pFee, 
        uint256 fee,
        uint256 remFee,
        uint256 rFee,
        uint256 beforeSecondaryFee,
        uint256 afterSecondaryFee
    );

    event SettlementFee(
        uint8 cType,
        address refer,
        address from, 
        address to, 
        uint256 amount, 
        uint256 beforeAmount, 
        uint256 afterAmount,
        uint256 beforeValue,
        uint256 afterValue
    );

    modifier onlyGov() {
        require(msg.sender == gov, "Governable: forbidden");
        _;
    }

    modifier onlyHander() {
        require(isHander[msg.sender] || msg.sender == gov, "no permiion");
        _;
    } 

    modifier onlyAdmin {
        require(adminFor[msg.sender], "no permission");
        _;
    }

    function initialize(address usdt) external {
        require(!initialized, "has initialized");
        initialized = true;
        USDT = usdt;
        gov = msg.sender;
        adminFor[msg.sender] = true;
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "_gov err");
        gov = _gov;
    }

    function replaceInvitation(address oldReferral, address newReferral, address user) external {
        require(msg.sender == address(referralStorage), "referralStorage err");

        uint256 fee = userTransactionInfo[user].fee;
        remainAccount[oldReferral].add(user);
        userTransactionInfo[user].fee = 0;
        remianFee[oldReferral][user] += fee;

        emit ReplaceInvitation(oldReferral, newReferral, user, fee);
    }

    function setContract(
        address _validateReffral,
        address _referralStorage,
        address _feeBonus,
        address _vault
    ) external onlyAdmin() {
        validateReffral = IValidateReferral(_validateReffral);
        referralStorage = IReferralStorage(_referralStorage);
        feeBonus = _feeBonus;
        vault = IVault(_vault);
    }

    function _withdrawFee(address indexToken) internal {
        uint256 fee = proFee.fee;   
        if(fee > 0) {
            proFee.fee = 0;
            proFee.haveClaim += fee;

            (uint256 _fee, TransferAmountData memory tData) = _safeTransfer(USDT, feeBonus, fee);

            proFee.actClaim += _fee;

            if(!IMemeData(IPhase(vault.phase()).memeData()).isAddMeme(indexToken)) {
                IFeeBonus(feeBonus).addFeeAmount(USDT, 1, fee);
            } else {
                IFeeBonus(feeBonus).addFeeAmount(indexToken, 3, fee);
            }

            emit WithdrawFee(
                address(this), 
                feeBonus, 
                fee, 
                _fee, 
                tData.beforeAmount, 
                tData.afterAmount, 
                tData.beforeValue, 
                tData.afterValue
            );    
        } 
    }

    function withdraw(address account, uint256 amount) external onlyAdmin() {
        (uint256 _amount, TransferAmountData memory tData) = _safeTransfer(USDT, account, amount);

        emit Withdraw(
            address(this), 
            account, 
            _amount, 
            tData.beforeAmount, 
            tData.afterAmount, 
            tData.beforeValue, 
            tData.afterValue
        );
    }

    function setAdmin(address account, bool isAdd) external onlyGov {
        adminFor[account] = isAdd;

        emit SetAdmin(account, isAdd);
    }

    function setHander(address account, bool isAdd) external onlyAdmin {
        isHander[account] = isAdd;
    } 
 
    function setDefaultUserAllocateRate(uint256 rate) external {
        require(rate <= baseRate, "rate err");

        defaultUserAllocateRate[msg.sender].allocateRate = rate;
        defaultUserAllocateRate[msg.sender].isAllocate = true;

        emit SetDefaultUserAllocateRate(msg.sender, rate);
        emit SetIsDefaultUserAllocateRate(msg.sender, true);
    }

    function setIsDefaultUserAllocateRate(bool isOpen) external {
        defaultUserAllocateRate[msg.sender].isAllocate = isOpen;

        emit SetIsDefaultUserAllocateRate(msg.sender, isOpen);
    }

    function batchSetUserAllocateRate(UserRate[] memory userRate) external {
        uint256 len = userRate.length;
        require(len > 0, "length err");
        for(uint256 i = 0; i < len; i++) {
            setUserAllocateRate(userRate[i].user, userRate[i].allocateRate);
        }
    }

    function setUserAllocateRate(address user, uint256 rate) public {
        require(rate <= baseRate, "rate err");

        userAllocateInfo[msg.sender][user].allocateRate = rate;
        userAllocateInfo[msg.sender][user].isAllocate = true;

        emit SetUserAllocateRate(msg.sender, user, rate);
        emit SetIsUseAllocateRate(msg.sender, user, true);
    }

    function setIsUseAllocateRate(address user, bool isOpen) external {
        userAllocateInfo[msg.sender][user].isAllocate = isOpen;

        emit SetIsUseAllocateRate(msg.sender, user, isOpen);
    }

    function setDefaultTarget(Target[] memory _target) external onlyAdmin() {
        validateReffral.validateDefaultSetTarget(address(this), _target);

        delete defaultTarget;
        uint256 len = _target.length;
        for(uint256 i = 0 ; i < len; i++) {
            defaultTarget.push(_target[i]);
        }

        emit SetDefaultTarget(_target);
    }

    function addSizeDelta(address user, address token, uint256 sizeDelta) external onlyHander {
        require(token == USDT, "token err");
        (, address referrer) = referralStorage.getTraderReferralInfo(user);

        userTransactionInfo[referrer].secondarySizeDelta += sizeDelta; 
        userTransactionInfo[user].sizeDelta += sizeDelta; 
        tradeAccount[referrer].add(user);
        tradeAccount[user].add(user);

        _updatePromoted(user);
        _updatePromoted(referrer);

        emit AddSizeDelta(user, referrer, token, sizeDelta);
    }

    function addFee(
        uint8 uType, 
        bytes32 typeKey, 
        bytes32 key, 
        address user, 
        address token, 
        uint256 fee,
        address indexToken
    ) external onlyHander {
        require(token == USDT, "token err");
        TransferEvent memory tEvent = TransferEvent(
            uType, typeKey, key, address(this), user, 0, 0, 0, 0, 0
        );

        if(fee > 0) {
            totalReferralDataFee += fee;
            uint8 cType;
            (, address referrer) = referralStorage.getTraderReferralInfo(user);
            if(referrer == address(0)) {
                if(referralStorage.owerCode(user) != referralStorage.zeroCode()) {
                    uint8 level = getUserLevel(user);
                    uint256 rate = getDefaultTarget(level-1).levelRate;
                
                    uint256 userFee = fee * rate / baseRate;
                    userTransactionInfo[user].haveFee += fee; 
                    uint256 pFee = fee - userFee;
                    proFee.fee += pFee;

                    if(userFee > 0) {
                        (uint256 _aAmount, TransferAmountData memory tData) = _safeTransfer(USDT, user, userFee);
                        tEvent.amount = _aAmount;
                        tEvent.beforeAmount = tData.beforeAmount;
                        tEvent.beforeValue = tData.beforeValue;
                        tEvent.afterAmount = tData.afterAmount;
                        tEvent.afterValue = tData.afterValue;
 
                        emit AccFee(tEvent);
                    }
                    cType = 1;
                    emit TransferFee(user, fee, userFee, pFee);
                } else {
                    cType = 2;
                    proFee.fee += fee;
                    userTransactionInfo[user].haveFee += fee; 
                    emit TransferFee(user, fee, 0, fee);
                }

            } else {
                cType = 3;
                userTransactionInfo[user].fee += fee; 
                userTransactionInfo[referrer].secondaryFee += fee; 
                currFeeAccount[referrer].add(user);

                _settlementFor(referrer, user);
            }
            emit  AddFee(user, referrer, token, fee, cType);
        }
        _withdrawFee(indexToken);
    }

    function batchSettlement(uint256 number) external {
        uint256 len = currFeeAccount[msg.sender].length();
        if(number > len) {
            number = len;
        }
        require(number > 0, "len err");

        for(uint256 i = 0; i < number; i++) {
            address user = currFeeAccount[msg.sender].at(0);

            _settlement(msg.sender, user);
        }
    }

    function settlement(address user) public {
        _settlementFor(msg.sender, user);
    }

    function _transferFor(
        uint8 cType, 
        address referrer, 
        address user, 
        uint256 amount
    ) internal {
        (uint256 _amount, TransferAmountData memory tData) = _safeTransfer(USDT, user, amount);

        if(cType == 1) {
            emit SettlementFee(
                1, 
                referrer, 
                address(this), 
                user, 
                _amount, 
                tData.beforeAmount, 
                tData.afterAmount, 
                tData.beforeValue, 
                tData.afterValue
            );
        }

        if(cType == 2) {
            emit SettlementFee(
                2, 
                referrer, 
                address(this), 
                user, 
                _amount, 
                tData.beforeAmount, 
                tData.afterAmount, 
                tData.beforeValue, 
                tData.afterValue
            );
        }

        if(cType == 3) {
            emit SettlementFee(
                3, 
                referrer, 
                address(this), 
                referrer, 
                _amount, 
                tData.beforeAmount, 
                tData.afterAmount, 
                tData.beforeValue, 
                tData.afterValue
            );
        }
    }

    function _settlementFor(address referrer, address user) internal {
        require(currFeeAccount[referrer].contains(user), "user err");
        
        currFeeAccount[referrer].remove(user);
        remainAccount[referrer].remove(user);
        pastFeeAccount[referrer].add(user);

        uint256 remFee = remianFee[referrer][user];
        uint256 beforeSecondaryFee = userTransactionInfo[referrer].secondaryFee;
        (uint256 userFee, uint256 refFee, uint256 pFee, uint256 fee, uint256 rFee) = _settlement(referrer, user);

        if(userFee > 0) {
            userTransactionInfo[referrer].secondaryActClaim += userFee; 
            userTransactionInfo[user].claimFee  += userFee;

            _transferFor(1, referrer, user, userFee);
        }

        if(rFee > 0) {
            userTransactionInfo[referrer].secondaryActClaim += rFee; 
            userTransactionInfo[user].claimFee += rFee;

            _transferFor(2, referrer, user, rFee);
        }

        if(refFee > 0) {
            userTransactionInfo[referrer].claimFee += refFee; 
            _transferFor(3, referrer, referrer, refFee);
        }

        if(pFee > 0) {
            proFee.fee += pFee;
        }

        uint256 afterSecondaryFee = userTransactionInfo[referrer].secondaryFee;

        emit Settlement(
            user, 
            referrer, 
            userFee, 
            refFee, 
            pFee, 
            fee, 
            remFee, 
            rFee, 
            beforeSecondaryFee, 
            afterSecondaryFee
        );
    }

    function _settlement(
        address referrer,
        address user
    ) internal returns(uint256, uint256, uint256, uint256, uint256) {
        (uint256 accFee, uint256 totalFee) = validateReffral.validateSettlement(address(this), referrer);

        uint256 fee = userTransactionInfo[user].fee;
        if(referralStorage.referral(user) != referrer) {
            fee = 0;
        } else {
            userTransactionInfo[user].fee  = 0;
        }

        uint256 rFee = remianFee[referrer][user];
        remianFee[referrer][user] = 0;

        uint256 tFee = fee + rFee;
        userTransactionInfo[user].haveFee  += tFee;

        userTransactionInfo[referrer].secondaryFee -= tFee; 
        userTransactionInfo[referrer].haveSecondaryFee += tFee; 

        return validateReffral.calculate(address(this), referrer, user, totalFee, accFee, fee, rFee);
    }

    function _safeTransfer(
        address token, 
        address account, 
        uint256 amount
    ) internal returns(uint256 value, TransferAmountData memory tData) {
        require(account != address(0), "account err");

        uint256 balance = IERC20(token).balanceOf(address(this)) ;
        value = amount > balance ? balance : amount;

        if(value > 0) {
            tData.beforeAmount = getAmount(token, address(this));
            tData.beforeValue = getAmount(token, account);
            IERC20(token).safeTransfer(account, value);
            tData.afterAmount = getAmount(token, address(this));
            tData.afterValue = getAmount(token, account);
        }
    }

    function _updatePromoted(address account) internal {
        (, address referrer) = referralStorage.getTraderReferralInfo(account);
        if(referrer == address(0) && referralStorage.owerCode(account) != referralStorage.zeroCode()) {
            (uint8 level, bool isUpdate) = validateReffral.validatePromoted(address(this), account);

            if(isUpdate) {
                userLevel[account] = level;
                emit Promoted(account, referrer, level);
            }
        }
    }

    function getUserTransactionInfo(
        address user
    ) external view returns(UserTransactionInfo memory) {
        return userTransactionInfo[user];
    }
 
    function getUserAllocateRate(address referral, address user) public view returns(address, uint256) {
        if(defaultUserAllocateRate[referral].isAllocate) {
            return (referral, defaultUserAllocateRate[referral].allocateRate);
        }

        if(userAllocateInfo[referral][user].isAllocate) {
            return (referral, userAllocateInfo[referral][user].allocateRate);
        }

        return (referral, defaultUserAllocateRate[referral].allocateRate);
    }

    function getDefaultTargets() public view returns(Target[] memory) {
        return defaultTarget;
    }

    function getDefaultTargetLength() public view returns(uint256) {
        return defaultTarget.length;
    }

    function getDefaultTarget(uint256 index) public view returns(Target memory) {
        return defaultTarget[index];
    }

    function getTradeAccountLength(address account) external view returns(uint256) {
        return tradeAccount[account].length();
    }

    function getTradeAccount(address account, uint256 index) external view returns(address) {
        return tradeAccount[account].at(index);
    }

    function getTradeAccountContains(address account, address user) external view returns(bool) {
        return tradeAccount[account].contains(user);
    }

    function getUserLevel(address user) public view returns(uint8) {
        (, address referrer) = referralStorage.getTraderReferralInfo(user);
        if(referrer != address(0)) {
            return 0;
        }

        if(referralStorage.owerCode(user) == referralStorage.zeroCode()) {
            return 0;
        }

        Target memory _target = getDefaultTarget(0);
        if(_target.levelSizeDelta == 0 && _target.levelTradeNum == 0 && userLevel[user] == 0) {
            return 1;
        }
        return userLevel[user];
    }

    function getCurrFeeAccountLength(
        address referrer
    ) external view returns(uint256) {
        return currFeeAccount[referrer].length();
    }

    function getCurrFeeAccount(
        address referrer, 
        uint256 index
    ) external view returns(address) {
        return currFeeAccount[referrer].at(index);
    }

    function getCurrFeeAccountContains(
        address referrer, 
        address user
    ) external view returns(bool) {
        return currFeeAccount[referrer].contains(user);
    }

    function getRemainAccountLength(
        address referrer
    ) external view returns(uint256) {
        return currFeeAccount[referrer].length();
    }

    function getRemainAccount (
        address referrer, 
        uint256 index
    ) external view returns(address) {
        return currFeeAccount[referrer].at(index);
    }

    function getRemainAccountContains(
        address referrer, 
        address user
    ) external view returns(bool) {
        return currFeeAccount[referrer].contains(user);
    }

   function getPastFeeAccountLength(
        address referrer
    ) external view returns(uint256) {
        return pastFeeAccount[referrer].length();
    }

    function getPastFeeAccount(
        address referrer, 
        uint256 index
    ) external view returns(address) {
        return pastFeeAccount[referrer].at(index);
    }

    function getPastFeeAccountContains(
        address referrer, 
        address user
    ) external view returns(bool) {
        return pastFeeAccount[referrer].contains(user);
    }

    function getProFee() external view returns(ProFee memory) {
        return proFee;
    }

    function getAmount(address token, address account) public view returns(uint256) {
        return IERC20(token).balanceOf(account);
    }

    function getDefaultUserAllocateRate(address account) external view returns(UserAllocateInfo memory) {
        return defaultUserAllocateRate[account];
    }
}