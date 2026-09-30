# Decisions

Numbered so the code and the reports can point at them. Each one says what was chosen, why, and
what it rules out. Dates are when Herman took the decision.

## 1. Reservations live in a ring, not a mapping (2026-09-29)

`MuunUSDTVault.reservations[swapId]` becomes `MuunRingVault.ring[idx]`, a `bytes32[2**32]`.
Muun picks the index at `lock`; the claimant learns it from the `Locked` event and passes it back
on `claimBySig`, `claimSelf` and `refund`.

- Why: under Glamsterdam's EIP-8037, a fresh storage slot costs a premium the ring repo measured
  at 97,920 gas (storage-proof-ring-swap, receipts of 2026-09-28). The legacy vault creates one
  slot per swap and deletes it on claim, so every swap pays it. A ring pays it once per index.
- Rules out: any design where the swap id alone locates the reservation on chain.

## 2. The entry carries the amount (2026-09-29)

Entry = 160 bits of `keccak(swapId, claimant, amount, expiry)` ‖ `amount` (64 bits) ‖ `expiry`
(32 bits). The alternative was a 224-bit hash plus expiry, as `Fulfillment.ring` in the ring
repo, with a mandatory `refund` before an expired index could be reused.

- Why: `lock` over an expired, unconsumed index can release the old amount and count inline, so
  reusing such a slot is one transaction instead of two. 160 bits of hash is the preimage strength
  of an address.
- Rules out: 224-bit entries; a `refund` requirement before reuse (`refund` stays permissionless
  for whoever wants the liquidity back earlier).

## 3. No path writes zero into the ring (2026-09-29)

`claim` and `refund` write `CONSUMED = bytes32(1)` instead of deleting. `lock` may rewrite a
consumed or expired entry.

- Why: a zeroed slot is a fresh slot again for EIP-8037 and pays the premium on the next lock.
  The legacy vault's `_reserves` word was already kept non-zero for the same reason.
- Cost accepted: the claim no longer earns the clearing refund (up to 4,800 gas under EIP-3529);
  the run measures it.

## 4. Expiry stays a timestamp (2026-09-29)

`uint48 expiry` timestamps, stored in 32 bits (valid until 2106), compared against
`block.timestamp` as before. The ring repo uses L1 block numbers because its vault on Base
shares a clock with Ethereum; this vault lives on Ethereum alone.

## 5. Same-run baseline (2026-09-29)

The legacy contract is kept verbatim under `contracts/legacy/` and redeployed by the measurement
run on the same token, same block range and same client as the ring vault. The 2026-08-31
bridge-vault receipts (MockUSDT) are shown as context only.

- Why: one token, one day, one client per comparison; the mainnet USDT copy is what production
  would pay.

## 6. EIP-712 domain version "2" (2026-09-29)

The ring vault signs `Claim` under version "2" so a claim signed for a legacy vault never
verifies on a ring vault at the same address on another chain. The `Claim` struct is unchanged:
`idx` is not signed, it only locates the entry, and the entry itself binds the swap.
