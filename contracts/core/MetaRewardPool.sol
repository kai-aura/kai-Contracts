// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { UD60x18, ud, convert, pow, powu, intoUint256 } from "@prb/math/src/UD60x18.sol";
import { IERC20 } from "@openzeppelin/contracts-0.8/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts-0.8/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts-0.8/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts-0.8/security/ReentrancyGuard.sol";
import { AuraMath, AuraMath32, AuraMath112, AuraMath224 } from "../utils/AuraMath.sol";
import { IKaiToken } from "../interfaces/IKaiToken.sol";
import { IRewardStaking } from "../interfaces/IRewardStaking.sol";
import { IKaiRewardPool } from "../interfaces/IKaiRewardPool.sol";
import { IBaseRewardPool4626 } from "../convex/IBaseRewardPool4626.sol";

interface RewardPool {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

/**
 * @title   MetaRewardPool
 * @author  ConvexFinance -> AuraFinance -> KaiFinance
 * @notice
 * @dev     Reward pool with checkpoints that hooks into an underlying AuraRewardPool.
 */
contract MetaRewardPool is ReentrancyGuard, Ownable, IKaiRewardPool {
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

    struct TransactionData {
        uint256 amount;
        // Block timestamp of the transaction.
        uint256 date;
    }
    struct RewardCheckpoint {
        // Total supply of staked tokens at the time of checkpoint.
        uint256 totalSupply;
        // Block timestamp of the checkpoint.
        uint256 date;
        // Amount of rewards earned since the last checkpoint.
        uint256 amount;
    }

    /* ========== STATE VARIABLES ========== */
    IKaiToken public rewardToken;
    address[] public underlyingRewardTokens;

    //     Core reward data
    mapping(address => RewardData) public rewardData;

    // Harvest no more than once per 1 days when somebody withdraws.
    uint256 public constant harvestCooldownPeriod = 86400;
    uint256 public lastHarvestedAt = 0;

    // Balances
    //     Supplies and historic supply
    uint256 public stakedSupply;

    //     Epochs contains only the tokens that were locked at that epoch, not a cumulative supply
    // token address -> array of reward checkpoints for that rewards token
    mapping(address => RewardCheckpoint[]) public rewardCheckpointsMap;

    //     Mappings for balance data
    mapping(address => uint256) public balances;

    //     Mappings for deposit & withdraw data
    mapping(address => TransactionData[]) public deposits;
    mapping(address => TransactionData[]) public withdraws;
    mapping(address => uint256) public totalWithdrawn;
    mapping(address => uint256) private _locked_liquidity;

    // Track last withdraw of rewards for each user,token tuple (user -> token address -> timestamp)
    mapping(address => mapping(address => uint256)) public lastRewardClaimDate;
    mapping(address => mapping(address => uint256)) public totalRewardsClaimed;

    uint256 public rewardStartBlock;
    uint256 public kaiRewardRate = 0.997e18;
    uint256 public amplifierRate = 3;
    address public immutable auraAddress = 0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF;

    // Config
    //     Tokens
    IERC20 public immutable stakingToken;
    address public immutable auraRewardPool;

    //     Shutdown
    bool public isShutdown = false;

    /* ========== EVENTS ========== */
    event Recovered(address _token, uint256 _amount);
    event RewardPaid(address indexed _user, address indexed _rewardsToken, uint256 _reward);
    event Staked(address indexed _user, uint256 _depositedAmount);
    event Withdrawn(address indexed _user, uint256 _amount);

    event Shutdown();

    /***************************************
                    CONSTRUCTOR
    ****************************************/

    /**
     * @param _stakingToken     Staking Token (0xADDRESS_HERE)
     * @param _auraRewardPool   The aura BaseRewardPool that this pool will sit on top of.
     */
    constructor(
        address _stakingToken,
        address _auraRewardPool,
        address[] memory _underlyingRewardTokens,
        IKaiToken _rewardToken,
        uint256 _rewardStartBlock
    ) Ownable() {
        stakingToken = IERC20(_stakingToken);
        auraRewardPool = _auraRewardPool;
        underlyingRewardTokens = _underlyingRewardTokens;
        rewardToken = _rewardToken;

        if (_rewardStartBlock == 0) {
            rewardStartBlock = block.timestamp;
        } else {
            rewardStartBlock = _rewardStartBlock;
        }
    }

    /***************************************
                    ADMIN
    ****************************************/
    // Shutdown the contract.
    function shutdown() external onlyOwner {
        require(!isShutdown, "shutdown");
        isShutdown = true;
        emit Shutdown();
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        require(_tokenAddress != address(stakingToken), "Cannot withdraw staking token");

        IERC20(_tokenAddress).safeTransfer(owner(), _tokenAmount);
        emit Recovered(_tokenAddress, _tokenAmount);
    }

    /***************************************
                    ACTIONS
    ****************************************/

    // Deposited tokens can be withdrawn at any time, but rewards accumulate per epoch.
    function depositFor(uint256 _amount, address _account) external nonReentrant returns (bool) {
        // Take tokens from the user.
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);

        // Deposit them into Aura's reward pool.
        _deposit(_amount, _account);
        return true;
    }

    function _deposit(uint256 _amount, address _account) internal {
        require(_amount > 0, "Cannot stake 0");
        require(!isShutdown, "shutdown");

        // Deposit into the underlying pool.
        stakingToken.safeIncreaseAllowance(auraRewardPool, _amount);
        stakingToken.approve(auraRewardPool, _amount);

        RewardPool(auraRewardPool).deposit(_amount, address(this));

        //add user balances
        balances[_account] = balances[_account].add(_amount);
        deposits[_account].push(TransactionData({ date: block.timestamp, amount: _amount }));

        //add to total supplies
        stakedSupply = stakedSupply.add(_amount);

        emit Staked(_account, _amount);
    }

    // Claim all pending rewards
    function _getReward(address _account) internal {
        require(!isShutdown, "shutdown");
        EarnedData[] memory _userRewards = _claimableRewards(_account);

        for (uint256 i = 0; i < _userRewards.length; i = unchkIncr(i)) {
            if (_userRewards[i].amount > 0) {
                lastRewardClaimDate[_account][_userRewards[i].token] = block.timestamp;

                // We will transfer Kai to the user in the following for loop. First we have to mint
                // the token to ourselves.
                if (i == 0) {
                    rewardToken.minterMint(address(this), _userRewards[0].amount);
                }

                // TODO: Possible optimization: memoize the users balance as of the latest checkpoint so that we
                // can skip calculating all previous ones.
                totalRewardsClaimed[_account][_userRewards[i].token] = totalRewardsClaimed[_account][
                    _userRewards[i].token
                ].add(_userRewards[i].amount);
                IERC20(_userRewards[i].token).safeTransfer(_account, _userRewards[i].amount);
                emit RewardPaid(_account, _userRewards[i].token, _userRewards[i].amount);
            }
        }
    }

    function getReward(address _account) external nonReentrant returns (bool) {
        _getReward(_account);
        return true;
    }

    // Withdraw all and get rewards.
    function withdrawAll() external nonReentrant {
        _withdraw(msg.sender, balances[msg.sender], true);
    }

    function withdrawWithoutRewards() external nonReentrant {
        _withdraw(msg.sender, balances[msg.sender], false);
    }

    // Withdraw without checkpointing or accruing any rewards, providing system is shutdown
    function emergencyWithdraw() external nonReentrant {
        require(isShutdown, "!shutdown");
        uint256 userBalance = balances[msg.sender];
        require(userBalance > 0, "no balance");
        balances[msg.sender] = 0;

        require(
            IBaseRewardPool4626(auraRewardPool).withdraw(userBalance, address(this), address(this)) == userBalance,
            "!unstake"
        );

        stakingToken.safeTransfer(msg.sender, userBalance);
    }

    // Withdraw all currently locked tokens where the unlock time has passed
    function _withdraw(address _account, uint256 _amount, bool _takeRewards) internal {
        require(!isShutdown, "shutdown");
        uint256 userBalance = balances[_account];
        require(userBalance > 0, "no balance");
        require(userBalance >= _amount, "MetaRewardPool: Insufficient balance");

        // Withdraw the requested amount, and claim rewards.
        // There is also a withdrawAndUnwrap function that we could consider using instead.
        require(
            IBaseRewardPool4626(auraRewardPool).withdraw(_amount, address(this), address(this)) == _amount,
            "!unstake"
        );

        if (_takeRewards) {
            _getReward(_account);
        }

        //update user balances and total supplies
        balances[_account] = balances[_account].sub(_amount);
        withdraws[_account].push(TransactionData({ date: block.timestamp, amount: _amount }));

        totalWithdrawn[_account] = totalWithdrawn[_account].add(_amount);
        stakedSupply = stakedSupply.sub(_amount);

        stakingToken.safeTransfer(_account, _amount);
        emit Withdrawn(_account, _amount);
    }

    function harvestRewards() public nonReentrant {
        return _harvestRewards();
    }

    function _harvestRewards() internal {
        lastHarvestedAt = block.timestamp;

        uint256[] memory balancesBefore = new uint256[](underlyingRewardTokens.length);

        for (uint256 i = 0; i < underlyingRewardTokens.length; i = unchkIncr(i)) {
            balancesBefore[i] = IERC20(underlyingRewardTokens[i]).balanceOf(address(this));
        }

        IBaseRewardPool4626(auraRewardPool).getReward(address(this), true);

        for (uint256 i = 0; i < underlyingRewardTokens.length; i = unchkIncr(i)) {
            uint256 balanceAfter = IERC20(underlyingRewardTokens[i]).balanceOf(address(this));

            if (balanceAfter > balancesBefore[i] || rewardCheckpointsMap[underlyingRewardTokens[i]].length == 0) {
                if (rewardCheckpointsMap[underlyingRewardTokens[i]].length == 0) {
                    rewardCheckpointsMap[underlyingRewardTokens[i]].push(
                        RewardCheckpoint({ date: block.timestamp, amount: 0, totalSupply: stakedSupply })
                    );
                }

                rewardCheckpointsMap[underlyingRewardTokens[i]].push(
                    RewardCheckpoint({
                        date: block.timestamp,
                        amount: balanceAfter - balancesBefore[i],
                        totalSupply: stakedSupply
                    })
                );
            }
        }
    }

    /***************************************
                VIEWS - BALANCES
    ****************************************/

    function balanceOf(address _user) external view returns (uint256) {
        return balances[_user];
    }

    // Supply of all properly locked balances at most recent eligible epoch
    function totalSupply() external view returns (uint256 supply) {
        return stakedSupply;
    }

    // Address and claimable amount of all reward tokens for the given account
    function claimableRewards(address _account) external nonReentrant returns (EarnedData[] memory userRewards) {
        return _claimableRewards(_account);
    }

    function _claimableRewards(address _account) internal returns (EarnedData[] memory userRewards) {
        // Harvest only if the cooldown period has passed since the last harvest.
        if (lastHarvestedAt + harvestCooldownPeriod <= block.timestamp) {
            _harvestRewards();
        }

        // Underlying pool's extra rewards + the main reward token.
        userRewards = new EarnedData[](underlyingRewardTokens.length + 1);

        for (uint256 i = 0; i < underlyingRewardTokens.length; i = unchkIncr(i)) {
            userRewards[i + 1] = EarnedData({
                token: underlyingRewardTokens[i],
                amount: _earned(_account, underlyingRewardTokens[i])
            });
        }

        // NOTE: We are basing Kai rewards based on the first token in underlyingRewardTokens.
        // So if that needs to be based off of Aura, then the first element of underlyingRewardTokens MUST be the Aura address.
        uint256 kaiRewardsEarned = 0;

        if (userRewards[1].token == auraAddress) {
            kaiRewardsEarned = _calculateKaiRewards(block.timestamp - rewardStartBlock, userRewards[1].amount);
        }

        userRewards[0] = EarnedData({ token: address(rewardToken), amount: kaiRewardsEarned });

        return userRewards;
    }

    function _calculateKaiRewards(uint256 timePassed, uint256 amount) internal view returns (uint256) {
        uint256 daysPassed = (timePassed / 86400) + 1;

        if (daysPassed > 1825) {
            return 0;
        }

        // amplifierRate * amount * (kaiRewardRate ^ daysPassed)
        return amplifierRate * intoUint256(ud(amount).mul(powu(ud(kaiRewardRate), daysPassed)));
    }

    function calculateKaiRewards(uint256 timePassed, uint256 amount) external view returns (uint256) {
        return _calculateKaiRewards(timePassed, amount);
    }

    function setKaiRewardRate(uint256 newRewardRate, uint256 newAmplifierRate) public onlyOwner {
        kaiRewardRate = newRewardRate;
        amplifierRate = newAmplifierRate;
    }

    function setUnderlyingRewardTokens(address[] memory _underlyingRewardTokens) public onlyOwner {
        underlyingRewardTokens = _underlyingRewardTokens;
    }

    /***************************************
                VIEWS - REWARDS
    ****************************************/

    function _earned(address _user, address _rewardsToken) internal view returns (uint256) {
        TransactionData[] memory myDeposits = deposits[_user];
        TransactionData[] memory myWithdraws = withdraws[_user];
        uint256 rewardsClaimed = totalRewardsClaimed[_user][_rewardsToken];

        uint256 withdrawIndex = 0;
        uint256 depositIndex = 0;
        uint256 tokensCarriedOver = 0;
        uint256 rewardsEarned = 0;
        RewardCheckpoint[] memory rewardCheckpoints = rewardCheckpointsMap[_rewardsToken];

        // First checkpoint is a dummy checkpoint that gives us the reference for dead reckoning the rest.
        for (uint256 i = 1; i < rewardCheckpoints.length; i = unchkIncr(i)) {
            uint256 checkpointStart = rewardCheckpoints[i - 1].date;
            uint256 checkpointDuration = rewardCheckpoints[i].date - checkpointStart;

            // Handle the case when it's the first harvest.
            if (checkpointDuration == 0) {
                checkpointDuration = 1;
            }

            uint256 sumOfWithdraws = 0;

            for (
                ;
                withdrawIndex < myWithdraws.length && myWithdraws[withdrawIndex].date < rewardCheckpoints[i].date;
                withdrawIndex++
            ) {
                sumOfWithdraws = sumOfWithdraws.add(myWithdraws[withdrawIndex].amount);
            }

            if (tokensCarriedOver >= sumOfWithdraws) {
                tokensCarriedOver = tokensCarriedOver.sub(sumOfWithdraws);
                sumOfWithdraws = 0;
            } else if (sumOfWithdraws > tokensCarriedOver) {
                sumOfWithdraws = sumOfWithdraws.sub(tokensCarriedOver);
                tokensCarriedOver = 0;
            }

            uint256 proratedTokens = tokensCarriedOver;
            TransactionData memory myDeposit;

            // Get all deposits for this checkpoint.
            for (
                ;
                depositIndex < myDeposits.length && myDeposits[depositIndex].date < rewardCheckpoints[i].date;
                depositIndex++
            ) {
                myDeposit = myDeposits[depositIndex];
                uint256 tokens = myDeposit.amount;

                if (sumOfWithdraws >= tokens) {
                    sumOfWithdraws = sumOfWithdraws.sub(tokens);
                    continue;
                } else if (sumOfWithdraws > 0) {
                    tokens = tokens.sub(sumOfWithdraws);
                    sumOfWithdraws = 0;
                }

                uint256 prorateRatio = 1;

                if (myDeposit.date > checkpointStart) {
                    uint256 dateSinceCheckpoint = myDeposit.date - checkpointStart;
                    prorateRatio = 1 - (dateSinceCheckpoint / checkpointDuration);
                }

                proratedTokens = proratedTokens.add(tokens * prorateRatio);
                tokensCarriedOver = tokensCarriedOver.add(tokens);
            }

            if (proratedTokens > 0 && rewardCheckpoints[i].amount > 0) {
                // Protect against accidental miscalculation.
                if (proratedTokens > rewardCheckpoints[i].totalSupply) {
                    proratedTokens = rewardCheckpoints[i].totalSupply;
                }

                rewardsEarned = rewardsEarned.add(
                    rewardCheckpoints[i].amount.mul(1e18).div(rewardCheckpoints[i].totalSupply).mul(proratedTokens).div(
                        1e18
                    )
                );
            }
        }

        return rewardsEarned.sub(rewardsClaimed);
    }

    function unchkIncr(uint256 i) private pure returns (uint256) {
        unchecked {
            return i + 1;
        }
    }
}
