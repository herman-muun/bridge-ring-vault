// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMuunRingVaultClaim {
    function claimBySig(
        bytes32 swapId,
        uint256 amount,
        address recipient,
        bytes calldata signature,
        uint32 idx
    ) external;
}

/// @title RingSponsoredClaimGateway
/// @notice `SponsoredClaimGateway` for `MuunRingVault`: the same Energy-sponsored emergency exit,
///         forwarding the ring vault's claim shape (no expiry, plus the ring index). Deployed with
///         `consume_user_resource_percent = 0` from the EnergySponsor account.
contract RingSponsoredClaimGateway {
    IMuunRingVaultClaim public immutable vault;

    constructor(IMuunRingVaultClaim vault_) {
        vault = vault_;
    }

    function claim(
        bytes32 swapId,
        uint256 amount,
        address recipient,
        bytes calldata signature,
        uint32 idx
    ) external {
        vault.claimBySig(swapId, amount, recipient, signature, idx);
    }
}
