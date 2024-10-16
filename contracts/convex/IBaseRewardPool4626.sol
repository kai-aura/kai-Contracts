// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

/*
   ____            __   __        __   _
  / __/__ __ ___  / /_ / /  ___  / /_ (_)__ __
 _\ \ / // // _ \/ __// _ \/ -_)/ __// / \ \ /
/___/ \_, //_//_/\__//_//_/\__/ \__//_/ /_\_\
     /___/

* Synthetix: BaseRewardPool.sol
*
* Docs: https://docs.synthetix.io/
*
*
* MIT License
* ===========
*
* Copyright (c) 2020 Synthetix
*
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
*/

import "./Interfaces.sol";
import "./MathUtil.sol";
import "@openzeppelin/contracts-0.8/utils/math/SafeMath.sol";
import "@openzeppelin/contracts-0.8/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-0.8/utils/Address.sol";
import "@openzeppelin/contracts-0.8/token/ERC20/utils/SafeERC20.sol";

/**
 * @title   IBaseRewardPool4626
 * @author  Synthetix -> ConvexFinance
 * @notice  Unipool rewards contract that is re-deployed from rFactory for each staking pool.
 * @dev     Changes made here by ConvexFinance are to do with the delayed reward allocation. Curve is queued for
 *          rewards and the distribution only begins once the new rewards are sufficiently large, or the epoch
 *          has ended. Additionally, enables hooks for `extraRewards` that can be enabled at any point to
 *          distribute a child reward token (i.e. a secondary one from Curve, or a seperate one).
 */
interface IBaseRewardPool4626 {
    // IERC20 public immutable rewardToken;
    // IERC20 public immutable stakingToken;
    // uint256 public constant duration = 7 days;

    // address public immutable operator;
    // address public immutable rewardManager;

    // uint256 public immutable pid;
    // uint256 public periodFinish = 0;
    // uint256 public rewardRate = 0;
    // uint256 public lastUpdateTime;
    // uint256 public rewardPerTokenStored;
    // uint256 public queuedRewards = 0;
    // uint256 public currentRewards = 0;
    // uint256 public historicalRewards = 0;
    // uint256 public constant newRewardRatio = 830;

    // mapping(address => uint256) public userRewardPerTokenPaid;
    // mapping(address => uint256) public rewards;

    // address[] public extraRewards;

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);

    function rewardToken() external view returns (IERC20);

    function extraRewards(uint256 index) external view returns (address);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    function extraRewardsLength() external view returns (uint256);

    function addExtraReward(address _reward) external returns (bool);

    function earned(address account) external view returns (uint256);

    function stake(uint256 _amount) external returns (bool);

    function stakeAll() external returns (bool);

    function stakeFor(address _for, uint256 _amount) external returns (bool);

    function withdraw(uint256 amount, bool claim) external returns (bool);

    function withdraw(uint256 amount, address receiver, address owner) external returns (uint256);

    function withdrawAll(bool claim) external;

    function withdrawAndUnwrap(uint256 amount, bool claim) external returns (bool);

    function withdrawAllAndUnwrap(bool claim) external;

    /**
     * @dev Gives a staker their rewards, with the option of claiming extra rewards
     * @param _account     Account for which to claim
     * @param _claimExtras Get the child rewards too?
     */
    function getReward(address _account, bool _claimExtras) external returns (bool);

    /**
     * @dev Called by a staker to get their allocated rewards
     */
    function getReward() external returns (bool);

    /**
     * @dev Donate some extra rewards to this contract
     */
    function donate(uint256 _amount) external returns (bool);

    /**
     * @dev Processes queued rewards in isolation, providing the period has finished.
     *      This allows a cheaper way to trigger rewards on low value pools.
     */
    function processIdleRewards() external;

    /**
     * @dev Called by the booster to allocate new Crv rewards to this pool
     *      Curve is queued for rewards and the distribution only begins once the new rewards are sufficiently
     *      large, or the epoch has ended.
     */
    function queueNewRewards(uint256 _rewards) external returns (bool);

    function deposit(uint256 assets, address receiver) external returns (uint256);

    function rewardPerToken() external view returns (uint256);
}
