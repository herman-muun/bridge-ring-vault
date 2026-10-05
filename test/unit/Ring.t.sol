// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";

import { MuunRingVault } from "../../contracts/MuunRingVault.sol";
import { VaultTestBase, idxOf } from "./VaultTestBase.sol";

/// The ring rules R1..R6 from the contract header (R7, the stake floors, lives in
/// `SponsorshipFunding.t.sol`). Every other behaviour is covered by the bridge-vault suites
/// adapted next to this file.
contract RingTest is VaultTestBase {
    bytes32 internal constant SWAP_A = bytes32("a");
    bytes32 internal constant SWAP_B = bytes32("b");
    uint32 internal constant IDX = 7;

    function _lockAt(bytes32 swapId, address who, uint256 amount, uint32 idx) internal {
        vm.prank(owner);
        vault.lock(swapId, who, amount, idx);
    }

    function _claimSig(bytes32 swapId, uint256 amount, address to)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(claimantKey, vault.claimDigest(swapId, amount, to));
        return abi.encodePacked(r, s, v);
    }

    // --- R1: layout and liveness ------------------------------------------------------------

    function test_R1_entryIsTheWholeHash() public view {
        bytes32 e = vault.entry(SWAP_A, claimant, AMOUNT);
        assertEq(e, keccak256(abi.encode(SWAP_A, claimant, AMOUNT)), "all 256 bits, nothing inline");
        assertTrue(e != vault.CONSUMED());
        assertTrue(e != bytes32(0));
    }

    /// Nothing is truncated: changing any field by one bit changes the whole entry.
    function testFuzz_R1_entryBindsEveryField(bytes32 id, address who, uint256 amount) public view {
        vm.assume(amount != AMOUNT || who != claimant || id != SWAP_A);
        assertTrue(vault.entry(id, who, amount) != vault.entry(SWAP_A, claimant, AMOUNT));
    }

    function test_R1_lockWritesTheEntryAtTheIndex() public {
        vm.expectEmit(true, true, false, true);
        emit MuunRingVault.Locked(SWAP_A, claimant, AMOUNT, IDX);
        _lockAt(SWAP_A, claimant, AMOUNT, IDX);
        assertEq(vault.ring(IDX), vault.entry(SWAP_A, claimant, AMOUNT));
        assertTrue(vault.isReservation(SWAP_A, claimant, AMOUNT, IDX));
        assertFalse(vault.isReservation(SWAP_A, claimant, AMOUNT, IDX + 1));
    }

    function test_R1_liveSlotCannotBeRewritten() public {
        _lockAt(SWAP_A, claimant, AMOUNT, IDX);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MuunRingVault.SlotLive.selector, IDX));
        vault.lock(SWAP_B, claimant, AMOUNT, IDX);

        // Still live ten years later: there is no expiry to wait out.
        vm.warp(block.timestamp + 10 * 365 days);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MuunRingVault.SlotLive.selector, IDX));
        vault.lock(SWAP_B, claimant, AMOUNT, IDX);

        // Not even for the same swap at the same amount: a reservation is written once.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MuunRingVault.SlotLive.selector, IDX));
        vault.lock(SWAP_A, claimant, AMOUNT, IDX);
    }

    function test_R1_amountIsBoundedByTheCounterOnly() public {
        vm.prank(owner);
        vm.expectRevert(MuunRingVault.ZeroAmount.selector);
        vault.lock(SWAP_A, claimant, 0, IDX);

        // Above the 128-bit `reserved` counter: a clean revert, never a checked-arithmetic panic.
        vm.prank(owner);
        vm.expectRevert(MuunRingVault.ValueOverflow.selector);
        vault.lock(SWAP_A, claimant, uint256(type(uint128).max) + 1, IDX);

        // Above 64 bits is fine now (the old entry packed `amount` in 64 bits); the vault just
        // has to hold it.
        uint256 big = uint256(type(uint64).max) + 1;
        token.mint(address(vault), big);
        _lockAt(SWAP_A, claimant, big, IDX);
        assertTrue(vault.isReservation(SWAP_A, claimant, big, IDX));
        assertEq(vault.reserved(), big);
    }

    // --- R2: no expiry, no refund -----------------------------------------------------------

    function test_R2_reservationIsClaimableForEver() public {
        _lockAt(SWAP_A, claimant, AMOUNT, IDX);
        vm.warp(block.timestamp + 50 * 365 days);

        vault.claimBySig(SWAP_A, AMOUNT, recipient, _claimSig(SWAP_A, AMOUNT, recipient), IDX);
        assertEq(token.balanceOf(recipient), AMOUNT);
        assertEq(vault.ring(IDX), vault.CONSUMED());
    }

    /// The owner has no function that touches a live reservation: nothing in the ABI takes a
    /// reservation away from `P`, and the counters it pins stay pinned.
    function test_R2_ownerCannotReleaseAnAbandonedReservation() public {
        _lockAt(SWAP_A, claimant, AMOUNT, IDX);
        vm.warp(block.timestamp + 10 * 365 days);

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(MuunRingVault.SlotLive.selector, IDX));
        vault.lock(SWAP_B, claimant, AMOUNT, IDX);
        vm.expectRevert(MuunRingVault.InvalidReservation.selector);
        vault.claimSelf(SWAP_A, AMOUNT, owner, IDX); // owner is not the claimant
        vm.stopPrank();

        assertEq(vault.reserved(), AMOUNT);
        assertEq(vault.inFlight(), 1);
        assertTrue(vault.isReservation(SWAP_A, claimant, AMOUNT, IDX));
    }

    /// A `Claim` signed under the version "2" struct (with `expiry`) recovers another signer and
    /// finds no reservation: decision #11.
    function test_R2_versionTwoClaimDoesNotVerify() public {
        _lockAt(SWAP_A, claimant, AMOUNT, IDX);
        bytes32 oldTypehash =
            keccak256("Claim(bytes32 swapId,uint256 amount,address recipient,uint48 expiry)");
        bytes32 structHash =
            keccak256(abi.encode(oldTypehash, SWAP_A, AMOUNT, recipient, uint48(1_900_000_000)));
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", vault.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(claimantKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(MuunRingVault.InvalidReservation.selector);
        vault.claimBySig(SWAP_A, AMOUNT, recipient, sig, IDX);
        assertTrue(vault.isReservation(SWAP_A, claimant, AMOUNT, IDX));
    }

    /// Documented, not prevented (decision #11): a `Claim` binds the triple, not the index. If
    /// Muun locked the same `(swapId, claimant, amount)` twice, one signature claims both; the
    /// funds go to the recipient `P` signed, so only Muun pays twice.
    function test_R2_duplicateTripleIsMuunsDoublePayout() public {
        _lockAt(SWAP_A, claimant, AMOUNT, IDX);
        _lockAt(SWAP_A, claimant, AMOUNT, IDX + 1);
        bytes memory sig = _claimSig(SWAP_A, AMOUNT, recipient);

        vault.claimBySig(SWAP_A, AMOUNT, recipient, sig, IDX);
        vault.claimBySig(SWAP_A, AMOUNT, recipient, sig, IDX + 1);
        assertEq(token.balanceOf(recipient), 2 * AMOUNT, "paid twice, to P's recipient");
        assertEq(vault.inFlight(), 0);
    }

    // --- R3: never zero ---------------------------------------------------------------------

    function test_R3_noPathWritesZero() public {
        _lockAt(SWAP_A, claimant, AMOUNT, IDX);
        vm.prank(claimant);
        vault.claimSelf(SWAP_A, AMOUNT, recipient, IDX);
        assertEq(vault.ring(IDX), vault.CONSUMED(), "claimSelf leaves CONSUMED");

        _lockAt(SWAP_B, claimant, AMOUNT, IDX);
        vault.claimBySig(SWAP_B, AMOUNT, recipient, _claimSig(SWAP_B, AMOUNT, recipient), IDX);
        assertEq(vault.ring(IDX), vault.CONSUMED(), "claimBySig leaves CONSUMED");

        assertTrue(vault.CONSUMED() != bytes32(0));
    }

    function test_R3_consumedSlotIsFreeImmediately() public {
        _lockAt(SWAP_A, claimant, AMOUNT, IDX);
        vm.prank(claimant);
        vault.claimSelf(SWAP_A, AMOUNT, recipient, IDX);

        // Same block, same index: a consumed slot is free with no waiting and no release event.
        _lockAt(SWAP_B, claimant, AMOUNT, IDX);
        assertEq(vault.inFlight(), 1);
        assertEq(vault.reserved(), AMOUNT);
        assertEq(vault.ring(IDX), vault.entry(SWAP_B, claimant, AMOUNT));
    }

    // --- R4: no double consumption ----------------------------------------------------------

    function test_R4_consumedEntryCannotBeClaimedAgain() public {
        _lockAt(SWAP_A, claimant, AMOUNT, IDX);
        vm.prank(claimant);
        vault.claimSelf(SWAP_A, AMOUNT, recipient, IDX);

        vm.prank(claimant);
        vm.expectRevert(MuunRingVault.InvalidReservation.selector);
        vault.claimSelf(SWAP_A, AMOUNT, recipient, IDX);

        bytes memory sig = _claimSig(SWAP_A, AMOUNT, recipient);
        vm.expectRevert(MuunRingVault.InvalidReservation.selector);
        vault.claimBySig(SWAP_A, AMOUNT, recipient, sig, IDX);
        assertEq(token.balanceOf(recipient), AMOUNT, "paid exactly once");
    }

    /// A consumed index rewritten for another swap does not revive the first claim.
    function test_R4_reusedIndexDoesNotReviveTheOldClaim() public {
        _lockAt(SWAP_A, claimant, AMOUNT, IDX);
        vm.prank(claimant);
        vault.claimSelf(SWAP_A, AMOUNT, recipient, IDX);
        _lockAt(SWAP_B, claimant, AMOUNT, IDX);

        bytes memory sig = _claimSig(SWAP_A, AMOUNT, recipient);
        vm.expectRevert(MuunRingVault.InvalidReservation.selector);
        vault.claimBySig(SWAP_A, AMOUNT, recipient, sig, IDX);
        assertTrue(vault.isReservation(SWAP_B, claimant, AMOUNT, IDX));
    }

    // --- R5: bound to the index -------------------------------------------------------------

    function test_R5_wrongIndexIsNotAPayout() public {
        _lockAt(SWAP_A, claimant, AMOUNT, IDX);

        vm.prank(claimant);
        vm.expectRevert(MuunRingVault.InvalidReservation.selector);
        vault.claimSelf(SWAP_A, AMOUNT, recipient, IDX + 1);

        // A second reservation at another index does not make the first claimable there.
        _lockAt(SWAP_B, claimant, AMOUNT, IDX + 1);
        vm.prank(claimant);
        vm.expectRevert(MuunRingVault.InvalidReservation.selector);
        vault.claimSelf(SWAP_A, AMOUNT, recipient, IDX + 1);

        vm.prank(claimant);
        vault.claimSelf(SWAP_A, AMOUNT, recipient, IDX);
        assertEq(token.balanceOf(recipient), AMOUNT);
    }

    // --- R6: the paymaster screen -----------------------------------------------------------

    function _opAt(bytes32 swapId, uint256 idxWord)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = _op(swapId);
        bytes memory inner = abi.encodeWithSelector(
            MuunRingVault.claimSelf.selector, swapId, AMOUNT, recipient, idxWord
        );
        op.callData = abi.encodeWithSignature(
            "execute(address,uint256,bytes)", address(vault), uint256(0), inner
        );
    }

    function test_R6_screenAcceptsTheRightIndexOnly() public {
        _lockAt(SWAP_A, claimant, AMOUNT, IDX);
        vm.signAndAttachDelegation(address(accountImpl), claimantKey);

        assertEq(vault.sponsorshipRejection(_opAt(SWAP_A, IDX), COST), vault.REJECT_NONE());
        assertEq(
            vault.sponsorshipRejection(_opAt(SWAP_A, IDX + 1), COST), vault.REJECT_RESERVATION()
        );
    }

    function test_R6_screenDeclinesAnIndexWordAboveUint32() public {
        _lockAt(SWAP_A, claimant, AMOUNT, IDX);
        vm.signAndAttachDelegation(address(accountImpl), claimantKey);

        // Same low 32 bits as the real index, dirty upper bits: declined, never decoded.
        uint256 dirty = (uint256(1) << 32) | IDX;
        assertEq(vault.sponsorshipRejection(_opAt(SWAP_A, dirty), COST), vault.REJECT_CALLDATA());
    }

    function test_R6_screenAcceptsTheMaximumIndex() public {
        uint32 top = type(uint32).max;
        _lockAt(SWAP_A, claimant, AMOUNT, top);
        vm.signAndAttachDelegation(address(accountImpl), claimantKey);

        assertEq(vault.sponsorshipRejection(_opAt(SWAP_A, top), COST), vault.REJECT_NONE());
        // Only the top bit set: above uint32, declined before any ring read.
        assertEq(
            vault.sponsorshipRejection(_opAt(SWAP_A, uint256(1) << 255), COST),
            vault.REJECT_CALLDATA()
        );
    }

    /// The 28 bytes of ABI padding after the inner call must be zero: one exit, one encoding.
    function test_R6_dirtyTrailingPaddingIsDeclined() public {
        _lockAt(SWAP_A, claimant, AMOUNT, IDX);
        vm.signAndAttachDelegation(address(accountImpl), claimantKey);

        PackedUserOperation memory op = _opAt(SWAP_A, IDX);
        bytes memory cd = op.callData;
        assertEq(cd.length, 292);
        cd[291] = 0x01;
        op.callData = cd;
        assertEq(vault.sponsorshipRejection(op, COST), vault.REJECT_CALLDATA());
    }

    function test_R6_calldataLengthIsTheFourArgumentShape() public {
        _lockAt(SWAP_A, claimant, AMOUNT, IDX);
        vm.signAndAttachDelegation(address(accountImpl), claimantKey);

        PackedUserOperation memory op = _opAt(SWAP_A, IDX);
        assertEq(op.callData.length, 292, "execute(vault, 0, claimSelf with four words)");

        // The five-argument shape of the previous version (with `expiry`) is declined on length.
        bytes memory inner = abi.encodeWithSelector(
            MuunRingVault.claimSelf.selector, SWAP_A, AMOUNT, recipient, uint48(0), IDX
        );
        op.callData = abi.encodeWithSignature(
            "execute(address,uint256,bytes)", address(vault), uint256(0), inner
        );
        assertEq(op.callData.length, 324);
        assertEq(vault.sponsorshipRejection(op, COST), vault.REJECT_CALLDATA());
    }
}
