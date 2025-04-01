// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "../libraries/utils/ReentrancyGuard.sol";
import "../core/interfaces/IGlpManager.sol";
import "../access/Governable.sol";
import "../fund-pool/v2/interfaces/IFundReader.sol";
import "../meme/interfaces/IMemeData.sol";

contract GlpRewardRouter is ReentrancyGuard, Governable {
    using SafeERC20 for IERC20;
    using Address for address payable;

    address public glpManager;
    address public USDT;

    IMemeData public memeData;
    IFundReader public foundReader;

    mapping (address => address) public pendingReceivers;

    event StakeGlp(address account, uint256 amount);
    event UnstakeGlp(address account, uint256 amount);

    constructor(address usdt) {
        USDT = usdt;
    }

    modifier onlyAuth() {
        require(foundReader.isGlpAuth(msg.sender) || memeData.poolToken(msg.sender) != address(0), "no permisson");
        _;
    }

    function setContract(
        address _glpManager,
        address _foundReader,
        address _memeData
    ) external onlyGov {
        glpManager = _glpManager;
        foundReader = IFundReader(_foundReader);
        memeData = IMemeData(_memeData);
    }

    function mintAndStakeGlp(
        address _indexToken,
        address _collateralToken, 
        uint256 _amount, 
        uint256 _minGlp
    ) external onlyAuth nonReentrant returns (uint256) {
        require(_amount > 0, "RewardRouter: invalid _amount");
        require(_collateralToken == USDT, "token err");

        address account = msg.sender;
        uint256 glpAmount = IGlpManager(glpManager).addLiquidityForAccount(_indexToken, account, account, _collateralToken, _amount, _minGlp);

        emit StakeGlp(account, glpAmount);

        return glpAmount;
    }

    function unstakeAndRedeemGlp(address _indexToken, address _tokenOut, uint256 _glpAmount, uint256 _minOut, address _receiver) external nonReentrant onlyAuth returns (uint256) {
        require(_glpAmount > 0, "RewardRouter: invalid _glpAmount");

        address account = msg.sender;
        uint256 amountOut = IGlpManager(glpManager).removeLiquidityForAccount(_indexToken, account, _tokenOut, _glpAmount, _minOut, _receiver);

        emit UnstakeGlp(account, _glpAmount);

        return amountOut;
    }
}
