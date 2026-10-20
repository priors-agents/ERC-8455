// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {ILaunchDeclarations} from "./ILaunchDeclarations.sol";
import {ILaunchDirectory} from "./ILaunchDirectory.sol";

interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}

interface IERC1271 {
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

/// @notice The two reads of an ERC-8004 identity registry this contract uses: `ownerOf` from ERC-721, and the agent
///         wallet ERC-8004 adds.
interface IIdentityRegistry {
    function ownerOf(uint256 agentId) external view returns (address);
    function getAgentWallet(uint256 agentId) external view returns (address);
}

/// @title LaunchDeclarations
/// @notice Reference implementation of the Launch Declarations draft. A launchpad calls it in its launch transaction,
///         next to an ERC-8376 directory. A launch the directory lists is declared under its `launchId` by the venue the
///         directory names, with the creator read from the directory; any other launch under an id scoped to the
///         venue that declares it. A venue-scoped declaration, and any identity, needs the creator's authorization:
///         the creator calls, or signs an EIP-712 `CreatorAuthorization` (ECDSA, or ERC-1271 for a contract). Only a
///         declaration's venue can add facts to it, and nothing declared can change.
/// @dev Not audited. A reference for the interface.
contract LaunchDeclarations is ILaunchDeclarations, IERC165 {
    /// @notice Domain tag of venue-scoped ids, so that none can equal an ERC-8376 `launchId`.
    bytes32 public constant VENUE_SCOPED = keccak256("erc.launch-declarations.venue-scoped");

    bytes32 public constant CREATOR_AUTHORIZATION_TYPEHASH = keccak256(
        "CreatorAuthorization(bytes32 declarationId,address venue,address token,address creator,address identityRegistry,uint256 agentId,uint256 deadline)"
    );
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant NAME_HASH = keccak256("Launch Declarations");
    bytes32 private constant VERSION_HASH = keccak256("1");
    bytes4 private constant ERC1271_MAGIC = 0x1626ba7e;
    /// @dev Half the secp256k1 group order: signatures with a larger `s` are malleable copies and are refused.
    uint256 private constant HALF_ORDER = 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    ILaunchDirectory private immutable _directory;

    mapping(bytes32 => Declaration) private _declarations;
    mapping(bytes32 => Allocation[]) private _allocations;
    mapping(bytes32 => Liquidity[]) private _liquidity;
    mapping(bytes32 => FeeRecipient[]) private _feeRecipients;
    mapping(address => bytes32[]) private _byToken;
    mapping(address => bytes32[]) private _byCreator;
    mapping(address => mapping(address => mapping(address => uint256))) public venueNonce; // venue => token => creator

    error NotVenue();
    error AlreadyDeclared();
    error ZeroToken();
    error ZeroCreator();
    error AgentWithoutRegistry();
    error NotIdentityHolder();
    error NotAuthorizedByCreator();
    error AuthorizationExpired();
    error ZeroHolder();
    error ZeroAmount();
    error VestingEndsBeforeStart();
    error ZeroLiquidityLocks();
    error FinancingWithoutLender();
    error ZeroFinanced();
    error ZeroFeeRights();
    error ZeroRecipient();

    constructor(address launchDirectory_) {
        _directory = ILaunchDirectory(launchDirectory_);
    }

    function launchDirectory() external view returns (address) {
        return address(_directory);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(ILaunchDeclarations).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ------------------------------------------------------------------ opening a declaration

    function declareListedCreator(
        bytes32 launchId,
        address identityRegistry,
        uint256 agentId,
        uint256 deadline,
        bytes calldata creatorSignature
    ) external {
        if (_directory.venueOf(launchId) != msg.sender) revert NotVenue();
        address token = _directory.tokenOf(launchId);
        address creator = _directory.deployerOf(launchId);
        _checkNew(launchId, token, creator, identityRegistry, agentId);
        // The directory already records the deployer on the venue's word; an identity is the creator's to attach.
        if (identityRegistry != address(0)) {
            _checkAuthorization(launchId, token, creator, identityRegistry, agentId, deadline, creatorSignature);
        }
        _record(launchId, IdKind.Erc8376, token, creator, identityRegistry, agentId);
    }

    function declareVenueCreator(
        address token,
        address creator,
        address identityRegistry,
        uint256 agentId,
        uint256 deadline,
        bytes calldata creatorSignature
    ) external returns (bytes32 declarationId) {
        uint256 nonce = venueNonce[msg.sender][token][creator];
        declarationId = keccak256(abi.encode(VENUE_SCOPED, block.chainid, msg.sender, token, creator, nonce));
        _checkNew(declarationId, token, creator, identityRegistry, agentId);
        _checkAuthorization(declarationId, token, creator, identityRegistry, agentId, deadline, creatorSignature);
        venueNonce[msg.sender][token][creator] = nonce + 1;
        _record(declarationId, IdKind.Venue, token, creator, identityRegistry, agentId);
    }

    /// @notice The EIP-712 digest a creator signs to authorize `venue` to open `declarationId`.
    function authorizationDigest(
        bytes32 declarationId,
        address venue,
        address token,
        address creator,
        address identityRegistry,
        uint256 agentId,
        uint256 deadline
    ) public view returns (bytes32) {
        bytes32 domain = keccak256(abi.encode(DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)));
        bytes32 structHash = keccak256(
            abi.encode(
                CREATOR_AUTHORIZATION_TYPEHASH,
                declarationId,
                venue,
                token,
                creator,
                identityRegistry,
                agentId,
                deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _checkNew(bytes32 declarationId, address token, address creator, address identityRegistry, uint256 agentId)
        private
        view
    {
        if (token == address(0)) revert ZeroToken();
        if (creator == address(0)) revert ZeroCreator();
        if (_declarations[declarationId].kind != IdKind.None) revert AlreadyDeclared();
        _checkIdentity(creator, identityRegistry, agentId);
    }

    /// @dev `msg.sender` is the venue in both kinds: checked against the directory for an ERC-8376 id, and part of the
    ///      preimage of a venue-scoped id.
    function _record(
        bytes32 declarationId,
        IdKind kind,
        address token,
        address creator,
        address identityRegistry,
        uint256 agentId
    ) private {
        _declarations[declarationId] = Declaration({
            kind: kind,
            token: token,
            creator: creator,
            venue: msg.sender,
            identityRegistry: identityRegistry,
            agentId: agentId,
            declaredAt: uint64(block.timestamp)
        });
        _byToken[token].push(declarationId);
        _byCreator[creator].push(declarationId);

        emit CreatorDeclared(declarationId, kind, token, creator, msg.sender, identityRegistry, agentId);
    }

    /// @dev The creator must hold the identity when it is declared: as its ERC-721 owner, or as the agent wallet an
    ///      ERC-8004 registry records. A registry without `getAgentWallet` is read through `ownerOf` alone. A registry
    ///      without code is refused before it is called, since a call that returns nothing cannot be decoded.
    function _checkIdentity(address creator, address identityRegistry, uint256 agentId) private view {
        if (identityRegistry == address(0)) {
            if (agentId != 0) revert AgentWithoutRegistry();
            return;
        }
        if (identityRegistry.code.length == 0) revert NotIdentityHolder();
        IIdentityRegistry registry = IIdentityRegistry(identityRegistry);
        try registry.ownerOf(agentId) returns (address owner) {
            if (owner == creator) return;
        } catch {}
        try registry.getAgentWallet(agentId) returns (address wallet) {
            if (wallet == creator) return;
        } catch {}
        revert NotIdentityHolder();
    }

    /// @dev The creator authorizes by calling, or by signing the declaration it authorizes. An authorization names one
    ///      declaration id, which opens once (an ERC-8376 id is then taken; a venue-scoped id's nonce moves on), and
    ///      the EIP-712 domain binds the chain and this contract, so it cannot be replayed.
    function _checkAuthorization(
        bytes32 declarationId,
        address token,
        address creator,
        address identityRegistry,
        uint256 agentId,
        uint256 deadline,
        bytes calldata signature
    ) private view {
        if (msg.sender == creator) return;
        // A deadline the creator sets in seconds: the few seconds a block producer can shift the time do not matter.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > deadline) revert AuthorizationExpired();
        bytes32 digest =
            authorizationDigest(declarationId, msg.sender, token, creator, identityRegistry, agentId, deadline);
        if (!_isValidSignature(creator, digest, signature)) revert NotAuthorizedByCreator();
    }

    /// @dev A 65-byte ECDSA signature by `signer` with a low `s`, or, where `signer` has code, its ERC-1271 approval.
    function _isValidSignature(address signer, bytes32 digest, bytes calldata signature) private view returns (bool) {
        if (signature.length == 65) {
            bytes32 r = bytes32(signature[0:32]);
            bytes32 s = bytes32(signature[32:64]);
            uint8 v = uint8(signature[64]);
            if (uint256(s) <= HALF_ORDER && (v == 27 || v == 28)) {
                address recovered = ecrecover(digest, v, r, s);
                if (recovered != address(0) && recovered == signer) return true;
            }
        }
        if (signer.code.length == 0) return false;
        (bool ok, bytes memory ret) = signer.staticcall(abi.encodeCall(IERC1271.isValidSignature, (digest, signature)));
        return ok && ret.length >= 32 && abi.decode(ret, (bytes32)) == bytes32(ERC1271_MAGIC);
    }

    // ------------------------------------------------------------------ declaring facts

    function declareAllocation(bytes32 declarationId, address holder, uint256 amount, uint64 vestStart, uint64 vestEnd)
        external
    {
        _onlyVenue(declarationId);
        if (holder == address(0)) revert ZeroHolder();
        if (amount == 0) revert ZeroAmount();
        if (vestEnd < vestStart) revert VestingEndsBeforeStart();

        _allocations[declarationId].push(
            Allocation({
                holder: holder,
                amount: amount,
                vestStart: vestStart,
                vestEnd: vestEnd,
                declaredAt: uint64(block.timestamp)
            })
        );
        emit AllocationDeclared(declarationId, holder, amount, vestStart, vestEnd);
    }

    function declareLiquidity(
        bytes32 declarationId,
        address liquidityLocks,
        uint256 lockId,
        address lender,
        address asset,
        uint256 financed,
        uint64 dueAt
    ) external {
        _onlyVenue(declarationId);
        if (liquidityLocks == address(0)) revert ZeroLiquidityLocks();
        if (lender == address(0)) {
            if (asset != address(0) || financed != 0 || dueAt != 0) revert FinancingWithoutLender();
        } else if (financed == 0) {
            revert ZeroFinanced();
        }

        _liquidity[declarationId].push(
            Liquidity({
                liquidityLocks: liquidityLocks,
                lockId: lockId,
                lender: lender,
                asset: asset,
                financed: financed,
                dueAt: dueAt,
                declaredAt: uint64(block.timestamp)
            })
        );
        emit LiquidityDeclared(declarationId, liquidityLocks, lockId, lender, asset, financed, dueAt);
    }

    function declareFeeRecipient(bytes32 declarationId, address feeRights, address recipient) external {
        _onlyVenue(declarationId);
        if (feeRights == address(0)) revert ZeroFeeRights();
        if (recipient == address(0)) revert ZeroRecipient();

        _feeRecipients[declarationId].push(
            FeeRecipient({feeRights: feeRights, recipient: recipient, declaredAt: uint64(block.timestamp)})
        );
        emit FeeRecipientDeclared(declarationId, feeRights, recipient);
    }

    /// @dev An id with no declaration has a zero venue, which no caller is.
    function _onlyVenue(bytes32 declarationId) private view {
        if (_declarations[declarationId].venue != msg.sender) revert NotVenue();
    }

    // ------------------------------------------------------------------ reading

    function getDeclaration(bytes32 declarationId) external view returns (Declaration memory) {
        return _declarations[declarationId];
    }

    function allocationsOf(bytes32 declarationId, uint256 start, uint256 limit)
        external
        view
        returns (Allocation[] memory out)
    {
        Allocation[] storage all = _allocations[declarationId];
        out = new Allocation[](_pageLength(all.length, start, limit));
        for (uint256 i; i < out.length; ++i) {
            out[i] = all[start + i];
        }
    }

    function liquidityOf(bytes32 declarationId, uint256 start, uint256 limit)
        external
        view
        returns (Liquidity[] memory out)
    {
        Liquidity[] storage all = _liquidity[declarationId];
        out = new Liquidity[](_pageLength(all.length, start, limit));
        for (uint256 i; i < out.length; ++i) {
            out[i] = all[start + i];
        }
    }

    function feeRecipientsOf(bytes32 declarationId, uint256 start, uint256 limit)
        external
        view
        returns (FeeRecipient[] memory out)
    {
        FeeRecipient[] storage all = _feeRecipients[declarationId];
        out = new FeeRecipient[](_pageLength(all.length, start, limit));
        for (uint256 i; i < out.length; ++i) {
            out[i] = all[start + i];
        }
    }

    function declarationIdsOf(address token, uint256 start, uint256 limit) external view returns (bytes32[] memory) {
        return _page(_byToken[token], start, limit);
    }

    function declarationIdsBy(address creator, uint256 start, uint256 limit) external view returns (bytes32[] memory) {
        return _page(_byCreator[creator], start, limit);
    }

    function _page(bytes32[] storage ids, uint256 start, uint256 limit) private view returns (bytes32[] memory out) {
        out = new bytes32[](_pageLength(ids.length, start, limit));
        for (uint256 i; i < out.length; ++i) {
            out[i] = ids[start + i];
        }
    }

    /// @dev How many entries a page from `start` holds, at most `limit`; zero at or past the end.
    function _pageLength(uint256 length, uint256 start, uint256 limit) private pure returns (uint256) {
        if (start >= length) return 0;
        uint256 rest = length - start;
        return limit < rest ? limit : rest;
    }
}
