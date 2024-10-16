// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { IAuraDepositor } from "../interfaces/IAuraDepositor.sol";
import { IDelegation } from "../interfaces/IDelegation.sol";
import { IAuraLocker } from "../interfaces/IAuraLocker.sol";
import { IMintable } from "../interfaces/IMintable.sol";
import { IRewardStaking } from "../interfaces/IRewardStaking.sol";
import { Address } from "@openzeppelin/contracts-0.8/utils/Address.sol";
import { IERC20 } from "@openzeppelin/contracts-0.8/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts-0.8/token/ERC20/utils/SafeERC20.sol";
import { SafeMath } from "@openzeppelin/contracts-0.8/utils/math/SafeMath.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts-0.8/security/ReentrancyGuard.sol";

/**
 * @title   AuraDepositor
 * @author  KaiFinance
 * @notice  This is the entry point for Aura > kaiAura wrapping. It accepts Aura, sends to 'AuraLocker'
 *          and then mints kaiAura at 1:1 via the 'minter'.
 *          There is no lock incentive like CrvDepositor because AuraLocker
 *          has a simpler engagement model which doesn't let us make optimizations
 *          like the ones in CrvDepositor.
 */
contract AuraDepositor is IAuraDepositor, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    struct EarnedData {
        address token;
        uint256 startingBalance;
    }

    address public immutable aura;
    uint256 internal constant MAXTIME = 1 * 364 * 86400;
    uint256 internal constant WEEK = 7 * 86400;

    address public daoOperator;
    address public immutable locker;
    address public immutable kaiLocker;
    address public immutable minter;

    bool public cooldown;

    /**
     * @param _locker   AuraLocker (vlAura) (0x3Fa73f1E5d8A792C80F426fc8F84FBF7Ce9bBCAC)
     * @param _kaiLocker   KaiLocker (vlKai) (0x?)
     * @param _minter   kaiAura token (TBD)
     * @param _aura   aura
     */
    constructor(address _locker, address _kaiLocker, address _minter, address _aura, address _daoOperator) {
        locker = _locker;
        kaiLocker = _kaiLocker;
        minter = _minter;
        aura = _aura;
        daoOperator = _daoOperator;
    }

    function setDaoOperator(address _daoOperator) external {
        require(msg.sender == daoOperator, "!auth");
        daoOperator = _daoOperator;
    }

    function emergencyWithdraw(address token, address to) external {
        require(msg.sender == daoOperator, "!auth");
        IERC20(token).transfer(to, IERC20(token).balanceOf(address(this)));
    }

    function setApprovals() external {
        require(IERC20(aura).approve(daoOperator, type(uint256).max), "!approval");
    }

    function setCooldown(bool _cooldown) external {
        require(msg.sender == daoOperator, "!auth");
        cooldown = _cooldown;
    }

    function _lockAura(uint256 amountToLock, address to) internal {
        // Don't let people stake Aura while the daoOperator has imposed a cooldown period.
        if (cooldown) {
            return;
        }

        IERC20(aura).approve(locker, amountToLock);
        IAuraLocker(locker).lock(to, amountToLock);

        require(IERC20(aura).balanceOf(address(this)) == 0, "failedToLock");
    }

    /**
     * @notice Deposit aura for kaiAura
     * @dev    Locked immediately.
     */
    function depositFor(address to, uint256 _amount) public {
        require(_amount > 0, "!>0");
        require(!cooldown, "cooldown");

        // CrvDepositor transfers directly to staker to skip an erc20 transfer,
        // but we can't do that with AuraLocker because its lock function
        // does the transfer by itself.
        IERC20(aura).transferFrom(msg.sender, address(this), _amount);
        _lockAura(_amount, daoOperator);

        // Mint cvxCrv and send to depositor.
        IMintable(minter).mint(to, _amount);
    }

    function claimRewards() public {
        require(!cooldown, "cooldown");

        EarnedData[] memory expectedRewards = new EarnedData[](5);

        for (uint16 i = 0; i < 5; i = unchkIncr(i)) {
            address token = IAuraLocker(locker).rewardTokens(i);

            if (token != address(0)) {
                expectedRewards[i].token = token;
                expectedRewards[i].startingBalance = IERC20(token).balanceOf(address(this));
            } else {
                break;
            }
        }

        IAuraLocker(locker).getReward(address(this));

        for (uint16 i = 0; i < 5; i = unchkIncr(i)) {
            if (expectedRewards[i].token != address(0)) {
                uint256 delta = IERC20(expectedRewards[i].token).balanceOf(address(this)) -
                    expectedRewards[i].startingBalance;

                if (delta > 0) {
                    IAuraLocker(kaiLocker).queueNewRewards(expectedRewards[i].token, delta);
                }
            } else {
                break;
            }
        }
    }

    function unchkIncr(uint16 i) private pure returns (uint16) {
        unchecked {
            return i + 1;
        }
    }
}
