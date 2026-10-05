# Bridge vault with a reservation ring under Glamsterdam gas rules: local node receipts

Measured 2026-10-02 (2026-10-02T19:30:23.206Z) on a **local go-ethereum node with Amsterdam active from genesis** (the `glamsterdam-local` repo; chainId 70910475, client `Geth/v1.17.6-stable/darwin-arm64/go1.27.1`; basefee 7 wei, block gas limit 200,000,000); no explorer, transaction hashes are shown as is. Script: `npm run measure:glam` (`scripts/measure-glamsterdam-vault.mjs`); machine-readable evidence: `reports/local-vault-2026-10.json`.

Two vaults, same run, same token, same owner `0x1E74b8f533111573836CE34d9EAc26E79a067E01`: the **legacy** `MuunUSDTVault` of bridge-vault (contracts/legacy/MuunUSDTVault.sol (bridge-vault, verbatim), 10883 runtime bytes, one fresh `reservations[swapId]` slot per swap, deleted on claim) at `0xA1E110eaC0E1e15f63Df5B86B47f8b97194865Dc`, and the **ring** `MuunRingVault` (contracts/MuunRingVault.sol, 11261 runtime bytes, `bytes32[2**32] ring`, an index per reservation holding the full 256-bit `keccak(swapId, claimant, amount)`, overwritten with `CONSUMED` on claim and rewritten by the next lock; no expiry and no refund, a reservation ends only with a claim) at `0x75d95764892D7fF8219d0b865623013A146985EC`. Both sit on the byte-exact mainnet USDT copy `0xEc5d8CEd8f7DDdE92EDd3636C166Fb4E8Be10bd6`, use EntryPoint v0.9 `0x433709009B8330FDa32311DF1C2AFA402eD8D009` and the `Simple7702Account` delegate `0xa46cc63eBF4Bd77888AA327837d20b23A63a56B5` already on the node, and reserve 10 USDT per swap. Round **first** uses ring indices 0..2 for the first time (the fresh-slot premium is in it); round **reuse** rewrites them (the steady state). Shapes C and E (an expiring reservation, a refund) exist on the legacy vault only: the ring has nothing to expire. "Cold" = the recipient had never held the token; "warm" = it already did. Every gas figure below is a receipt's `gasUsed`; nothing is an estimate.

## Result: legacy vault against ring vault, step by step

- What the table shows: for each round and step, the receipt's `gasUsed` of the same operation on the legacy vault and on the ring vault, and the difference (ring minus legacy, arithmetic on two receipts). The `handleOps` rows are the outer transaction of the sponsored EIP-7702 + ERC-4337 `claimSelf`; the `actualGasUsed` the EntryPoint charged is in the receipts table further down.

| Round | Step | legacy gasUsed | ring gasUsed | Δ ring − legacy | legacy tx | ring tx |
|---|---|---:|---:|---:|---|---|
| first | lock A | **159,794** | **159,795** | 1 | `0xaae575c7…` | `0x9182ed75…` |
| first | claimBySig A, warm recipient | **81,841** | **93,524** | 11,683 | `0xc9c0c69b…` | `0x6f6791b1…` |
| first | lock B | **159,782** | **159,807** | 25 | `0x2593b421…` | `0x89bf8854…` |
| first | claimBySig B, cold recipient | **179,749** | **191,456** | 11,707 | `0xa55422c5…` | `0x25929f3f…` |
| first | lock C (legacy only: expiring reservation) | **159,794** | – | n/a | `0x72374ab9…` | – |
| first | refund C after expiry (legacy only) | **35,047** | – | n/a | `0xbd4698af…` | – |
| first | lock D | **159,794** | **159,795** | 1 | `0x36f8e008…` | `0x778bbf59…` |
| first | sponsored claimSelf D (handleOps outer) | **486,715** | **498,038** | 11,323 | `0xdd8c04ae…` | `0x44c55860…` |
| first | lock E (legacy only: left to expire) | **159,794** | – | n/a | `0x95491e53…` | – |
| reuse | lock A | **159,782** | **61,889** | -97,893 | `0x7ada3dd8…` | `0x822cd4ef…` |
| reuse | claimBySig A, warm recipient | **81,817** | **93,524** | 11,707 | `0xaad8dcd3…` | `0xd3e4e3e3…` |
| reuse | lock B | **159,794** | **61,901** | -97,893 | `0x45154d8b…` | `0x65fa7c82…` |
| reuse | claimBySig B, cold recipient | **179,761** | **191,456** | 11,695 | `0xbe975085…` | `0x2084764d…` |
| reuse | lock C (legacy only: expiring reservation) | **159,782** | – | n/a | `0xbfa0d80c…` | – |
| reuse | refund C after expiry (legacy only) | **35,037** | – | n/a | `0x218fab3f…` | – |
| reuse | lock D | **159,782** | **61,877** | -97,905 | `0x2f5191f2…` | `0x40020fec…` |
| reuse | sponsored claimSelf D (handleOps outer) | **486,703** | **498,026** | 11,323 | `0x76aed61f…` | `0x2b587bb4…` |
| reuse | lock E (legacy only: left to expire) | **159,794** | – | n/a | `0xd42c6ae0…` | – |
| reuse | refund of the expired E of the previous round (legacy only) | **35,047** | – | n/a | `0xd19cc630…` | – |
| floor | bare USDT transfer, cold / warm recipient | 152,417 / 54,497 | same | – | `0x59a0bed4…` | `0x7bc30dad…` |

## Steady state per swap

- What the table shows: the receipts added up per path (arithmetic on receipts), legacy against ring, next to bridge-vault's own receipts of 2026-08-31 on the same devnet over `MockUSDT` (its `reports/ETH_GAS_REPORT.md`; a different token, so read that column as context, not as the baseline of this run). Locks are round-reuse receipts. Where a row says so, the claim-side receipt is from round first: a claim, a sponsored exit or a refund writes the same thing whether the index was fresh or reused, so the figure is the same measurement; the reuse-round repeat did not run (see below).

| Path | legacy (this run) | ring (this run) | Δ ring − legacy | bridge-vault 2026-08-31 (MockUSDT) |
|---|---:|---:|---:|---:|
| `lock` | 159,782 | 61,889 | -97,893 | 157,208 `0x9689e625…` |
| `claimBySig`, warm recipient | 81,817 | 93,524 | 11,707 | – |
| `claimBySig`, cold recipient | 179,761 | 191,456 | 11,695 | 167,927 `0x224950ca…` |
| happy path, warm (`lock` + `claimBySig`) | 241,599 | 155,413 | -86,186 | – |
| happy path, cold (`lock` + `claimBySig`) | 339,555 | 253,357 | -86,198 | 325,135 |
| escape hatch (`lock` + sponsored `claimSelf`, outer tx) | 646,485 | 559,903 | -86,582 | 735,106 `0x8029e367…` |
| sponsored `claimSelf`, `actualGasUsed` charged by the EntryPoint | 338,712 | 338,882 | 170 | 420,185 |
| expired swap (`lock` + `refund`); the ring has no expiry | 194,819 | – | – | – |

## Reading the receipts

- Fresh-slot premium as paid on the ring: lock A first use 159,795 against reuse 61,889, 97,906 gas. The legacy vault pays it on every lock (first 159,794, reuse 159,782: no reuse to speak of).
- Steady-state `lock`: ring 61,889 against legacy 159,782, 97,893 gas less per swap.
- `claimBySig` (warm): ring 93,524 against legacy 81,817, 11,707 gas more: the ring writes `CONSUMED` (non-zero to non-zero) where the legacy vault deletes the slot and earns the clearing refund, and it carries one more calldata word (`idx`) and one more event field, minus the `expiry` word and the time check it no longer has. The same delta shows on the cold claim.
- Net per happy-path swap, warm: 86,186 gas less on the ring (155,413 against 241,599).
- An expired, unconsumed reservation costs the legacy vault `refund` 35,047 plus the next `lock` 159,794 = 194,841, two transactions. The ring has no such path: a reservation never expires (R2), an abandoned one keeps its index and its liquidity for ever, and the next swap takes another index.
- The ring's `lock` also checks the EntryPoint stake against its floors (R7: `MIN_STAKE` 0.01 ETH, `MIN_UNSTAKE_DELAY` 86,400 s in this run): two comparisons on the `getDepositInfo` read it already made.
- The escape hatch is unchanged in kind: the sponsored `claimSelf` costs the EntryPoint `actualGasUsed` 338,882 on the ring against 338,712 on the legacy vault; the claimant held zero ETH before and after in both, with no prerequisite transaction (authorization nonce 0 in both).
- Floor: a bare USDT transfer is 54,497 warm / 152,417 cold; the cold column is the recipient's fresh balance slot in the token, the same on both vaults and on any design.
- Deploying the legacy vault cost 17,160,049 gas once (setup table).
- Deploying the ring vault cost 17,745,768 gas once (setup table).

## Every receipt

- What the table shows: every measured transaction of this run: vault, round, shape, ring index (ring vault only), the recipient's token balance in the parent block where a transfer happened (the evidence for cold / warm), `gasUsed`, the EntryPoint's `actualGasUsed` for the sponsored exits, the block, and the transaction hash (a dora link on the devnet). Every lock receipt was checked for its `Locked` event (swap id, claimant, amount, the expiry on the legacy vault and the index on the ring) and every claim or refund receipt for its `Redeemed` / `Refunded` event; a mismatch would have aborted the run. State reads are not used as evidence: on the devnet the public RPC load-balances over nodes that answer a pinned block with stale or empty state, and the local run keeps the same rule.

| # | Vault | Round | Shape | idx | Recipient balance before | gasUsed | actualGasUsed | Block | Tx |
|---:|---|---|---|---:|---:|---:|---:|---:|---|
| 1 | floor | floor | bare USDT transfer, cold recipient | – | 0 | **152,417** | – | 124279 | `0x59a0bed4…` |
| 2 | floor | floor | bare USDT transfer, warm recipient | – | 10000000 | **54,497** | – | 124281 | `0x7bc30dad…` |
| 3 | legacy | first | lock A | – | – | **159,794** | – | 124283 | `0xaae575c7…` |
| 4 | legacy | first | lock B | – | – | **159,782** | – | 124285 | `0x2593b421…` |
| 5 | legacy | first | lock C | – | – | **159,794** | – | 124287 | `0x72374ab9…` |
| 6 | legacy | first | lock D | – | – | **159,794** | – | 124289 | `0x36f8e008…` |
| 7 | legacy | first | lock E | – | – | **159,794** | – | 124291 | `0x95491e53…` |
| 8 | ring | first | lock A | 0 | – | **159,795** | – | 124293 | `0x9182ed75…` |
| 9 | ring | first | lock B | 1 | – | **159,807** | – | 124295 | `0x89bf8854…` |
| 10 | ring | first | lock D | 2 | – | **159,795** | – | 124297 | `0x778bbf59…` |
| 11 | legacy | first | claimBySig A, warm recipient | – | 20000000 | **81,841** | – | 124300 | `0xc9c0c69b…` |
| 12 | legacy | first | claimBySig B, cold recipient | – | 0 | **179,749** | – | 124302 | `0xa55422c5…` |
| 13 | legacy | first | sponsored 7702+4337 claimSelf D, warm recipient (handleOps outer tx) | – | 30000000 | **486,715** | 338,712 | 124304 | `0xdd8c04ae…` |
| 14 | ring | first | claimBySig A, warm recipient | 0 | 40000000 | **93,524** | – | 124306 | `0x6f6791b1…` |
| 15 | ring | first | claimBySig B, cold recipient | 1 | 0 | **191,456** | – | 124308 | `0x25929f3f…` |
| 16 | ring | first | sponsored 7702+4337 claimSelf D, warm recipient (handleOps outer tx) | 2 | 50000000 | **498,038** | 338,882 | 124310 | `0x44c55860…` |
| 17 | legacy | first | refund C after expiry | – | – | **35,047** | – | 124347 | `0xbd4698af…` |
| 18 | legacy | reuse | refund of the expired E of round first (a transaction the ring never needs) | – | – | **35,047** | – | 124355 | `0xd19cc630…` |
| 19 | legacy | reuse | lock A | – | – | **159,782** | – | 124357 | `0x7ada3dd8…` |
| 20 | legacy | reuse | lock B | – | – | **159,794** | – | 124359 | `0x45154d8b…` |
| 21 | legacy | reuse | lock C | – | – | **159,782** | – | 124361 | `0xbfa0d80c…` |
| 22 | legacy | reuse | lock D | – | – | **159,782** | – | 124364 | `0x2f5191f2…` |
| 23 | legacy | reuse | lock E | – | – | **159,794** | – | 124366 | `0xd42c6ae0…` |
| 24 | ring | reuse | lock A | 0 | – | **61,889** | – | 124368 | `0x822cd4ef…` |
| 25 | ring | reuse | lock B | 1 | – | **61,901** | – | 124370 | `0x65fa7c82…` |
| 26 | ring | reuse | lock D | 2 | – | **61,877** | – | 124372 | `0x40020fec…` |
| 27 | legacy | reuse | claimBySig A, warm recipient | – | 60000000 | **81,817** | – | 124374 | `0xaad8dcd3…` |
| 28 | legacy | reuse | claimBySig B, cold recipient | – | 0 | **179,761** | – | 124376 | `0xbe975085…` |
| 29 | legacy | reuse | sponsored 7702+4337 claimSelf D, warm recipient (handleOps outer tx) | – | 70000000 | **486,703** | 338,712 | 124378 | `0x76aed61f…` |
| 30 | ring | reuse | claimBySig A, warm recipient | 0 | 80000000 | **93,524** | – | 124380 | `0xd3e4e3e3…` |
| 31 | ring | reuse | claimBySig B, cold recipient | 1 | 0 | **191,456** | – | 124382 | `0x2084764d…` |
| 32 | ring | reuse | sponsored 7702+4337 claimSelf D, warm recipient (handleOps outer tx) | 2 | 90000000 | **498,026** | 338,882 | 124384 | `0x2b587bb4…` |
| 33 | legacy | reuse | refund C after expiry | – | – | **35,037** | – | 124421 | `0x218fab3f…` |
| 34 | legacy | cleanup | refund of the expired E of round reuse (cleanup) | – | – | **35,047** | – | 124429 | `0xcf13304f…` |

## Setup and cleanup (not part of any per-swap figure)

- What the table shows: the one-off transactions of this run: deployments, USDT liquidity, EntryPoint deposit and stake, the bundler's ETH, and the deposit withdrawn back at the end. Each is a receipt.

| Vault | What | Contract | gasUsed | Block | Tx |
|---|---|---|---:|---:|---|
| legacy | deploy legacy MuunUSDTVault (mapping) | `0xA1E110eaC0E1e15f63Df5B86B47f8b97194865Dc` | 17,160,049 | 124263 | `0xdda0e837…` |
| legacy | USDT liquidity to the vault | – | 152,417 | 124265 | `0xe1474f58…` |
| legacy | EntryPoint.depositTo(vault) | – | 133,696 | 124267 | `0x09a3a7fd…` |
| legacy | vault.addStake | – | 149,761 | 124269 | `0x2116d9f9…` |
| ring | deploy MuunRingVault (ring, no expiry) | `0x75d95764892D7fF8219d0b865623013A146985EC` | 17,745,768 | 124271 | `0xdc3f561e…` |
| ring | USDT liquidity to the vault | – | 152,417 | 124273 | `0x36dd8910…` |
| ring | EntryPoint.depositTo(vault) | – | 133,696 | 124275 | `0xd2b46646…` |
| ring | vault.addStake | – | 149,761 | 124277 | `0x64508c60…` |
| legacy | withdrawETH from the deposit (cleanup) | – | 38,882 | 124431 | `0xd6dfdfff…` |
| ring | withdrawETH from the deposit (cleanup) | – | 38,900 | 124433 | `0x1d6da2ae…` |

## Fidelity

- USDT: `0xEc5d8CEd8f7DDdE92EDd3636C166Fb4E8Be10bd6` carries mainnet `0xdAC17F958D2ee523a2206206994597C13D831ec7`'s runtime (11075 bytes, keccak `0xb44fb4e949d0f78f87f79ee46428f23a2a5713ce6fc6e0beb3dda78c2ac1ea55`; compared against mainnet `eth_getCode` in this run: true), not proxied, like mainnet. `paused` / `deprecated` / `basisPointsRate` / `maximumFee` read false / false / 0 / 0.
- Both vaults were deployed by this run from this repo's `forge build` (solc 0.8.28, optimizer 200, evm prague) with the same `Config` (the ring adds its two stake floors; exit envelope 700,000 gas, sponsored fee ceiling 50 gwei, `EMERGENCY_EXIT_COST` 0.035 ETH). The legacy source is bridge-vault's `contracts/MuunUSDTVault.sol` byte for byte.

