// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { MockTetherUSDT } from "../contracts/legacy/MockTetherUSDT.sol";
import { MuunRingVault } from "../contracts/MuunRingVault.sol";
import { RingSponsoredClaimGateway, IMuunRingVaultClaim } from "../contracts/RingSponsoredClaimGateway.sol";

/// The ring rules of the TRON port, named after the contract's R1-R5.
contract MuunRingVaultTest is Test {
    MockTetherUSDT token;
    MuunRingVault vault;
    RingSponsoredClaimGateway gateway;

    address muun = makeAddr("muun");
    address recipient = makeAddr("recipient");
    uint256 claimantKey = 0xC1A1;
    address claimant;
    uint256 constant AMOUNT = 10e6;

    function setUp() public {
        claimant = vm.addr(claimantKey);
        token = new MockTetherUSDT();
        vault = new MuunRingVault(address(token), muun);
        gateway = new RingSponsoredClaimGateway(IMuunRingVaultClaim(address(vault)));
        token.mint(1_000e6);
        token.transfer(address(vault), 1_000e6);
    }

    function _sig(bytes32 swapId) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(claimantKey, vault.claimDigest(swapId, AMOUNT, recipient));
        return abi.encodePacked(r, s, v);
    }

    function _lock(bytes32 swapId, uint32 idx) internal {
        vm.prank(muun);
        vault.lock(swapId, claimant, AMOUNT, idx);
    }

    function test_lockClaimReuse() public {
        _lock("a", 7);
        assertTrue(vault.isReservation("a", claimant, AMOUNT, 7));
        assertEq(vault.reserved(), AMOUNT);

        vault.claimBySig("a", AMOUNT, recipient, _sig("a"), 7);
        assertEq(token.balanceOf(recipient), AMOUNT);
        assertEq(vault.ring(7), vault.CONSUMED()); // R3
        assertEq(vault.reserved(), 0);

        _lock("b", 7); // reuse of a consumed index
        gateway.claim("b", AMOUNT, recipient, _sig("b"), 7);
        assertEq(token.balanceOf(recipient), 2 * AMOUNT);
    }

    function test_R1_liveSlotRefused() public {
        _lock("a", 7);
        vm.prank(muun);
        vm.expectRevert(abi.encodeWithSelector(MuunRingVault.SlotLive.selector, uint32(7)));
        vault.lock("b", claimant, AMOUNT, 7);
    }

    function test_R4_noDoubleClaim() public {
        _lock("a", 7);
        bytes memory sig = _sig("a");
        vault.claimBySig("a", AMOUNT, recipient, sig, 7);
        vm.expectRevert(MuunRingVault.InvalidReservation.selector);
        vault.claimBySig("a", AMOUNT, recipient, sig, 7);
    }

    function test_R5_boundToIndex() public {
        _lock("a", 7);
        _lock("b", 8);
        bytes memory sig = _sig("a");
        vm.expectRevert(MuunRingVault.InvalidReservation.selector);
        vault.claimBySig("a", AMOUNT, recipient, sig, 8);
    }

    function test_claimSelf() public {
        _lock("a", 7);
        vm.prank(claimant);
        vault.claimSelf("a", AMOUNT, recipient, 7);
        assertEq(token.balanceOf(recipient), AMOUNT);
    }

    function test_onlyOwnerLocks() public {
        vm.expectRevert(MuunRingVault.NotOwner.selector);
        vault.lock("a", claimant, AMOUNT, 7);
    }

    function test_lockNeedsFreeLiquidity() public {
        vm.prank(muun);
        vm.expectRevert(MuunRingVault.InsufficientFreeLiquidity.selector);
        vault.lock("a", claimant, 1_001e6, 7);
    }
}
