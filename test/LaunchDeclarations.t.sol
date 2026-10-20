// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ILaunchDeclarations} from "../src/ILaunchDeclarations.sol";
import {LaunchDeclarations} from "../src/LaunchDeclarations.sol";
import {
    MockLaunchDirectory,
    MockIdentityRegistry,
    MockERC721Registry,
    MockERC1271Wallet,
    MockLaunchpad
} from "./mocks/Mocks.sol";

contract LaunchDeclarationsTest is Test {
    // As the ERC text defines them.
    bytes32 constant TAG = keccak256("erc.launch-declarations.venue-scoped");
    bytes32 constant AUTH_TYPEHASH = keccak256(
        "CreatorAuthorization(bytes32 declarationId,address venue,address token,address creator,address identityRegistry,uint256 agentId,uint256 deadline)"
    );
    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    uint256 constant ORDER = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141; // secp256k1

    address constant TOKEN = address(0x70C3);
    address constant TOKEN2 = address(0x70C4);
    address constant LOCKS = address(0x10C5); // a Liquidity Locks contract; never called
    address constant FEES = address(0xFEE5); // a Creator Fee Rights contract; never called
    address constant USDG = address(0x0d5);

    MockLaunchDirectory directory;
    MockIdentityRegistry identity;
    LaunchDeclarations decl;

    address escrow = makeAddr("escrow"); // an ERC-8376 escrow separate from its venue, as at full conformance
    address venue = makeAddr("venue");
    address otherVenue = makeAddr("otherVenue");
    address creator;
    address other;
    address attacker;
    address hot;
    mapping(address => uint256) keyOf;
    uint256 agentId;

    function setUp() public {
        directory = new MockLaunchDirectory();
        identity = new MockIdentityRegistry();
        decl = new LaunchDeclarations(address(directory));
        creator = _person("creator");
        other = _person("other");
        attacker = _person("attacker");
        hot = _person("hotWallet");
        agentId = identity.register(creator);
    }

    // ------------------------------------------------------------- helpers

    function _person(string memory name) internal returns (address a) {
        uint256 pk;
        (a, pk) = makeAddrAndKey(name);
        keyOf[a] = pk;
    }

    function _launchId(address esc, address token, address deployer, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, esc, token, deployer, nonce));
    }

    function _venueId(address v, address token, address c, uint256 nonce) internal view returns (bytes32) {
        return keccak256(abi.encode(TAG, block.chainid, v, token, c, nonce));
    }

    /// @dev The EIP-712 digest, computed here from the ERC text rather than read from the contract.
    function _digest(address declarations, uint256 chainId, bytes32 structHash) internal pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("Launch Declarations"), keccak256("1"), chainId, declarations)
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, structHash));
    }

    function _structHash(bytes32 id, address v, address token, address c, address reg, uint256 agent, uint256 dl)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(AUTH_TYPEHASH, id, v, token, c, reg, agent, dl));
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev `c`'s authorization for venue `v` to open `id`, valid for an hour, at this contract on this chain.
    function _auth(bytes32 id, address v, address token, address c, address reg, uint256 agent)
        internal
        view
        returns (uint256 dl, bytes memory sig)
    {
        dl = block.timestamp + 1 hours;
        sig = _sign(keyOf[c], _digest(address(decl), block.chainid, _structHash(id, v, token, c, reg, agent, dl)));
    }

    /// @dev Lists a launch in the directory the way an ERC-8376 escrow does, naming `v` as its venue.
    function _list(address token, address deployer, address v, uint256 nonce) internal returns (bytes32 id) {
        id = _launchId(escrow, token, deployer, nonce);
        vm.prank(escrow);
        directory.list(id, token, deployer, v, nonce);
    }

    /// @dev Lists a launch by `creator` at `venue` and declares it with the creator's identity and authorization.
    function _listAndDeclare(address token, uint256 nonce) internal returns (bytes32 id) {
        id = _list(token, creator, venue, nonce);
        (uint256 dl, bytes memory sig) = _auth(id, venue, token, creator, address(identity), agentId);
        vm.prank(venue);
        decl.declareListedCreator(id, address(identity), agentId, dl, sig);
    }

    /// @dev A venue-scoped declaration by `v` naming `c`, authorized by `c` (by calling when `c` is the venue).
    function _declareAtVenue(address v, address token, address c) internal returns (bytes32) {
        return _declareAtVenue(v, token, c, address(0), 0);
    }

    function _declareAtVenue(address v, address token, address c, address reg, uint256 agent)
        internal
        returns (bytes32)
    {
        uint256 dl;
        bytes memory sig;
        if (v != c) {
            (dl, sig) = _auth(_venueId(v, token, c, decl.venueNonce(v, token, c)), v, token, c, reg, agent);
        }
        vm.prank(v);
        return decl.declareVenueCreator(token, c, reg, agent, dl, sig);
    }

    function _allocations(bytes32 id) internal view returns (ILaunchDeclarations.Allocation[] memory) {
        return decl.allocationsOf(id, 0, type(uint256).max);
    }

    // ------------------------------------------------------------- ERC-8376 ids

    function test_listed_launchpadDeclaresInItsLaunchTransaction() public {
        MockLaunchpad pad = new MockLaunchpad(directory, decl);
        address vesting = makeAddr("teamVesting");
        bytes32 expected = _launchId(address(pad), TOKEN, creator, 0); // known before the launch
        (uint256 dl, bytes memory sig) = _auth(expected, address(pad), TOKEN, creator, address(identity), agentId);
        MockLaunchpad.Facts memory f = MockLaunchpad.Facts({
            identityRegistry: address(identity),
            agentId: agentId,
            teamVesting: vesting,
            teamAmount: 50_000_000e18,
            liquidityLocks: LOCKS,
            lockId: 7,
            feeRights: FEES,
            deadline: dl,
            creatorSignature: sig
        });
        vm.prank(creator);
        bytes32 id = pad.launch(TOKEN, f);

        assertEq(id, expected);
        assertEq(directory.launchesOf(TOKEN)[0], id);
        assertEq(directory.deployerOf(id), creator); // the applicant, not the launchpad

        ILaunchDeclarations.Declaration memory d = decl.getDeclaration(id);
        assertEq(uint8(d.kind), uint8(ILaunchDeclarations.IdKind.Erc8376));
        assertEq(d.token, TOKEN);
        assertEq(d.creator, creator);
        assertEq(d.venue, address(pad));
        assertEq(d.identityRegistry, address(identity));
        assertEq(d.agentId, agentId);
        assertEq(_allocations(id)[0].holder, vesting);
        assertEq(_allocations(id)[0].amount, 50_000_000e18);
        assertEq(decl.liquidityOf(id, 0, 1)[0].lockId, 7);
        assertEq(decl.feeRecipientsOf(id, 0, 1)[0].recipient, creator);
        assertEq(decl.declarationIdsOf(TOKEN, 0, 10)[0], id);
        assertEq(decl.declarationIdsBy(creator, 0, 10)[0], id);
    }

    function test_listed_creatorIsTheDirectoryDeployer() public {
        // Without an identity, so that only the creator rule is at stake; no authorization is needed.
        bytes32 plain = _list(TOKEN2, other, venue, 1);
        vm.prank(venue);
        decl.declareListedCreator(plain, address(0), 0, 0, "");
        assertEq(decl.getDeclaration(plain).creator, directory.deployerOf(plain));
        assertEq(decl.getDeclaration(plain).creator, other);
        assertEq(decl.getDeclaration(plain).token, TOKEN2);

        bytes32 id = _list(TOKEN, creator, venue, 0);
        (uint256 dl, bytes memory sig) = _auth(id, venue, TOKEN, creator, address(identity), agentId);
        vm.expectEmit(true, true, true, true, address(decl));
        emit ILaunchDeclarations.CreatorDeclared(
            id, ILaunchDeclarations.IdKind.Erc8376, TOKEN, creator, venue, address(identity), agentId
        );
        vm.prank(venue);
        decl.declareListedCreator(id, address(identity), agentId, dl, sig);

        ILaunchDeclarations.Declaration memory d = decl.getDeclaration(id);
        assertEq(d.creator, directory.deployerOf(id));
        assertEq(d.creator, creator);
        assertEq(d.token, directory.tokenOf(id));
        assertEq(d.venue, venue);
        assertEq(d.declaredAt, block.timestamp);

        // A deployer that does not hold an identity cannot carry it, even with its own authorization.
        bytes32 id2 = _list(TOKEN2, other, venue, 0);
        (dl, sig) = _auth(id2, venue, TOKEN2, other, address(identity), agentId);
        vm.prank(venue);
        vm.expectRevert(LaunchDeclarations.NotIdentityHolder.selector);
        decl.declareListedCreator(id2, address(identity), agentId, dl, sig);
    }

    function test_listed_onlyTheVenueMayDeclare() public {
        bytes32 id = _list(TOKEN, creator, venue, 0);
        address[3] memory others = [attacker, escrow, creator];
        for (uint256 i; i < others.length; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(LaunchDeclarations.NotVenue.selector);
            decl.declareListedCreator(id, address(0), 0, 0, "");
        }
        vm.prank(venue);
        decl.declareListedCreator(id, address(0), 0, 0, "");
        assertEq(decl.getDeclaration(id).venue, venue);
    }

    function test_listed_unlistedIdCannotBeSquatted() public {
        bytes32 future = _launchId(escrow, TOKEN, creator, 0); // predictable from public inputs
        vm.prank(attacker);
        vm.expectRevert(LaunchDeclarations.NotVenue.selector);
        decl.declareListedCreator(future, address(0), 0, 0, "");
        vm.prank(venue); // not even the future venue, before the escrow lists it
        vm.expectRevert(LaunchDeclarations.NotVenue.selector);
        decl.declareListedCreator(future, address(0), 0, 0, "");
        vm.prank(attacker); // nor can the attacker list it: the directory checks the escrow
        vm.expectRevert(MockLaunchDirectory.NotEscrowOfLaunch.selector);
        directory.list(future, TOKEN, creator, attacker, 0);

        _list(TOKEN, creator, venue, 0);
        (uint256 dl, bytes memory sig) = _auth(future, venue, TOKEN, creator, address(identity), agentId);
        vm.prank(venue);
        decl.declareListedCreator(future, address(identity), agentId, dl, sig);
        assertEq(decl.getDeclaration(future).venue, venue);
    }

    function test_listed_launchWithoutDeployerOrToken_reverts() public {
        bytes32 noDeployer = _list(TOKEN, address(0), venue, 0);
        vm.prank(venue);
        vm.expectRevert(LaunchDeclarations.ZeroCreator.selector);
        decl.declareListedCreator(noDeployer, address(0), 0, 0, "");

        bytes32 noToken = _list(address(0), creator, venue, 0);
        vm.prank(venue);
        vm.expectRevert(LaunchDeclarations.ZeroToken.selector);
        decl.declareListedCreator(noToken, address(0), 0, 0, "");
    }

    function test_listed_secondDeclaration_reverts() public {
        bytes32 id = _listAndDeclare(TOKEN, 0);
        vm.prank(venue);
        vm.expectRevert(LaunchDeclarations.AlreadyDeclared.selector);
        decl.declareListedCreator(id, address(0), 0, 0, "");
        assertEq(decl.getDeclaration(id).identityRegistry, address(identity));
    }

    // ------------------------------------------------------------- the creator's authorization

    function test_auth_venueScoped_needsTheCreator() public {
        // A venue the creator never authorized can neither name it nor attach its genuine identity.
        vm.startPrank(attacker);
        vm.expectRevert(LaunchDeclarations.NotAuthorizedByCreator.selector);
        decl.declareVenueCreator(TOKEN, creator, address(0), 0, block.timestamp, "");
        vm.expectRevert(LaunchDeclarations.NotAuthorizedByCreator.selector);
        decl.declareVenueCreator(TOKEN, creator, address(identity), agentId, block.timestamp, "");
        vm.stopPrank();
        // Nor with a signature by anyone but the creator.
        bytes32 id = _venueId(attacker, TOKEN, creator, 0);
        uint256 dl = block.timestamp + 1 hours;
        bytes memory forged = _sign(
            keyOf[attacker],
            _digest(address(decl), block.chainid, _structHash(id, attacker, TOKEN, creator, address(0), 0, dl))
        );
        vm.prank(attacker);
        vm.expectRevert(LaunchDeclarations.NotAuthorizedByCreator.selector);
        decl.declareVenueCreator(TOKEN, creator, address(0), 0, dl, forged);
        assertEq(decl.declarationIdsBy(creator, 0, 10).length, 0);

        // The creator authorizes by calling, or by signing for the venue.
        vm.prank(creator);
        bytes32 own = decl.declareVenueCreator(TOKEN, creator, address(identity), agentId, 0, "");
        bytes32 signed = _declareAtVenue(venue, TOKEN, creator, address(identity), agentId);
        bytes32[] memory by = decl.declarationIdsBy(creator, 0, 10);
        assertEq(by.length, 2);
        assertEq(by[0], own);
        assertEq(by[1], signed);
        assertEq(decl.getDeclaration(signed).agentId, agentId);
    }

    function test_auth_listedIdentity_needsTheCreator() public {
        bytes32 id = _list(TOKEN, creator, venue, 0);
        vm.startPrank(venue);
        vm.expectRevert(LaunchDeclarations.NotAuthorizedByCreator.selector);
        decl.declareListedCreator(id, address(identity), agentId, block.timestamp, "");
        (uint256 dl, bytes memory forged) = _auth(id, venue, TOKEN, attacker, address(identity), agentId);
        vm.expectRevert(LaunchDeclarations.NotAuthorizedByCreator.selector);
        decl.declareListedCreator(id, address(identity), agentId, dl, forged);
        vm.stopPrank();

        (dl, forged) = _auth(id, venue, TOKEN, creator, address(identity), agentId);
        vm.prank(venue);
        decl.declareListedCreator(id, address(identity), agentId, dl, forged);
        assertEq(decl.getDeclaration(id).identityRegistry, address(identity));

        // Without an identity the venue names the deployer the directory records, with no authorization.
        bytes32 bare = _list(TOKEN2, creator, venue, 0);
        vm.prank(venue);
        decl.declareListedCreator(bare, address(0), 0, 0, "");
        assertEq(decl.getDeclaration(bare).creator, creator);
    }

    function test_auth_signatureIsSingleUseAndBound() public {
        bytes32 id = _venueId(venue, TOKEN, creator, 0);
        (uint256 dl, bytes memory sig) = _auth(id, venue, TOKEN, creator, address(identity), agentId);

        // bound to the venue, the token and the identity
        vm.prank(otherVenue);
        vm.expectRevert(LaunchDeclarations.NotAuthorizedByCreator.selector);
        decl.declareVenueCreator(TOKEN, creator, address(identity), agentId, dl, sig);
        vm.startPrank(venue);
        vm.expectRevert(LaunchDeclarations.NotAuthorizedByCreator.selector);
        decl.declareVenueCreator(TOKEN2, creator, address(identity), agentId, dl, sig);
        vm.expectRevert(LaunchDeclarations.NotAuthorizedByCreator.selector);
        decl.declareVenueCreator(TOKEN, creator, address(0), 0, dl, sig);
        // a malleated copy (high s) is refused
        bytes memory high = _malleate(sig);
        vm.expectRevert(LaunchDeclarations.NotAuthorizedByCreator.selector);
        decl.declareVenueCreator(TOKEN, creator, address(identity), agentId, dl, high);

        // used once; replaying it fails, since the venue's nonce has moved on
        assertEq(decl.declareVenueCreator(TOKEN, creator, address(identity), agentId, dl, sig), id);
        vm.expectRevert(LaunchDeclarations.NotAuthorizedByCreator.selector);
        decl.declareVenueCreator(TOKEN, creator, address(identity), agentId, dl, sig);
        vm.stopPrank();

        // an authorization for a listed launch does not carry over to its relaunch
        bytes32 first = _list(TOKEN2, creator, venue, 0);
        bytes32 second = _list(TOKEN2, creator, venue, 1);
        (dl, sig) = _auth(first, venue, TOKEN2, creator, address(identity), agentId);
        vm.startPrank(venue);
        decl.declareListedCreator(first, address(identity), agentId, dl, sig);
        vm.expectRevert(LaunchDeclarations.NotAuthorizedByCreator.selector);
        decl.declareListedCreator(second, address(identity), agentId, dl, sig);
        vm.stopPrank();

        // and it expires
        bytes32 next = _venueId(venue, TOKEN, creator, 1);
        (dl, sig) = _auth(next, venue, TOKEN, creator, address(0), 0);
        vm.warp(dl + 1);
        vm.prank(venue);
        vm.expectRevert(LaunchDeclarations.AuthorizationExpired.selector);
        decl.declareVenueCreator(TOKEN, creator, address(0), 0, dl, sig);
    }

    function _malleate(bytes memory sig) internal pure returns (bytes memory) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        return abi.encodePacked(r, bytes32(ORDER - uint256(s)), v == 27 ? uint8(28) : uint8(27));
    }

    function test_auth_wrongDomain_fails() public {
        bytes32 id = _venueId(venue, TOKEN, creator, 0);
        uint256 dl = block.timestamp + 1 hours;
        bytes32 sh = _structHash(id, venue, TOKEN, creator, address(0), 0, dl);

        // signed for another declarations contract
        LaunchDeclarations elsewhere = new LaunchDeclarations(address(directory));
        bytes memory sig = _sign(keyOf[creator], _digest(address(elsewhere), block.chainid, sh));
        vm.prank(venue);
        vm.expectRevert(LaunchDeclarations.NotAuthorizedByCreator.selector);
        decl.declareVenueCreator(TOKEN, creator, address(0), 0, dl, sig);

        // signed for another chain
        sig = _sign(keyOf[creator], _digest(address(decl), block.chainid + 1, sh));
        vm.prank(venue);
        vm.expectRevert(LaunchDeclarations.NotAuthorizedByCreator.selector);
        decl.declareVenueCreator(TOKEN, creator, address(0), 0, dl, sig);

        // the right domain works
        sig = _sign(keyOf[creator], _digest(address(decl), block.chainid, sh));
        vm.prank(venue);
        assertEq(decl.declareVenueCreator(TOKEN, creator, address(0), 0, dl, sig), id);
    }

    function test_auth_contractCreatorThroughERC1271() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(other); // `other` holds the wallet's key
        address w = address(wallet);
        bytes32 id = _venueId(venue, TOKEN, w, 0);
        uint256 dl = block.timestamp + 1 hours;
        bytes32 digest = _digest(address(decl), block.chainid, _structHash(id, venue, TOKEN, w, address(0), 0, dl));

        vm.startPrank(venue);
        vm.expectRevert(LaunchDeclarations.NotAuthorizedByCreator.selector);
        decl.declareVenueCreator(TOKEN, w, address(0), 0, dl, _sign(keyOf[attacker], digest));
        assertEq(decl.declareVenueCreator(TOKEN, w, address(0), 0, dl, _sign(keyOf[other], digest)), id);

        // a creator contract that does not implement ERC-1271 authorizes nothing
        address noWallet = address(directory);
        bytes32 id2 = _venueId(venue, TOKEN, noWallet, 0);
        bytes32 digest2 =
            _digest(address(decl), block.chainid, _structHash(id2, venue, TOKEN, noWallet, address(0), 0, dl));
        vm.expectRevert(LaunchDeclarations.NotAuthorizedByCreator.selector);
        decl.declareVenueCreator(TOKEN, noWallet, address(0), 0, dl, _sign(keyOf[other], digest2));
        vm.stopPrank();
    }

    // ------------------------------------------------------------- venue-scoped ids

    function test_venue_idDerivation_andNonce() public {
        assertEq(decl.venueNonce(venue, TOKEN, creator), 0);
        bytes32 expected = _venueId(venue, TOKEN, creator, 0);
        (uint256 dl, bytes memory sig) = _auth(expected, venue, TOKEN, creator, address(identity), agentId);
        vm.expectEmit(true, true, true, true, address(decl));
        emit ILaunchDeclarations.CreatorDeclared(
            expected, ILaunchDeclarations.IdKind.Venue, TOKEN, creator, venue, address(identity), agentId
        );
        vm.prank(venue);
        bytes32 id0 = decl.declareVenueCreator(TOKEN, creator, address(identity), agentId, dl, sig);
        assertEq(decl.venueNonce(venue, TOKEN, creator), 1);
        bytes32 id1 = _declareAtVenue(venue, TOKEN, creator); // a relaunch at the same venue
        bytes32 idOther = _declareAtVenue(venue, TOKEN, other); // another creator starts at nonce 0

        assertEq(id0, expected);
        assertEq(id1, _venueId(venue, TOKEN, creator, 1));
        assertEq(idOther, _venueId(venue, TOKEN, other, 0));
        assertEq(decl.venueNonce(venue, TOKEN, creator), 2);
        assertEq(uint8(decl.getDeclaration(id0).kind), uint8(ILaunchDeclarations.IdKind.Venue));
        assertEq(decl.getDeclaration(id0).venue, venue);
        assertEq(decl.getDeclaration(id0).declaredAt, block.timestamp);
    }

    function test_venue_twoVenuesDoNotCollide() public {
        bytes32 a = _declareAtVenue(venue, TOKEN, creator);
        bytes32 b = _declareAtVenue(otherVenue, TOKEN, creator);
        assertEq(a, _venueId(venue, TOKEN, creator, 0));
        assertEq(b, _venueId(otherVenue, TOKEN, creator, 0));
        assertTrue(a != b);

        vm.prank(venue);
        vm.expectRevert(LaunchDeclarations.NotVenue.selector);
        decl.declareAllocation(b, other, 1, 0, 0);
    }

    function test_venue_squatterOnlyGetsItsOwnId() public {
        bytes32 squat = _declareAtVenue(attacker, TOKEN, attacker); // anyone may declare its own launch of any token
        bytes32 real = _declareAtVenue(venue, TOKEN, creator);

        assertEq(squat, _venueId(attacker, TOKEN, attacker, 0));
        assertEq(real, _venueId(venue, TOKEN, creator, 0)); // unaffected by the squatter
        assertEq(decl.getDeclaration(squat).venue, attacker); // and readers see who wrote each

        vm.startPrank(attacker);
        vm.expectRevert(LaunchDeclarations.NotVenue.selector);
        decl.declareAllocation(real, attacker, 1, 0, 0);
        vm.expectRevert(LaunchDeclarations.NotVenue.selector);
        decl.declareLiquidity(real, LOCKS, 1, address(0), address(0), 0, 0);
        vm.expectRevert(LaunchDeclarations.NotVenue.selector);
        decl.declareFeeRecipient(real, FEES, attacker);
        vm.stopPrank();
    }

    function test_venue_idNeverEqualsAListedLaunchId() public {
        MockLaunchpad pad = new MockLaunchpad(directory, decl);
        MockLaunchpad.Facts memory f = MockLaunchpad.Facts(address(0), 0, other, 1, LOCKS, 1, FEES, 0, "");

        // Listed first: the untagged formula would give the venue-scoped id the very launchId the directory holds.
        vm.prank(creator);
        bytes32 listed = pad.launch(TOKEN, f);
        assertEq(keccak256(abi.encode(block.chainid, address(pad), TOKEN, creator, uint256(0))), listed);
        (uint256 dl, bytes memory sig) =
            _auth(_venueId(address(pad), TOKEN, creator, 0), address(pad), TOKEN, creator, address(0), 0);
        bytes32 scoped = pad.declareUnlisted(TOKEN, creator, dl, sig);
        assertTrue(scoped != listed);
        assertEq(uint8(decl.getDeclaration(listed).kind), uint8(ILaunchDeclarations.IdKind.Erc8376));
        assertEq(uint8(decl.getDeclaration(scoped).kind), uint8(ILaunchDeclarations.IdKind.Venue));

        // Venue-scoped first: it cannot take the id the listed launch needs later.
        (dl, sig) = _auth(_venueId(address(pad), TOKEN2, creator, 0), address(pad), TOKEN2, creator, address(0), 0);
        bytes32 scoped2 = pad.declareUnlisted(TOKEN2, creator, dl, sig);
        vm.prank(creator);
        bytes32 listed2 = pad.launch(TOKEN2, f);
        assertTrue(scoped2 != listed2);
        assertEq(uint8(decl.getDeclaration(listed2).kind), uint8(ILaunchDeclarations.IdKind.Erc8376));
    }

    function test_venue_idIsChainBound() public {
        uint256 here = block.chainid;
        vm.chainId(4663);
        bytes32 id = _declareAtVenue(venue, TOKEN, creator);
        assertEq(id, keccak256(abi.encode(TAG, uint256(4663), venue, TOKEN, creator, uint256(0))));
        assertTrue(id != keccak256(abi.encode(TAG, here, venue, TOKEN, creator, uint256(0))));
    }

    function test_venue_rejectsZeroTokenOrCreator() public {
        vm.startPrank(venue);
        vm.expectRevert(LaunchDeclarations.ZeroToken.selector);
        decl.declareVenueCreator(address(0), creator, address(0), 0, 0, "");
        vm.expectRevert(LaunchDeclarations.ZeroCreator.selector);
        decl.declareVenueCreator(TOKEN, address(0), address(0), 0, 0, "");
        vm.stopPrank();
    }

    function testFuzz_venueId_isTheFormula_andNeverTheLaunchId(address v, address token, uint256 pk) public {
        vm.assume(v != address(0) && token != address(0));
        pk = bound(pk, 1, ORDER - 1);
        address c = vm.addr(pk);
        keyOf[c] = pk;
        bytes32 id = _declareAtVenue(v, token, c);
        assertEq(id, _venueId(v, token, c, 0));
        assertTrue(id != _launchId(v, token, c, 0));
        assertEq(decl.getDeclaration(id).venue, v);
        assertEq(decl.getDeclaration(id).creator, c);
    }

    // ------------------------------------------------------------- the creator's identity

    function test_identity_ownerOrAgentWallet() public {
        // the owner of the identity
        bytes32 a = _declareAtVenue(venue, TOKEN, creator, address(identity), agentId);
        assertEq(decl.getDeclaration(a).agentId, agentId);

        // the agent wallet the owner set
        vm.prank(creator);
        identity.setAgentWallet(agentId, hot);
        bytes32 b = _declareAtVenue(venue, TOKEN, hot, address(identity), agentId);
        assertEq(decl.getDeclaration(b).creator, hot);

        // and for an ERC-8376 id, against the directory's deployer
        bytes32 id = _list(TOKEN2, hot, venue, 0);
        (uint256 dl, bytes memory sig) = _auth(id, venue, TOKEN2, hot, address(identity), agentId);
        vm.prank(venue);
        decl.declareListedCreator(id, address(identity), agentId, dl, sig);
        assertEq(decl.getDeclaration(id).identityRegistry, address(identity));
    }

    function test_identity_notHeldByTheCreator_reverts() public {
        // creators declaring their own launches, so that only the identity rule is at stake
        vm.prank(attacker);
        vm.expectRevert(LaunchDeclarations.NotIdentityHolder.selector);
        decl.declareVenueCreator(TOKEN, attacker, address(identity), agentId, 0, "");
        vm.prank(creator);
        vm.expectRevert(LaunchDeclarations.NotIdentityHolder.selector);
        decl.declareVenueCreator(TOKEN, creator, address(identity), 999, 0, ""); // never issued

        // after a transfer the former owner holds it no longer, and its agent wallet is cleared
        vm.prank(creator);
        identity.transfer(agentId, other);
        vm.prank(creator);
        vm.expectRevert(LaunchDeclarations.NotIdentityHolder.selector);
        decl.declareVenueCreator(TOKEN, creator, address(identity), agentId, 0, "");
        vm.prank(other);
        decl.declareVenueCreator(TOKEN, other, address(identity), agentId, 0, "");

        // a registry with no agent wallet is read through ownerOf alone
        MockERC721Registry plain = new MockERC721Registry();
        plain.mint(creator, 0);
        vm.prank(creator);
        decl.declareVenueCreator(TOKEN, creator, address(plain), 0, 0, "");
        vm.prank(attacker);
        vm.expectRevert(LaunchDeclarations.NotIdentityHolder.selector);
        decl.declareVenueCreator(TOKEN, attacker, address(plain), 0, 0, "");
    }

    function test_identity_registryWithoutCode_reverts() public {
        address eoaRegistry = makeAddr("eoaRegistry");
        vm.prank(creator);
        vm.expectRevert(LaunchDeclarations.NotIdentityHolder.selector);
        decl.declareVenueCreator(TOKEN, creator, eoaRegistry, 1, 0, "");

        bytes32 id = _list(TOKEN, creator, venue, 0);
        (uint256 dl, bytes memory sig) = _auth(id, venue, TOKEN, creator, eoaRegistry, 1);
        vm.prank(venue);
        vm.expectRevert(LaunchDeclarations.NotIdentityHolder.selector);
        decl.declareListedCreator(id, eoaRegistry, 1, dl, sig);
    }

    function test_identity_noneIsAllZero() public {
        vm.prank(creator);
        vm.expectRevert(LaunchDeclarations.AgentWithoutRegistry.selector);
        decl.declareVenueCreator(TOKEN, creator, address(0), 5, 0, "");

        bytes32 id = _declareAtVenue(venue, TOKEN, creator);
        assertEq(decl.getDeclaration(id).identityRegistry, address(0));
        assertEq(decl.getDeclaration(id).agentId, 0);
    }

    // ------------------------------------------------------------- facts

    function test_facts_onlyTheDeclarationsVenue() public {
        bytes32 scoped = _declareAtVenue(venue, TOKEN, creator);
        bytes32 listed = _listAndDeclare(TOKEN2, 0);
        bytes32 unknown = bytes32(uint256(1));
        address[3] memory callers = [attacker, creator, escrow];
        bytes32[2] memory ids = [scoped, listed];
        for (uint256 i; i < callers.length; ++i) {
            for (uint256 j; j < ids.length; ++j) {
                vm.startPrank(callers[i]);
                vm.expectRevert(LaunchDeclarations.NotVenue.selector);
                decl.declareAllocation(ids[j], other, 1, 0, 0);
                vm.expectRevert(LaunchDeclarations.NotVenue.selector);
                decl.declareLiquidity(ids[j], LOCKS, 1, address(0), address(0), 0, 0);
                vm.expectRevert(LaunchDeclarations.NotVenue.selector);
                decl.declareFeeRecipient(ids[j], FEES, other);
                vm.stopPrank();
            }
        }
        vm.startPrank(venue);
        vm.expectRevert(LaunchDeclarations.NotVenue.selector);
        decl.declareAllocation(unknown, other, 1, 0, 0);
        vm.expectRevert(LaunchDeclarations.NotVenue.selector);
        decl.declareLiquidity(unknown, LOCKS, 1, address(0), address(0), 0, 0);
        vm.expectRevert(LaunchDeclarations.NotVenue.selector);
        decl.declareFeeRecipient(unknown, FEES, other);
        decl.declareAllocation(scoped, other, 1, 0, 0);
        decl.declareAllocation(listed, other, 1, 0, 0);
        vm.stopPrank();
    }

    function test_allocation_recordedInOrder_andRejectsEmptyFields() public {
        bytes32 id = _declareAtVenue(venue, TOKEN, creator);
        address team = makeAddr("team");
        uint64 t0 = uint64(block.timestamp);

        vm.startPrank(venue);
        vm.expectEmit(true, true, false, true, address(decl));
        emit ILaunchDeclarations.AllocationDeclared(id, team, 100e18, t0 + 30 days, t0 + 365 days);
        decl.declareAllocation(id, team, 100e18, t0 + 30 days, t0 + 365 days);
        decl.declareAllocation(id, other, 5e18, 0, 0); // free from launch
        decl.declareAllocation(id, other, 1e18, t0 + 7 days, t0 + 7 days); // all at once at a cliff

        vm.expectRevert(LaunchDeclarations.ZeroHolder.selector);
        decl.declareAllocation(id, address(0), 1, 0, 0);
        vm.expectRevert(LaunchDeclarations.ZeroAmount.selector);
        decl.declareAllocation(id, team, 0, 0, 0);
        vm.expectRevert(LaunchDeclarations.VestingEndsBeforeStart.selector);
        decl.declareAllocation(id, team, 1, t0 + 2, t0 + 1);
        vm.stopPrank();

        ILaunchDeclarations.Allocation[] memory a = _allocations(id);
        assertEq(a.length, 3);
        assertEq(a[0].holder, team);
        assertEq(a[0].amount, 100e18);
        assertEq(a[0].vestStart, t0 + 30 days);
        assertEq(a[0].vestEnd, t0 + 365 days);
        assertEq(a[0].declaredAt, t0);
        assertEq(a[1].holder, other);
        assertEq(a[2].vestStart, a[2].vestEnd);
    }

    function test_liquidity_unfinancedAndFinanced() public {
        bytes32 id = _declareAtVenue(venue, TOKEN, creator);
        address lender = makeAddr("lender");
        uint64 due = uint64(block.timestamp) + 60 days;

        vm.startPrank(venue);
        decl.declareLiquidity(id, LOCKS, 7, address(0), address(0), 0, 0);
        vm.expectEmit(true, false, false, true, address(decl));
        emit ILaunchDeclarations.LiquidityDeclared(id, LOCKS, 8, lender, USDG, 1_000e6, due);
        decl.declareLiquidity(id, LOCKS, 8, lender, USDG, 1_000e6, due);
        decl.declareLiquidity(id, LOCKS, 9, lender, address(0), 1 ether, 0); // native currency, no due date

        vm.expectRevert(LaunchDeclarations.ZeroLiquidityLocks.selector);
        decl.declareLiquidity(id, address(0), 1, address(0), address(0), 0, 0);
        vm.expectRevert(LaunchDeclarations.FinancingWithoutLender.selector);
        decl.declareLiquidity(id, LOCKS, 1, address(0), USDG, 0, 0);
        vm.expectRevert(LaunchDeclarations.FinancingWithoutLender.selector);
        decl.declareLiquidity(id, LOCKS, 1, address(0), address(0), 1, 0);
        vm.expectRevert(LaunchDeclarations.FinancingWithoutLender.selector);
        decl.declareLiquidity(id, LOCKS, 1, address(0), address(0), 0, due);
        vm.expectRevert(LaunchDeclarations.ZeroFinanced.selector);
        decl.declareLiquidity(id, LOCKS, 1, lender, USDG, 0, due);
        vm.stopPrank();

        ILaunchDeclarations.Liquidity[] memory l = decl.liquidityOf(id, 0, 10);
        assertEq(l.length, 3);
        assertEq(l[0].liquidityLocks, LOCKS);
        assertEq(l[0].lockId, 7);
        assertEq(l[0].lender, address(0));
        assertEq(l[0].financed, 0);
        assertEq(l[1].lockId, 8);
        assertEq(l[1].lender, lender);
        assertEq(l[1].asset, USDG);
        assertEq(l[1].financed, 1_000e6);
        assertEq(l[1].dueAt, due);
        assertEq(l[1].declaredAt, block.timestamp);
        assertEq(l[2].asset, address(0));
    }

    function test_feeRecipient_recorded_andRejectsZero() public {
        bytes32 id = _declareAtVenue(venue, TOKEN, creator);
        vm.startPrank(venue);
        vm.expectEmit(true, false, false, true, address(decl));
        emit ILaunchDeclarations.FeeRecipientDeclared(id, FEES, creator);
        decl.declareFeeRecipient(id, FEES, creator);
        decl.declareFeeRecipient(id, address(0xFEE6), other); // a second stream

        vm.expectRevert(LaunchDeclarations.ZeroFeeRights.selector);
        decl.declareFeeRecipient(id, address(0), creator);
        vm.expectRevert(LaunchDeclarations.ZeroRecipient.selector);
        decl.declareFeeRecipient(id, FEES, address(0));
        vm.stopPrank();

        ILaunchDeclarations.FeeRecipient[] memory r = decl.feeRecipientsOf(id, 0, 10);
        assertEq(r.length, 2);
        assertEq(r[0].feeRights, FEES);
        assertEq(r[0].recipient, creator);
        assertEq(r[0].declaredAt, block.timestamp);
        assertEq(r[1].recipient, other);
    }

    function test_facts_areAppendOnly_andNeverChange() public {
        bytes32 id = _listAndDeclare(TOKEN, 0);
        uint256 t0 = block.timestamp;
        vm.prank(venue);
        decl.declareAllocation(id, other, 10, 0, 0);

        vm.warp(t0 + 3 days); // liquidity added at graduation, after launch
        vm.startPrank(venue);
        decl.declareLiquidity(id, LOCKS, 1, address(0), address(0), 0, 0);
        decl.declareAllocation(id, other, 12, 0, 0); // a correction: the right amount, beside the wrong one
        vm.expectRevert(LaunchDeclarations.AlreadyDeclared.selector);
        decl.declareListedCreator(id, address(0), 0, 0, "");
        vm.stopPrank();

        ILaunchDeclarations.Allocation[] memory a = _allocations(id);
        assertEq(a.length, 2);
        assertEq(a[0].holder, other);
        assertEq(a[0].amount, 10);
        assertEq(a[0].declaredAt, t0);
        assertEq(a[1].holder, other);
        assertEq(a[1].amount, 12);
        assertEq(a[1].declaredAt, t0 + 3 days);
        assertEq(decl.liquidityOf(id, 0, 1)[0].declaredAt, t0 + 3 days);
        ILaunchDeclarations.Declaration memory d = decl.getDeclaration(id);
        assertEq(d.creator, creator);
        assertEq(d.agentId, agentId);
        assertEq(d.declaredAt, t0);
    }

    function test_relaunch_supersedesNothing() public {
        bytes32 first = _listAndDeclare(TOKEN, 0);
        vm.prank(venue);
        decl.declareAllocation(first, other, 10, 0, 0);
        uint256 t0 = block.timestamp;

        vm.warp(t0 + 30 days);
        bytes32 relaunch = _listAndDeclare(TOKEN, 1); // the same token and creator, listed again
        vm.prank(venue);
        decl.declareAllocation(relaunch, attacker, 99, 0, 0);
        bytes32 scoped0 = _declareAtVenue(otherVenue, TOKEN, creator); // a venue outside ERC-8376
        bytes32 scoped1 = _declareAtVenue(otherVenue, TOKEN, creator); // and its relaunch

        ILaunchDeclarations.Declaration memory d = decl.getDeclaration(first);
        assertEq(uint8(d.kind), uint8(ILaunchDeclarations.IdKind.Erc8376));
        assertEq(d.creator, creator);
        assertEq(d.venue, venue);
        assertEq(d.declaredAt, t0);
        ILaunchDeclarations.Allocation[] memory a = _allocations(first);
        assertEq(a.length, 1);
        assertEq(a[0].holder, other);
        assertEq(a[0].amount, 10);
        assertEq(_allocations(relaunch)[0].amount, 99);
        assertEq(decl.getDeclaration(relaunch).declaredAt, t0 + 30 days);
        assertEq(_allocations(scoped0).length, 0);

        bytes32[] memory all = decl.declarationIdsOf(TOKEN, 0, 10);
        assertEq(all.length, 4);
        assertEq(all[0], first);
        assertEq(all[1], relaunch);
        assertEq(all[2], scoped0);
        assertEq(all[3], scoped1);
    }

    function test_factLists_arePaged() public {
        bytes32 id = _declareAtVenue(venue, TOKEN, creator);
        vm.startPrank(venue);
        for (uint256 i; i < 5; ++i) {
            decl.declareAllocation(id, other, i + 1, 0, 0);
            decl.declareLiquidity(id, LOCKS, i + 1, address(0), address(0), 0, 0);
            decl.declareFeeRecipient(id, FEES, i % 2 == 0 ? creator : other);
        }
        vm.stopPrank();

        ILaunchDeclarations.Allocation[] memory a = decl.allocationsOf(id, 1, 2);
        assertEq(a.length, 2);
        assertEq(a[0].amount, 2);
        assertEq(a[1].amount, 3);
        ILaunchDeclarations.Liquidity[] memory l = decl.liquidityOf(id, 3, 10);
        assertEq(l.length, 2);
        assertEq(l[0].lockId, 4);
        assertEq(l[1].lockId, 5);
        ILaunchDeclarations.FeeRecipient[] memory r = decl.feeRecipientsOf(id, 3, 2);
        assertEq(r.length, 2);
        assertEq(r[0].recipient, other);
        assertEq(r[1].recipient, creator);
        assertEq(decl.allocationsOf(id, 5, 10).length, 0);
        assertEq(decl.liquidityOf(id, 5, 10).length, 0);
        assertEq(decl.feeRecipientsOf(id, 7, 1).length, 0);
        assertEq(decl.allocationsOf(id, 1, type(uint256).max).length, 4);
        assertEq(decl.allocationsOf(bytes32(uint256(1)), 0, 10).length, 0);

        // A venue that lengthens its own list cannot stop a bounded reader from reading the first page.
        vm.startPrank(venue);
        for (uint256 i; i < 300; ++i) {
            decl.declareAllocation(id, other, i + 1, 0, 0);
        }
        vm.stopPrank();
        (bool ok, bytes memory ret) =
            address(decl).staticcall{gas: 300_000}(abi.encodeCall(decl.allocationsOf, (id, 0, 10)));
        assertTrue(ok, "first page unreadable within 300k gas");
        assertEq(abi.decode(ret, (ILaunchDeclarations.Allocation[])).length, 10);
    }

    // ------------------------------------------------------------- reading

    function test_getDeclaration_unknownIsNone() public view {
        bytes32 unknown = keccak256("nothing");
        ILaunchDeclarations.Declaration memory d = decl.getDeclaration(unknown);
        assertEq(uint8(d.kind), uint8(ILaunchDeclarations.IdKind.None));
        assertEq(d.token, address(0));
        assertEq(d.creator, address(0));
        assertEq(d.venue, address(0));
        assertEq(d.identityRegistry, address(0));
        assertEq(d.agentId, 0);
        assertEq(d.declaredAt, 0);
        assertEq(_allocations(unknown).length, 0);
        assertEq(decl.liquidityOf(unknown, 0, 10).length, 0);
        assertEq(decl.feeRecipientsOf(unknown, 0, 10).length, 0);
    }

    function test_lists_pages() public {
        bytes32[] memory ids = new bytes32[](5);
        for (uint256 i; i < 5; ++i) {
            ids[i] = _declareAtVenue(venue, TOKEN, creator);
        }
        bytes32[] memory p = decl.declarationIdsOf(TOKEN, 1, 2);
        assertEq(p.length, 2);
        assertEq(p[0], ids[1]);
        assertEq(p[1], ids[2]);
        assertEq(decl.declarationIdsOf(TOKEN, 4, 10).length, 1);
        assertEq(decl.declarationIdsOf(TOKEN, 5, 10).length, 0);
        assertEq(decl.declarationIdsOf(TOKEN, 0, type(uint256).max).length, 5);
        assertEq(decl.declarationIdsOf(TOKEN, 1, type(uint256).max).length, 4);
        p = decl.declarationIdsBy(creator, 3, 2);
        assertEq(p.length, 2);
        assertEq(p[0], ids[3]);
        assertEq(p[1], ids[4]);
        assertEq(decl.declarationIdsBy(creator, 5, 1).length, 0);
        assertEq(decl.declarationIdsBy(other, 0, 10).length, 0);
    }

    function test_severalLaunchesPerToken() public {
        bytes32 l0 = _listAndDeclare(TOKEN, 0);
        bytes32 l1 = _listAndDeclare(TOKEN, 1); // a relaunch, listed again
        bytes32 v0 = _declareAtVenue(otherVenue, TOKEN, creator); // at a venue outside ERC-8376
        bytes32 v1 = _declareAtVenue(venue, TOKEN, other); // another creator's launch of the same token

        bytes32[] memory all = decl.declarationIdsOf(TOKEN, 0, 10);
        assertEq(all.length, 4);
        assertEq(all[0], l0);
        assertEq(all[1], l1);
        assertEq(all[2], v0);
        assertEq(all[3], v1);
        bytes32[] memory byCreator = decl.declarationIdsBy(creator, 0, 10);
        assertEq(byCreator.length, 3);
        assertEq(byCreator[2], v0);

        // ERC-8376 reaches only the listed ones; venue-scoped declarations are outside its coverage
        bytes32[] memory launches = directory.launchesOf(TOKEN);
        assertEq(launches.length, 2);
        assertEq(launches[0], l0);
        assertEq(launches[1], l1);
        assertEq(directory.launchesBy(creator).length, 2);
        assertEq(directory.tokenOf(v0), address(0));
        assertEq(uint8(decl.getDeclaration(l1).kind), uint8(ILaunchDeclarations.IdKind.Erc8376));
        assertEq(uint8(decl.getDeclaration(v0).kind), uint8(ILaunchDeclarations.IdKind.Venue));
    }

    // ------------------------------------------------------------- interface and directory

    function test_supportsInterface() public view {
        assertTrue(decl.supportsInterface(type(ILaunchDeclarations).interfaceId));
        assertTrue(decl.supportsInterface(0x01ffc9a7));
        assertFalse(decl.supportsInterface(0xffffffff));
    }

    function test_launchDirectory_isFixed() public {
        assertEq(decl.launchDirectory(), address(directory));
        _listAndDeclare(TOKEN, 0);
        _declareAtVenue(venue, TOKEN, creator);
        assertEq(decl.launchDirectory(), address(directory));
    }

    function test_mockDirectory_followsErc8376() public {
        bytes32 id = _launchId(escrow, TOKEN, creator, 0);
        vm.prank(escrow); // a wrong nonce gives another identifier
        vm.expectRevert(MockLaunchDirectory.NotEscrowOfLaunch.selector);
        directory.list(id, TOKEN, creator, venue, 1);
        vm.prank(escrow);
        directory.list(id, TOKEN, creator, venue, 0);
        vm.prank(escrow);
        vm.expectRevert(MockLaunchDirectory.AlreadyListed.selector);
        directory.list(id, TOKEN, creator, attacker, 0);
        assertEq(directory.escrowOf(id), escrow);
        assertEq(directory.venueOf(id), venue);
        assertEq(directory.deployerOf(id), creator);
        assertEq(directory.tokenOf(id), TOKEN);
        assertEq(directory.launchesBy(creator)[0], id);
    }
}
