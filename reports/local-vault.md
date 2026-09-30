# Bridge vault with a reservation ring under Glamsterdam gas rules: devnet receipts

Measured 2026-09-30 (2026-09-30T14:49:43.310Z) on a **local go-ethereum node with Amsterdam active from genesis** (the `glamsterdam-local` repo; chainId 70910475, client `Geth/v1.17.6-stable/darwin-arm64/go1.27.1`; basefee 7 wei, block gas limit 200,000,000); no explorer, transaction hashes are shown as is. Script: `npm run measure:glam` (`scripts/measure-glamsterdam-vault.mjs`); machine-readable evidence: `reports/local-vault.json`.

Two vaults, same run, same token, same owner [`0x1E74b8f533111573836CE34d9EAc26E79a067E01`](null/address/0x1E74b8f533111573836CE34d9EAc26E79a067E01): the **legacy** `MuunUSDTVault` of bridge-vault (contracts/legacy/MuunUSDTVault.sol (bridge-vault, verbatim), 10883 runtime bytes, one fresh `reservations[swapId]` slot per swap, deleted on claim) at [`0x37e558dfE6CA904f2037D2388811065e26a56a93`](null/address/0x37e558dfE6CA904f2037D2388811065e26a56a93), and the **ring** `MuunRingVault` (contracts/MuunRingVault.sol, 11588 runtime bytes, `bytes32[2**32] ring`, an index per reservation, overwritten with `CONSUMED` on claim and rewritten by the next lock) at [`0xb9971d787cD3C47ef117642f93EA0acd5164A783`](null/address/0xb9971d787cD3C47ef117642f93EA0acd5164A783). Both sit on the byte-exact mainnet USDT copy [`0xEc5d8CEd8f7DDdE92EDd3636C166Fb4E8Be10bd6`](null/address/0xEc5d8CEd8f7DDdE92EDd3636C166Fb4E8Be10bd6), use EntryPoint v0.9 [`0x433709009B8330FDa32311DF1C2AFA402eD8D009`](null/address/0x433709009B8330FDa32311DF1C2AFA402eD8D009) and the `Simple7702Account` delegate [`0xa46cc63eBF4Bd77888AA327837d20b23A63a56B5`](null/address/0xa46cc63eBF4Bd77888AA327837d20b23A63a56B5) already on the devnet, and reserve 10 USDT per swap. Round **first** uses ring indices 0..4 for the first time (the fresh-slot premium is in it); round **reuse** rewrites them (the steady state). "Cold" = the recipient had never held the token; "warm" = it already did. Every gas figure below is a receipt's `gasUsed`; nothing is an estimate.

## Result: legacy vault against ring vault, step by step

- What the table shows: for each round and step, the receipt's `gasUsed` of the same operation on the legacy vault and on the ring vault, and the difference (ring minus legacy, arithmetic on two receipts). The `handleOps` rows are the outer transaction of the sponsored EIP-7702 + ERC-4337 `claimSelf`; the `actualGasUsed` the EntryPoint charged is in the receipts table further down.

| Round | Step | legacy gasUsed | ring gasUsed | Δ ring − legacy | legacy tx | ring tx |
|---|---|---:|---:|---:|---|---|
| first | lock A | **159,794** | **160,500** | 706 | `0xf7358160…` | `0x6fa82f09…` |
| first | claimBySig A, warm recipient | **81,817** | **93,925** | 12,108 | `0xcf62f179…` | `0xb6e89b3b…` |
| first | lock B | **159,794** | **160,512** | 718 | `0x889ce10d…` | `0x87fbc2a7…` |
| first | claimBySig B, cold recipient | **179,761** | **191,857** | 12,096 | `0xb850efbb…` | `0xefe25bbf…` |
| first | lock C | **159,794** | **160,512** | 718 | `0x87603606…` | `0x69072580…` |
| first | refund C after expiry | **35,047** | **44,292** | 9,245 | `0x0bb18c6c…` | `0x672df833…` |
| first | lock D | **159,782** | **160,512** | 730 | `0x7a9a246d…` | `0x661846a3…` |
| first | sponsored claimSelf D (handleOps outer) | **486,703** | **499,266** | 12,563 | `0x9cfb47db…` | `0x8c41ed32…` |
| first | lock E | **159,794** | **160,512** | 718 | `0x12cc2606…` | `0x3ae5cf59…` |
| reuse | lock A | **159,794** | **62,594** | -97,200 | `0x069ab382…` | `0xfc2805f1…` |
| reuse | claimBySig A, warm recipient | **81,841** | **93,949** | 12,108 | `0xaf1a287d…` | `0x6fc0c1f9…` |
| reuse | lock B | **159,794** | **62,606** | -97,188 | `0xfaa85ea1…` | `0x2b5abba9…` |
| reuse | claimBySig B, cold recipient | **179,761** | **191,881** | 12,120 | `0x52b5651c…` | `0x561edf76…` |
| reuse | lock C | **159,782** | **62,606** | -97,176 | `0xffe1ba18…` | `0x93cfa79a…` |
| reuse | refund C after expiry | **35,037** | **44,292** | 9,255 | `0xa1abd74b…` | `0x3fd7ce10…` |
| reuse | lock D | **159,794** | **62,606** | -97,188 | `0x0d163f3f…` | `0xd606a3a6…` |
| reuse | sponsored claimSelf D (handleOps outer) | **486,703** | **499,266** | 12,563 | `0xa36fe247…` | `0x522b18fe…` |
| reuse | lock E (ring: rewrites the expired slot, releases inline) | **159,794** | **54,297** | -105,497 | `0x9018473f…` | `0x9831d3ab…` |
| reuse | refund of the expired E of the previous round | **35,047** | – | – | `0x487244b3…` | – |
| floor | bare USDT transfer, cold / warm recipient | 152,417 / 54,497 | same | – | `0x3e1d2c33…` | `0xe3f59d28…` |

## Steady state per swap

- What the table shows: the receipts added up per path (arithmetic on receipts), legacy against ring, next to bridge-vault's own receipts of 2026-08-31 on the same devnet over `MockUSDT` (its `reports/ETH_GAS_REPORT.md`; a different token, so read that column as context, not as the baseline of this run). Locks are round-reuse receipts. Where a row says so, the claim-side receipt is from round first: a claim, a sponsored exit or a refund writes the same thing whether the index was fresh or reused, so the figure is the same measurement; the reuse-round repeat did not run (see below).

| Path | legacy (this run) | ring (this run) | Δ ring − legacy | bridge-vault 2026-08-31 (MockUSDT) |
|---|---:|---:|---:|---:|
| `lock` | 159,794 | 62,594 | -97,200 | 157,208 `0x9689e625…` |
| `claimBySig`, warm recipient | 81,841 | 93,949 | 12,108 | – |
| `claimBySig`, cold recipient | 179,761 | 191,881 | 12,120 | 167,927 `0x224950ca…` |
| happy path, warm (`lock` + `claimBySig`) | 241,635 | 156,543 | -85,092 | – |
| happy path, cold (`lock` + `claimBySig`) | 339,555 | 254,487 | -85,068 | 325,135 |
| escape hatch (`lock` + sponsored `claimSelf`, outer tx) | 646,497 | 561,872 | -84,625 | 735,106 `0x8029e367…` |
| sponsored `claimSelf`, `actualGasUsed` charged by the EntryPoint | 338,712 | 339,456 | 744 | 420,185 |
| expired swap (`lock` + `refund`) | 194,819 | 106,898 | -87,921 | – |

## Reading the receipts

- Fresh-slot premium as paid on the ring: lock A first use 160,500 against reuse 62,594, 97,906 gas. The legacy vault pays it on every lock (first 159,794, reuse 159,794: no reuse to speak of).
- Steady-state `lock`: ring 62,594 against legacy 159,794, 97,200 gas less per swap.
- `claimBySig` (warm): ring 93,949 against legacy 81,841, 12,108 gas more: the ring writes `CONSUMED` (non-zero to non-zero) where the legacy vault deletes the slot and earns the clearing refund, and it carries one more calldata word and one more event field. The same delta shows on the cold claim and, without any transfer, on `refund` (44,292 against 35,037).
- Net per happy-path swap, warm: 85,092 gas less on the ring (156,543 against 241,635).
- Reusing an expired, unconsumed reservation: the ring's lock E rewrites the slot and releases it inline in 54,297 gas; the legacy vault needs `refund` 35,047 plus `lock` 159,794 = 194,841, two transactions.
- The escape hatch is unchanged in kind: the sponsored `claimSelf` costs the EntryPoint `actualGasUsed` 339,456 on the ring against 338,712 on the legacy vault; the claimant held zero ETH before and after in both, with no prerequisite transaction (authorization nonce 0 in both).
- Floor: a bare USDT transfer is 54,497 warm / 152,417 cold; the cold column is the recipient's fresh balance slot in the token, the same on both vaults and on any design.
- Deploying the legacy vault cost 17,160,049 gas once (setup table).
- Deploying the ring vault cost 18,250,257 gas once (setup table).

## Every receipt

- What the table shows: every measured transaction of this run: vault, round, shape, ring index (ring vault only), the recipient's token balance in the parent block where a transfer happened (the evidence for cold / warm), `gasUsed`, the EntryPoint's `actualGasUsed` for the sponsored exits, the block, and a dora link. Every lock receipt was checked for its `Locked` event (swap id, claimant, amount, expiry and, on the ring, the index) and every claim or refund receipt for its `Redeemed` / `Refunded` event; a mismatch would have aborted the run. State reads are not used as evidence: the public RPC load-balances over nodes that answer a pinned block with stale or empty state.

| # | Vault | Round | Shape | idx | Recipient balance before | gasUsed | actualGasUsed | Block | Tx |
|---:|---|---|---|---:|---:|---:|---:|---:|---|
| 1 | floor | floor | bare USDT transfer, cold recipient | – | 0 | **152,417** | – | [1419](null/block/1419) | `0x3e1d2c33…` |
| 2 | floor | floor | bare USDT transfer, warm recipient | – | 10000000 | **54,497** | – | [1421](null/block/1421) | `0xe3f59d28…` |
| 3 | legacy | first | lock A | – | – | **159,794** | – | [1423](null/block/1423) | `0xf7358160…` |
| 4 | legacy | first | lock B | – | – | **159,794** | – | [1425](null/block/1425) | `0x889ce10d…` |
| 5 | legacy | first | lock C | – | – | **159,794** | – | [1427](null/block/1427) | `0x87603606…` |
| 6 | legacy | first | lock D | – | – | **159,782** | – | [1429](null/block/1429) | `0x7a9a246d…` |
| 7 | legacy | first | lock E | – | – | **159,794** | – | [1431](null/block/1431) | `0x12cc2606…` |
| 8 | ring | first | lock A | 0 | – | **160,500** | – | [1433](null/block/1433) | `0x6fa82f09…` |
| 9 | ring | first | lock B | 1 | – | **160,512** | – | [1435](null/block/1435) | `0x87fbc2a7…` |
| 10 | ring | first | lock C | 2 | – | **160,512** | – | [1437](null/block/1437) | `0x69072580…` |
| 11 | ring | first | lock D | 3 | – | **160,512** | – | [1439](null/block/1439) | `0x661846a3…` |
| 12 | ring | first | lock E | 4 | – | **160,512** | – | [1441](null/block/1441) | `0x3ae5cf59…` |
| 13 | legacy | first | claimBySig A, warm recipient | – | 20000000 | **81,817** | – | [1443](null/block/1443) | `0xcf62f179…` |
| 14 | legacy | first | claimBySig B, cold recipient | – | 0 | **179,761** | – | [1445](null/block/1445) | `0xb850efbb…` |
| 15 | legacy | first | sponsored 7702+4337 claimSelf D, warm recipient (handleOps outer tx) | – | 30000000 | **486,703** | 338,712 | [1447](null/block/1447) | `0x9cfb47db…` |
| 16 | ring | first | claimBySig A, warm recipient | 0 | 40000000 | **93,925** | – | [1449](null/block/1449) | `0xb6e89b3b…` |
| 17 | ring | first | claimBySig B, cold recipient | 1 | 0 | **191,857** | – | [1451](null/block/1451) | `0xefe25bbf…` |
| 18 | ring | first | sponsored 7702+4337 claimSelf D, warm recipient (handleOps outer tx) | 3 | 50000000 | **499,266** | 339,456 | [1453](null/block/1453) | `0x8c41ed32…` |
| 19 | legacy | first | refund C after expiry | – | – | **35,047** | – | [1497](null/block/1497) | `0x0bb18c6c…` |
| 20 | ring | first | refund C after expiry | 2 | – | **44,292** | – | [1499](null/block/1499) | `0x672df833…` |
| 21 | legacy | reuse | refund of the expired E of round first (the transaction the ring saves) | – | – | **35,047** | – | [1501](null/block/1501) | `0x487244b3…` |
| 22 | legacy | reuse | lock A | – | – | **159,794** | – | [1503](null/block/1503) | `0x069ab382…` |
| 23 | legacy | reuse | lock B | – | – | **159,794** | – | [1505](null/block/1505) | `0xfaa85ea1…` |
| 24 | legacy | reuse | lock C | – | – | **159,782** | – | [1507](null/block/1507) | `0xffe1ba18…` |
| 25 | legacy | reuse | lock D | – | – | **159,794** | – | [1509](null/block/1509) | `0x0d163f3f…` |
| 26 | legacy | reuse | lock E | – | – | **159,794** | – | [1511](null/block/1511) | `0x9018473f…` |
| 27 | ring | reuse | lock A | 0 | – | **62,594** | – | [1513](null/block/1513) | `0xfc2805f1…` |
| 28 | ring | reuse | lock B | 1 | – | **62,606** | – | [1515](null/block/1515) | `0x2b5abba9…` |
| 29 | ring | reuse | lock C | 2 | – | **62,606** | – | [1517](null/block/1517) | `0x93cfa79a…` |
| 30 | ring | reuse | lock D | 3 | – | **62,606** | – | [1520](null/block/1520) | `0xd606a3a6…` |
| 31 | ring | reuse | lock E (rewrites the expired slot, releases it inline) | 4 | – | **54,297** | – | [1522](null/block/1522) | `0x9831d3ab…` |
| 32 | legacy | reuse | claimBySig A, warm recipient | – | 60000000 | **81,841** | – | [1524](null/block/1524) | `0xaf1a287d…` |
| 33 | legacy | reuse | claimBySig B, cold recipient | – | 0 | **179,761** | – | [1526](null/block/1526) | `0x52b5651c…` |
| 34 | legacy | reuse | sponsored 7702+4337 claimSelf D, warm recipient (handleOps outer tx) | – | 70000000 | **486,703** | 338,712 | [1528](null/block/1528) | `0xa36fe247…` |
| 35 | ring | reuse | claimBySig A, warm recipient | 0 | 80000000 | **93,949** | – | [1530](null/block/1530) | `0x6fc0c1f9…` |
| 36 | ring | reuse | claimBySig B, cold recipient | 1 | 0 | **191,881** | – | [1532](null/block/1532) | `0x561edf76…` |
| 37 | ring | reuse | sponsored 7702+4337 claimSelf D, warm recipient (handleOps outer tx) | 3 | 90000000 | **499,266** | 339,456 | [1534](null/block/1534) | `0x522b18fe…` |
| 38 | legacy | reuse | refund C after expiry | – | – | **35,037** | – | [1577](null/block/1577) | `0xa1abd74b…` |
| 39 | ring | reuse | refund C after expiry | 2 | – | **44,292** | – | [1580](null/block/1580) | `0x3fd7ce10…` |
| 40 | legacy | cleanup | refund of the expired E of round reuse (cleanup) | – | – | **35,047** | – | [1582](null/block/1582) | `0x06ebb280…` |
| 41 | ring | cleanup | refund of the expired E of round reuse (cleanup) | 4 | – | **44,292** | – | [1586](null/block/1586) | `0x8209532e…` |

## Setup and cleanup (not part of any per-swap figure)

- What the table shows: the one-off transactions of this run: deployments, USDT liquidity, EntryPoint deposit and stake, the bundler's ETH, and the deposit withdrawn back at the end. Each is a receipt.

| Vault | What | Contract | gasUsed | Block | Tx |
|---|---|---|---:|---:|---|
| legacy | deploy legacy MuunUSDTVault (mapping) | [`0x37e558dfE6CA904f2037D2388811065e26a56a93`](null/address/0x37e558dfE6CA904f2037D2388811065e26a56a93) | 17,160,049 | [1402](null/block/1402) | `0x4bd47120…` |
| legacy | USDT liquidity to the vault | – | 152,417 | [1404](null/block/1404) | `0x7fb8dd85…` |
| legacy | EntryPoint.depositTo(vault) | – | 133,696 | [1406](null/block/1406) | `0x3260c67c…` |
| legacy | vault.addStake | – | 149,761 | [1408](null/block/1408) | `0x3ba55fc7…` |
| ring | deploy MuunRingVault (ring) | [`0xb9971d787cD3C47ef117642f93EA0acd5164A783`](null/address/0xb9971d787cD3C47ef117642f93EA0acd5164A783) | 18,250,257 | [1410](null/block/1410) | `0x44271d64…` |
| ring | USDT liquidity to the vault | – | 152,417 | [1412](null/block/1412) | `0x7896c7a8…` |
| ring | EntryPoint.depositTo(vault) | – | 133,696 | [1415](null/block/1415) | `0x7a958ec5…` |
| ring | vault.addStake | – | 149,783 | [1417](null/block/1417) | `0x61a9567a…` |
| legacy | withdrawETH from the deposit (cleanup) | – | 38,882 | [1584](null/block/1584) | `0xbbb76cf0…` |
| ring | withdrawETH from the deposit (cleanup) | – | 38,872 | [1588](null/block/1588) | `0xf5f41867…` |

## Fidelity

- USDT: [`0xEc5d8CEd8f7DDdE92EDd3636C166Fb4E8Be10bd6`](null/address/0xEc5d8CEd8f7DDdE92EDd3636C166Fb4E8Be10bd6) carries mainnet `0xdAC17F958D2ee523a2206206994597C13D831ec7`'s runtime (11075 bytes, keccak `0xb44fb4e949d0f78f87f79ee46428f23a2a5713ce6fc6e0beb3dda78c2ac1ea55`; compared against mainnet `eth_getCode` in this run: true), not proxied, like mainnet. `paused` / `deprecated` / `basisPointsRate` / `maximumFee` read false / false / 0 / 0.
- Both vaults were deployed by this run from this repo's `forge build` (solc 0.8.28, optimizer 200, evm prague) with the same `Config` (exit envelope 700,000 gas, sponsored fee ceiling 50 gwei, `EMERGENCY_EXIT_COST` 0.035 ETH). The legacy source is bridge-vault's `contracts/MuunUSDTVault.sol` byte for byte.

