# TRON Nile energy report: legacy vault against ring vault

Network: `nile`
Run date: `2026-10-13` (2026-10-13T15:28:53.441Z)
Amount delivered per swap: `10 USDT`
Script: `npm run measure:tron` (`scripts/tron/measure-tron-vault.mjs`, rendered by `scripts/tron/render-tron-vault.mjs`); machine-readable evidence: `reports/tron-vault.json`.

Two vaults, same run, same token (`MockTetherUSDT`, [`TLEwMdYoAAbS6j6kg7uZGjDaxukUZaY7Qm`](https://nile.tronscan.org/#/address/TLEwMdYoAAbS6j6kg7uZGjDaxukUZaY7Qm)), same owner [`TVUhPkrPDqqeE55AE9B6GaoAthr4uchjV1`](https://nile.tronscan.org/#/address/TVUhPkrPDqqeE55AE9B6GaoAthr4uchjV1):
the TRON **legacy** `MuunUSDTVault` (5117 runtime bytes, one fresh `reservations[swapId]` slot per swap, deleted on claim) at [`TU2XtWphnjED2o61Q8uxP84p97wvFAhcW5`](https://nile.tronscan.org/#/address/TU2XtWphnjED2o61Q8uxP84p97wvFAhcW5),
and the TRON **ring** `MuunRingVault` (4987 runtime bytes, `bytes32[2**32] ring`, overwritten with `CONSUMED` on claim and rewritten by the next lock; no expiry, no refund) at [`TNiQzfbzCaALh1UZpYx8R7d5z1ED1opZAS`](https://nile.tronscan.org/#/address/TNiQzfbzCaALh1UZpYx8R7d5z1ED1opZAS).
Their sponsored exits are `SponsoredClaimGateway` [`TGQ1dfXt2NadHvzTEPrWpkV8i1mFyrXqpr`](https://nile.tronscan.org/#/address/TGQ1dfXt2NadHvzTEPrWpkV8i1mFyrXqpr) and `RingSponsoredClaimGateway` [`TCu5zb3oGNSaZSAj9av1d5tgoEy3KssFbP`](https://nile.tronscan.org/#/address/TCu5zb3oGNSaZSAj9av1d5tgoEy3KssFbP), both deployed by the Energy sponsor [`TJ7sAnmyuM4srwtk7cyocyirQDWPjvykWF`](https://nile.tronscan.org/#/address/TJ7sAnmyuM4srwtk7cyocyirQDWPjvykWF) with `consume_user_resource_percent` 0 / 0.

Round **first** writes ring indices 890834705..890834707 for the first time; round **reuse** rewrites them (the steady state). The legacy vault takes a fresh mapping slot every time, so its two rounds are the same operation twice. "Cold" = the recipient had never held the token; "warm" = it already did. Every figure is a receipt's `energy_usage_total`; Energy is priced at 100 sun (0.0001 TRX) when burned.

## Result: step by step

- What the table shows: for each round and step, the receipt's `energy_usage_total` of the same operation on the legacy vault and on the ring vault, and the difference (ring minus legacy, arithmetic on two receipts).

| Round | Step | legacy Energy | ring Energy | Δ ring − legacy | legacy tx | ring tx |
|---|---|---:|---:|---:|---|---|
| first | A: lock | 29,326 | 29,308 | -18 | [`861715a7…`](https://nile.tronscan.org/#/transaction/861715a7fc41ddea44c82883aa5985ef9b164253437560d238d9f230a13eee34) | [`eae95825…`](https://nile.tronscan.org/#/transaction/eae95825a62094aa4e16b49a4d581dc271310fe9783fa3c6200babdea49a63af) |
| first | A: claimBySig, cold recipient | 47,335 | 47,531 | 196 | [`192d2cb9…`](https://nile.tronscan.org/#/transaction/192d2cb978e714bec4cf3bc90ad470586c0fbbe43503eae583aa638cc9e4f5a7) | [`913b5fc3…`](https://nile.tronscan.org/#/transaction/913b5fc3477df5b2091413756777b9c629d140c2f338094cdb80c085151e045a) |
| first | B: lock | 29,326 | 29,308 | -18 | [`a9903fe7…`](https://nile.tronscan.org/#/transaction/a9903fe7bc862e8a39376c722cbe165eefebc3e097fe8233533131e95ae003a7) | [`6f1b66b0…`](https://nile.tronscan.org/#/transaction/6f1b66b0909f4cea3200edc33164f9eaf21684830af2bba451cb0e8436cf64a5) |
| first | B: claimBySig, warm recipient | 32,335 | 32,531 | 196 | [`440dd359…`](https://nile.tronscan.org/#/transaction/440dd3593c0ec3bac26eaec4d9beb6373f6ef220a99f254ca91959cbd23a2d95) | [`774699bd…`](https://nile.tronscan.org/#/transaction/774699bdf84102e4e53ee6df3e7455f47f553cccbc49269a4351bd97b1efd3d0) |
| first | D: lock | 29,326 | 29,308 | -18 | [`aeed0b7d…`](https://nile.tronscan.org/#/transaction/aeed0b7d56d415083d4d17036e27a3c9a385948f7b73e5677a284ae91dff8f99) | [`1237c9ea…`](https://nile.tronscan.org/#/transaction/1237c9ea94b4b9ad85c7a3e6203c9efa1bcea6e5f57654e9e84029bc65e5198c) |
| first | D: claimBySig, cold recipient | 47,335 | 47,531 | 196 | [`72cc4570…`](https://nile.tronscan.org/#/transaction/72cc4570ee4ea0cbff6135fb5c4b2630be19f2e63e145d1d8651e3743cd40168) | [`75f6df8d…`](https://nile.tronscan.org/#/transaction/75f6df8d8ccf9819cb2e335e503e9bd9c884af1a3825196330adf64a8280215e) |
| reuse | A: lock | 29,326 | 14,322 | -15,004 | [`3117811c…`](https://nile.tronscan.org/#/transaction/3117811c04ac533e3b08e8409e5d173a4e3719d0d727ea341b8d9517d788df79) | [`9be37a96…`](https://nile.tronscan.org/#/transaction/9be37a9649eab02f108c95653506044e8941633f05c8e393f7114469db38c35d) |
| reuse | A: claimBySig, cold recipient | 47,335 | 47,531 | 196 | [`aee89f38…`](https://nile.tronscan.org/#/transaction/aee89f3894ce4c51e5479084aecb2d84bf40ffb3bf96e084f7e98bbad652b4d0) | [`936ee292…`](https://nile.tronscan.org/#/transaction/936ee2928fa382000df03709ed644dc2f5fbbf262585606cb346dba3e79c5606) |
| reuse | B: lock | 29,326 | 14,322 | -15,004 | [`0d476618…`](https://nile.tronscan.org/#/transaction/0d476618be910a0e30529edab0391f3e8010eda56f4c67defac13cff0c7546e8) | [`15a3967a…`](https://nile.tronscan.org/#/transaction/15a3967a4daa0d57773a42d0d2eb3ed35e0ac1c8ad8f1e04614844b2d931339e) |
| reuse | B: claimBySig, warm recipient | 32,335 | 32,531 | 196 | [`6b923909…`](https://nile.tronscan.org/#/transaction/6b92390923d23f5b8084f7b24ecfb3a0202d342f09735f5a0665fde55573e8a1) | [`b3a7473f…`](https://nile.tronscan.org/#/transaction/b3a7473f2032306555fb638f217f2a13ac5b53a7a069d69bdcd462e0e3572dde) |
| reuse | D: lock | 29,326 | 14,322 | -15,004 | [`9c99b33d…`](https://nile.tronscan.org/#/transaction/9c99b33d0ff2c2fc67911eab65842fec6356aac3485ddb3c34f2d8ccde0ae121) | [`50a0ad3f…`](https://nile.tronscan.org/#/transaction/50a0ad3ff544cb71673907b346b5a0c4658a92bdcfc58e773e331f4e122bd1d9) |
| reuse | D: sponsored `gateway.claim`, cold recipient | 48,405 | 48,614 | 209 | [`7b9932b9…`](https://nile.tronscan.org/#/transaction/7b9932b962bb8cd8d8d0b80912a0a955d82a704338f9863dfc30d7a2a195f49f) | [`39d13885…`](https://nile.tronscan.org/#/transaction/39d13885ffeccf7754367f98e9b84f05629ed94ba541f84cef6f13c9eec669e3) |

## Steady state per swap (round reuse)

- What the table shows: the round-reuse receipts added up per path (arithmetic on receipts), legacy against ring, and what each would cost in TRX if the Energy were burned at 100 sun.

| Path | legacy | ring | Δ ring − legacy | TRX if burned, legacy / ring |
|---|---:|---:|---:|---:|
| `lock` | 29,326 | 14,322 | -15,004 | 2.93 / 1.43 |
| `claimBySig`, warm recipient | 32,335 | 32,531 | 196 | 3.23 / 3.25 |
| `claimBySig`, cold recipient | 47,335 | 47,531 | 196 | 4.73 / 4.75 |
| happy path, warm (`lock` + `claimBySig`) | 61,661 | 46,853 | -14,808 | 6.17 / 4.69 |
| happy path, cold (`lock` + `claimBySig`) | 76,661 | 61,853 | -14,808 | 7.67 / 6.19 |
| sponsored `gateway.claim` (sponsor's Energy) | 48,405 | 48,614 | 209 | 4.84 / 4.86 |
| escape hatch (`lock` + sponsored claim) | 77,731 | 62,936 | -14,795 | 7.77 / 6.29 |

## Reading the receipts

- Fresh-slot cost as paid on the ring: lock A first use 29,308 against reuse 14,322, 14,986 Energy. The legacy vault pays it on every lock (first 29,326, reuse 29,326).
- Steady-state `lock`: ring 14,322 against legacy 29,326, 15,004 Energy less per swap.
- Net per happy-path swap, warm: 14,808 Energy less on the ring (46,853 against 61,661; 1.48 TRX at the burn price).
- The ring has no expiry, so no `refund` path to measure; an abandoned reservation keeps its index.

### The sponsored claims

Each was broadcast by a freshly activated relay that is not the claimant, holding zero TRX; the claimant only signed.

- What the table shows: per sponsored claim, the relay that broadcast it, its TRX balance around the claim, the fee it paid, how much of the Energy the gateway's origin (the sponsor) covered, and the sponsor's available Energy before and after.

| Vault | Relay | Relay TRX before / after | Relay fee (TRX) | Energy paid by gateway origin | Sponsor Energy before → after |
|---|---|---:|---:|---:|---:|
| legacy | [`TKfyKHQSe5fd9YFGRicd8mSRxZ8BBSg17Y`](https://nile.tronscan.org/#/address/TKfyKHQSe5fd9YFGRicd8mSRxZ8BBSg17Y) | 0 / 0 | 0 | 48,405 of 48,405 | 121,169 → 72,766 |
| ring | [`TDVjc464mPnHaAPMHuc38Tu1dst9GH7KHj`](https://nile.tronscan.org/#/address/TDVjc464mPnHaAPMHuc38Tu1dst9GH7KHj) | 0 / 0 | 0 | 48,614 of 48,614 | 72,776 → 24,166 |

## Assertions

- PASS - every swap delivered exactly the amount
- PASS - A recipients were cold, B recipients warm
- PASS - every reservation cleared by its claim
- PASS - no signature could claim twice (R4)
- PASS - a live ring index refused a second lock (R1)
- PASS - reserved() returned to baseline on both vaults
- PASS - sponsored relays held 0 TRX before and after
- PASS - sponsored claims burned no TRX
- PASS - sponsored claim Energy was paid by the gateway's origin
- PASS - direct claims were not sponsored

Measured against `MockTetherUSDT`, the replica of `TetherToken`'s transfer path that bridge-vault's `reports/TRON_GAS_REPORT.md` (2026-08-26) cross-checked against the real Nile USDT; the vault-to-vault deltas do not depend on the token. Deployment, vault funding and sponsor staking are excluded from per-swap figures.
