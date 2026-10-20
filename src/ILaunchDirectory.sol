// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title ERC-8376 launch directory
/// @notice `ILaunchDirectory` as ERC-8376 defines it: the same events and functions, with shorter comments. A launch
///         is identified by `keccak256(abi.encode(block.chainid, escrow, token, deployer, nonce))`, and only the
///         escrow named in that identifier may list it.
interface ILaunchDirectory {
    event LaunchListed(
        bytes32 indexed launchId, address indexed token, address indexed deployer, address escrow, address venue
    );

    /// @notice List a launch. Caller MUST be the escrow named in the identifier.
    function list(bytes32 launchId, address token, address deployer, address venue, uint256 nonce) external;

    /// @notice Every launch recorded for a token, oldest first.
    function launchesOf(address token) external view returns (bytes32[] memory);

    /// @notice Every launch by a deployer, oldest first.
    function launchesBy(address deployer) external view returns (bytes32[] memory);

    function escrowOf(bytes32 launchId) external view returns (address);
    function venueOf(bytes32 launchId) external view returns (address);
    function deployerOf(bytes32 launchId) external view returns (address);
    function tokenOf(bytes32 launchId) external view returns (address);
}
