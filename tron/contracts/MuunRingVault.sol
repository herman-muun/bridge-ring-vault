// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title MuunRingVault (TRON)
/// @notice TRON port of bridge-ring-vault's `MuunRingVault`: the TRON `MuunUSDTVault` with its
///         reservations kept in a ring of reusable storage slots instead of a per-swap mapping
///         entry.
/// @dev Ported the way the TRON `MuunUSDTVault` was: the ERC-4337 paymaster, EntryPoint stake and
///      sponsorship accounting are dropped (TRON has none of them; the emergency exit is
///      `RingSponsoredClaimGateway`), and the EIP-712 domain uses TIP-712's
///      `block.chainid & 0xffffffff`. The ring rules are the Ethereum contract's:
///
///  R1  `ring[idx]` holds one reservation: the full 256-bit `keccak(swapId, claimant, amount)`.
///      `lock` writes an index only when it holds `0` (never used) or `CONSUMED`; a live
///      reservation is never rewritten (`SlotLive`).
///  R2  A reservation never expires and there is no `refund`: only a claim ends it.
///  R3  No path writes zero into the ring. A claim overwrites the entry with `CONSUMED`, so an
///      index pays the fresh-slot cost once and never again.
///  R4  A consumed entry no longer matches any reservation: claiming it again is
///      `InvalidReservation`.
///  R5  A reservation is bound to its index: the same swap presented at another `idx` is
///      `InvalidReservation`, never a payout.
contract MuunRingVault {
    using SafeERC20 for IERC20;

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error SlotLive(uint32 idx); // R1
    error InvalidReservation();
    error InsufficientFreeLiquidity();

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

    bytes32 public constant CLAIM_TYPEHASH =
        keccak256("Claim(bytes32 swapId,uint256 amount,address recipient)");
    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant NAME_HASH = keccak256("Muun USDT Vault");
    bytes32 private constant VERSION_HASH = keccak256("3");

    /// R3: what a consumed slot holds. Non-zero; no reservation hashes to it.
    bytes32 public constant CONSUMED = bytes32(uint256(1));

    IERC20 public immutable token;
    address public immutable owner;

    // Keep this word non-zero even when there are no live reservations.
    uint256 private _reservedPlusOne = 1;

    /// R1: the ring. `ring[idx]` is one reservation, a `CONSUMED` marker or zero (never used).
    bytes32[2 ** 32] public ring;

    constructor(address token_, address owner_) {
        if (token_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        token = IERC20(token_);
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function reserved() public view returns (uint256) {
        return _reservedPlusOne - 1;
    }

    function freeLiquidity() public view returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        uint256 r = reserved();
        return bal > r ? bal - r : 0;
    }

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

    function lock(bytes32 swapId, address claimant, uint256 amount, uint32 idx) external onlyOwner {
        if (claimant == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // R1, R2: the slot must be never used or consumed. A live reservation is never rewritten.
        bytes32 cur = ring[idx];
        if (cur != bytes32(0) && cur != CONSUMED) revert SlotLive(idx);

        uint256 nextReserved = reserved() + amount;
        if (token.balanceOf(address(this)) < nextReserved) revert InsufficientFreeLiquidity();

        ring[idx] = entry(swapId, claimant, amount);
        _reservedPlusOne = nextReserved + 1;
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
                EIP712_DOMAIN_TYPEHASH,
                NAME_HASH,
                VERSION_HASH,
                block.chainid & 0xffffffff, // TIP-712
                address(this)
            )
        );
    }

    function _consumeReservation(bytes32 swapId, address claimant, uint256 amount, uint32 idx)
        internal
    {
        if (ring[idx] != entry(swapId, claimant, amount)) revert InvalidReservation();
        ring[idx] = CONSUMED; // R3, R4
        _reservedPlusOne -= amount;
    }
}
