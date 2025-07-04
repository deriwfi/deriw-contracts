// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "./interfaces/IVault.sol";
import "../access/Governable.sol";
import "./interfaces/IEventStruct.sol";
import "../Pendant/interfaces/ISlippage.sol";
import "../Pendant/interfaces/IPhase.sol";
pragma experimental ABIEncoderV2;

contract VaultUtils is IEventStruct, Governable {
    using SafeMath for uint256;

    IVault public vault;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    mapping (address => uint256) public userGlobalLongSizes;
    mapping (address => uint256) public userGlobalShortSizes;

    struct ValidateData {
        address account; 
        address collateralToken; 
        address indexToken; 
        bool isLong;
        bool isLiqu;
    }

    modifier onlyVault() {
        require(address(vault) == msg.sender, "not vault");
        _;
    }

    function setVault(IVault _vault) external onlyGov {
        vault = _vault;
    }

    function updateCumulativeFundingRate(address /* _collateralToken */, address /* _indexToken */) public  pure returns (bool) {
        return true;
    }

    function validateIncreasePosition(address /* _account */, address /* _collateralToken */, address /* _indexToken */, uint256 /* _sizeDelta */, bool /* _isLong */) external  view {
        // no additional validations
    }

    function validateDecreasePosition(address /* _account */, address /* _collateralToken */, address /* _indexToken */ , uint256 /* _collateralDelta */, uint256 /* _sizeDelta */, bool /* _isLong */, address /* _receiver */) public  view {
        // no additional validations
    }

    function getPosition(address _account, address _collateralToken, address _indexToken, bool _isLong) internal view returns (Position memory) {
        IVault _vault = vault;
        Position memory position;
        {
            (uint256 size, uint256 collateral, uint256 averagePrice, , /* reserveAmount */, /* realisedPnl */, /* hasProfit */, uint256 lastIncreasedTime) = _vault.getPosition(_account, _collateralToken, _indexToken, _isLong);
            position.size = size;
            position.collateral = collateral;
            position.averagePrice = averagePrice;
            position.lastIncreasedTime = lastIncreasedTime;
        }
        return position;
    }

    function validateLiquidation(address _account, address _collateralToken, address _indexToken, bool _isLong, bool _raise) public view  returns (uint256, uint256) {
        Position memory position = getPosition(_account, _collateralToken, _indexToken, _isLong);
        IVault _vault = vault;

        (bool hasProfit, uint256 delta) = _vault.getDelta(_indexToken, position.size, position.averagePrice, _isLong, position.lastIncreasedTime);

        uint256 marginFees = getPositionFee(_account, _collateralToken, _indexToken, _isLong, position.size);

        if (!hasProfit && position.collateral < delta) {
            if (_raise) { revert("Vault: losses exceed collateral"); }
            return (1, marginFees);
        }

        uint256 remainingCollateral = position.collateral;
        if (!hasProfit) {
            remainingCollateral = position.collateral.sub(delta);
        }

        if (remainingCollateral < marginFees) {
            if (_raise) { revert("Vault: fees exceed collateral"); }
            // cap the fees to the remainingCollateral
            return (1, remainingCollateral);
        }

        if (remainingCollateral < marginFees.add(_vault.liquidationFeeUsd())) {
            if (_raise) { revert("Vault: liquidation fees exceed collateral"); }
            return (1, marginFees);
        }


        (uint256 maxLeverage,,,) = IPhase(vault.phase()).getTokenData(_account);
        if (remainingCollateral.mul(maxLeverage) < position.size.mul(BASIS_POINTS_DIVISOR)) {
            if (_raise) { revert("Vault: maxLeverage exceeded"); }
            return (2, marginFees);
        }

        return (0, marginFees);
    }


    function getPositionFee(address /* _account */, address /* _collateralToken */, address /* _indexToken */, bool /* _isLong */, uint256 _sizeDelta) public  view returns (uint256) {
        if (_sizeDelta == 0) { return 0; }
        // _sizeDelta * (10000 - 2) / 10000
        uint256 afterFeeUsd = _sizeDelta.mul(BASIS_POINTS_DIVISOR.sub(vault.marginFeeBasisPoints())).div(BASIS_POINTS_DIVISOR);
        return _sizeDelta.sub(afterFeeUsd);//2%
    }


    function validatePositionFrom(
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        uint256 _collateralDelta, 
        uint256 _sizeDelta, 
        bool _isLong, 
        address _receiver
    ) external view returns (bytes32, uint256) {
        require(msg.sender == address(vault), "vault err");
        validateDecreasePosition(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);

        bytes32 key = vault.getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        Position memory position = vault.getPositionFrom(key);

        require(
            position.size > 0 && 
            position.size >= _sizeDelta && 
            position.collateral >= _collateralDelta, 
            "size err"
        );

        uint256 reserveDelta = position.reserveAmount * _sizeDelta / position.size;

        return (key, reserveDelta);        
    }

    function collectMarginFees(
        address _account,
        address _collateralToken, 
        address _indexToken, 
        bool _isLong, 
        uint256 _sizeDelta
    ) public view returns (uint256, uint256) {
        uint256 feeUsd = getPositionFee(_account, _collateralToken, _indexToken, _isLong, _sizeDelta);

        uint256 feeTokens = vault.usdToTokenMin(_collateralToken, feeUsd);

        return (feeUsd, feeTokens);
    }


    // ***************************************

    function increaseUserGlobalLongSize(
        address user, 
        address token, 
        address indexToken,  
        uint256 _amount
    ) external onlyVault {
        userGlobalLongSizes[user] += _amount;

        (
            uint256 maxLeverage, 
            uint256 maxSize, 
            ,
            bool isTokenSet
        ) = IPhase(vault.phase()).getTokenData(user);

        if (isTokenSet) {
            require(userGlobalLongSizes[user] <= maxSize, " user total long err");
        }
        validate(user, token, indexToken, true, maxLeverage);   
    }

    function decreaseUserGlobalLongSize(address user, uint256 _amount) external onlyVault {
        uint256 size = userGlobalLongSizes[user];
        if (_amount > size) {
          userGlobalLongSizes[user] = 0;
          return;
        }

        userGlobalLongSizes[user] = size - _amount;
    }

    function decreaseUserGlobalShortSize(address user, uint256 _amount) external onlyVault {
        uint256 size = userGlobalShortSizes[user];
        if (_amount > size) {
          userGlobalShortSizes[user] = 0;
          return;
        }

        userGlobalShortSizes[user] = size - _amount;
    }

    function increaseUserGlobalShortSize(
        address user, 
        address token, 
        address indexToken, 
        uint256 _amount
    ) external onlyVault {
        userGlobalShortSizes[user] += _amount;
        (
            uint256 maxLeverage, 
            , 
            uint256 maxShortSize, 
            bool isTokenSet
        ) = IPhase(vault.phase()).getTokenData(user);

        if (isTokenSet) {
            require(userGlobalShortSizes[user] <= maxShortSize, "user total shorts err");
        }
        validate(user, token, indexToken,  false, maxLeverage);
    }

    function validate(
        address user, 
        address token, 
        address indexToken, 
        bool isLong,
        uint256 maxLeverage
    ) internal view returns(bool) {
        bytes32 key = vault.getPositionKey(user, token, indexToken, isLong);
        Position memory pos = vault.getPositionFrom(key);

        require(pos.size * BASIS_POINTS_DIVISOR / pos.collateral <= maxLeverage, "maxLeverage err");

        return true;
    }
    
    function getOrderValue(
        address user, 
        bool isLong
    ) external view returns(uint256, bool) {
        (
            , 
            uint256 maxLongSize, 
            uint256 maxShortSize, 
            bool isTokenSet
        ) = IPhase(vault.phase()).getTokenData(user);

        if(isLong) {
            return ISlippage(vault.slippage()).getMinOrderValueFor(maxLongSize, userGlobalLongSizes[user], isTokenSet);
        } else {
            return ISlippage(vault.slippage()).getMinOrderValueFor(maxShortSize, userGlobalShortSizes[user], isTokenSet);
        }
    }

    function getValueFor(
        address user, 
        bool isLong,
        uint256 _min, 
        uint256 num
    ) external view returns(uint256, uint256) {
        ISlippage slippage =  ISlippage(vault.slippage());

        (
            , 
            uint256 maxLongSize, 
            uint256 maxShortSize, 
            bool isTokenSet
        ) = IPhase(vault.phase()).getTokenData(user);
        address _user = user;

        if(isLong) {
            return slippage.getMinValueFor(_min, num, maxLongSize, userGlobalLongSizes[_user], isTokenSet);
        } else {
            return slippage.getMinValueFor(_min, num, maxShortSize,  userGlobalShortSizes[_user], isTokenSet);
        }
    }

    function batchValidateLiquidation(ValidateData[] memory vData) external view  returns (ValidateData[] memory) {
        uint256 len = vData.length;
        ValidateData[] memory data = new ValidateData[](len);

        for(uint256 i = 0; i < len; i++) {
            ValidateData memory _data = vData[i];
            (uint256 liquidationState,) = validateLiquidation(
                _data.account, 
                _data.collateralToken, 
                _data.indexToken, 
                _data.isLong, 
                false    
            );

            data[i] = _data;
            if(liquidationState != 0) {
                data[i].isLiqu = true;
            }
        }
        return data;
    }

}
