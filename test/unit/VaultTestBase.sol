// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";

import { EntryPoint } from "account-abstraction/core/EntryPoint.sol";
import { IEntryPoint } from "account-abstraction/interfaces/IEntryPoint.sol";
import { Simple7702Account } from "account-abstraction/accounts/Simple7702Account.sol";
import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";

import { MockUSDT } from "../../contracts/MockUSDT.sol";
import { MuunRingVault } from "../../contracts/MuunRingVault.sol";

/// The index a test locks a swap at: derived from the id so every helper agrees without a lookup.
function idxOf(bytes32 swapId) pure returns (uint32) {
    return uint32(uint256(keccak256(abi.encode(swapId))));
}

abstract contract VaultTestBase is Test {
    uint256 internal constant PVG_CAP = 100_000;
    uint256 internal constant VGL_CAP = 250_000;
    uint256 internal constant CGL_CAP = 250_000;
    uint256 internal constant PMV_CAP = 100_000;
    uint256 internal constant ENVELOPE = PVG_CAP + VGL_CAP + CGL_CAP + PMV_CAP;
    uint256 internal constant MAX_FEE = 50 gwei;
    uint256 internal constant PRIORITY_CAP = 2 gwei;
    uint256 internal constant COST = ENVELOPE * MAX_FEE;
    uint256 internal constant MIN_STAKE = 1 ether;
    uint32 internal constant MIN_UNSTAKE_DELAY = 1 days;

    uint256 internal constant VAULT_USDT = 1_000_000e6;
    uint256 internal constant AMOUNT = 10e6;

    EntryPoint internal entryPoint;
    Simple7702Account internal accountImpl;
    MockUSDT internal token;
    MuunRingVault internal vault;

    address internal owner;
    uint256 internal ownerKey;
    address internal claimant;
    uint256 internal claimantKey;
    address internal recipient = address(0xDE57);
    address internal bundler = address(0xB0417);

    function setUp() public virtual {
        (owner, ownerKey) = makeAddrAndKey("muun");
        (claimant, claimantKey) = makeAddrAndKey("claimantP");

        entryPoint = new EntryPoint();
        accountImpl = new Simple7702Account(IEntryPoint(address(entryPoint)));
        token = new MockUSDT();

        vault = _deployVault();

        vm.deal(owner, 100 ether);
        vm.deal(bundler, 100 ether);
        vm.warp(1_800_000_000);

        _fundDeposit(10 * COST);
        vm.prank(owner);
        vault.addStake{ value: MIN_STAKE }(MIN_UNSTAKE_DELAY);
    }

    // --- helpers ---------------------------------------------------------------------------

    function _config() internal view returns (MuunRingVault.Config memory c) {
        c.token = address(token);
        c.owner = owner;
        c.entryPoint = IEntryPoint(address(entryPoint));
        c.accountImplementation = address(accountImpl);
        c.maxSponsoredFeePerGas = MAX_FEE;
        c.preVerificationGasCap = PVG_CAP;
        c.verificationGasLimitCap = VGL_CAP;
        c.callGasLimitCap = CGL_CAP;
        c.paymasterVerificationGasLimitCap = PMV_CAP;
        c.maxPriorityFeePerGasCap = PRIORITY_CAP;
        c.minStake = MIN_STAKE;
        c.minUnstakeDelaySec = MIN_UNSTAKE_DELAY;
    }

    /// A vault on the shared token with liquidity, no deposit and no stake yet.
    function _deployVault() internal returns (MuunRingVault v) {
        v = new MuunRingVault(_config());
        token.mint(address(v), VAULT_USDT);
    }

    /// Credit the vault's EntryPoint deposit. Permissionless, so no prank is needed.
    function _fundDeposit(uint256 amount) internal {
        vm.deal(owner, owner.balance + amount);
        vm.prank(owner);
        entryPoint.depositTo{ value: amount }(address(vault));
    }

    /// Set the EntryPoint deposit to an exact value. Only shrinks while nothing is in flight.
    function _setDeposit(uint256 target) internal {
        uint256 dep = vault.sponsorshipDeposit();
        if (dep > target) {
            vm.prank(owner);
            vault.withdrawETH(payable(owner), dep - target, true);
        } else if (dep < target) {
            _fundDeposit(target - dep);
        }
    }

    function _lock(bytes32 swapId) internal {
        vm.prank(owner);
        vault.lock(swapId, claimant, AMOUNT, idxOf(swapId));
    }

    function _exitCallData(bytes32 swapId, uint256 amount, address to)
        internal
        view
        returns (bytes memory)
    {
        bytes memory inner =
            abi.encodeCall(MuunRingVault.claimSelf, (swapId, amount, to, idxOf(swapId)));
        return abi.encodeWithSignature(
            "execute(address,uint256,bytes)", address(vault), uint256(0), inner
        );
    }

    function _pack(uint256 high, uint256 low) internal pure returns (bytes32) {
        return bytes32((high << 128) | low);
    }

    function _paymasterAndData(uint256 pmVerificationGas, uint256 postOpGas)
        internal
        view
        returns (bytes memory)
    {
        return abi.encodePacked(address(vault), uint128(pmVerificationGas), uint128(postOpGas));
    }

    function _op(bytes32 swapId) internal view returns (PackedUserOperation memory op) {
        op.sender = claimant;
        op.nonce = 0;
        op.initCode = hex"7702";
        op.callData = _exitCallData(swapId, AMOUNT, recipient);
        op.accountGasLimits = _pack(VGL_CAP, CGL_CAP);
        op.preVerificationGas = PVG_CAP;
        op.gasFees = _pack(1 gwei, 10 gwei);
        op.paymasterAndData = _paymasterAndData(PMV_CAP, 0);
        op.signature = hex"";
    }

    function _sign(PackedUserOperation memory op, uint256 key)
        internal
        view
        returns (PackedUserOperation memory)
    {
        bytes32 h = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, h);
        op.signature = abi.encodePacked(r, s, v);
        return op;
    }

    function _handleOps(PackedUserOperation memory op) internal {
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        // EntryPoint.handleOps is guarded by `tx.origin == msg.sender`, so both must be set.
        vm.prank(bundler, bundler);
        entryPoint.handleOps(ops, payable(bundler));
    }

    /// The prefund the EntryPoint takes for `op`, i.e. what the deposit must hold.
    function _maxCost(PackedUserOperation memory op) internal pure returns (uint256) {
        uint256 agl = uint256(op.accountGasLimits);
        uint256 gas = (agl >> 128) + uint128(agl) + op.preVerificationGas;
        bytes memory pmd = op.paymasterAndData;
        uint256 pmv;
        uint256 post;
        assembly {
            // paymasterAndData data starts at pmd+0x20: [20:36] pmVerificationGas, [36:52] postOpGas
            pmv := shr(128, mload(add(pmd, 0x34)))
            post := shr(128, mload(add(pmd, 0x44)))
        }
        gas += pmv + post;
        return gas * uint128(uint256(op.gasFees));
    }
}
