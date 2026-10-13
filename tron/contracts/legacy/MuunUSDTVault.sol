// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title MuunUSDTVault (TRON)
/// @notice Prefunded USDT vault for adaptor-signature atomic swaps.
/// @dev TRON port of the Ethereum vault. Differences, all in the EIP-712 domain:
///      TIP-712 specifies `block.chainid & 0xffffffff`, and the domain version is
///      bumped to "2" so a claim signed for one chain can never be presented on the
///      other even if a future deployment collided on address and chain id.
///      Everything else - reservation commitments, claim struct, accounting - is
///      byte-for-byte the Ethereum contract, so the two are directly comparable.
contract MuunUSDTVault {
    using SafeERC20 for IERC20;

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidExpiry();
    error ReservationExists();
    error InvalidReservation();
    error ReservationExpired();
    error ReservationNotExpired();
    error InsufficientFreeLiquidity();

    event Deposited(address indexed from, uint256 amount);
    event Withdrawn(address indexed to, uint256 amount);
    event Locked(bytes32 indexed swapId, address indexed claimant, uint256 amount, uint48 expiry);
    event Redeemed(
        bytes32 indexed swapId,
        address indexed claimant,
        address indexed recipient,
        uint256 amount,
        bool relayed
    );
    event Refunded(bytes32 indexed swapId, address indexed claimant, uint256 amount);

    bytes32 public constant CLAIM_TYPEHASH =
        keccak256("Claim(bytes32 swapId,uint256 amount,address recipient,uint48 expiry)");
    bytes32 private constant EIP712_DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant NAME_HASH = keccak256("Muun USDT Vault");
    bytes32 private constant VERSION_HASH = keccak256("2");

    IERC20 public immutable token;
    address public immutable owner;

    // Keep this word non-zero even when there are no live reservations.
    uint256 private _reservedPlusOne = 1;

    // Simple PoC model: one fresh mapping entry per swap.
    mapping(bytes32 swapId => bytes32 commitment) public reservations;

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

    function lock(bytes32 swapId, address claimant, uint256 amount, uint48 expiry)
        external
        onlyOwner
    {
        if (claimant == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (expiry <= block.timestamp) revert InvalidExpiry();
        if (reservations[swapId] != bytes32(0)) revert ReservationExists();

        uint256 nextReserved = reserved() + amount;
        if (token.balanceOf(address(this)) < nextReserved) revert InsufficientFreeLiquidity();

        reservations[swapId] = reservationCommitment(claimant, amount, expiry);
        _reservedPlusOne = nextReserved + 1;
        emit Locked(swapId, claimant, amount, expiry);
    }

    function claimBySig(
        bytes32 swapId,
        uint256 amount,
        address recipient,
        uint48 expiry,
        bytes calldata signature
    ) external {
        if (recipient == address(0)) revert ZeroAddress();
        if (block.timestamp > expiry) revert ReservationExpired();

        address claimant = ECDSA.recover(claimDigest(swapId, amount, recipient, expiry), signature);
        _consumeReservation(swapId, claimant, amount, expiry);
        token.safeTransfer(recipient, amount);
        emit Redeemed(swapId, claimant, recipient, amount, true);
    }

    function claimSelf(bytes32 swapId, uint256 amount, address recipient, uint48 expiry) external {
        if (recipient == address(0)) revert ZeroAddress();
        if (block.timestamp > expiry) revert ReservationExpired();

        address claimant = msg.sender;
        _consumeReservation(swapId, claimant, amount, expiry);
        token.safeTransfer(recipient, amount);
        emit Redeemed(swapId, claimant, recipient, amount, false);
    }

    function refund(bytes32 swapId, address claimant, uint256 amount, uint48 expiry)
        external
        onlyOwner
    {
        if (block.timestamp <= expiry) revert ReservationNotExpired();
        _consumeReservation(swapId, claimant, amount, expiry);
        emit Refunded(swapId, claimant, amount);
    }

    function isReservation(bytes32 swapId, address claimant, uint256 amount, uint48 expiry)
        external
        view
        returns (bool)
    {
        return reservations[swapId] == reservationCommitment(claimant, amount, expiry);
    }

    function reservationCommitment(address claimant, uint256 amount, uint48 expiry)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(claimant, amount, expiry));
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
                EIP712_DOMAIN_TYPEHASH,
                NAME_HASH,
                VERSION_HASH,
                block.chainid & 0xffffffff, // TIP-712
                address(this)
            )
        );
    }

    function _consumeReservation(bytes32 swapId, address claimant, uint256 amount, uint48 expiry)
        internal
    {
        if (reservations[swapId] != reservationCommitment(claimant, amount, expiry)) {
            revert InvalidReservation();
        }
        delete reservations[swapId];
        _reservedPlusOne -= amount;
    }
}
