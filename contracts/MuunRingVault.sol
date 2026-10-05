// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import { IPaymaster } from "account-abstraction/interfaces/IPaymaster.sol";
import { IEntryPoint } from "account-abstraction/interfaces/IEntryPoint.sol";
import { IStakeManager } from "account-abstraction/interfaces/IStakeManager.sol";
import { PackedUserOperation } from "account-abstraction/interfaces/PackedUserOperation.sol";
import {
    SIG_VALIDATION_FAILED,
    SIG_VALIDATION_SUCCESS
} from "account-abstraction/core/Helpers.sol";

/// @title MuunRingVault
/// @notice `MuunUSDTVault` (bridge-vault) with its reservations kept in a ring of reusable storage
///         slots instead of a per-swap mapping entry. Same prefunded USDT vault, same ERC-4337
///         paymaster that sponsors its own emergency exits, same funding guarantee.
///
/// @dev Ring rules. The tests in `test/unit/Ring.t.sol` are named after them.
///
///  R1  `ring[idx]` holds one reservation: the full 256-bit `keccak(swapId, claimant, amount)`.
///      Which index a reservation takes is Muun's choice; the claimant learns it from `Locked`.
///      `lock` writes an index only when it holds `0` (never used) or `CONSUMED`; a live
///      reservation is never rewritten (`SlotLive`).
///  R2  A reservation never expires and there is no `refund`. Once locked it is the claimant's
///      for ever, as if the tokens had been sent to it: only `claimSelf` or `claimBySig` ends it.
///      A claimant that never comes back leaves its index occupied, and that is accepted; the
///      pinned liquidity and exit budget are Muun's cost (decision 2026-10-01).
///  R3  No path writes zero into the ring. `claim` overwrites the entry with `CONSUMED`, a
///      non-zero marker no reservation can equal, so under Glamsterdam's state creation pricing
///      an index pays the fresh-slot premium once and never again.
///  R4  A consumed entry no longer matches any reservation: claiming it again is
///      `InvalidReservation`.
///  R5  A reservation is bound to its index: the same swap presented at another `idx` is
///      `InvalidReservation`, never a payout.
///  R6  The paymaster screens the sponsored `claimSelf` by its fourth argument too: `idx` must fit
///      32 bits and `ring[idx]` must hold the sender's reservation.
///  R7  `lock` requires the EntryPoint stake to satisfy the bundlers, not only `staked`:
///      `stake >= MIN_STAKE` and `unstakeDelaySec >= MIN_UNSTAKE_DELAY` (ERC-7562 reputation
///      rules). Both are immutables set at deploy.
///
///      Everything else (deposit, withdraw, ETH, stake except R7, gas caps, the funding
///      guarantee) is the bridge-vault contract unchanged; `_reserves` was already kept non-zero.
///      A `Claim` signature binds `(swapId, amount, recipient)` and never expires, not an index:
///      the same `(swapId, claimant, amount)` must never be locked twice, which
///      `swapId = keccak(T, U)` with a fresh `P` per swap guarantees; a second lock of one triple
///      would let one signature claim both, at Muun's cost only.
contract MuunRingVault is IPaymaster {
    using SafeERC20 for IERC20;

    // --- errors -----------------------------------------------------------------------------

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error SlotLive(uint32 idx); // R1
    error InvalidReservation();
    error InsufficientFreeLiquidity();

    error InvalidEntryPointInterface(address entryPoint, bytes4 interfaceId);
    error InvalidConfig();
    error NotFromEntryPoint(address caller);
    error ValueOverflow();
    error NotStaked();
    error StakeTooLow(uint256 stake, uint256 minimum); // R7
    error UnstakeDelayTooShort(uint32 unstakeDelaySec, uint32 minimum); // R7
    error SponsorshipUnderfunded(uint256 required, uint256 available);
    error SponsorshipInUse(uint256 inFlight);
    error InsufficientEth();
    error EthTransferFailed();
    error UnsupportedCall();

    // --- events -----------------------------------------------------------------------------

    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event Locked(bytes32 indexed swapId, address indexed claimant, uint256 amount, uint32 idx);
    event Redeemed(
        bytes32 indexed swapId,
        address indexed claimant,
        address indexed recipient,
        uint256 amount,
        bool relayed,
        uint32 idx
    );

    event EthWithdrawn(address indexed to, uint256 amount, bool fromDeposit);
    event SponsorshipUsed(bytes32 indexed swapId, address indexed claimant);

    // --- EIP-712 ----------------------------------------------------------------------------

    bytes32 public constant CLAIM_TYPEHASH =
        keccak256("Claim(bytes32 swapId,uint256 amount,address recipient)");
    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant NAME_HASH = keccak256("Muun USDT Vault");
    bytes32 private constant VERSION_HASH = keccak256("3");

    // --- packed accounting layout -----------------------------------------------------------

    /// bits [127:0]   reserved USDT + 1  (kept non-zero so the slot is never re-created)
    /// bits [191:128] live reservation count
    /// bits [255:192] reserved; do not repurpose
    uint256 private constant RESERVED_MASK = type(uint128).max;
    uint256 private constant INFLIGHT_MASK = type(uint64).max;
    uint256 private constant INFLIGHT_SHIFT = 128;

    // --- ring entry -------------------------------------------------------------------------

    /// R1: `ring[idx] = keccak256(abi.encode(swapId, claimant, amount))`, all 256 bits.
    /// R3: what a consumed slot holds. Non-zero; no reservation hashes to it.
    bytes32 public constant CONSUMED = bytes32(uint256(1));

    // --- exit call shape --------------------------------------------------------------------

    bytes4 private constant EXECUTE_SELECTOR = bytes4(keccak256("execute(address,uint256,bytes)"));
    uint256 private constant EXIT_CALLDATA_LEN = 292;
    uint256 private constant EXIT_INNER_OFFSET = 0x60;
    uint256 private constant EXIT_INNER_LEN = 132;
    uint256 private constant DELEGATION_LEN = 23;

    /// Rejection reason codes returned by `sponsorshipRejection`.
    uint8 public constant REJECT_NONE = 0;
    uint8 public constant REJECT_MAX_COST = 1;
    uint8 public constant REJECT_NONCE = 2;
    uint8 public constant REJECT_CALLDATA = 3;
    uint8 public constant REJECT_RESERVATION = 4;
    uint8 public constant REJECT_GAS_CAP = 5;
    uint8 public constant REJECT_DELEGATE = 6;

    // --- configuration ----------------------------------------------------------------------

    struct Config {
        address token;
        address owner;
        IEntryPoint entryPoint;
        address accountImplementation;
        uint256 maxSponsoredFeePerGas;
        uint256 preVerificationGasCap;
        uint256 verificationGasLimitCap;
        uint256 callGasLimitCap;
        uint256 paymasterVerificationGasLimitCap;
        uint256 maxPriorityFeePerGasCap;
        uint256 minStake; // R7
        uint32 minUnstakeDelaySec; // R7
    }

    IERC20 public immutable token;
    address public immutable owner;
    IEntryPoint public immutable entryPoint;

    /// The only EIP-7702 delegate whose code may interpret a sponsored exit call.
    address public immutable accountImplementation;

    /// Sum of the four gas caps below. `EMERGENCY_EXIT_COST = EXIT_GAS_ENVELOPE * MAX_SPONSORED_FEE_PER_GAS`.
    uint256 public immutable EXIT_GAS_ENVELOPE;
    uint256 public immutable MAX_SPONSORED_FEE_PER_GAS;
    uint256 public immutable EMERGENCY_EXIT_COST;

    uint256 public immutable PRE_VERIFICATION_GAS_CAP;
    uint256 public immutable VERIFICATION_GAS_LIMIT_CAP;
    uint256 public immutable CALL_GAS_LIMIT_CAP;
    uint256 public immutable PAYMASTER_VERIFICATION_GAS_LIMIT_CAP;
    uint256 public immutable MAX_PRIORITY_FEE_PER_GAS_CAP;

    /// R7: what the EntryPoint stake must hold for bundlers to count the paymaster as staked.
    uint256 public immutable MIN_STAKE;
    uint32 public immutable MIN_UNSTAKE_DELAY;

    // --- state ------------------------------------------------------------------------------

    uint256 private _reserves = 1;

    /// R1: the ring. `ring[idx]` is one reservation, a `CONSUMED` marker or zero (never used).
    bytes32[2 ** 32] public ring;

    constructor(Config memory c) {
        if (
            c.token == address(0) || c.owner == address(0) || address(c.entryPoint) == address(0)
                || c.accountImplementation == address(0)
        ) revert ZeroAddress();

        bytes4 id = type(IEntryPoint).interfaceId;
        if (!IERC165(address(c.entryPoint)).supportsInterface(id)) {
            revert InvalidEntryPointInterface(address(c.entryPoint), id);
        }

        uint256 envelope = c.preVerificationGasCap + c.verificationGasLimitCap + c.callGasLimitCap
            + c.paymasterVerificationGasLimitCap;
        uint256 cost = envelope * c.maxSponsoredFeePerGas;
        if (envelope == 0 || cost == 0) revert InvalidConfig();
        if (c.minStake == 0 || c.minUnstakeDelaySec == 0) revert InvalidConfig();

        token = IERC20(c.token);
        owner = c.owner;
        entryPoint = c.entryPoint;
        accountImplementation = c.accountImplementation;

        EXIT_GAS_ENVELOPE = envelope;
        MAX_SPONSORED_FEE_PER_GAS = c.maxSponsoredFeePerGas;
        EMERGENCY_EXIT_COST = cost;

        PRE_VERIFICATION_GAS_CAP = c.preVerificationGasCap;
        VERIFICATION_GAS_LIMIT_CAP = c.verificationGasLimitCap;
        CALL_GAS_LIMIT_CAP = c.callGasLimitCap;
        PAYMASTER_VERIFICATION_GAS_LIMIT_CAP = c.paymasterVerificationGasLimitCap;
        MAX_PRIORITY_FEE_PER_GAS_CAP = c.maxPriorityFeePerGasCap;
        MIN_STAKE = c.minStake;
        MIN_UNSTAKE_DELAY = c.minUnstakeDelaySec;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    receive() external payable { }

    // --- accounting views -------------------------------------------------------------------

    function reserved() public view returns (uint256) {
        return (_reserves & RESERVED_MASK) - 1;
    }

    function inFlight() public view returns (uint256) {
        return (_reserves >> INFLIGHT_SHIFT) & INFLIGHT_MASK;
    }

    function freeLiquidity() public view returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        uint256 r = reserved();
        return bal > r ? bal - r : 0;
    }

    /// @notice ETH the EntryPoint holds for this contract, spendable on sponsored exits.
    function sponsorshipDeposit() public view returns (uint256) {
        return entryPoint.balanceOf(address(this));
    }

    /// @notice ETH that must remain backing the live reservations.
    function requiredSponsorship() public view returns (uint256) {
        return inFlight() * EMERGENCY_EXIT_COST;
    }

    // --- USDT -------------------------------------------------------------------------------

    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Deposited(msg.sender, amount);
    }

    function withdraw(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 bal = token.balanceOf(address(this));
        uint256 r = reserved();
        if (bal < amount || bal - amount < r) revert InsufficientFreeLiquidity();

        token.safeTransfer(to, amount);
        emit Withdrawn(to, amount);
    }

    // --- reservations -----------------------------------------------------------------------

    function lock(bytes32 swapId, address claimant, uint256 amount, uint32 idx) external onlyOwner {
        if (claimant == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > RESERVED_MASK) revert ValueOverflow();

        // R1, R2: the slot must be free, which means never used or consumed. A live reservation
        // is never rewritten, however old it is.
        bytes32 cur = ring[idx];
        if (cur != bytes32(0) && cur != CONSUMED) revert SlotLive(idx);

        uint256 packed = _reserves;
        uint256 nextReservedPlusOne = (packed & RESERVED_MASK) + amount;
        uint256 nextInFlight = ((packed >> INFLIGHT_SHIFT) & INFLIGHT_MASK) + 1;
        if (nextReservedPlusOne > RESERVED_MASK || nextInFlight > INFLIGHT_MASK) {
            revert ValueOverflow();
        }
        if (token.balanceOf(address(this)) < nextReservedPlusOne - 1) {
            revert InsufficientFreeLiquidity();
        }

        // One read of the EntryPoint gives both the deposit and the staked flag. Sponsorship must
        // be usable as well as funded, so an unstaked paymaster cannot accept new swaps.
        IStakeManager.DepositInfo memory info = entryPoint.getDepositInfo(address(this));
        if (!info.staked) revert NotStaked();
        // R7: staked in the bundlers' sense too, or the sponsored exit is dead on arrival.
        if (info.stake < MIN_STAKE) revert StakeTooLow(info.stake, MIN_STAKE);
        if (info.unstakeDelaySec < MIN_UNSTAKE_DELAY) {
            revert UnstakeDelayTooShort(info.unstakeDelaySec, MIN_UNSTAKE_DELAY);
        }

        // One budget per live reservation, this one included. The EntryPoint debits the deposit
        // and nothing else, so the deposit is the only quantity worth testing here.
        uint256 required = nextInFlight * EMERGENCY_EXIT_COST;
        if (info.deposit < required) revert SponsorshipUnderfunded(required, info.deposit);

        ring[idx] = entry(swapId, claimant, amount);
        _reserves = nextReservedPlusOne | (nextInFlight << INFLIGHT_SHIFT);

        emit Locked(swapId, claimant, amount, idx);
    }

    function claimBySig(
        bytes32 swapId,
        uint256 amount,
        address recipient,
        bytes calldata signature,
        uint32 idx
    ) external {
        if (recipient == address(0)) revert ZeroAddress();

        address claimant = ECDSA.recover(claimDigest(swapId, amount, recipient), signature);
        _consumeReservation(swapId, claimant, amount, idx);
        token.safeTransfer(recipient, amount);
        emit Redeemed(swapId, claimant, recipient, amount, true, idx);
    }

    function claimSelf(bytes32 swapId, uint256 amount, address recipient, uint32 idx) external {
        if (recipient == address(0)) revert ZeroAddress();

        address claimant = msg.sender;
        _consumeReservation(swapId, claimant, amount, idx);
        token.safeTransfer(recipient, amount);
        emit Redeemed(swapId, claimant, recipient, amount, false, idx);
    }

    function isReservation(bytes32 swapId, address claimant, uint256 amount, uint32 idx)
        external
        view
        returns (bool)
    {
        return ring[idx] == entry(swapId, claimant, amount);
    }

    /// @notice The ring entry `lock` writes for a reservation: the whole hash. R1.
    function entry(bytes32 swapId, address claimant, uint256 amount) public pure returns (bytes32) {
        return keccak256(abi.encode(swapId, claimant, amount));
    }

    function claimDigest(bytes32 swapId, uint256 amount, address recipient)
        public
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(CLAIM_TYPEHASH, swapId, amount, recipient));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)
            )
        );
    }

    function _consumeReservation(bytes32 swapId, address claimant, uint256 amount, uint32 idx)
        internal
    {
        if (ring[idx] != entry(swapId, claimant, amount)) revert InvalidReservation();
        ring[idx] = CONSUMED; // R3, R4

        uint256 packed = _reserves;
        // Checked arithmetic doubles as an assertion that the counters cannot underflow.
        uint256 nextReservedPlusOne = (packed & RESERVED_MASK) - amount;
        uint256 nextInFlight = ((packed >> INFLIGHT_SHIFT) & INFLIGHT_MASK) - 1;
        _reserves = nextReservedPlusOne | (nextInFlight << INFLIGHT_SHIFT);
    }

    // --- ETH ---------------------------------------------------------------------------------

    /// @notice Withdraw ETH. The EntryPoint deposit backs the live reservations and is gated;
    ///         the contract's own balance backs nothing and is not.
    ///
    /// @dev The two pools are checked independently. A combined check would let the deposit be
    ///      drained while the plain balance covered the requirement, which is exactly the state
    ///      the guarantee forbids.
    function withdrawETH(address payable to, uint256 amount, bool fromDeposit) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        if (fromDeposit) {
            uint256 dep = entryPoint.balanceOf(address(this));
            uint256 required = requiredSponsorship();
            if (dep < amount) revert InsufficientEth();
            if (dep - amount < required) revert SponsorshipUnderfunded(required, dep - amount);
            entryPoint.withdrawTo(to, amount);
        } else {
            if (address(this).balance < amount) revert InsufficientEth();
            (bool ok,) = to.call{ value: amount }("");
            if (!ok) revert EthTransferFailed();
        }
        emit EthWithdrawn(to, amount, fromDeposit);
    }

    function addStake(uint32 unstakeDelaySec) external payable onlyOwner {
        entryPoint.addStake{ value: msg.value }(unstakeDelaySec);
    }

    /// @dev `unlockStake` clears the staked flag immediately, which would make bundlers drop
    ///      every pending exit. It is therefore only reachable when nothing is in flight.
    function unlockStake() external onlyOwner {
        uint256 n = inFlight();
        if (n != 0) revert SponsorshipInUse(n);
        entryPoint.unlockStake();
    }

    function withdrawStake(address payable to) external onlyOwner {
        uint256 n = inFlight();
        if (n != 0) revert SponsorshipInUse(n);
        entryPoint.withdrawStake(to);
    }

    // --- paymaster ---------------------------------------------------------------------------

    function validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32, uint256 maxCost)
        external
        returns (bytes memory context, uint256 validationData)
    {
        if (msg.sender != address(entryPoint)) revert NotFromEntryPoint(msg.sender);

        (uint8 code, bytes32 swapId) = _screen(userOp, maxCost);
        if (code != REJECT_NONE) return ("", SIG_VALIDATION_FAILED);

        emit SponsorshipUsed(swapId, userOp.sender);
        return ("", SIG_VALIDATION_SUCCESS); // no time bound: reservations do not expire (R2)
    }

    /// @dev Context is always empty, so the EntryPoint never calls this.
    function postOp(PostOpMode, bytes calldata, uint256, uint256) external view {
        if (msg.sender != address(entryPoint)) revert NotFromEntryPoint(msg.sender);
        revert UnsupportedCall();
    }

    /// @notice Preflight twin of the paymaster check. On chain a rejection only surfaces as
    ///         `AA34`; this returns which rule failed.
    function sponsorshipRejection(PackedUserOperation calldata userOp, uint256 maxCost)
        external
        view
        returns (uint8 code)
    {
        (code,) = _screen(userOp, maxCost);
    }

    function _screen(PackedUserOperation calldata userOp, uint256 maxCost)
        private
        view
        returns (uint8 code, bytes32 swapId)
    {
        if (maxCost > EMERGENCY_EXIT_COST) return (REJECT_MAX_COST, 0);

        // The EntryPoint bumps the nonce during validation, so pinning it to zero allows exactly
        // one sponsored operation per claimant, and `P` is fresh per swap.
        if (userOp.nonce != 0) return (REJECT_NONCE, 0);

        if (!_withinGasCaps(userOp)) return (REJECT_GAS_CAP, 0);
        if (_delegateOf(userOp.sender) != _expectedDelegation()) return (REJECT_DELEGATE, 0);

        bytes calldata cd = userOp.callData;
        if (cd.length != EXIT_CALLDATA_LEN) return (REJECT_CALLDATA, 0);
        if (bytes4(cd[0:4]) != EXECUTE_SELECTOR) return (REJECT_CALLDATA, 0);
        if (uint256(bytes32(cd[4:36])) != uint256(uint160(address(this)))) {
            return (REJECT_CALLDATA, 0);
        }
        if (uint256(bytes32(cd[36:68])) != 0) return (REJECT_CALLDATA, 0);
        if (uint256(bytes32(cd[68:100])) != EXIT_INNER_OFFSET) return (REJECT_CALLDATA, 0);
        if (uint256(bytes32(cd[100:132])) != EXIT_INNER_LEN) return (REJECT_CALLDATA, 0);
        if (bytes4(cd[132:136]) != this.claimSelf.selector) return (REJECT_CALLDATA, 0);

        // Decode the four argument words by hand rather than with abi.decode: a dirty upper byte
        // in the packed `recipient` or `idx` word makes abi.decode *revert*, which surfaces as
        // FailedOpWithRevert and is penalised harder by bundlers than a graceful decline.
        bytes32 id = bytes32(cd[136:168]);
        uint256 amount = uint256(bytes32(cd[168:200]));
        uint256 recipientWord = uint256(bytes32(cd[200:232]));
        uint256 idxWord = uint256(bytes32(cd[232:264]));
        if (recipientWord == 0 || recipientWord > type(uint160).max) return (REJECT_CALLDATA, 0);
        if (idxWord > type(uint32).max) return (REJECT_CALLDATA, 0); // R6
        // The 28 bytes of ABI padding after the inner call must be zero, so one exit has one
        // encoding (and one userOp hash).
        if (uint224(bytes28(cd[264:292])) != 0) return (REJECT_CALLDATA, 0);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 idx = uint32(idxWord); // range checked above
        if (ring[idx] != entry(id, userOp.sender, amount)) return (REJECT_RESERVATION, 0);
        return (REJECT_NONE, id);
    }

    function _withinGasCaps(PackedUserOperation calldata userOp) private view returns (bool) {
        uint256 accountGasLimits = uint256(userOp.accountGasLimits);
        if ((accountGasLimits >> 128) > VERIFICATION_GAS_LIMIT_CAP) return false;
        // the low 128 bits are the field itself
        // forge-lint: disable-next-line(unsafe-typecast)
        if (uint128(accountGasLimits) > CALL_GAS_LIMIT_CAP) return false;
        if (userOp.preVerificationGas > PRE_VERIFICATION_GAS_CAP) return false;
        if ((uint256(userOp.gasFees) >> 128) > MAX_PRIORITY_FEE_PER_GAS_CAP) return false;

        bytes calldata pmd = userOp.paymasterAndData;
        if (pmd.length < 52) return false;
        if (uint128(bytes16(pmd[20:36])) > PAYMASTER_VERIFICATION_GAS_LIMIT_CAP) return false;
        if (uint128(bytes16(pmd[36:52])) != 0) return false;
        return true;
    }

    function _expectedDelegation() private view returns (bytes23) {
        return bytes23(abi.encodePacked(hex"ef0100", accountImplementation));
    }

    /// @dev First 23 code bytes of `a`, which for an EIP-7702 account is `0xef0100 || delegate`.
    function _delegateOf(address a) private view returns (bytes23 d) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0)
            extcodecopy(a, ptr, 0, DELEGATION_LEN)
            d := mload(ptr)
        }
    }
}
