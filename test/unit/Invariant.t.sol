// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { StdInvariant } from "forge-std/Test.sol";
import { Test } from "forge-std/Test.sol";

import { EntryPoint } from "account-abstraction/core/EntryPoint.sol";
import { Simple7702Account } from "account-abstraction/accounts/Simple7702Account.sol";
import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";

import { MockUSDT } from "../../contracts/MockUSDT.sol";
import { MuunRingVault } from "../../contracts/MuunRingVault.sol";
import { VaultTestBase, idxOf } from "./VaultTestBase.sol";

contract VaultHandler is Test {
    struct Swap {
        bytes32 id;
        address claimant;
        uint256 key;
        uint256 amount;
        bool live;
        bool sponsored; // its single sponsored attempt has been spent
    }

    MuunRingVault public vault;
    MockUSDT public token;
    EntryPoint public entryPoint;
    Simple7702Account public accountImpl;
    address public owner;
    address public bundler = address(0xB0417);

    Swap[] public swaps;
    uint256 public ghostReserved;
    uint256 public ghostInFlight;
    uint256 private _salt;

    constructor(MuunRingVault v, MockUSDT t, EntryPoint e, Simple7702Account a, address o) {
        vault = v;
        token = t;
        entryPoint = e;
        accountImpl = a;
        owner = o;
        vm.deal(bundler, 1000 ether);
    }

    function swapCount() external view returns (uint256) {
        return swaps.length;
    }

    /// Reservations that still hold an unspent sponsorship budget.
    function ghostUnsponsored() external view returns (uint256 n) {
        for (uint256 i = 0; i < swaps.length; i++) {
            if (swaps[i].live && !swaps[i].sponsored) n++;
        }
    }

    // --- actions ----------------------------------------------------------------------------

    function lock(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 1000e6);
        bytes32 id = keccak256(abi.encode("swap", _salt));
        (address p, uint256 key) = makeAddrAndKey(string.concat("P", vm.toString(_salt)));
        _salt++;

        vm.prank(owner);
        try vault.lock(id, p, amount, idxOf(id)) {
            vm.signAndAttachDelegation(address(accountImpl), key);
            swaps.push(Swap(id, p, key, amount, true, false));
            ghostReserved += amount;
            ghostInFlight += 1;
        } catch { }
    }

    /// The only transition that can decrement the deposit.
    function sponsoredExit(uint256 idxSeed, bool starve) external {
        uint256 i = _pick(idxSeed);
        if (i == type(uint256).max) return;
        Swap storage sw = swaps[i];

        PackedUserOperation memory op;
        op.sender = sw.claimant;
        op.nonce = 0;
        op.initCode = hex"7702";
        op.callData = abi.encodeWithSignature(
            "execute(address,uint256,bytes)",
            address(vault),
            uint256(0),
            abi.encodeCall(
                MuunRingVault.claimSelf, (sw.id, sw.amount, address(0xD00D), idxOf(sw.id))
            )
        );
        op.accountGasLimits = bytes32((uint256(250_000) << 128) | (starve ? 25_000 : 250_000));
        op.preVerificationGas = 100_000;
        op.gasFees = bytes32((uint256(1 gwei) << 128) | uint256(10 gwei));
        op.paymasterAndData = abi.encodePacked(address(vault), uint128(100_000), uint128(0));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sw.key, entryPoint.getUserOpHash(op));
        op.signature = abi.encodePacked(r, s, v);

        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        vm.prank(bundler, bundler);
        try entryPoint.handleOps(ops, payable(bundler)) {
            // The nonce is spent in the validation phase, so the budget is consumed either way.
            sw.sponsored = true;
            if (vault.ring(idxOf(sw.id)) == vault.CONSUMED()) {
                sw.live = false;
                ghostReserved -= sw.amount;
                ghostInFlight -= 1;
            }
        } catch { }
    }

    function claim(uint256 idxSeed) external {
        uint256 i = _pick(idxSeed);
        if (i == type(uint256).max) return;
        Swap storage sw = swaps[i];

        vm.prank(sw.claimant);
        try vault.claimSelf(sw.id, sw.amount, address(0xD00D), idxOf(sw.id)) {
            _release(i);
        } catch { }
    }

    /// Anyone may credit the deposit; this is how the vault is funded now.
    function donateDeposit(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 0, 5 ether);
        address donor = address(0xD0);
        vm.deal(donor, amount);
        vm.prank(donor);
        entryPoint.depositTo{ value: amount }(address(vault));
    }

    function withdrawEth(uint256 amountSeed, bool fromDeposit) external {
        uint256 amount = bound(amountSeed, 1, 5 ether);
        vm.prank(owner);
        try vault.withdrawETH(payable(owner), amount, fromDeposit) { } catch { }
    }

    /// R2: time passing is a no-op for the ring and the counters. Kept so the fuzzer interleaves
    /// long waits with everything else.
    function warp(uint256 dtSeed) external {
        vm.warp(block.timestamp + bound(dtSeed, 1, 10 days));
    }

    function _pick(uint256 seed) private view returns (uint256) {
        if (swaps.length == 0) return type(uint256).max;
        for (uint256 k = 0; k < swaps.length; k++) {
            uint256 i = (seed + k) % swaps.length;
            if (swaps[i].live) return i;
        }
        return type(uint256).max;
    }

    function _release(uint256 i) private {
        swaps[i].live = false;
        ghostReserved -= swaps[i].amount;
        ghostInFlight -= 1;
    }
}

contract VaultInvariantTest is StdInvariant, VaultTestBase {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new VaultHandler(vault, token, entryPoint, accountImpl, owner);
        targetContract(address(handler));
    }

    /// Guards against the invariant becoming a restatement of `deposit >= inFlight * COST`.
    /// A starved sponsored exit spends the budget without consuming the reservation, so the two
    /// counts must be able to diverge, and the deposit must fall while `inFlight` holds.
    function test_handlerActuallyDrivesTheSponsoredPath() public {
        handler.lock(1);
        assertEq(handler.ghostInFlight(), 1, "handler locked");
        assertEq(handler.ghostUnsponsored(), 1);

        uint256 depositBefore = vault.sponsorshipDeposit();
        handler.sponsoredExit(0, true); // starve the call gas

        assertEq(handler.ghostInFlight(), 1, "reservation survived the burn");
        assertEq(handler.ghostUnsponsored(), 0, "its budget is spent");
        assertLt(vault.sponsorshipDeposit(), depositBefore, "the deposit really was charged");
        assertLe(depositBefore - vault.sponsorshipDeposit(), COST, "bounded by one budget");
    }

    /// And the succeeding variant consumes the reservation outright.
    function test_handlerSponsoredExitCanSucceed() public {
        handler.lock(2);
        uint256 before = vault.sponsorshipDeposit();
        handler.sponsoredExit(0, false);

        assertEq(handler.ghostInFlight(), 0, "reservation consumed");
        assertEq(handler.ghostUnsponsored(), 0);
        assertLt(vault.sponsorshipDeposit(), before);
    }

    /// The property the whole design exists to buy: every reservation that has not yet spent its
    /// single sponsored attempt is still fully backed by the account the EntryPoint debits.
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_everyUnsponsoredReservationIsBacked() public view {
        assertGe(vault.sponsorshipDeposit(), handler.ghostUnsponsored() * COST);
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_accountingSlotNeverZero() public view {
        assertTrue(vm.load(address(vault), bytes32(0)) != bytes32(0));
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_countersMatchGhostState() public view {
        assertEq(vault.reserved(), handler.ghostReserved());
        assertEq(vault.inFlight(), handler.ghostInFlight());
    }

    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_usdtCoversReservations() public view {
        assertGe(token.balanceOf(address(vault)), vault.reserved());
    }

    /// R2 as an invariant: every reservation the handler still counts as live is in the ring
    /// exactly as locked, however much time the handler has warped.
    /// forge-config: default.invariant.runs = 32
    /// forge-config: default.invariant.depth = 40
    function invariant_liveReservationsNeverExpire() public view {
        uint256 n = handler.swapCount();
        for (uint256 i = 0; i < n; i++) {
            (bytes32 id, address p,, uint256 amount, bool live,) = handler.swaps(i);
            if (live) assertTrue(vault.isReservation(id, p, amount, idxOf(id)), "still there");
        }
    }
}
