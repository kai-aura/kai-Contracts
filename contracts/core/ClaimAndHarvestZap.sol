// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { IKaiRewardPool } from "../interfaces/IKaiRewardPool.sol";

interface IMetaRewardPool is IKaiRewardPool {
    function harvestRewards() external;
    function lastHarvestedAt() external returns (uint256);
}

contract ClaimAndHarvestZap {
    constructor() {}

    function claimAndHarvest(address wallet, IMetaRewardPool rewardPool, uint256 staleTimeSeconds) external {
        if (block.timestamp - rewardPool.lastHarvestedAt() > staleTimeSeconds) {
            rewardPool.harvestRewards();
        }

        rewardPool.getReward(wallet);
    }

    function claimableRewards(
        address wallet,
        IMetaRewardPool rewardPool,
        uint256 staleTimeSeconds
    ) external returns (IKaiRewardPool.EarnedData[] memory userRewards) {
        if (block.timestamp - rewardPool.lastHarvestedAt() > staleTimeSeconds) {
            rewardPool.harvestRewards();
        }

        return rewardPool.claimableRewards(wallet);
    }
}
