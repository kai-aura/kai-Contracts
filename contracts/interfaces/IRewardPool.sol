// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

// It's the same as IRewardPool4626.sol except
// there's no expectation that the RewardPool supports EIP-4626 (vault - transferable token ownership.)
interface IRewardPool {
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external returns (uint256 shares);

    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function asset() external view returns (address);

    function balanceOf(address account) external view returns (uint256);

    function processIdleRewards() external;
}
