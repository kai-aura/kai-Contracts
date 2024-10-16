// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

// https://github.com/convex-eth/platform/blob/d3061c19b5e01a4e562c8121b08c44f1b42f0b85/contracts/contracts/interfaces/IDelegation.sol
interface IDelegation {
    function clearDelegate(bytes32 _id) external;

    function setDelegate(bytes32 _id, address _delegate) external;

    function delegation(address _address, bytes32 _id) external view returns (address);
}
