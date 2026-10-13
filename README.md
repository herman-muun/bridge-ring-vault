# bridge-ring-vault

Muun's prefunded USDT bridge vault ([bridge-vault](../bridge-vault)) with its reservations kept in
a ring of reusable storage slots, the way [storage-proof-ring-swap](../storage-proof-ring-swap)
keeps its payment records. The question it answers: under Glamsterdam gas rules, and on TRON,
how much does the ring take off `lock`, and what does it cost on the claim side.

- `docs/design.md`: the layout, the lifecycle, what changed.
- `docs/decisions.md`: why each choice, numbered.
- `reports/local-vault-2026-10.md`: the receipts of the current contract (no expiry, 256-bit
  entry, stake floors), legacy vault and ring vault side by side, same run, local Glamsterdam
  node, 2026-10-02.
- `reports/glamsterdam-vault.md`: the same comparison for the current contract on the public
  Platåberget devnet, 2026-10-12.
- `reports/tron-vault.md`: the TRON port of both vaults side by side on Nile, in Energy,
  2026-10-13.
- `reports/local-vault.md`: the previous layout (with `expiry`) on the local node, 2026-09-30.
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
| `reports/glamsterdam-vault.{json,md}` | its output on Platåberget (current contract) |
| `tron/contracts/MuunRingVault.sol` | the ring vault ported to TRON (R1..R5; no paymaster, TIP-712 domain) |
| `tron/contracts/RingSponsoredClaimGateway.sol` | its Energy-sponsored emergency exit |
| `tron/contracts/legacy/*.sol` | bridge-vault's TRON vault, gateway and `MockTetherUSDT`, verbatim, the baseline |
| `tron/test/MuunRingVault.t.sol` | R1, R4, R5 and the lock / claim / reuse cycle of the TRON port |
| `scripts/tron/measure-tron-vault.mjs` | the TRON measurement run, `npm run measure:tron` |
| `reports/tron-vault.{json,md}` | its output on Nile |

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

### TRON (Nile)

```
npm run build:tron && npm run test:tron
npm run accounts:tron   # writes .env.nile (keys + deployed addresses; mode 600, gitignored)
# fund the printed DEPLOYER at https://nileex.io/join/getJoinPage
npm run fund:tron       # moves the sponsor's and MUUN's share over from DEPLOYER
npm run deploy:tron     # token, both vaults, both gateways, sponsor stake
npm run measure:tron    # writes reports/tron-vault.{json,md}
```

- What the table shows: the TRX each role needs from scratch, from the fees measured on Nile
  (`scripts/tron/lib/budget.mjs` holds the same figures; `deploy`, `fund` and `measure` check
  balances against them before sending anything and say what is short).

| Role | Needs | For |
|---|---:|---|
| `DEPLOYER` | 283 | `MockTetherUSDT` 55.36, `MuunUSDTVault` 103.99, `MuunRingVault` 101.19, plus seeding the vaults and activating relays per run |
| `ENERGY_SPONSOR` | 1,528 | 1,500 staked for Energy (`SPONSOR_STAKE_TRX`), the two gateway deploys at 12.76 and 13.04 |
| `MUUN` | 95 per run | one run burned 89.79 |

About 1,910 TRX in all, so a fresh setup may take more than one faucet request; `fund:tron`
says how much is missing. After that, each further run needs only `npm run fund:tron && npm run
measure:tron`, about 95 TRX. A sponsored claim takes about 48.6k Energy and the stake regenerates
about 73.6 Energy per staked TRX per day. With a stake under about 1,370 TRX the run waits for
regeneration before its second sponsored claim instead of failing; under about 710 TRX it can
never start one.

To rerun on the existing Nile deployment instead, copy the `.env.nile` that holds its keys and
addresses (it is not in git) and skip `accounts:tron` and `deploy:tron`. Contracts built from
`tron/` use their own `foundry.toml` (solc 0.8.24, Paris), because TRON's compiler trails the
Ethereum profile's. The run picks three never-used ring indices (or `RING_IDX_BASE`), runs the
same swaps against both vaults in two rounds, and writes `reports/tron-vault.{json,md}`.

## Rules kept from the sibling repos

Measured numbers only, anything else is labelled `[ESTIMATE]`; a "What the table shows" bullet
before every table; every external claim dated and sourced; `.env` is mode 600 and never
committed; `.env.example` lists names only.
