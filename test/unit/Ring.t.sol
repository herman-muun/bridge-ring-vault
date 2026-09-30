// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";

import { MuunRingVault } from "../../contracts/MuunRingVault.sol";
import { VaultTestBase, idxOf } from "./VaultTestBase.sol";

/// The ring rules R1..R6 from the contract header. Every other behaviour is covered by the
/// bridge-vault suites adapted next to this file.
contract RingTest is VaultTestBase {
    bytes32 internal constant SWAP_A = bytes32("a");
    bytes32 internal constant SWAP_B = bytes32("b");
    uint32 internal constant IDX = 7;

    function _lockAt(bytes32 swapId, address who, uint256 amount, uint48 expiry, uint32 idx)
        internal
    {
        vm.prank(owner);
        vault.lock(swapId, who, amount, expiry, idx);
    }

    // --- R1: layout and liveness ------------------------------------------------------------

    function test_R1_entryLayout() public view {
        uint48 expiry = _defaultExpiry();
        bytes32 e = vault.entry(SWAP_A, claimant, AMOUNT, expiry);
        uint256 h = uint256(keccak256(abi.encode(SWAP_A, claimant, AMOUNT, expiry)));
        assertEq(uint256(e) >> 96, h >> 96, "top 160 bits are the hash");
        assertEq((uint256(e) >> 32) & type(uint64).max, AMOUNT, "amount field");
        assertEq(uint256(e) & type(uint32).max, expiry, "expiry field");
    }

    function test_R1_lockWritesTheEntryAtTheIndex() public {
        uint48 expiry = _defaultExpiry();
        vm.expectEmit(true, true, false, true);
        emit MuunRingVault.Locked(SWAP_A, claimant, AMOUNT, expiry, IDX);
        _lockAt(SWAP_A, claimant, AMOUNT, expiry, IDX);
        assertEq(vault.ring(IDX), vault.entry(SWAP_A, claimant, AMOUNT, expiry));
        assertTrue(vault.isReservation(SWAP_A, claimant, AMOUNT, expiry, IDX));
        assertFalse(vault.isReservation(SWAP_A, claimant, AMOUNT, expiry, IDX + 1));
    }

    function test_R1_liveSlotCannotBeRewritten() public {
        uint48 expiry = _defaultExpiry();
        _lockAt(SWAP_A, claimant, AMOUNT, expiry, IDX);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MuunRingVault.SlotLive.selector, IDX, expiry));
        vault.lock(SWAP_B, claimant, AMOUNT, expiry, IDX);

        // Still live in the block of the expiry itself: claims are valid through it.
        vm.warp(expiry);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MuunRingVault.SlotLive.selector, IDX, expiry));
        vault.lock(SWAP_B, claimant, AMOUNT, expiry + 1, IDX);
    }

    function test_R1_amountAndExpiryMustFitTheEntry() public {
        uint48 expiry = _defaultExpiry();
        vm.prank(owner);
        vm.expectRevert(MuunRingVault.ZeroAmount.selector);
        vault.lock(SWAP_A, claimant, uint256(type(uint64).max) + 1, expiry, IDX);

        vm.prank(owner);
        vm.expectRevert(MuunRingVault.InvalidExpiry.selector);
        vault.lock(SWAP_A, claimant, AMOUNT, uint48(type(uint32).max) + 1, IDX);
    }

    // --- R2: reuse of an expired, unconsumed slot -------------------------------------------

    function test_R2_lockOverExpiredSlotReleasesTheOldReservation() public {
        uint48 expiry = _defaultExpiry();
        _lockAt(SWAP_A, claimant, AMOUNT, expiry, IDX);
        assertEq(vault.reserved(), AMOUNT);
        assertEq(vault.inFlight(), 1);

        vm.warp(uint256(expiry) + 1);
        uint48 expiry2 = _defaultExpiry();
        vm.expectEmit(true, false, false, true);
        emit MuunRingVault.Released(IDX, AMOUNT);
        _lockAt(SWAP_B, claimant, 3 * AMOUNT, expiry2, IDX);

        assertEq(vault.reserved(), 3 * AMOUNT, "old amount released, new one reserved");
        assertEq(vault.inFlight(), 1, "count released then re-taken");
        assertEq(vault.ring(IDX), vault.entry(SWAP_B, claimant, 3 * AMOUNT, expiry2));

        // The old reservation is gone for good: a refund no longer finds it (a claim is already
        // past its expiry).
        vm.expectRevert(MuunRingVault.InvalidReservation.selector);
        vault.refund(SWAP_A, claimant, AMOUNT, expiry, IDX);
    }

    /// The inline release counts one budget: with exactly one exit budget funded, replacing the
    /// expired reservation is allowed (it frees the budget it takes).
    function test_R2_inlineReleaseFreesTheSponsorshipBudget() public {
        _setDeposit(COST);
        uint48 expiry = _defaultExpiry();
        _lockAt(SWAP_A, claimant, AMOUNT, expiry, IDX);

        vm.warp(uint256(expiry) + 1);
        _lockAt(SWAP_B, claimant, AMOUNT, _defaultExpiry(), IDX);
        assertEq(vault.inFlight(), 1);
    }

    // --- R3: never zero ---------------------------------------------------------------------

    function test_R3_noPathWritesZero() public {
        uint48 expiry = _defaultExpiry();

        _lockAt(SWAP_A, claimant, AMOUNT, expiry, IDX);
        vm.prank(claimant);
        vault.claimSelf(SWAP_A, AMOUNT, recipient, expiry, IDX);
        assertEq(vault.ring(IDX), vault.CONSUMED(), "claimSelf leaves CONSUMED");

        _lockAt(SWAP_B, claimant, AMOUNT, expiry, IDX);
        vm.warp(uint256(expiry) + 1);
        vault.refund(SWAP_B, claimant, AMOUNT, expiry, IDX);
        assertEq(vault.ring(IDX), vault.CONSUMED(), "refund leaves CONSUMED");

        uint48 expiry3 = _defaultExpiry();
        _lockAt(SWAP_A, claimant, AMOUNT, expiry3, IDX);
        vm.warp(uint256(expiry3) + 1);
        _lockAt(SWAP_B, claimant, AMOUNT, _defaultExpiry(), IDX);
        assertTrue(vault.ring(IDX) != bytes32(0), "lock over expired rewrites, never clears");
        assertTrue(vault.CONSUMED() != bytes32(0));
    }

    function test_R3_consumedSlotIsFreeImmediately() public {
        uint48 expiry = _defaultExpiry();
        _lockAt(SWAP_A, claimant, AMOUNT, expiry, IDX);
        vm.prank(claimant);
        vault.claimSelf(SWAP_A, AMOUNT, recipient, expiry, IDX);

        // Same block, same index, no waiting for the old expiry and no release event.
        _lockAt(SWAP_B, claimant, AMOUNT, expiry, IDX);
        assertEq(vault.inFlight(), 1);
        assertEq(vault.reserved(), AMOUNT);
    }

    // --- R4: no double consumption ----------------------------------------------------------

    function test_R4_consumedEntryCannotBeClaimedOrRefundedAgain() public {
        uint48 expiry = _defaultExpiry();
        _lockAt(SWAP_A, claimant, AMOUNT, expiry, IDX);
        vm.prank(claimant);
        vault.claimSelf(SWAP_A, AMOUNT, recipient, expiry, IDX);

        vm.prank(claimant);
        vm.expectRevert(MuunRingVault.InvalidReservation.selector);
        vault.claimSelf(SWAP_A, AMOUNT, recipient, expiry, IDX);

        bytes32 digest = vault.claimDigest(SWAP_A, AMOUNT, recipient, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(claimantKey, digest);
        vm.expectRevert(MuunRingVault.InvalidReservation.selector);
        vault.claimBySig(SWAP_A, AMOUNT, recipient, expiry, abi.encodePacked(r, s, v), IDX);

        vm.warp(uint256(expiry) + 1);
        vm.expectRevert(MuunRingVault.InvalidReservation.selector);
        vault.refund(SWAP_A, claimant, AMOUNT, expiry, IDX);
        assertEq(token.balanceOf(recipient), AMOUNT, "paid exactly once");
    }

    // --- R5: bound to the index -------------------------------------------------------------

    function test_R5_wrongIndexIsNotAPayout() public {
        uint48 expiry = _defaultExpiry();
        _lockAt(SWAP_A, claimant, AMOUNT, expiry, IDX);

        vm.prank(claimant);
        vm.expectRevert(MuunRingVault.InvalidReservation.selector);
        vault.claimSelf(SWAP_A, AMOUNT, recipient, expiry, IDX + 1);

        // A second reservation at another index does not make the first claimable there.
        _lockAt(SWAP_B, claimant, AMOUNT, expiry, IDX + 1);
        vm.prank(claimant);
        vm.expectRevert(MuunRingVault.InvalidReservation.selector);
        vault.claimSelf(SWAP_A, AMOUNT, recipient, expiry, IDX + 1);

        vm.prank(claimant);
        vault.claimSelf(SWAP_A, AMOUNT, recipient, expiry, IDX);
        assertEq(token.balanceOf(recipient), AMOUNT);
    }

    // --- R6: the paymaster screen -----------------------------------------------------------

    function _opAt(bytes32 swapId, uint48 expiry, uint256 idxWord)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op = _op(swapId, expiry);
        bytes memory inner = abi.encodeWithSelector(
            MuunRingVault.claimSelf.selector, swapId, AMOUNT, recipient, expiry, idxWord
        );
        op.callData = abi.encodeWithSignature(
            "execute(address,uint256,bytes)", address(vault), uint256(0), inner
        );
    }

    function test_R6_screenAcceptsTheRightIndexOnly() public {
        uint48 expiry = _defaultExpiry();
        _lockAt(SWAP_A, claimant, AMOUNT, expiry, IDX);
        vm.signAndAttachDelegation(address(accountImpl), claimantKey);

        assertEq(vault.sponsorshipRejection(_opAt(SWAP_A, expiry, IDX), COST), vault.REJECT_NONE());
        assertEq(
            vault.sponsorshipRejection(_opAt(SWAP_A, expiry, IDX + 1), COST),
            vault.REJECT_RESERVATION()
        );
    }

    function test_R6_screenDeclinesAnIndexWordAboveUint32() public {
        uint48 expiry = _defaultExpiry();
        _lockAt(SWAP_A, claimant, AMOUNT, expiry, IDX);
        vm.signAndAttachDelegation(address(accountImpl), claimantKey);

        // Same low 32 bits as the real index, dirty upper bits: declined, never decoded.
        uint256 dirty = (uint256(1) << 32) | IDX;
        assertEq(vault.sponsorshipRejection(_opAt(SWAP_A, expiry, dirty), COST), vault.REJECT_CALLDATA());
    }

    function test_R6_calldataLengthIsTheFiveArgumentShape() public {
        uint48 expiry = _defaultExpiry();
        _lockAt(SWAP_A, claimant, AMOUNT, expiry, IDX);
        vm.signAndAttachDelegation(address(accountImpl), claimantKey);

        PackedUserOperation memory op = _opAt(SWAP_A, expiry, IDX);
        assertEq(op.callData.length, 324, "execute(vault, 0, claimSelf with five words)");

        // The four-argument (bridge-vault) shape is declined on length alone.
        bytes memory inner = abi.encodeWithSelector(
            MuunRingVault.claimSelf.selector, SWAP_A, AMOUNT, recipient, expiry
        );
        op.callData = abi.encodeWithSignature(
            "execute(address,uint256,bytes)", address(vault), uint256(0), inner
        );
        assertEq(op.callData.length, 292);
        assertEq(vault.sponsorshipRejection(op, COST), vault.REJECT_CALLDATA());
    }
}
