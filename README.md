# bridge-ring-vault

Muun's prefunded USDT bridge vault ([bridge-vault](../bridge-vault)) with its reservations kept in
a ring of reusable storage slots, the way [storage-proof-ring-swap](../storage-proof-ring-swap)
keeps its payment records. The question it answers: under Glamsterdam gas rules, how much does
the ring take off `lock`, and what does it cost on the claim side.

- `docs/design.md`: the layout, the lifecycle, what changed.
- `docs/decisions.md`: why each choice, numbered.
- `reports/glamsterdam-vault.md`: the receipts, legacy vault and ring vault side by side, same run.
- `PLAN.md`: the plan this was built from.

## Layout

| Path | What |
|---|---|
| `contracts/MuunRingVault.sol` | the ring vault (rules R1..R6 in its header) |
| `contracts/legacy/MuunUSDTVault.sol` | bridge-vault's contract, verbatim, the baseline of the run |
| `contracts/MockUSDT.sol` | test token (bridge-vault's) |
| `test/unit/Ring.t.sol` | R1..R6 |
| `test/unit/*.t.sol` | bridge-vault's suites adapted to the ring API |
| `scripts/measure-glamsterdam-vault.mjs` | the devnet run, `npm run measure:glam` |
| `reports/glamsterdam-vault.{json,md}` | its output |

## Run

```
npm install
forge build && forge test
cp .env.example .env && chmod 600 .env   # fill in the names listed there
npm run measure:glam
```

The measurement needs the Glamsterdam devnet (Platåberget), the byte-exact mainnet USDT copy on
it, EntryPoint v0.9 and a `Simple7702Account` delegate already deployed there, and two funded
keys: the devnet actor (owner of both vaults and of the USDT copy) and a bundler. It deploys both
vaults, funds them, runs the same steps against each in two rounds, and writes the reports. Set
`LEGACY_VAULT_ADDRESS` and `RING_VAULT_ADDRESS` to reuse deployments.

## Rules kept from the sibling repos

Measured numbers only, anything else is labelled `[ESTIMATE]`; a "What the table shows" bullet
before every table; every external claim dated and sourced; `.env` is mode 600 and never
committed; `.env.example` lists names only.
