// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IRouter.sol";

contract Router is IRouter {
    using SafeERC20 for IERC20;
    using Address for address payable;

    address public gov;
    address public vault;

    mapping (address => bool) public plugins;

    modifier onlyGov() {
        require(msg.sender == gov, "Router: forbidden");
        _;
    }

    constructor(address _vault) {
        vault = _vault;
        gov = msg.sender;
    }

    function setGov(address _gov) external onlyGov {
        require(_gov != address(0), "account err");
        gov = _gov;
    }

    function addPlugin(address _plugin) external override onlyGov {
        plugins[_plugin] = true;
    }

    function removePlugin(address _plugin) external onlyGov {
        plugins[_plugin] = false;
    }

    function pluginTransfer(address _token, address _account, address _receiver, uint256 _amount) external override {
        _validatePlugin();
        IERC20(_token).safeTransferFrom(_account, _receiver, _amount);
    }

    function pluginIncreasePosition(
        bytes32 _key, 
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        uint256 _sizeDelta, 
        bool _isLong,
        uint256 _amount
    ) external override {
        _validatePlugin();

        IVault(vault).increasePosition(_key, _account, _collateralToken, _indexToken, _sizeDelta, _isLong, _amount);
    }

    function pluginDecreasePosition(
        bytes32 _key, 
        address _account, 
        address _collateralToken, 
        address _indexToken, 
        uint256 _collateralDelta, 
        uint256 _sizeDelta, 
        bool _isLong, 
        address _receiver
    ) external override returns (uint256) {
        _validatePlugin();
        return IVault(vault).decreasePosition(_key, _account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);
    }

    function _validatePlugin() private view {
        require(plugins[msg.sender], "Router: invalid plugin");
    }
}
