// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMuunUSDTVaultClaim {
    function claimBySig(
        bytes32 swapId,
        uint256 amount,
        address recipient,
        uint48 expiry,
        bytes calldata signature
    ) external;
}

/// @title SponsoredClaimGateway
/// @notice TRON emergency-exit entry point. Deployed with
///         `consume_user_resource_percent = 0` from a dedicated EnergySponsor
///         account, so the sponsor's staked Energy pays for every call and the
///         caller needs only Bandwidth - of which every activated account has 600
///         free per day.
///
/// @dev Deliberately minimal and trustless. Authorization is the claimant's
///      TIP-712 signature recovered inside the vault, so this contract forwards no
///      identity and needs no privileges: `msg.sender` at the vault is this
///      gateway, and the vault does not care.
///
///      This is intentionally NOT the vault itself. Putting the sponsorship flag on
///      the vault would also sponsor Muun's own `lock`/`withdraw` and would expose
///      the vault's entire external surface to Energy griefing.
contract SponsoredClaimGateway {
    IMuunUSDTVaultClaim public immutable vault;

    constructor(IMuunUSDTVaultClaim vault_) {
        vault = vault_;
    }

    function claim(
        bytes32 swapId,
        uint256 amount,
        address recipient,
        uint48 expiry,
        bytes calldata signature
    ) external {
        vault.claimBySig(swapId, amount, recipient, expiry, signature);
    }
}
