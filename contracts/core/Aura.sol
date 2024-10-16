// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import { ERC20 } from "@openzeppelin/contracts-0.8/token/ERC20/ERC20.sol";
import { AuraMath } from "../utils/AuraMath.sol";
import { IMintable } from "../interfaces/IMintable.sol";
import { IKaiToken } from "../interfaces/IKaiToken.sol";

/**
 * @title   AuraToken
 * @notice  Basically an ERC20 with minting functionality operated by the DAO.
 * @dev     The minting schedule is based on the amount of CRV earned through staking and is
 *          distributed along a supply curve (cliffs etc). Fork of Aura (and originally ConvexToken).
 */
contract AuraToken is IKaiToken, ERC20, IMintable {
    using AuraMath for uint256;

    address public operator;
    mapping(address => bool) public allowedMinters;

    uint256 public constant MAX_SUPPLY = 10e25;
    uint256 public constant INIT_MINT_AMOUNT = 8e25;

    address public minter;
    uint256 private minterMinted = type(uint256).max;

    /* ========== EVENTS ========== */

    event Initialised();

    /**
     * @param _nameArg      Token name
     * @param _symbolArg    Token symbol
     */
    constructor(string memory _nameArg, string memory _symbolArg) ERC20(_nameArg, _symbolArg) {
        operator = msg.sender;
    }

    /**
     * @dev Initialise and mints initial supply of tokens.
     * @param _to        Target address to mint.
     * @param _minter    The minter address.
     */
    function init(address _to, address _minter) external {
        require(msg.sender == operator, "Only operator");
        require(totalSupply() == 0, "Only once");
        require(_minter != address(0), "Invalid minter");

        _mint(_to, INIT_MINT_AMOUNT);
        minter = _minter;
        minterMinted = 0;

        emit Initialised();
    }

    function setAllowedMinter(address _minter, bool _isAllowed) external {
        require(msg.sender == operator, "Only operator");
        allowedMinters[_minter] = _isAllowed;
    }

    function setOperator(address _operator) external {
        require(msg.sender == operator, "Only operator");
        operator = _operator;
    }

    /**
     * @dev Mints AURA to a given user based on the BAL supply schedule.
     */
    function mint(address _to, uint256 _amount) external {
        require(totalSupply() != 0, "Not initialised");
        require(_amount + totalSupply() < MAX_SUPPLY, "Would exceed max supply");

        if (msg.sender != operator) {
            // dont error just return. if a shutdown happens, rewards on old system
            // can still be claimed, just wont mint cvx
            return;
        }

        _mint(_to, _amount);
    }

    /**
     * @dev Allows minter to mint to a specific address
     */
    function minterMint(address _to, uint256 _amount) external {
        require(msg.sender == minter || allowedMinters[msg.sender] == true, "Only minter");
        minterMinted = minterMinted.add(_amount);
        _mint(_to, _amount);
    }
}
