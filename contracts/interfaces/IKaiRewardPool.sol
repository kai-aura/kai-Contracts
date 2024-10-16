// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

interface IKaiRewardPool {
    struct EarnedData {
        address token;
        uint256 amount;
    }

    function withdrawAll() external;

    function balanceOf(address account) external view returns (uint256);

    function depositFor(uint256 assets, address receiver) external returns (bool);

    function claimableRewards(address account) external returns (EarnedData[] memory rewards);

    function getReward(address account) external returns (bool);
}
