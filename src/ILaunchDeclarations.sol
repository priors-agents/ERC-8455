// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @title Launch Declarations (draft ERC)
/// @notice The facts a launchpad declares when it launches a token: the creator and its ERC-8004 identity, the supply
///         allocated outside the sale and its vesting, the lock holding the liquidity and any financing of it, and the
///         fee recipient. A launch listed in an ERC-8376 directory is declared under its ERC-8376 `launchId`; any
///         other launch under an id scoped to the venue that declares it.
/// @dev The ERC-165 identifier is `type(ILaunchDeclarations).interfaceId`.
interface ILaunchDeclarations {
    /// @dev `None` for an id with no declaration; `Erc8376` for an ERC-8376 `launchId`; `Venue` for a venue-scoped id.
    enum IdKind {
        None,
        Erc8376,
        Venue
    }

    struct Declaration {
        IdKind kind;
        address token;
        address creator; // for an ERC-8376 id, the directory's `deployerOf(launchId)`
        address venue; // the only address that may declare facts under the id
        address identityRegistry; // the creator's ERC-8004 identity registry, or zero for none
        uint256 agentId; // zero when `identityRegistry` is zero
        uint64 declaredAt;
    }

    struct Allocation {
        address holder;
        uint256 amount; // in the token's base units
        uint64 vestStart; // the amount vests linearly from `vestStart` to `vestEnd`
        uint64 vestEnd;
        uint64 declaredAt;
    }

    struct Liquidity {
        address liquidityLocks; // a contract implementing the Liquidity Locks draft, or zero for liquidity in no lock
        uint256 lockId; // zero when `liquidityLocks` is zero
        address lender; // zero when the liquidity was not financed
        address asset; // what the lender lent; the zero address for the native currency
        uint256 financed;
        uint64 dueAt; // zero for no due date
        uint64 declaredAt;
    }

    struct FeeRecipient {
        address feeRights; // a contract implementing the Creator Fee Rights draft
        address recipient;
        uint64 declaredAt;
    }

    event CreatorDeclared(
        bytes32 indexed declarationId,
        IdKind kind,
        address indexed token,
        address indexed creator,
        address venue,
        address identityRegistry,
        uint256 agentId
    );
    event AllocationDeclared(
        bytes32 indexed declarationId, address indexed holder, uint256 amount, uint64 vestStart, uint64 vestEnd
    );
    event LiquidityDeclared(
        bytes32 indexed declarationId,
        address liquidityLocks,
        uint256 lockId,
        address lender,
        address asset,
        uint256 financed,
        uint64 dueAt
    );
    event FeeRecipientDeclared(bytes32 indexed declarationId, address feeRights, address recipient);

    /// @notice The ERC-8376 directory that ERC-8376 ids are read from. Never changes.
    function launchDirectory() external view returns (address);

    /// @notice Opens the declaration of a launch the directory lists, under its `launchId`. The directory's venue for
    ///         the launch only; the token and the creator are read from the directory. Attaching an identity needs the
    ///         creator's authorization: the creator is the caller, or `creatorSignature` is its EIP-712 signature of a
    ///         `CreatorAuthorization` valid until `deadline`.
    function declareListedCreator(
        bytes32 launchId,
        address identityRegistry,
        uint256 agentId,
        uint256 deadline,
        bytes calldata creatorSignature
    ) external;

    /// @notice Opens the declaration of a launch the directory does not list, under an id scoped to `msg.sender`.
    ///         Always needs the creator's authorization, as above.
    function declareVenueCreator(
        address token,
        address creator,
        address identityRegistry,
        uint256 agentId,
        uint256 deadline,
        bytes calldata creatorSignature
    ) external returns (bytes32 declarationId);

    /// @notice The nonce of the next venue-scoped declaration `venue` opens for `token` and `creator`.
    function venueNonce(address venue, address token, address creator) external view returns (uint256);

    /// @notice Declares supply allocated outside the sale. A holder's allocations add up, so a cliff or a stepped
    ///         schedule is declared as several. The declaration's venue only.
    function declareAllocation(bytes32 declarationId, address holder, uint256 amount, uint64 vestStart, uint64 vestEnd)
        external;

    /// @notice Declares the lock that holds the launch's liquidity, or a part of it, and who financed it. Liquidity in
    ///         no lock is declared only when financed. The declaration's venue only.
    function declareLiquidity(
        bytes32 declarationId,
        address liquidityLocks,
        uint256 lockId,
        address lender,
        address asset,
        uint256 financed,
        uint64 dueAt
    ) external;

    /// @notice Declares where the token's creator fees are accounted and who receives them. The declaration's venue
    ///         only.
    function declareFeeRecipient(bytes32 declarationId, address feeRights, address recipient) external;

    /// @notice The declaration `declarationId`; kind `None` and every field zero when there is none.
    function getDeclaration(bytes32 declarationId) external view returns (Declaration memory);

    /// @notice The allocations declared under `declarationId`, in the order declared, from `start`, at most `limit`.
    function allocationsOf(bytes32 declarationId, uint256 start, uint256 limit)
        external
        view
        returns (Allocation[] memory);

    /// @notice The liquidity declared under `declarationId`, in the order declared, from `start`, at most `limit`.
    function liquidityOf(bytes32 declarationId, uint256 start, uint256 limit) external view returns (Liquidity[] memory);

    /// @notice The fee recipients declared under `declarationId`, in the order declared, from `start`, at most `limit`.
    function feeRecipientsOf(bytes32 declarationId, uint256 start, uint256 limit)
        external
        view
        returns (FeeRecipient[] memory);

    /// @notice Declaration ids of `token`, of both kinds, oldest first, from `start`, at most `limit`.
    function declarationIdsOf(address token, uint256 start, uint256 limit) external view returns (bytes32[] memory);

    /// @notice Declaration ids naming `creator`, of both kinds, oldest first, from `start`, at most `limit`.
    function declarationIdsBy(address creator, uint256 start, uint256 limit) external view returns (bytes32[] memory);
}
