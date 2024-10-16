// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "@openzeppelin/contracts-0.8/utils/math/SafeMath.sol";
import "@openzeppelin/contracts-0.8/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts-0.8/utils/Address.sol";
import "@openzeppelin/contracts-0.8/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-0.8/token/ERC20/ERC20.sol";

/**
 * @title   kaiAuraToken
 * @author  ConvexFinance
 * @notice  Dumb ERC20 token that allows the operator (crvDepositor) to mint and burn tokens. Forked from cCrv.sol to remove creator.
 */
contract kaiAuraToken is ERC20 {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public operator;

    constructor(string memory _nameArg, string memory _symbolArg) public ERC20(_nameArg, _symbolArg) {
        operator = msg.sender;
    }

    /**
     * @notice Allows the initial operator (deployer) to set the operator.
     *         Note - In AURA (but not kai!): crvDepositor has no way to change this back, so it's effectively immutable
     */
    function setOperator(address _operator) external {
        require(msg.sender == operator, "!auth");
        operator = _operator;
    }

    /**
     * @notice Allows the crvDepositor to mint
     */
    function mint(address _to, uint256 _amount) external {
        require(msg.sender == operator, "!authorized");

        _mint(_to, _amount);
    }

    /**
     * @notice Allows the crvDepositor to burn
     */
    function burn(address _from, uint256 _amount) external {
        require(msg.sender == operator, "!authorized");

        _burn(_from, _amount);
    }
}
