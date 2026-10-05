// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { VaultTestBase, idxOf } from "./VaultTestBase.sol";
import { MuunRingVault } from "../../contracts/MuunRingVault.sol";
import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";
import { IPaymaster } from "account-abstraction/interfaces/IPaymaster.sol";

contract WrongAccount { }

contract PaymasterValidationTest is VaultTestBase {
    uint256 internal constant SIG_FAILED = 1;

    bytes32 internal swapId = bytes32("a");

    function setUp() public override {
        super.setUp();
        _lock(swapId);
        vm.signAndAttachDelegation(address(accountImpl), claimantKey);
    }

    function _validate(PackedUserOperation memory op, uint256 maxCost)
        internal
        returns (uint256 validationData)
    {
        vm.prank(address(entryPoint));
        (, validationData) = vault.validatePaymasterUserOp(op, bytes32(0), maxCost);
    }

    function _expectReject(PackedUserOperation memory op, uint8 code) internal {
        assertEq(vault.sponsorshipRejection(op, COST), code, "reason code");
        assertEq(_validate(op, COST), SIG_FAILED, "must decline, not accept");
        assertEq(uint256(vm.load(address(vault), bytes32(0))), _accountingWord(), "no state write");
    }

    uint256 private _word;

    function _accountingWord() private returns (uint256) {
        if (_word == 0) _word = uint256(vm.load(address(vault), bytes32(0)));
        return _word;
    }

    // --- acceptance -------------------------------------------------------------------------

    function test_acceptsAWellFormedExit() public {
        PackedUserOperation memory op = _op(swapId);
        assertEq(vault.sponsorshipRejection(op, COST), vault.REJECT_NONE());

        uint256 validationData = _validate(op, COST);
        assertEq(validationData, 0, "success, no validUntil: reservations do not expire (R2)");
    }

    function test_onlyEntryPointMayValidate() public {
        PackedUserOperation memory op = _op(swapId);
        vm.expectRevert(
            abi.encodeWithSelector(MuunRingVault.NotFromEntryPoint.selector, address(this))
        );
        vault.validatePaymasterUserOp(op, bytes32(0), COST);
    }

    function test_postOpAlwaysReverts() public {
        vm.prank(address(entryPoint));
        vm.expectRevert(MuunRingVault.UnsupportedCall.selector);
        vault.postOp(IPaymaster.PostOpMode.opSucceeded, "", 0, 0);
    }

    // --- budget and nonce -------------------------------------------------------------------

    function test_maxCostAtTheCapIsAccepted() public {
        PackedUserOperation memory op = _op(swapId);
        assertEq(uint160(_validate(op, COST)), 0, "accepted at exactly the cap");
    }

    function test_maxCostAboveTheCapIsDeclined() public {
        PackedUserOperation memory op = _op(swapId);
        assertEq(vault.sponsorshipRejection(op, COST + 1), vault.REJECT_MAX_COST());
        assertEq(_validate(op, COST + 1), SIG_FAILED);
    }

    /// One sponsored operation per claimant, and P is fresh per swap.
    function test_nonZeroNonceIsDeclined() public {
        PackedUserOperation memory op = _op(swapId);
        op.nonce = 1;
        _expectReject(op, vault.REJECT_NONCE());
    }

    function test_nonZeroNonceKeyIsDeclined() public {
        PackedUserOperation memory op = _op(swapId);
        op.nonce = uint256(1) << 64;
        _expectReject(op, vault.REJECT_NONCE());
    }

    // --- per-dimension gas caps -------------------------------------------------------------

    function test_verificationGasLimitCap() public {
        PackedUserOperation memory op = _op(swapId);
        op.accountGasLimits = _pack(VGL_CAP + 1, CGL_CAP);
        _expectReject(op, vault.REJECT_GAS_CAP());
    }

    function test_callGasLimitCap() public {
        PackedUserOperation memory op = _op(swapId);
        op.accountGasLimits = _pack(VGL_CAP, CGL_CAP + 1);
        _expectReject(op, vault.REJECT_GAS_CAP());
    }

    /// preVerificationGas is added to the charge verbatim by the EntryPoint, so it must be capped
    /// on its own rather than only through the maxCost product.
    function test_preVerificationGasCap() public {
        PackedUserOperation memory op = _op(swapId);
        op.preVerificationGas = PVG_CAP + 1;
        _expectReject(op, vault.REJECT_GAS_CAP());
    }

    function test_paymasterVerificationGasLimitCap() public {
        PackedUserOperation memory op = _op(swapId);
        op.paymasterAndData = _paymasterAndData(PMV_CAP + 1, 0);
        _expectReject(op, vault.REJECT_GAS_CAP());
    }

    function test_postOpGasLimitMustBeZero() public {
        PackedUserOperation memory op = _op(swapId);
        op.paymasterAndData = _paymasterAndData(PMV_CAP, 1);
        _expectReject(op, vault.REJECT_GAS_CAP());
    }

    /// An uncapped priority fee pins the charged gas price at maxFeePerGas regardless of basefee.
    function test_maxPriorityFeePerGasCap() public {
        PackedUserOperation memory op = _op(swapId);
        op.gasFees = _pack(PRIORITY_CAP + 1, 10 gwei);
        _expectReject(op, vault.REJECT_GAS_CAP());
    }

    function test_shortPaymasterAndDataIsDeclined() public {
        PackedUserOperation memory op = _op(swapId);
        op.paymasterAndData = abi.encodePacked(address(vault));
        _expectReject(op, vault.REJECT_GAS_CAP());
    }

    // --- the 7702 delegate pin ----------------------------------------------------------------

    function test_senderWithNoCodeIsDeclined() public {
        (address bare, uint256 bareKey) = makeAddrAndKey("bare");
        bareKey;
        PackedUserOperation memory op = _op(swapId);
        op.sender = bare;
        _expectReject(op, vault.REJECT_DELEGATE());
    }

    function test_senderDelegatedToAnotherImplementationIsDeclined() public {
        (, uint256 otherKey) = makeAddrAndKey("other");
        WrongAccount wrong = new WrongAccount();
        vm.signAndAttachDelegation(address(wrong), otherKey);

        PackedUserOperation memory op = _op(swapId);
        op.sender = vm.addr(otherKey);
        _expectReject(op, vault.REJECT_DELEGATE());
    }

    function test_senderThatIsAPlainContractIsDeclined() public {
        PackedUserOperation memory op = _op(swapId);
        op.sender = address(new WrongAccount());
        _expectReject(op, vault.REJECT_DELEGATE());
    }

    // --- calldata shape -----------------------------------------------------------------------

    function test_wrongLengthIsDeclined() public {
        PackedUserOperation memory op = _op(swapId);
        bytes memory good = op.callData;

        op.callData = abi.encodePacked(good, hex"00");
        _expectReject(op, vault.REJECT_CALLDATA());

        bytes memory short = new bytes(good.length - 1);
        for (uint256 i = 0; i < short.length; i++) {
            short[i] = good[i];
        }
        op.callData = short;
        _expectReject(op, vault.REJECT_CALLDATA());
    }

    function test_wrongOuterSelectorIsDeclined() public {
        PackedUserOperation memory op = _op(swapId);
        bytes memory cd = op.callData;
        cd[0] = 0xff;
        op.callData = cd;
        _expectReject(op, vault.REJECT_CALLDATA());
    }

    function test_wrongTargetIsDeclined() public {
        PackedUserOperation memory op = _op(swapId);
        bytes memory inner =
            abi.encodeCall(MuunRingVault.claimSelf, (swapId, AMOUNT, recipient, idxOf(swapId)));
        op.callData = abi.encodeWithSignature(
            "execute(address,uint256,bytes)", address(token), uint256(0), inner
        );
        _expectReject(op, vault.REJECT_CALLDATA());
    }

    function test_nonZeroValueIsDeclined() public {
        PackedUserOperation memory op = _op(swapId);
        bytes memory inner =
            abi.encodeCall(MuunRingVault.claimSelf, (swapId, AMOUNT, recipient, idxOf(swapId)));
        op.callData = abi.encodeWithSignature(
            "execute(address,uint256,bytes)", address(vault), uint256(1), inner
        );
        _expectReject(op, vault.REJECT_CALLDATA());
    }

    function test_wrongInnerSelectorIsDeclined() public {
        PackedUserOperation memory op = _op(swapId);
        bytes memory inner = abi.encodeCall(
            MuunRingVault.claimBySig, (swapId, AMOUNT, recipient, "", idxOf(swapId))
        );
        // Force the encoding back to the exact exit length so only the selector differs.
        bytes memory fixedInner = new bytes(132);
        for (uint256 i = 0; i < 132; i++) {
            fixedInner[i] = inner[i];
        }
        op.callData = abi.encodeWithSignature(
            "execute(address,uint256,bytes)", address(vault), uint256(0), fixedInner
        );
        _expectReject(op, vault.REJECT_CALLDATA());
    }

    function test_zeroRecipientIsDeclined() public {
        PackedUserOperation memory op = _op(swapId);
        bytes memory inner =
            abi.encodeCall(MuunRingVault.claimSelf, (swapId, AMOUNT, address(0), idxOf(swapId)));
        op.callData = abi.encodeWithSignature(
            "execute(address,uint256,bytes)", address(vault), uint256(0), inner
        );
        _expectReject(op, vault.REJECT_CALLDATA());
    }

    /// A dirty upper byte in the packed recipient word is declined, never decoded.
    function test_dirtyPaddingIsDeclined() public {
        PackedUserOperation memory op = _op(swapId);
        bytes memory cd = op.callData;
        cd[200] = 0x01; // high byte of the recipient word
        op.callData = cd;
        _expectReject(op, vault.REJECT_CALLDATA());
    }

    // --- reservation binding ------------------------------------------------------------------

    function test_unknownSwapIsDeclined() public {
        PackedUserOperation memory op = _op(bytes32("nope"));
        _expectReject(op, vault.REJECT_RESERVATION());
    }

    function test_wrongSenderIsDeclined() public {
        (, uint256 otherKey) = makeAddrAndKey("intruder");
        vm.signAndAttachDelegation(address(accountImpl), otherKey);

        PackedUserOperation memory op = _op(swapId);
        op.sender = vm.addr(otherKey);
        _expectReject(op, vault.REJECT_RESERVATION());
    }

    function test_wrongAmountIsDeclined() public {
        PackedUserOperation memory op = _op(swapId);
        bytes memory inner =
            abi.encodeCall(MuunRingVault.claimSelf, (swapId, AMOUNT + 1, recipient, idxOf(swapId)));
        op.callData = abi.encodeWithSignature(
            "execute(address,uint256,bytes)", address(vault), uint256(0), inner
        );
        _expectReject(op, vault.REJECT_RESERVATION());
    }

    function test_consumedReservationIsDeclined() public {
        vm.prank(claimant);
        vault.claimSelf(swapId, AMOUNT, recipient, idxOf(swapId));

        PackedUserOperation memory op = _op(swapId);
        assertEq(vault.sponsorshipRejection(op, COST), vault.REJECT_RESERVATION());
    }
}
