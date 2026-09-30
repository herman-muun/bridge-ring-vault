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
import { _packValidationData, SIG_VALIDATION_FAILED } from "account-abstraction/core/Helpers.sol";

/// @title MuunRingVault
/// @notice `MuunUSDTVault` (bridge-vault) with its reservations kept in a ring of reusable storage
///         slots instead of a per-swap mapping entry. Same prefunded USDT vault, same ERC-4337
///         paymaster that sponsors its own emergency exits, same funding guarantee.
///
/// @dev Ring rules. The tests in `test/unit/Ring.t.sol` are named after them.
///
///  R1  `ring[idx]` holds one reservation: 160 bits of `keccak(swapId, claimant, amount, expiry)`,
///      then `amount` (64 bits) and `expiry` (32 bits, a timestamp). Which index a reservation
///      takes is Muun's choice; the claimant learns it from `Locked`. A slot is live while
///      `expiry >= block.timestamp` and `lock` refuses to rewrite it (`SlotLive`).
///  R2  A slot whose reservation expired unconsumed may be rewritten by `lock`, which releases
///      the old amount and count first. No separate `refund` transaction is needed to reuse it.
///  R3  No path writes zero into the ring. `claim` and `refund` overwrite the entry with
///      `CONSUMED`, a non-zero marker no reservation can equal, so under Glamsterdam's state
///      creation pricing an index pays the fresh-slot premium once and never again.
///  R4  A consumed or rewritten entry no longer matches any reservation: claiming or refunding it
///      again is `InvalidReservation`.
///  R5  A reservation is bound to its index: the same swap presented at another `idx` is
///      `InvalidReservation`, never a payout.
///  R6  The paymaster screens the sponsored `claimSelf` by its fifth argument too: `idx` must fit
///      32 bits and `ring[idx]` must hold the sender's reservation.
///
///      Everything else (deposit, withdraw, ETH, stake, gas caps, the funding guarantee) is the
///      bridge-vault contract unchanged; `_reserves` was already kept non-zero.
contract MuunRingVault is IPaymaster {
    using SafeERC20 for IERC20;

    // --- errors -----------------------------------------------------------------------------

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidExpiry();
    error SlotLive(uint32 idx, uint32 expiry); // R1
    error InvalidReservation();
    error ReservationExpired();
    error ReservationNotExpired();
    error InsufficientFreeLiquidity();

    error InvalidEntryPointInterface(address entryPoint, bytes4 interfaceId);
    error InvalidConfig();
    error NotFromEntryPoint(address caller);
    error ValueOverflow();
    error NotStaked();
    error SponsorshipUnderfunded(uint256 required, uint256 available);
    error SponsorshipInUse(uint256 inFlight);
    error InsufficientEth();
    error EthTransferFailed();
    error UnsupportedCall();

    // --- events -----------------------------------------------------------------------------

    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event Locked(
        bytes32 indexed swapId, address indexed claimant, uint256 amount, uint48 expiry, uint32 idx
    );
    event Redeemed(
        bytes32 indexed swapId,
        address indexed claimant,
        address indexed recipient,
        uint256 amount,
        bool relayed,
        uint32 idx
    );
    event Refunded(bytes32 indexed swapId, address indexed claimant, uint256 amount, uint32 idx);
    /// @notice R2: `lock` rewrote an expired, unconsumed slot and released what it held.
    event Released(uint32 indexed idx, uint256 amount);

    event EthWithdrawn(address indexed to, uint256 amount, bool fromDeposit);
    event SponsorshipUsed(bytes32 indexed swapId, address indexed claimant);

    // --- EIP-712 ----------------------------------------------------------------------------

    bytes32 public constant CLAIM_TYPEHASH =
        keccak256("Claim(bytes32 swapId,uint256 amount,address recipient,uint48 expiry)");
    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant NAME_HASH = keccak256("Muun USDT Vault");
    bytes32 private constant VERSION_HASH = keccak256("2");

    // --- packed accounting layout -----------------------------------------------------------

    /// bits [127:0]   reserved USDT + 1  (kept non-zero so the slot is never re-created)
    /// bits [191:128] live reservation count
    /// bits [255:192] reserved; do not repurpose
    uint256 private constant RESERVED_MASK = type(uint128).max;
    uint256 private constant INFLIGHT_MASK = type(uint64).max;
    uint256 private constant INFLIGHT_SHIFT = 128;

    // --- ring entry layout ------------------------------------------------------------------

    /// bits [255:96]  keccak(swapId, claimant, amount, expiry)[0:20]
    /// bits [95:32]   amount (USDT units)
    /// bits [31:0]    expiry (timestamp)
    uint256 private constant ENTRY_AMOUNT_SHIFT = 32;
    uint256 private constant ENTRY_HASH_SHIFT = 96;
    uint256 private constant ENTRY_AMOUNT_MASK = type(uint64).max;
    uint256 private constant ENTRY_EXPIRY_MASK = type(uint32).max;

    /// R3: what a consumed slot holds. Non-zero, expiry 1, no reservation hashes to it.
    bytes32 public constant CONSUMED = bytes32(uint256(1));

    // --- exit call shape --------------------------------------------------------------------

    bytes4 private constant EXECUTE_SELECTOR = bytes4(keccak256("execute(address,uint256,bytes)"));
    uint256 private constant EXIT_CALLDATA_LEN = 324;
    uint256 private constant EXIT_INNER_OFFSET = 0x60;
    uint256 private constant EXIT_INNER_LEN = 164;
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

        uint256 envelope = c.preVerificationGasCap + c.verificationGasLimitCap
            + c.callGasLimitCap + c.paymasterVerificationGasLimitCap;
        uint256 cost = envelope * c.maxSponsoredFeePerGas;
        if (envelope == 0 || cost == 0) revert InvalidConfig();

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

    function lock(bytes32 swapId, address claimant, uint256 amount, uint48 expiry, uint32 idx)
        external
        onlyOwner
    {
        if (claimant == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > ENTRY_AMOUNT_MASK) revert ZeroAmount();
        if (expiry <= block.timestamp || expiry > ENTRY_EXPIRY_MASK) revert InvalidExpiry();

        uint256 packed = _reserves;

        // R1, R2: the slot must be free. Expired and unconsumed means its reservation is still
        // counted, so release it here; `refund` would have done the same in its own transaction.
        bytes32 cur = ring[idx];
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 limit = uint32(uint256(cur)); // the low 32 bits are the expiry field
        if (limit >= block.timestamp) revert SlotLive(idx, limit);
        if (cur != bytes32(0) && cur != CONSUMED) {
            uint256 oldAmount = (uint256(cur) >> ENTRY_AMOUNT_SHIFT) & ENTRY_AMOUNT_MASK;
            packed = ((packed & RESERVED_MASK) - oldAmount)
                | ((((packed >> INFLIGHT_SHIFT) & INFLIGHT_MASK) - 1) << INFLIGHT_SHIFT);
            emit Released(idx, oldAmount);
        }

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

        // One budget per live reservation, this one included. The EntryPoint debits the deposit
        // and nothing else, so the deposit is the only quantity worth testing here.
        uint256 required = nextInFlight * EMERGENCY_EXIT_COST;
        if (info.deposit < required) revert SponsorshipUnderfunded(required, info.deposit);

        ring[idx] = entry(swapId, claimant, amount, expiry);
        _reserves = nextReservedPlusOne | (nextInFlight << INFLIGHT_SHIFT);

        emit Locked(swapId, claimant, amount, expiry, idx);
    }

    function claimBySig(
        bytes32 swapId,
        uint256 amount,
        address recipient,
        uint48 expiry,
        bytes calldata signature,
        uint32 idx
    ) external {
        if (recipient == address(0)) revert ZeroAddress();
        if (block.timestamp > expiry) revert ReservationExpired();

        address claimant = ECDSA.recover(claimDigest(swapId, amount, recipient, expiry), signature);
        _consumeReservation(swapId, claimant, amount, expiry, idx);
        token.safeTransfer(recipient, amount);
        emit Redeemed(swapId, claimant, recipient, amount, true, idx);
    }

    function claimSelf(bytes32 swapId, uint256 amount, address recipient, uint48 expiry, uint32 idx)
        external
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (block.timestamp > expiry) revert ReservationExpired();

        address claimant = msg.sender;
        _consumeReservation(swapId, claimant, amount, expiry, idx);
        token.safeTransfer(recipient, amount);
        emit Redeemed(swapId, claimant, recipient, amount, false, idx);
    }

    /// @notice Release an expired reservation. Permissionless: claims already revert past expiry,
    ///         so there is no race, and a stalled owner must not be able to inflate `inFlight`
    ///         and block new locks forever.
    function refund(bytes32 swapId, address claimant, uint256 amount, uint48 expiry, uint32 idx)
        external
    {
        if (block.timestamp <= expiry) revert ReservationNotExpired();
        _consumeReservation(swapId, claimant, amount, expiry, idx);
        emit Refunded(swapId, claimant, amount, idx);
    }

    function isReservation(
        bytes32 swapId,
        address claimant,
        uint256 amount,
        uint48 expiry,
        uint32 idx
    ) external view returns (bool) {
        return ring[idx] == entry(swapId, claimant, amount, expiry);
    }

    /// @notice The ring entry `lock` writes for a reservation. R1.
    function entry(bytes32 swapId, address claimant, uint256 amount, uint48 expiry)
        public
        pure
        returns (bytes32)
    {
        uint256 h = uint256(keccak256(abi.encode(swapId, claimant, amount, expiry)));
        // The top 160 bits of the hash, then amount, then expiry. `lock` range-checks both
        // fields; a value that does not fit yields an entry no `lock` ever wrote, hence no match.
        return bytes32(
            (h & (~uint256(0) << ENTRY_HASH_SHIFT))
                | ((amount & ENTRY_AMOUNT_MASK) << ENTRY_AMOUNT_SHIFT)
                | (uint256(expiry) & ENTRY_EXPIRY_MASK)
        );
    }

    function claimDigest(bytes32 swapId, uint256 amount, address recipient, uint48 expiry)
        public
        view
        returns (bytes32)
    {
        bytes32 structHash =
            keccak256(abi.encode(CLAIM_TYPEHASH, swapId, amount, recipient, expiry));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, NAME_HASH, VERSION_HASH, block.chainid, address(this)
            )
        );
    }

    function _consumeReservation(
        bytes32 swapId,
        address claimant,
        uint256 amount,
        uint48 expiry,
        uint32 idx
    ) internal {
        if (ring[idx] != entry(swapId, claimant, amount, expiry)) revert InvalidReservation();
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
    function withdrawETH(address payable to, uint256 amount, bool fromDeposit)
        external
        onlyOwner
    {
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

    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32,
        uint256 maxCost
    ) external returns (bytes memory context, uint256 validationData) {
        if (msg.sender != address(entryPoint)) revert NotFromEntryPoint(msg.sender);

        (uint8 code, uint48 expiry, bytes32 swapId) = _screen(userOp, maxCost);
        if (code != REJECT_NONE) return ("", SIG_VALIDATION_FAILED);

        emit SponsorshipUsed(swapId, userOp.sender);
        return ("", _packValidationData(false, expiry, 0));
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
        (code,,) = _screen(userOp, maxCost);
    }

    function _screen(PackedUserOperation calldata userOp, uint256 maxCost)
        private
        view
        returns (uint8 code, uint48 expiry, bytes32 swapId)
    {
        if (maxCost > EMERGENCY_EXIT_COST) return (REJECT_MAX_COST, 0, 0);

        // The EntryPoint bumps the nonce during validation, so pinning it to zero allows exactly
        // one sponsored operation per claimant, and `P` is fresh per swap.
        if (userOp.nonce != 0) return (REJECT_NONCE, 0, 0);

        if (!_withinGasCaps(userOp)) return (REJECT_GAS_CAP, 0, 0);
        if (_delegateOf(userOp.sender) != _expectedDelegation()) return (REJECT_DELEGATE, 0, 0);

        bytes calldata cd = userOp.callData;
        if (cd.length != EXIT_CALLDATA_LEN) return (REJECT_CALLDATA, 0, 0);
        if (bytes4(cd[0:4]) != EXECUTE_SELECTOR) return (REJECT_CALLDATA, 0, 0);
        if (uint256(bytes32(cd[4:36])) != uint256(uint160(address(this)))) {
            return (REJECT_CALLDATA, 0, 0);
        }
        if (uint256(bytes32(cd[36:68])) != 0) return (REJECT_CALLDATA, 0, 0);
        if (uint256(bytes32(cd[68:100])) != EXIT_INNER_OFFSET) return (REJECT_CALLDATA, 0, 0);
        if (uint256(bytes32(cd[100:132])) != EXIT_INNER_LEN) return (REJECT_CALLDATA, 0, 0);
        if (bytes4(cd[132:136]) != this.claimSelf.selector) return (REJECT_CALLDATA, 0, 0);

        // Decode the five argument words by hand rather than with abi.decode: a dirty upper byte
        // in the packed `recipient`, `expiry` or `idx` word makes abi.decode *revert*, which
        // surfaces as FailedOpWithRevert and is penalised harder by bundlers than a graceful
        // decline.
        bytes32 id = bytes32(cd[136:168]);
        uint256 amount = uint256(bytes32(cd[168:200]));
        uint256 recipientWord = uint256(bytes32(cd[200:232]));
        uint256 expiryWord = uint256(bytes32(cd[232:264]));
        uint256 idxWord = uint256(bytes32(cd[264:296]));
        if (recipientWord == 0 || recipientWord > type(uint160).max) return (REJECT_CALLDATA, 0, 0);
        if (expiryWord > type(uint48).max) return (REJECT_CALLDATA, 0, 0);
        if (idxWord > type(uint32).max) return (REJECT_CALLDATA, 0, 0); // R6

        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 exp = uint48(expiryWord); // range checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 idx = uint32(idxWord); // range checked above
        if (ring[idx] != entry(id, userOp.sender, amount, exp)) {
            return (REJECT_RESERVATION, 0, 0);
        }
        return (REJECT_NONE, exp, id);
    }

    function _withinGasCaps(PackedUserOperation calldata userOp) private view returns (bool) {
        uint256 accountGasLimits = uint256(userOp.accountGasLimits);
        if ((accountGasLimits >> 128) > VERIFICATION_GAS_LIMIT_CAP) return false;
        // forge-lint: disable-next-line(unsafe-typecast) — the low 128 bits are the field itself
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
