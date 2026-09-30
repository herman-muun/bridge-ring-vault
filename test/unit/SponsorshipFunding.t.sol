// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { VaultTestBase, idxOf } from "./VaultTestBase.sol";
import { MuunRingVault } from "../../contracts/MuunRingVault.sol";
import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";

contract SponsorshipFundingTest is VaultTestBase {
    // --- the lock-time solvency gate --------------------------------------------------------

    function test_lock_succeedsAtExactBoundary() public {
        _setDeposit(COST);
        _lock(bytes32("a"), _defaultExpiry());
        assertEq(vault.inFlight(), 1);
    }

    function test_lock_revertsOneWeiBelowBoundary() public {
        _setDeposit(COST - 1);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                MuunRingVault.SponsorshipUnderfunded.selector, COST, COST - 1
            )
        );
        vault.lock(bytes32("a"), claimant, AMOUNT, _defaultExpiry(), idxOf(bytes32("a")));
    }

    /// One budget per live reservation, this one included.
    function test_lock_requirementGrowsWithInFlight() public {
        _setDeposit(2 * COST);
        _lock(bytes32("a"), _defaultExpiry());
        _lock(bytes32("b"), _defaultExpiry());

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                MuunRingVault.SponsorshipUnderfunded.selector, 3 * COST, 2 * COST
            )
        );
        vault.lock(bytes32("c"), claimant, AMOUNT, _defaultExpiry(), idxOf(bytes32("c")));
    }

    /// The pin for the whole design: the EntryPoint debits the deposit and nothing else, so ETH
    /// sitting in the contract must not let a swap through.
    function test_lock_ignoresTheContractBalanceEntirely() public {
        _setDeposit(0);
        vm.deal(address(vault), 100 ether);

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(MuunRingVault.SponsorshipUnderfunded.selector, COST, 0)
        );
        vault.lock(bytes32("a"), claimant, AMOUNT, _defaultExpiry(), idxOf(bytes32("a")));
    }

    /// Anyone can restore the vault's ability to open swaps, without touching vault code.
    function test_thirdPartyDepositUnblocksLock() public {
        _setDeposit(0);
        vm.prank(owner);
        vm.expectRevert();
        vault.lock(bytes32("a"), claimant, AMOUNT, _defaultExpiry(), idxOf(bytes32("a")));

        address stranger = address(0x5747);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        entryPoint.depositTo{ value: COST }(address(vault));

        _lock(bytes32("a"), _defaultExpiry());
        assertEq(vault.inFlight(), 1);
    }

    function test_lock_revertsWhenUnstaked() public {
        vm.prank(owner);
        vault.unlockStake();

        vm.prank(owner);
        vm.expectRevert(MuunRingVault.NotStaked.selector);
        vault.lock(bytes32("a"), claimant, AMOUNT, _defaultExpiry(), idxOf(bytes32("a")));
    }

    // --- withdrawal gating ------------------------------------------------------------------

    /// The contract balance backs nothing, so it can always be swept.
    function test_withdrawETH_balanceBranchIsUngated() public {
        _lock(bytes32("a"), _defaultExpiry());
        vm.deal(address(vault), 5 ether);

        vm.prank(owner);
        vault.withdrawETH(payable(owner), 5 ether, false);
        assertEq(address(vault).balance, 0);
        assertGe(vault.sponsorshipDeposit(), vault.requiredSponsorship());
    }

    function test_withdrawETH_depositBranchGated() public {
        _setDeposit(2 * COST);
        _lock(bytes32("a"), _defaultExpiry());

        vm.prank(owner);
        vm.expectRevert();
        vault.withdrawETH(payable(owner), COST + 1, true);

        vm.prank(owner);
        vault.withdrawETH(payable(owner), COST, true);
        assertEq(vault.sponsorshipDeposit(), COST);
    }

    /// A balance that covers the requirement must not unlock the deposit.
    function test_withdrawETH_balanceCannotUnlockTheDeposit() public {
        _setDeposit(COST);
        _lock(bytes32("a"), _defaultExpiry());
        vm.deal(address(vault), 100 ether);

        vm.prank(owner);
        vm.expectRevert();
        vault.withdrawETH(payable(owner), COST, true);
    }

    function test_withdrawETH_onlyOwner() public {
        vm.expectRevert(MuunRingVault.NotOwner.selector);
        vault.withdrawETH(payable(address(this)), 1, false);
    }

    /// The deposit is one EntryPoint entry serving one role. A UserOperation naming the vault as
    /// its own sender is the only way a third party could reach it without holding a reservation,
    /// and it cannot: the vault has no `validateUserOp` and no `fallback`.
    function test_vaultCannotBeChargedAsAUserOpSender() public {
        _lock(bytes32("a"), _defaultExpiry());
        uint256 depositBefore = vault.sponsorshipDeposit();

        PackedUserOperation memory op;
        op.sender = address(vault);
        op.nonce = 0;
        op.accountGasLimits = _pack(VGL_CAP, CGL_CAP);
        op.preVerificationGas = PVG_CAP;
        op.gasFees = _pack(1 gwei, 10 gwei);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler, bundler);
        vm.expectRevert();
        entryPoint.handleOps(ops, payable(bundler));

        assertEq(vault.sponsorshipDeposit(), depositBefore, "deposit untouched");
    }

    // --- stake gating -----------------------------------------------------------------------

    function test_unlockStake_blockedWhileInFlight() public {
        _lock(bytes32("a"), _defaultExpiry());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MuunRingVault.SponsorshipInUse.selector, 1));
        vault.unlockStake();
    }

    function test_withdrawStake_blockedWhileInFlight() public {
        _lock(bytes32("a"), _defaultExpiry());
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MuunRingVault.SponsorshipInUse.selector, 1));
        vault.withdrawStake(payable(owner));
    }

    function test_unlockStake_allowedWhenIdle() public {
        vm.prank(owner);
        vault.unlockStake();
    }

    function test_stakeFunctions_onlyOwner() public {
        vm.expectRevert(MuunRingVault.NotOwner.selector);
        vault.unlockStake();
        vm.expectRevert(MuunRingVault.NotOwner.selector);
        vault.addStake(1);
    }

    // --- packed accounting ------------------------------------------------------------------

    function test_accountingSlotIsNeverZero() public {
        assertEq(uint256(vm.load(address(vault), bytes32(0))), 1, "non-zero at deploy");

        bytes32 swapId = bytes32("a");
        uint48 expiry = _defaultExpiry();
        _lock(swapId, expiry);
        assertTrue(vm.load(address(vault), bytes32(0)) != bytes32(0));

        vm.warp(uint256(expiry) + 1);
        vault.refund(swapId, claimant, AMOUNT, expiry, idxOf(swapId));
        assertTrue(vm.load(address(vault), bytes32(0)) != bytes32(0), "non-zero once drained");
        assertEq(vault.reserved(), 0);
        assertEq(vault.inFlight(), 0);
    }

    function test_countersDecrementOnClaimSelf() public {
        bytes32 swapId = bytes32("a");
        uint48 expiry = _defaultExpiry();
        _lock(swapId, expiry);

        vm.prank(claimant);
        vault.claimSelf(swapId, AMOUNT, recipient, expiry, idxOf(swapId));

        assertEq(vault.inFlight(), 0);
        assertEq(vault.reserved(), 0);
        assertEq(token.balanceOf(recipient), AMOUNT);
    }

    function test_countersDecrementOnClaimBySig() public {
        bytes32 swapId = bytes32("a");
        uint48 expiry = _defaultExpiry();
        _lock(swapId, expiry);

        bytes32 digest = vault.claimDigest(swapId, AMOUNT, recipient, expiry);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(claimantKey, digest);
        vault.claimBySig(swapId, AMOUNT, recipient, expiry, abi.encodePacked(r, s, v), idxOf(swapId));

        assertEq(vault.inFlight(), 0);
        assertEq(vault.reserved(), 0);
        assertEq(token.balanceOf(recipient), AMOUNT);
    }

    /// A stalled owner must not be able to inflate inFlight forever.
    function test_refundIsPermissionlessAfterExpiry() public {
        bytes32 swapId = bytes32("a");
        uint48 expiry = _defaultExpiry();
        _lock(swapId, expiry);

        vm.expectRevert(MuunRingVault.ReservationNotExpired.selector);
        vault.refund(swapId, claimant, AMOUNT, expiry, idxOf(swapId));

        vm.warp(uint256(expiry) + 1);
        vm.prank(address(0xBEEF));
        vault.refund(swapId, claimant, AMOUNT, expiry, idxOf(swapId));
        assertEq(vault.inFlight(), 0);
    }

    function testFuzz_countersTrackGhostState(uint8 nRaw) public {
        uint256 n = bound(uint256(nRaw), 1, 20);
        _setDeposit((n + 1) * COST);

        uint48 expiry = _defaultExpiry();
        for (uint256 i = 0; i < n; i++) {
            _lock(bytes32(i + 1), expiry);
        }
        assertEq(vault.inFlight(), n);
        assertEq(vault.reserved(), n * AMOUNT);

        vm.warp(uint256(expiry) + 1);
        for (uint256 i = 0; i < n; i++) {
            vault.refund(bytes32(i + 1), claimant, AMOUNT, expiry, idxOf(bytes32(i + 1)));
        }
        assertEq(vault.inFlight(), 0);
        assertEq(vault.reserved(), 0);
    }
}
