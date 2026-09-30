// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Vm } from "forge-std/Vm.sol";
import { VaultTestBase, idxOf } from "./VaultTestBase.sol";
import { MuunRingVault } from "../../contracts/MuunRingVault.sol";
import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";
import { IEntryPoint } from "account-abstraction/interfaces/IEntryPoint.sol";

/// A delegate that passes account validation and then burns the whole call gas limit.
contract MaliciousDelegate {
    function validateUserOp(PackedUserOperation calldata, bytes32, uint256)
        external
        pure
        returns (uint256)
    {
        return 0;
    }

    function execute(address, uint256, bytes calldata) external pure {
        uint256 x;
        while (true) {
            unchecked {
                x = uint256(keccak256(abi.encode(x)));
            }
        }
    }
}

contract RecoveryE2ETest is VaultTestBase {
    bytes32 internal constant USER_OP_EVENT = keccak256(
        "UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)"
    );

    function setUp() public override {
        super.setUp();
        vm.signAndAttachDelegation(address(accountImpl), claimantKey);
    }

    function _lastUserOp()
        internal
        returns (bool success, uint256 actualGasCost, uint256 actualGasUsed)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory l = logs[i - 1];
            if (l.topics.length > 0 && l.topics[0] == USER_OP_EVENT) {
                (, success, actualGasCost, actualGasUsed) =
                    abi.decode(l.data, (uint256, bool, uint256, uint256));
                return (success, actualGasCost, actualGasUsed);
            }
        }
        revert("no UserOperationEvent");
    }

    // --- the honest emergency exit ------------------------------------------------------------

    function test_zeroEthClaimantExitsAndTheDepositPaysForIt() public {
        bytes32 swapId = bytes32("a");
        uint48 expiry = _defaultExpiry();
        _lock(swapId, expiry);

        vm.deal(claimant, 0);
        uint256 depositBefore = vault.sponsorshipDeposit();
        uint256 beneficiaryBefore = bundler.balance;

        vm.recordLogs();
        _handleOps(_sign(_op(swapId, expiry), claimantKey));
        (bool success, uint256 actualGasCost,) = _lastUserOp();

        assertTrue(success, "user operation succeeded");
        assertEq(claimant.balance, 0, "claimant held no ETH before or after");
        assertEq(token.balanceOf(recipient), AMOUNT, "USDT delivered");
        assertEq(vault.inFlight(), 0, "counter released");
        assertEq(vault.reserved(), 0);
        assertEq(vault.ring(idxOf(swapId)), vault.CONSUMED(), "reservation consumed");
        assertEq(
            depositBefore - vault.sponsorshipDeposit(), actualGasCost, "deposit paid exactly"
        );
        assertEq(bundler.balance - beneficiaryBefore, actualGasCost, "bundler reimbursed");
        assertLe(actualGasCost, COST, "never more than one budget");
    }

    function test_exitAfterExpiryIsRejected() public {
        bytes32 swapId = bytes32("a");
        uint48 expiry = _defaultExpiry();
        _lock(swapId, expiry);

        PackedUserOperation memory op = _sign(_op(swapId, expiry), claimantKey);
        vm.warp(uint256(expiry) + 1);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler, bundler);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEntryPoint.FailedOp.selector, 0, "AA32 paymaster expired or not due"
            )
        );
        entryPoint.handleOps(ops, payable(bundler));
    }

    // --- the delegate pin ---------------------------------------------------------------------

    /// Without the pin, `P` could delegate to anything and burn the budget without consuming its
    /// reservation. With it, such an operation never reaches execution and costs the deposit zero.
    function test_maliciousDelegateIsRejectedAndCostsNothing() public {
        bytes32 swapId = bytes32("a");
        uint48 expiry = _defaultExpiry();
        _lock(swapId, expiry);

        MaliciousDelegate evil = new MaliciousDelegate();
        vm.signAndAttachDelegation(address(evil), claimantKey);

        uint256 depositBefore = vault.sponsorshipDeposit();
        PackedUserOperation memory op = _sign(_op(swapId, expiry), claimantKey);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler, bundler);
        vm.expectRevert(
            abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA34 signature error")
        );
        entryPoint.handleOps(ops, payable(bundler));

        assertEq(vault.sponsorshipDeposit(), depositBefore, "deposit untouched");
        assertEq(vault.inFlight(), 1, "reservation still live");
    }

    // --- the residual innocent burn, and its containment ---------------------------------------

    /// A pinned delegate can still fail in execution, e.g. an under-estimated call gas limit. The
    /// deposit pays for that attempt, the reservation survives, and `nonce == 0` makes it the
    /// only sponsored attempt this claimant gets.
    function test_burnedAttemptIsBoundedAndNotRepeatable() public {
        bytes32 swapId = bytes32("a");
        uint48 expiry = _defaultExpiry();
        _lock(swapId, expiry);

        uint256 depositBefore = vault.sponsorshipDeposit();

        PackedUserOperation memory op = _op(swapId, expiry);
        op.accountGasLimits = _pack(VGL_CAP, 25_000); // too little to finish the transfer
        vm.recordLogs();
        _handleOps(_sign(op, claimantKey));
        (bool success, uint256 burned,) = _lastUserOp();

        assertFalse(success, "execution reverted");
        assertEq(token.balanceOf(recipient), 0, "no payout");
        assertEq(vault.inFlight(), 1, "reservation survived");
        assertLe(depositBefore - vault.sponsorshipDeposit(), COST, "bounded by one budget");
        assertEq(burned, depositBefore - vault.sponsorshipDeposit());

        // No second sponsored attempt is reachable, and the two ways of trying fail differently.
        // Replaying nonce 0 is rejected by the EntryPoint, whose sequence has advanced.
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _sign(_op(swapId, expiry), claimantKey);
        vm.prank(bundler, bundler);
        vm.expectRevert(
            abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA25 invalid account nonce")
        );
        entryPoint.handleOps(ops, payable(bundler));

        // Using the sequence the EntryPoint would now accept is declined by the paymaster.
        PackedUserOperation memory next = _op(swapId, expiry);
        next.nonce = 1;
        assertEq(vault.sponsorshipRejection(next, COST), vault.REJECT_NONCE());
        ops[0] = _sign(next, claimantKey);
        vm.prank(bundler, bundler);
        vm.expectRevert(
            abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA34 signature error")
        );
        entryPoint.handleOps(ops, payable(bundler));

        assertLe(depositBefore - vault.sponsorshipDeposit(), COST, "total drain is one budget");
    }

    /// The guarantee: one claimant burning its own budget must not endanger anyone else's exit.
    function test_oneClaimantBurningItsBudgetDoesNotStrandAnother() public {
        (address other, uint256 otherKey) = makeAddrAndKey("claimantQ");
        vm.signAndAttachDelegation(address(accountImpl), otherKey);

        uint48 expiry = _defaultExpiry();
        bytes32 swapA = bytes32("a");
        bytes32 swapB = bytes32("b");

        vm.startPrank(owner);
        vault.lock(swapA, claimant, AMOUNT, expiry, idxOf(swapA));
        vault.lock(swapB, other, AMOUNT, expiry, idxOf(swapB));
        vm.stopPrank();

        assertGe(vault.sponsorshipDeposit(), 2 * COST);

        // A burns its attempt.
        PackedUserOperation memory bad = _op(swapA, expiry);
        bad.accountGasLimits = _pack(VGL_CAP, 25_000);
        _handleOps(_sign(bad, claimantKey));
        assertEq(token.balanceOf(recipient), 0);

        // B still has a full budget and exits normally.
        address recipientB = address(0xB0B);
        PackedUserOperation memory good = _op(swapB, expiry);
        good.sender = other;
        good.callData = _exitCallData(swapB, AMOUNT, recipientB, expiry);
        vm.deal(other, 0);

        vm.recordLogs();
        _handleOps(_sign(good, otherKey));
        (bool success,,) = _lastUserOp();

        assertTrue(success, "B's honest exit still succeeds");
        assertEq(token.balanceOf(recipientB), AMOUNT, "B was paid");
        assertEq(other.balance, 0, "B never needed ETH");
        assertGe(vault.sponsorshipDeposit(), 0);
    }

    // --- Rider 4: the reserve must not be extractable -------------------------------------------

    /// A self-bundling claimant maximising every gas dimension the caps allow, on an otherwise
    /// honest and successful exit, must not be able to convert the budget into profit.
    function test_selfBundlerCannotExtractTheBudget() public {
        bytes32 swapId = bytes32("a");
        uint48 expiry = _defaultExpiry();
        _lock(swapId, expiry);

        uint256 depositBefore = vault.sponsorshipDeposit();

        PackedUserOperation memory op = _op(swapId, expiry);
        op.preVerificationGas = PVG_CAP;
        op.gasFees = _pack(PRIORITY_CAP, MAX_FEE);
        assertLe(_maxCost(op), COST, "the caps keep the prefund inside one budget");

        // The claimant is also the bundler and the beneficiary: any overpayment is its profit.
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = _sign(op, claimantKey);
        vm.deal(claimant, 0);
        vm.recordLogs();
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, payable(claimant));
        (bool success, uint256 actualGasCost, uint256 actualGasUsed) = _lastUserOp();

        assertTrue(success);
        uint256 spent = depositBefore - vault.sponsorshipDeposit();
        assertEq(spent, actualGasCost);
        assertLe(spent, COST, "bounded by one budget");
        assertLe(actualGasUsed, ENVELOPE, "charged gas stays inside the declared envelope");
    }
}
