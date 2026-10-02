# bridge-ring-vault: plan

## Hardening pass (plan, 2026-10-02)

Status: plan. Source: `hardening-exploration/REPORT.md` §1.4 (E1, E5b, E9), §2.3, §2.6, and
`research/ring-entry-comparison.md`. Decisions taken by Herman on 2026-10-01 and 2026-10-02.
The claim tip (`bridge-vault/LAST_LEG.md`, "Possible improvement") stays out of this pass.

### TL;DR

- A reservation never expires. `expiry`, `refund`, rule R2 and `Released` go; a slot is consumed
  only by `claimSelf` or `claimBySig`, and `lock` accepts an index only when it holds `0` or
  `CONSUMED`. An abandoned reservation stays for ever, as if the USDT had been sent to `P`; the
  pinned liquidity and exit budget are Muun's cost.
- With nothing to read inline, the entry is the full 256-bit `keccak(swapId, claimant, amount)`:
  birthday 2^128 instead of 2^80, second preimage 2^256.
- `lock` requires the EntryPoint stake to satisfy the bundlers, not only `staked == true`:
  `stake >= MIN_STAKE` and `unstakeDelaySec >= MIN_UNSTAKE_DELAY`, both immutables.
- Not in this pass: the claim tip, any change to the paymaster shapes beyond dropping `expiry`,
  anything on the Base path.

```mermaid
flowchart LR
  Z["ring[idx] = 0, never used"] -->|"lock, fresh-slot premium once"| L["live: keccak(swapId, claimant, amount)"]
  C["CONSUMED = 1"] -->|"lock, warm rewrite"| L
  L -->|"claimSelf or claimBySig"| C
  L -->|"user never comes back"| L
```

### 1. Contract changes (`contracts/MuunRingVault.sol`)

- What the table shows: each element of the contract as it is and what the pass does to it.

| element | today | after the pass |
| --- | --- | --- |
| entry layout | `hash160 ‖ amount64 ‖ expiry32` | `keccak256(abi.encode(swapId, claimant, amount))`, 256 bits; `ENTRY_*_SHIFT/MASK` removed |
| `lock(swapId, claimant, amount, expiry, idx)` | reverts `SlotLive` while `expiry >= now`; releases an expired entry inline (R2) | `lock(swapId, claimant, amount, idx)`: reverts `SlotLive(idx)` unless `ring[idx]` is `0` or `CONSUMED`; no inline release |
| `amount` bound | `uint64` (entry field) | `uint128` (the `reserved` counter); `ZeroAmount` and `ValueOverflow` as today |
| `claimSelf`, `claimBySig` | take `expiry`, revert `ReservationExpired` | drop `expiry`; no time check |
| `refund`, `Refunded`, `Released`, `InvalidExpiry`, `ReservationExpired`, `ReservationNotExpired` | present | removed |
| `entry` | `entry(swapId, claimant, amount, expiry)` | `entry(swapId, claimant, amount)` |
| `isReservation` | `isReservation(swapId, claimant, amount, expiry, idx)` | `isReservation(swapId, claimant, amount, idx)` |
| `Locked`, `Redeemed` | `Locked` carries `expiry` | `Locked(swapId, claimant, amount, idx)`; `Redeemed` unchanged |
| EIP-712 `Claim` | `Claim(bytes32 swapId,uint256 amount,address recipient,uint48 expiry)`, domain version "2" | `Claim(bytes32 swapId,uint256 amount,address recipient)`, domain version "3" |
| paymaster `_screen` | calldata 324 B, inner 164 B, five words, returns `validUntil = expiry` | calldata 292 B, inner 132 B, four words (`swapId, amount, recipient, idx`), `validUntil = 0` |
| stake check in `lock` | `info.staked` | plus `info.stake >= MIN_STAKE` (`StakeTooLow`) and `info.unstakeDelaySec >= MIN_UNSTAKE_DELAY` (`UnstakeDelayTooShort`) |
| `Config` | ten fields | plus `minStake`, `minUnstakeDelaySec`; constructor rejects zero for either |
| header rules | R1 to R6 | R1 rewritten (256-bit entry, free means `0` or `CONSUMED`), R2 replaced by "no expiry, no refund", R3 to R6 kept, R7 "stake minimums" |

What does not change: `bytes32[2**32] ring`, `CONSUMED`, `_reserves` packing, deposit and
withdraw gating, ETH and stake functions, gas caps, the delegate check, `sponsorshipRejection`.

### 2. Tests (`test/unit/`)

- What the table shows: per file, what is removed and what is added.

| file | remove | add |
| --- | --- | --- |
| `Ring.t.sol` | R2 (inline release), every `warp` past expiry, `refund` cases | R1: `lock` over a live entry reverts whatever the time; R2': a reservation is claimable after a `warp` of years; R7: entry equals the raw keccak and no 64-bit truncation of `amount` matches another amount |
| `PaymasterValidation.t.sol` | the `expiry` word tests | the 292-byte shape; the old 324-byte shape is `REJECT_CALLDATA`; `validationData` carries no `validUntil` |
| `SponsorshipFunding.t.sol` | `addStake(1)` as a valid setup | `lock` reverts `StakeTooLow` and `UnstakeDelayTooShort`; the floor values pass |
| `Invariant.t.sol` | the expired-entry term | `reserved == sum of unconsumed entries`, `inFlight == count of unconsumed entries`, for ever |
| `RecoveryE2E.t.sol` | `expiry` plumbing | unchanged scenarios: sponsored exit to a recipient that is not `P`, one burned attempt bounded, nonce 1 declined |
| `VaultTestBase.sol` | | `Config` with `minStake` 1 ether and `minUnstakeDelaySec` 1 day, matching the fixtures |

### 3. Measurement and docs

1. `scripts/measure-glamsterdam-vault.mjs` and `scripts/lib/userop.mjs`: drop `expiry` from
   the calls and the userOp, drop the "wait for expiry" and the `refund` step, keep the two
   rounds (`first`, `reuse`) with the reuse round driven by claims only.
2. Run against the local Glamsterdam node (`glamsterdam-local`, chain id 70910475) and write
   `reports/local-vault-2026-10.{json,md}` next to the existing reports. Expected `[ESTIMATE]`:
   `lock` within a few hundred gas of today's 62,504 on reuse (one fewer range check, one more
   comparison on the stake), `claimBySig` unchanged.
3. `docs/decisions.md`: #7 no expiry and no refund (2026-10-01), #8 256-bit entry, #9 stake
   minimums, #10 claim tip deferred; mark #2 and #4 as replaced. `docs/design.md` §1 to §3 and
   `README.md` updated after the receipts. `hardening-exploration/REPORT.md` §2.3 and §2.6 move
   from "decided" to "implemented".

### 4. Order of work

1. Contract (section 1), `forge build`.
2. Tests (section 2), `forge test`.
3. Scripts, local run, reports (section 3).
4. Docs. Herman commits.

### 5. Values to confirm before any deployment

- What the table shows: the two new immutables, the suggested values and what settles them.

| immutable | suggested | settles it |
| --- | --- | --- |
| `MIN_STAKE` | 1 ether on Ethereum `[ESTIMATE]` | ERC-7562 `MIN_STAKE_VALUE` ("roughly $1000"); ask Pimlico and Candide for their mainnet value |
| `MIN_UNSTAKE_DELAY` | 86,400 s | ERC-7562 `MIN_UNSTAKE_DELAY` |

Status 2026-09-30: sections 1 to 4 done (contract, 74 tests, runner, receipts). The devnet run
of 2026-09-29 measured every step at least once and the locks of both rounds; its reuse-round
claims did not repeat because the public RPC went down (details in
`reports/glamsterdam-vault.md`, "What did not run"). Numbers in `docs/design.md` §4.

The Ethereum bridge vault of `bridge-vault` (`MuunUSDTVault`, lock / claimBySig / sponsored
claimSelf) rewritten so that reservations live in a ring of reusable storage slots, the way
`storage-proof-ring-swap` did for `Fulfillment.ring`. Goal: measure on the Glamsterdam devnet
(Platåberget) how much of the fresh-slot premium the ring removes from `lock`, with the old vault
re-measured in the same run as the baseline.

## TL;DR

- What changes: `mapping(bytes32 => bytes32) reservations` becomes `bytes32[2**32] ring`. A
  reservation is written into the index Muun picks. The slot is never zeroed again: `claim` and
  `refund` overwrite it with a non-zero `CONSUMED` marker, and `lock` may rewrite an index whose
  reservation expired or was consumed.
- What we expected [ESTIMATE, written before the run]: `lock` drops by about the fresh-slot
  premium measured on the ring repo (97,920 gas, 2026-09-28 receipts), from 157,208 to roughly
  59,000 in steady state; `claimBySig` rises by up to 4,800 gas for the lost clearing refund.
  Measured: `lock` 159,692 to 62,504 (−97,188); `claimBySig` +12,108, more than the refund
  alone.
- How we check it: one script, `npm run measure:glam`, deploys the old vault and the ring vault
  on the byte-exact mainnet USDT copy already on the devnet, runs the same steps against both
  (round `first`, wait for expiry, round `reuse`), and writes `reports/glamsterdam-vault.{json,md}`.

## 1. Storage: mapping entry vs ring entry

```mermaid
flowchart LR
  subgraph old["bridge-vault today"]
    A["reservations[swapId] = keccak(claimant, amount, expiry)"]
    A -->|"lock: zero to non-zero, fresh slot premium every swap"| B["live"]
    B -->|"claim or refund: delete, slot back to zero"| C["zero again"]
  end
  subgraph new["bridge-ring-vault"]
    D["ring[idx] = hash160 ‖ amount64 ‖ expiry32"]
    D -->|"lock: premium only the first time idx is used"| E["live"]
    E -->|"claim or refund: write CONSUMED, never zero"| F["consumed, reusable"]
    E -->|"expiry passes"| G["expired, reusable"]
    F -->|"next lock rewrites"| D
    G -->|"next lock rewrites and releases the old amount"| D
  end
```

- What the table shows: the entry layout the ring vault stores per index and why each field is
  there.

| Bits | Field | Why |
|---|---|---|
| 255..96 | `hash160 = keccak(swapId, claimant, amount, expiry)[0:20]` | binds the slot to one swap and one claimant; 160 bits is the same preimage strength as an address |
| 95..32 | `amount` (uint64, USDT units) | lets `lock` release an expired reservation inline (`reserved -= amount`, `inFlight -= 1`) without a separate `refund` tx |
| 31..0 | `expiry` (uint32 timestamp) | the reuse rule: free when `expiry < block.timestamp` or when the entry is `CONSUMED` |

`CONSUMED = bytes32(uint256(1))`: non-zero, expiry bits 1, no real entry ever equals it. The
`_reserves` word (reserved + 1 ‖ inFlight) is unchanged; it was already kept non-zero.

Timestamps stay (the old vault, the claimant signatures and the paymaster expiry all use
`uint48` timestamps; 32 bits hold until 2106). There is no storage proof on this vault, so the
ring's slot position is not part of the protocol.

## 2. Contract changes

- What the table shows: every function of `MuunUSDTVault` and what the ring version does
  differently. New contract name `MuunRingVault`; the old one is kept verbatim under
  `contracts/legacy/` as the baseline of the run.

| Function | Old | Ring |
|---|---|---|
| `lock(swapId, claimant, amount, expiry)` | reverts if `reservations[swapId] != 0` | `lock(..., idx)`: reverts `SlotLive` if `ring[idx]` is live; if expired and not consumed, releases its amount and count first; writes the entry |
| `claimBySig(..., sig)` / `claimSelf(...)` | compare commitment, `delete` | `(..., idx)`: compare `ring[idx]` with the recomputed entry, write `CONSUMED`, transfer |
| `refund(...)` | permissionless after expiry, `delete` | `(..., idx)`: same rule, writes `CONSUMED` |
| `isReservation(...)` | mapping lookup | `(..., idx)`: entry comparison |
| `validatePaymasterUserOp` / `_screen` | parses 4 words of `claimSelf` (calldata 292 B) | parses 5 words (`idx` ≤ uint32.max, calldata 324 B, inner 164 B), checks `ring[idx]` |
| events `Locked`, `Redeemed`, `Refunded` | | gain `idx` so the claimant learns its index at lock time |
| everything else (deposit, withdraw, ETH, stake, gas caps) | | unchanged |

Rules to test (`test/unit/Ring.t.sol`, names R1..R6, plus the four old test files adapted):

1. R1 `lock` on a live index reverts `SlotLive(idx, expiry)`.
2. R2 `lock` on an expired, unconsumed index releases the old amount and count, then reserves the new one.
3. R3 no path ever writes zero into `ring` (claim, refund, lock over expired).
4. R4 a consumed entry cannot be claimed or refunded again (`InvalidReservation`).
5. R5 the same swap at a wrong `idx` is `InvalidReservation`, not a payout.
6. R6 `_screen` rejects an `idx` word above uint32.max and a reservation that is not at `idx`.

## 3. E2E on Glamsterdam (Platåberget, chainId 7091047534)

```mermaid
sequenceDiagram
  participant S as measure script
  participant T as USDT copy 0xc621
  participant O as legacy MuunUSDTVault
  participant R as MuunRingVault
  participant E as EntryPoint v0.9 0x71c4
  S->>T: assert code hash equals mainnet USDT
  S->>O: deploy on T, fund, depositTo, addStake
  S->>R: deploy on T, fund, depositTo, addStake
  Note over S,R: round first, every index used for the first time
  S->>O: lock, claimBySig warm, lock, claimBySig cold, lock, refund after expiry
  S->>R: same steps with idx 0..2
  S->>E: handleOps sponsored 7702 claimSelf against O then against R
  Note over S,R: wait until every expiry has passed
  Note over S,R: round reuse, same indices rewritten
  S->>O: same steps
  S->>R: same steps, plus lock over an expired unconsumed index
  S->>T: bare transfer cold and warm, the floor
  S->>S: write reports/glamsterdam-vault.json and .md
```

- What the table shows: the receipts the run produces per vault and round. Every number in the
  report is a receipt's `gasUsed`; expectations are labelled `[ESTIMATE]` until then.

| Step | Old vault | Ring vault | What it isolates |
|---|---|---|---|
| `lock` | fresh `reservations[swapId]` every time | index fresh in round `first`, rewritten in `reuse` | the fresh-slot premium |
| `claimBySig`, warm recipient | delete + refund | `CONSUMED` write | the lost clearing refund |
| `claimBySig`, cold recipient | | | the recipient premium, same on both |
| `refund` after expiry | delete | `CONSUMED` write | permissionless release |
| `lock` over an expired unconsumed index | n/a | inline release | the refund tx saved |
| sponsored `claimSelf` (7702 + 4337, self-bundled `handleOps`) | 577,886 outer on 2026-08-31 | | the escape hatch |
| bare `transfer` cold / warm | 152,417 / 54,497 on 2026-09-28 | | the floor |

Run parameters: `RESERVATION_TTL_SECONDS` short (60 s) so round `reuse` starts within minutes;
amount 10 USDT; both vaults get liquidity from the actor, which owns the USDT copy and can
`issue`; both get the same EntryPoint deposit and stake.

Accounts (env names only, never values): `GLAMSTERDAM_RPC_URL`, `GLAMSTERDAM_PRIVATE_KEY`
(the ring repo's devnet actor `0xAE3d…`, owner of the USDT copy, 2.44 ETH on 2026-09-29),
`BUNDLER_PRIVATE_KEY` (bridge-vault's bundler `0xbc27…`, needs ETH for `handleOps`),
`ENTRY_POINT_ADDRESS` `0x71c413…`, `SIMPLE_7702_ACCOUNT_ADDRESS` `0xdA213B…`,
`GLAMSTERDAM_USDT_COPY_ADDRESS` `0xc621…`, optional `LEGACY_VAULT_ADDRESS` and
`RING_VAULT_ADDRESS` to reuse deployments, `RESERVATION_TTL_SECONDS`, `AMOUNT_USDT`.

## 4. Repo layout and order of work

- What the table shows: what gets created, from where, in the order it will be done.

| # | Item | Source |
|---|---|---|
| 1 | `foundry.toml`, `remappings.txt`, `package.json`, `.gitignore`, `.env.example` (names only), `.env` mode 600 | bridge-vault, plus the ring repo's `GLAMSTERDAM_*` names |
| 2 | `contracts/legacy/MuunUSDTVault.sol`, `contracts/MockUSDT.sol` | bridge-vault, verbatim |
| 3 | `contracts/MuunRingVault.sol` | new, section 2 |
| 4 | `test/` (four files adapted) + `test/unit/Ring.t.sol` | bridge-vault tests + R1..R6 |
| 5 | `scripts/lib/common.mjs` (retrying sends, 503 handling), `scripts/measure-glamsterdam-vault.mjs`, `scripts/lib/userop.mjs` (the 7702 + 4337 op builder) | ring repo's measure script, bridge-vault's `recovery-path.mjs` |
| 6 | `npm run measure:glam`, `reports/glamsterdam-vault.{json,md}` | the run |
| 7 | `README.md`, `docs/design.md`, `docs/decisions.md` | after the receipts |

Repo rules carried over: measured numbers only, `[ESTIMATE]` otherwise; a "What the table
shows" bullet before every table; every external claim dated and sourced; no em-dashes; Herman
commits.

## 5. Open points to settle before coding

1. `amount` in the entry (inline release on reuse) versus a 224-bit hash like `Fulfillment` and a
   mandatory `refund` before reuse. Recommendation: amount in the entry; it removes a transaction
   and 160 bits of hash is enough.
2. Same-run baseline: redeploy the legacy vault on the USDT copy rather than reuse the 2026-08-31
   deployment on `MockUSDT`, so both columns share token, day and client. Recommendation: redeploy.
3. Keep timestamps for `expiry` (old vault semantics) rather than L1 block numbers (ring repo
   semantics). Recommendation: timestamps; this vault has no L1 clock to share with an L2.
