// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

/*
   ____            __   __        __   _
  / __/__ __ ___  / /_ / /  ___  / /_ (_)__ __
 _\ \ / // // _ \/ __// _ \/ -_)/ __// / \ \ /
/___/ \_, //_//_/\__//_//_/\__/ \__//_/ /_\_\
     /___/

* Synthetix: MultiRewardPool.sol
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

import "../convex/Interfaces.sol";
import "../convex/MathUtil.sol";
import "@openzeppelin/contracts-0.8/utils/math/SafeMath.sol";
import "@openzeppelin/contracts-0.8/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-0.8/utils/Address.sol";
import "@openzeppelin/contracts-0.8/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts-0.8/security/ReentrancyGuard.sol";
import {AuraMath, AuraMath32, AuraMath112, AuraMath224} from "../utils/AuraMath.sol";

/**
 * @title   MultiRewardPool
 * @author  Synthetix -> ConvexFinance
 * @notice  Unipool rewards contract that is re-deployed from rFactory for each staking pool.
 * @dev     Same as BaseRewardPool except that the DAO can push multiple rewards.
 */
contract MultiRewardPool is ReentrancyGuard {
    using AuraMath for uint256;
    using AuraMath224 for uint224;
    using AuraMath112 for uint112;
    using AuraMath32 for uint32;
    using SafeERC20 for IERC20;

    /* ==========     STRUCTS     ========== */

    struct RewardData {
        /// Timestamp for current period finish
        uint32 periodFinish;
        /// Last time any user took action
        uint32 lastUpdateTime;
        /// RewardRate for the rest of the period
        uint96 rewardRate;
        /// Ever increasing rewardPerToken rate, based on % of total supply
        uint96 rewardPerTokenStored;
    }
    struct UserData {
        uint128 rewardPerTokenPaid;
        uint128 rewards;
    }
    struct EarnedData {
        address token;
        uint256 amount;
    }

    address[] public rewardTokens;
    IERC20 public immutable stakingToken;
    uint256 public constant duration = 12 days;

    address public immutable operator;
    mapping(address => RewardData) public rewardData;

    mapping(address => uint256) public queuedRewards;
    uint256 public currentRewards = 0;
    mapping(address => uint256) public historicalRewards;
    uint256 public constant newRewardRatio = 830;
    uint256 private _totalSupply;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    mapping(address => uint256) private _balances;

    mapping(address => bool) public rewardDistributors;

    mapping(address => mapping(address => UserData)) public userData;

    event RewardAdded(address indexed _token, uint256 _reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(
        address indexed _user,
        address indexed _rewardsToken,
        uint256 _reward
    );

    /**
     * @dev This is called directly from RewardFactory
     * @param stakingToken_  Staking token.
     * @param rewardTokens_  Reward tokens
     */
    constructor(
        address stakingToken_,
        address[] memory rewardTokens_,
        address operator_
    ) {
        stakingToken = IERC20(stakingToken_);
        rewardTokens = rewardTokens_;
        operator = operator_;
    }

    modifier updateReward(address _account) {
        {
            uint256 rewardTokensLength = rewardTokens.length;
            for (uint256 i = 0; i < rewardTokensLength; i = unchkIncr(i)) {
                address token = rewardTokens[i];
                uint256 newRewardPerToken = _rewardPerToken(token);
                rewardData[token].rewardPerTokenStored = newRewardPerToken
                    .to96();
                rewardData[token].lastUpdateTime = _lastTimeRewardApplicable(
                    rewardData[token].periodFinish
                ).to32();
                if (_account != address(0)) {
                    userData[_account][token] = UserData({
                        rewardPerTokenPaid: newRewardPerToken.to128(),
                        rewards: _earned(_account, token).to128()
                    });
                }
            }
        }
        _;
    }

    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    // Add a new reward token to be distributed to stakers
    function addReward(address _rewardsToken) external {
        require(msg.sender == operator, "!authorized");
        require(
            rewardData[_rewardsToken].lastUpdateTime == 0,
            "Reward already exists"
        );
        require(
            _rewardsToken != address(stakingToken),
            "Cannot add StakingToken as reward"
        );
        require(rewardTokens.length < 5, "Max rewards length");

        rewardTokens.push(_rewardsToken);
        rewardData[_rewardsToken].lastUpdateTime = uint32(block.timestamp);
        rewardData[_rewardsToken].periodFinish = uint32(block.timestamp);
    }

    /***************************************
                VIEWS - REWARDS
    ****************************************/

    // Address and claimable amount of all reward tokens for the given account
    function claimableRewards(
        address _account
    ) external view returns (EarnedData[] memory userRewards) {
        userRewards = new EarnedData[](rewardTokens.length);

        uint256 userRewardsLength = userRewards.length;
        for (uint256 i = 0; i < userRewardsLength; i = unchkIncr(i)) {
            address token = rewardTokens[i];
            userRewards[i].token = token;
            userRewards[i].amount = _earned(_account, token);
        }
        return userRewards;
    }

    function lastTimeRewardApplicable(
        address _rewardsToken
    ) external view returns (uint256) {
        return
            _lastTimeRewardApplicable(rewardData[_rewardsToken].periodFinish);
    }

    function rewardPerToken(
        address _rewardsToken
    ) external view returns (uint256) {
        return _rewardPerToken(_rewardsToken);
    }

    function _earned(
        address _user,
        address _rewardsToken
    ) internal view returns (uint256) {
        UserData memory data = userData[_user][_rewardsToken];
        return
            _balances[_user]
                .mul(
                    _rewardPerToken(_rewardsToken).sub(data.rewardPerTokenPaid)
                )
                .div(1e18)
                .add(data.rewards);
    }

    function _lastTimeRewardApplicable(
        uint256 _finishTime
    ) internal view returns (uint256) {
        return AuraMath.min(block.timestamp, _finishTime);
    }

    function _rewardPerToken(
        address _rewardsToken
    ) internal view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardData[_rewardsToken].rewardPerTokenStored;
        }
        return
            uint256(rewardData[_rewardsToken].rewardPerTokenStored).add(
                _lastTimeRewardApplicable(
                    rewardData[_rewardsToken].periodFinish
                )
                    .sub(rewardData[_rewardsToken].lastUpdateTime)
                    .mul(rewardData[_rewardsToken].rewardRate)
                    .mul(1e18)
                    .div(_totalSupply)
            );
    }

    function deposit(uint256 _amount) public nonReentrant returns (bool) {
        _processStake(_amount, msg.sender);

        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        emit Staked(msg.sender, _amount);

        return true;
    }

    function stakeAll() external returns (bool) {
        uint256 balance = stakingToken.balanceOf(msg.sender);
        deposit(balance);
        return true;
    }

    function depositFor(
        uint256 _amount,
        address _for
    ) public nonReentrant returns (bool) {
        _processStake(_amount, _for);

        //take away from sender
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        emit Staked(_for, _amount);

        return true;
    }

    /**
     * @dev Generic internal staking function that basically does 3 things: update rewards based
     *      on previous balance, trigger also on any child contracts, then update balances.
     * @param _amount    Units to add to the users balance
     * @param _receiver  Address of user who will receive the stake
     */
    function _processStake(
        uint256 _amount,
        address _receiver
    ) internal updateReward(_receiver) {
        require(_amount > 0, "RewardPool : Cannot stake 0");

        _totalSupply = _totalSupply.add(_amount);
        _balances[_receiver] = _balances[_receiver].add(_amount);
    }

    function withdraw(
        uint256 amount,
        bool claim
    ) public nonReentrant updateReward(msg.sender) returns (bool) {
        require(amount > 0, "RewardPool : Cannot withdraw 0");

        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = _balances[msg.sender].sub(amount);

        stakingToken.safeTransfer(msg.sender, amount);

        if (claim) {
            _getReward(msg.sender, true);
        }

        emit Withdrawn(msg.sender, amount);
        return true;
    }

    function withdrawAll(bool claim) external {
        withdraw(_balances[msg.sender], claim);
    }

    function withdrawAndUnwrap(
        uint256 amount,
        bool claim
    ) public nonReentrant returns (bool) {
        _withdrawAndUnwrapTo(amount, msg.sender, msg.sender);
        //get rewards too
        if (claim) {
            getReward(msg.sender, true);
        }
        return true;
    }

    function _withdrawAndUnwrapTo(
        uint256 amount,
        address from,
        address receiver
    ) internal updateReward(from) returns (bool) {
        _totalSupply = _totalSupply.sub(amount);
        _balances[from] = _balances[from].sub(amount);

        stakingToken.transfer(receiver, amount);
        emit Withdrawn(from, amount);

        return true;
    }

    function withdrawAllAndUnwrap(bool claim) external {
        withdrawAndUnwrap(_balances[msg.sender], claim);
    }

    /**
     * @dev Gives a staker their rewards, with the option of claiming extra rewards
     * @param _account     Account for which to claim
     * @param _claimExtras Get the child rewards too?
     */
    function getReward(
        address _account,
        bool _claimExtras
    ) public nonReentrant updateReward(_account) returns (bool) {
        return _getReward(_account, _claimExtras);
    }

    function _getReward(
        address _account,
        bool _claimExtras
    ) internal updateReward(_account) returns (bool) {
        uint256 rewardTokensLength = rewardTokens.length;
        for (uint256 i = 0; i < rewardTokensLength; i = unchkIncr(i)) {
            address _rewardsToken = rewardTokens[i];
            uint256 reward = userData[_account][_rewardsToken].rewards;
            if (reward > 0) {
                userData[_account][_rewardsToken].rewards = 0;
                IERC20(_rewardsToken).safeTransfer(_account, reward);
                emit RewardPaid(_account, _rewardsToken, reward);
            }
        }

        return true;
    }

    /**
     * @dev Called by a staker to get their allocated rewards
     */
    function getReward() external returns (bool) {
        getReward(msg.sender, true);
        return true;
    }

    // Modify approval for an address to call queueNewRewards
    function approveRewardDistributor(
        address _rewardsToken,
        address _distributor,
        bool _approved
    ) external {
        require(msg.sender == operator, "!authorized");
        rewardDistributors[_distributor] = _approved;
    }

    /***************************************
                REWARD FUNDING
    ****************************************/
    function queueNewRewards(
        address _rewardsToken,
        uint256 _rewards
    ) external nonReentrant {
        require(
            rewardDistributors[msg.sender] || msg.sender == operator,
            "!authorized"
        );
        require(_rewards > 0, "No reward");

        RewardData storage rdata = rewardData[_rewardsToken];

        IERC20(_rewardsToken).safeTransferFrom(
            msg.sender,
            address(this),
            _rewards
        );

        _rewards = _rewards.add(queuedRewards[_rewardsToken]);
        require(_rewards < 1e25, "!rewards");

        if (block.timestamp >= rdata.periodFinish) {
            _notifyReward(_rewardsToken, _rewards);
            queuedRewards[_rewardsToken] = 0;
            return;
        }

        //et = now - (finish-duration)
        uint256 elapsedTime = block.timestamp.sub(
            rdata.periodFinish.sub(duration.to32())
        );
        //current at now: rewardRate * elapsedTime
        uint256 currentAtNow = rdata.rewardRate * elapsedTime;
        uint256 queuedRatio = currentAtNow.mul(1000).div(_rewards);
        if (queuedRatio < newRewardRatio) {
            _notifyReward(_rewardsToken, _rewards);
            queuedRewards[_rewardsToken] = 0;
        } else {
            queuedRewards[_rewardsToken] = _rewards;
        }
    }

    function _notifyReward(
        address _rewardsToken,
        uint256 _reward
    ) internal updateReward(address(0)) {
        RewardData storage rdata = rewardData[_rewardsToken];
        historicalRewards[_rewardsToken] = historicalRewards[_rewardsToken].add(
            _reward
        );

        if (block.timestamp >= rdata.periodFinish) {
            rdata.rewardRate = _reward.div(duration).to96();
        } else {
            uint256 remaining = uint256(rdata.periodFinish).sub(
                block.timestamp
            );
            uint256 leftover = remaining.mul(rdata.rewardRate);
            rdata.rewardRate = _reward.add(leftover).div(duration).to96();
        }

        // Equivalent to 10 million tokens over a weeks duration
        require(rdata.rewardRate < 1e20, "!rewardRate");

        rdata.lastUpdateTime = block.timestamp.to32();
        rdata.periodFinish = block.timestamp.add(duration).to32();

        emit RewardAdded(_rewardsToken, _reward);
    }

    function unchkIncr(uint256 i) private pure returns (uint256) {
        unchecked {
            return i + 1;
        }
    }
}
