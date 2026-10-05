# Decisions

Numbered so the code and the reports can point at them. Each one says what was chosen, why, and
what it rules out. Dates are when Herman took the decision.

## 1. Reservations live in a ring, not a mapping (2026-09-29; `refund` below is gone since #7)

`MuunUSDTVault.reservations[swapId]` becomes `MuunRingVault.ring[idx]`, a `bytes32[2**32]`.
Muun picks the index at `lock`; the claimant learns it from the `Locked` event and passes it back
on `claimBySig`, `claimSelf` and `refund`.

- Why: under Glamsterdam's EIP-8037, a fresh storage slot costs a premium the ring repo measured
  at 97,920 gas (storage-proof-ring-swap, receipts of 2026-09-28). The legacy vault creates one
  slot per swap and deletes it on claim, so every swap pays it. A ring pays it once per index.
- Rules out: any design where the swap id alone locates the reservation on chain.

## 2. The entry carries the amount (2026-09-29, replaced by #8 on 2026-10-02)

Entry = 160 bits of `keccak(swapId, claimant, amount, expiry)` ‖ `amount` (64 bits) ‖ `expiry`
(32 bits). The alternative was a 224-bit hash plus expiry, as `Fulfillment.ring` in the ring
repo, with a mandatory `refund` before an expired index could be reused.

- Why: `lock` over an expired, unconsumed index can release the old amount and count inline, so
  reusing such a slot is one transaction instead of two. 160 bits of hash is the preimage strength
  of an address.
- Rules out: 224-bit entries; a `refund` requirement before reuse (`refund` stays permissionless
  for whoever wants the liquidity back earlier).

## 3. No path writes zero into the ring (2026-09-29, amended by #7: no `refund`, no expired entry)

`claim` and `refund` write `CONSUMED = bytes32(1)` instead of deleting. `lock` may rewrite a
consumed or expired entry.

- Why: a zeroed slot is a fresh slot again for EIP-8037 and pays the premium on the next lock.
  The legacy vault's `_reserves` word was already kept non-zero for the same reason.
- Cost accepted: the claim no longer earns the clearing refund (up to 4,800 gas under EIP-3529);
  the run measures it.

## 4. Expiry stays a timestamp (2026-09-29, replaced by #7 on 2026-10-02)

`uint48 expiry` timestamps, stored in 32 bits (valid until 2106), compared against
`block.timestamp` as before. The ring repo uses L1 block numbers because its vault on Base
shares a clock with Ethereum; this vault lives on Ethereum alone.

## 5. Same-run baseline (2026-09-29)

The legacy contract is kept verbatim under `contracts/legacy/` and redeployed by the measurement
run on the same token, same block range and same client as the ring vault. The 2026-08-31
bridge-vault receipts (MockUSDT) are shown as context only.

- Why: one token, one day, one client per comparison; the mainnet USDT copy is what production
  would pay.

## 6. EIP-712 domain version "2" (2026-09-29, replaced by #11)

The ring vault signs `Claim` under version "2" so a claim signed for a legacy vault never
verifies on a ring vault at the same address on another chain. The `Claim` struct is unchanged:
`idx` is not signed, it only locates the entry, and the entry itself binds the swap.

## 7. Reservations never expire; `refund` and rule R2 are gone (2026-10-01)

Once `lock` writes a reservation it is the claimant's for ever, as if the USDT had been sent to
`P = T + U`. Only `claimSelf` or `claimBySig` end it; `lock` accepts an index only when it holds
`0` or `CONSUMED`. `refund`, `Refunded`, `Released`, the `expiry` argument of every function, the
`expiry` field of `Claim` and of `Locked`, and the paymaster's `validUntil` are removed.

- Why: `expiry` was Muun's free choice at `lock` and the PTLC lives in a Lightning channel where
  no Bitcoin clock runs until someone force-closes. After the user revealed its adaptor, Muun
  could stay silent past `expiry`, refund or rewrite the slot, and only then take the BTC: the
  user's only defence was to force-close early and stay online until its `tx_cancel` confirmed
  (`hardening-exploration/REPORT.md` §1.4 E1 and E2; with `t1` = 144 blocks and a 48 h expiry,
  force-close about 6.5 h after `lock` `[ESTIMATE]`). Without an expiry an offline user loses
  nothing: the reservation waits. The Base vault never had an expiry (its V2); this gives the
  Ethereum vault the same property.
- Cost accepted: an abandoned reservation pins its amount in `reserved` and one exit budget in
  `inFlight` for ever, Muun's liquidity cost; a time-bounded exit sponsorship is a product
  option that would need a new contract. Muun can still claim as `P` if `u` ever leaks through
  the user's own `tx_refund`.
- Rules out: any owner function that touches a live reservation; any inline release on `lock`.

## 8. The entry is the full 256-bit hash (2026-10-02)

`ring[idx] = keccak256(abi.encode(swapId, claimant, amount))`, nothing in the clear.

- Why: with #7 nothing has to be read inline (no expiry to compare, no amount to release), so
  the 96 bits that held `amount` and `expiry` go back to the hash. Collision work moves from a
  2^80 birthday on 160 bits to 2^128; second preimage from 2^160 to 2^256
  (`hardening-exploration/research/ring-entry-comparison.md`). `amount` is bounded by the
  128-bit `reserved` counter only.
- Rules out: #2's layout.

## 9. `lock` requires the bundlers' stake floors (2026-10-02)

`lock` reverts `StakeTooLow` unless `getDepositInfo(vault).stake >= MIN_STAKE`, and
`UnstakeDelayTooShort` unless `unstakeDelaySec >= MIN_UNSTAKE_DELAY`; both immutables from
`Config.minStake` and `Config.minUnstakeDelaySec`, zero rejected at deploy (rule R7).

- Why: ERC-7562 lets a paymaster read its own storage (STO-031) only when staked, and a bundler
  counts an entity as staked only above `MIN_STAKE_VALUE` (per chain, "roughly $1000") with
  `MIN_UNSTAKE_DELAY = 86400` (https://eips.ethereum.org/EIPS/eip-7562, status Review, read
  2026-09-30). The vault checked only the EntryPoint's `staked` flag, which 1 wei with a 1 s
  delay sets; the delay cannot be lowered later and the stake cannot be unlocked while a
  reservation is live, so a wrong first stake left the zero-ETH exit dead for every user until
  the owner topped it up, which a malicious owner would not do
  (`hardening-exploration/research/protocol-trust-audit.md` E5b). Two comparisons on a value
  `lock` already reads.
- Values: deployment parameters. Suggested 1 ether and 86,400 s on Ethereum mainnet
  `[ESTIMATE]`, to confirm with Pimlico and Candide; the measurement run stakes exactly its
  floors (0.01 ether, 86,400 s). Reopened if ERC-7562 or a bundler raises its floor (new vault,
  the floors are immutable).

## 10. The claim tip stays out (2026-10-02)

`bridge-vault/LAST_LEG.md` ("Possible improvement: a claim tip") would add a `tip` to `Claim`
so any searcher relays `claimBySig` for USDT when the sponsored exit is burned or no bundler
takes the paymaster (E3, E4, E10, E11 of the audit). Deferred: #7 and #8 close the cases that
lose funds; the tip is a liveness improvement and changes the struct the client signs, so it
goes in a pass of its own.

## 11. EIP-712 domain version "3" (2026-10-02)

`Claim(bytes32 swapId,uint256 amount,address recipient)` under version "3": a claim signed for
the version "2" struct (with `expiry`) never verifies here, and the other way round.

Accepted with it: a `Claim` binds `(swapId, amount, recipient)` and never expires, not an index.
If Muun ever locked the same `(swapId, claimant, amount)` twice (two live indices, or a re-lock
after a claim), one signature could be relayed to claim both; the funds go to the recipient `P`
signed, so it is Muun's double payout and nobody else's loss. `swapId = keccak(T, U)` with a
fresh `P` per swap already makes a triple unique; the contract does not enforce it.

