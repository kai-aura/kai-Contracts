// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

interface IAuraLocker {
    function rewardTokens(uint256 i) external view returns (address token);

    function lock(address _account, uint256 _amount) external;

    function checkpointEpoch() external;

    function epochCount() external view returns (uint256);

    function balanceAtEpochOf(uint256 _epoch, address _user) external view returns (uint256 amount);

    function totalSupplyAtEpoch(uint256 _epoch) external view returns (uint256 supply);

    function queueNewRewards(address _rewardsToken, uint256 reward) external;

    function getReward(address _account, bool _stake) external;

    function getReward(address _account) external;

    function processExpiredLocks(bool _relock) external;
}
