// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {ILaunchDirectory} from "../../src/ILaunchDirectory.sol";
import {ILaunchDeclarations} from "../../src/ILaunchDeclarations.sol";

/// @notice An ERC-8376 directory: permissionless, ownerless, and checking only that the caller is the escrow named in
///         the identifier, which it recomputes from the caller and the listed fields. A launch is listed once.
contract MockLaunchDirectory is ILaunchDirectory {
    struct Launch {
        address token;
        address deployer;
        address escrow;
        address venue;
    }

    mapping(bytes32 => Launch) private _launches;
    mapping(address => bytes32[]) private _byToken;
    mapping(address => bytes32[]) private _byDeployer;

    error NotEscrowOfLaunch();
    error AlreadyListed();

    function list(bytes32 launchId, address token, address deployer, address venue, uint256 nonce) external {
        if (keccak256(abi.encode(block.chainid, msg.sender, token, deployer, nonce)) != launchId) {
            revert NotEscrowOfLaunch();
        }
        if (_launches[launchId].escrow != address(0)) revert AlreadyListed();
        _launches[launchId] = Launch({token: token, deployer: deployer, escrow: msg.sender, venue: venue});
        _byToken[token].push(launchId);
        _byDeployer[deployer].push(launchId);
        emit LaunchListed(launchId, token, deployer, msg.sender, venue);
    }

    function launchesOf(address token) external view returns (bytes32[] memory) {
        return _byToken[token];
    }

    function launchesBy(address deployer) external view returns (bytes32[] memory) {
        return _byDeployer[deployer];
    }

    function escrowOf(bytes32 launchId) external view returns (address) {
        return _launches[launchId].escrow;
    }

    function venueOf(bytes32 launchId) external view returns (address) {
        return _launches[launchId].venue;
    }

    function deployerOf(bytes32 launchId) external view returns (address) {
        return _launches[launchId].deployer;
    }

    function tokenOf(bytes32 launchId) external view returns (address) {
        return _launches[launchId].token;
    }
}

/// @notice An ERC-8004 identity registry reduced to what the tests need: ids assigned incrementally from 1, `ownerOf`
///         reverting for an id never issued, and an agent wallet that starts as the owner and is cleared on transfer.
contract MockIdentityRegistry {
    uint256 private _next = 1;
    mapping(uint256 => address) private _owners;
    mapping(uint256 => address) private _wallets;

    function register(address owner) external returns (uint256 agentId) {
        agentId = _next++;
        _owners[agentId] = owner;
        _wallets[agentId] = owner;
    }

    /// @dev ERC-8004 asks for a signature from the new wallet; the mock trusts the owner.
    function setAgentWallet(uint256 agentId, address wallet) external {
        require(_owners[agentId] == msg.sender, "not owner");
        _wallets[agentId] = wallet;
    }

    function transfer(uint256 agentId, address to) external {
        require(_owners[agentId] == msg.sender, "not owner");
        _owners[agentId] = to;
        delete _wallets[agentId];
    }

    function ownerOf(uint256 agentId) external view returns (address owner) {
        owner = _owners[agentId];
        require(owner != address(0), "no token");
    }

    function getAgentWallet(uint256 agentId) external view returns (address) {
        return _wallets[agentId];
    }
}

/// @notice An ERC-721-shaped registry with `ownerOf` and no agent wallet.
contract MockERC721Registry {
    mapping(uint256 => address) private _owners;

    function mint(address to, uint256 id) external {
        _owners[id] = to;
    }

    function ownerOf(uint256 id) external view returns (address owner) {
        owner = _owners[id];
        require(owner != address(0), "no token");
    }
}

/// @notice A contract wallet that approves, through ERC-1271, what its owner key signed.
contract MockERC1271Wallet {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        if (signature.length != 65) return 0xffffffff;
        bytes32 r = bytes32(signature[0:32]);
        bytes32 s = bytes32(signature[32:64]);
        uint8 v = uint8(signature[64]);
        return ecrecover(hash, v, r, s) == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

/// @notice A launchpad at ERC-8376 detection level: it lists its own launches, so it is the escrow named in their ids
///         and the venue the directory records, and it declares each launch's facts in the same transaction. The
///         caller of `launch` is the applicant, and is listed as the deployer; it hands over its authorization to
///         attach its identity.
contract MockLaunchpad {
    ILaunchDirectory public immutable directory;
    ILaunchDeclarations public immutable declarations;
    mapping(address => mapping(address => uint256)) public launchCount; // token => deployer => launches here

    constructor(ILaunchDirectory directory_, ILaunchDeclarations declarations_) {
        directory = directory_;
        declarations = declarations_;
    }

    struct Facts {
        address identityRegistry;
        uint256 agentId;
        address teamVesting;
        uint256 teamAmount;
        address liquidityLocks;
        uint256 lockId;
        address feeRights;
        uint256 deadline;
        bytes creatorSignature;
    }

    function launch(address token, Facts calldata f) external returns (bytes32 launchId) {
        uint256 nonce = launchCount[token][msg.sender]++;
        launchId = keccak256(abi.encode(block.chainid, address(this), token, msg.sender, nonce));
        directory.list(launchId, token, msg.sender, address(this), nonce);

        declarations.declareListedCreator(launchId, f.identityRegistry, f.agentId, f.deadline, f.creatorSignature);
        uint64 start = uint64(block.timestamp) + 30 days;
        declarations.declareAllocation(launchId, f.teamVesting, f.teamAmount, start, start + 335 days);
        declarations.declareLiquidity(launchId, f.liquidityLocks, f.lockId, address(0), address(0), 0, 0);
        declarations.declareFeeRecipient(launchId, f.feeRights, msg.sender);
    }

    /// @notice A venue-scoped declaration by the same launchpad, for a launch it does not list.
    function declareUnlisted(address token, address creator, uint256 deadline, bytes calldata creatorSignature)
        external
        returns (bytes32)
    {
        return declarations.declareVenueCreator(token, creator, address(0), 0, deadline, creatorSignature);
    }
}
