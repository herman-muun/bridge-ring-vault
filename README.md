# bridge-ring-vault

Muun's prefunded USDT bridge vault ([bridge-vault](../bridge-vault)) with its reservations kept in
a ring of reusable storage slots, the way [storage-proof-ring-swap](../storage-proof-ring-swap)
keeps its payment records. The question it answers: under Glamsterdam gas rules, how much does
the ring take off `lock`, and what does it cost on the claim side.

- `docs/design.md`: the layout, the lifecycle, what changed.
- `docs/decisions.md`: why each choice, numbered.
- `reports/local-vault-2026-10.md`: the receipts of the current contract (no expiry, 256-bit
  entry, stake floors), legacy vault and ring vault side by side, same run, local Glamsterdam
  node, 2026-10-02.
- `reports/local-vault.md` and `reports/glamsterdam-vault.md`: the previous layout (with
  `expiry`) on the local node (2026-09-30) and on Platåberget (2026-09-29).
- `PLAN.md`: the plan this was built from, and the hardening pass of 2026-10-02 on top.

## Layout

- What the table shows: every path in the repo and what it holds.

| Path | What |
|---|---|
| `contracts/MuunRingVault.sol` | the ring vault (rules R1..R7 in its header) |
| `contracts/legacy/MuunUSDTVault.sol` | bridge-vault's contract, verbatim, the baseline of the run |
| `contracts/MockUSDT.sol` | test token (bridge-vault's) |
| `test/unit/Ring.t.sol` | R1..R6 (R7 in `SponsorshipFunding.t.sol`) |
| `test/unit/*.t.sol` | bridge-vault's suites adapted to the ring API |
| `scripts/measure-glamsterdam-vault.mjs` | the measurement run, `npm run measure:glam` |
| `reports/local-vault-2026-10.{json,md}` | its output on the local node (current contract) |

## Run

```
npm install
forge build && forge test
cp .env.example .env && chmod 600 .env   # fill in the names listed there
npm run measure:glam
```

The measurement needs a chain with Glamsterdam gas rules (the local node of the
`glamsterdam-local` repo, or the Platåberget devnet), the byte-exact mainnet USDT copy on it,
EntryPoint v0.9 and a `Simple7702Account` delegate already deployed there, and two funded keys:
the actor (owner of both vaults and of the USDT copy) and a bundler. It deploys both vaults,
funds them, runs the same steps against each in two rounds, and writes the reports. Set
`LEGACY_VAULT_ADDRESS` and `RING_VAULT_ADDRESS` to reuse deployments. For the local node:

```
set -a; . ../glamsterdam-local/.env.local; set +a
SIMPLE_7702_ACCOUNT_ADDRESS=$DELEGATE_ADDRESS LEGACY_VAULT_ADDRESS= RING_VAULT_ADDRESS= \
RESERVATION_TTL_SECONDS=60 RESERVATION_TTL_LONG_SECONDS=300 GLAMSTERDAM_REPORT_NAME=local-vault-2026-10 \
node scripts/measure-glamsterdam-vault.mjs
```

## Rules kept from the sibling repos

Measured numbers only, anything else is labelled `[ESTIMATE]`; a "What the table shows" bullet
before every table; every external claim dated and sourced; `.env` is mode 600 and never
committed; `.env.example` lists names only.
