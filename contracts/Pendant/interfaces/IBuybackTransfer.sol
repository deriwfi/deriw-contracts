// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IBuybackTransfer {
    struct LossSplit {
        address buybackReceiver;
        uint256 buybackAmount;
        address insuranceReceiver;
        uint256 insuranceAmount;
        address mainReceiver;
        uint256 mainAmount;
    }

    function syncTier(address _indexToken, uint256 _amount)
        external
        returns (LossSplit memory lossSplit);

    function getH(address _indexToken) external view returns (uint256);

    function getCurrentTier(address _indexToken) external view returns (uint256);

    function getDivertRates(address _indexToken)
        external
        view
        returns (uint256 tier, uint256 buybackBps, uint256 insuranceBps, uint256 mainBps);

    function splitLoss(address _indexToken, uint256 _amount) external view returns (LossSplit memory);
}
