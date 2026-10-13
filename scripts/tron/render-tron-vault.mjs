// Renders reports/tron-vault.md from reports/tron-vault.json.
import { readFile, writeFile } from "node:fs/promises";
import { resolve } from "node:path";

const r = JSON.parse(await readFile(resolve("reports", "tron-vault.json"), "utf8"));
const EXPLORER = "https://nile.tronscan.org/#";
const addr = (a) => `[\`${a}\`](${EXPLORER}/address/${a})`;
const tx = (h) => `[\`${h.slice(0, 8)}…\`](${EXPLORER}/transaction/${h})`;
const n = (v) => (v === null || v === undefined ? "–" : Number(v).toLocaleString("en-US"));
const trxOf = (energy) => (energy * 100 / 1e6).toFixed(2);

const get = (kind, round, shape) => r.swaps.find((s) => s.kind === kind && s.round === round && s.shape === shape);
const delta = (ring, legacy) => n(ring - legacy);

const SHAPES = {
  A: "claimBySig, cold recipient",
  B: "claimBySig, warm recipient",
  D: { first: "claimBySig, cold recipient", reuse: "sponsored `gateway.claim`, cold recipient" },
};
const shapeLabel = (shape, round) => (typeof SHAPES[shape] === "string" ? SHAPES[shape] : SHAPES[shape][round]);

const stepRows = [];
for (const round of ["first", "reuse"]) {
  for (const shape of ["A", "B", "D"]) {
    const l = get("legacy", round, shape), g = get("ring", round, shape);
    stepRows.push(`| ${round} | ${shape}: lock | ${n(l.lock.energyTotal)} | ${n(g.lock.energyTotal)} | ${delta(g.lock.energyTotal, l.lock.energyTotal)} | ${tx(l.lock.txid)} | ${tx(g.lock.txid)} |`);
    stepRows.push(`| ${round} | ${shape}: ${shapeLabel(shape, round)} | ${n(l.claim.energyTotal)} | ${n(g.claim.energyTotal)} | ${delta(g.claim.energyTotal, l.claim.energyTotal)} | ${tx(l.claim.txid)} | ${tx(g.claim.txid)} |`);
  }
}

// Steady state: everything from round reuse.
const E = (kind, shape, part) => get(kind, "reuse", shape)[part].energyTotal;
const steady = [
  ["`lock`", E("legacy", "A", "lock"), E("ring", "A", "lock")],
  ["`claimBySig`, warm recipient", E("legacy", "B", "claim"), E("ring", "B", "claim")],
  ["`claimBySig`, cold recipient", E("legacy", "A", "claim"), E("ring", "A", "claim")],
  ["happy path, warm (`lock` + `claimBySig`)", E("legacy", "B", "lock") + E("legacy", "B", "claim"), E("ring", "B", "lock") + E("ring", "B", "claim")],
  ["happy path, cold (`lock` + `claimBySig`)", E("legacy", "A", "lock") + E("legacy", "A", "claim"), E("ring", "A", "lock") + E("ring", "A", "claim")],
  ["sponsored `gateway.claim` (sponsor's Energy)", E("legacy", "D", "claim"), E("ring", "D", "claim")],
  ["escape hatch (`lock` + sponsored claim)", E("legacy", "D", "lock") + E("legacy", "D", "claim"), E("ring", "D", "lock") + E("ring", "D", "claim")],
];
const steadyRows = steady.map(([label, l, g]) => `| ${label} | ${n(l)} | ${n(g)} | ${delta(g, l)} | ${trxOf(l)} / ${trxOf(g)} |`);

const ringFirstA = get("ring", "first", "A").lock.energyTotal, ringReuseA = E("ring", "A", "lock");
const legacyFirstA = get("legacy", "first", "A").lock.energyTotal, legacyReuseA = E("legacy", "A", "lock");
const [, hwL, hwG] = steady[3];
const sponsoredRows = r.swaps.filter((s) => s.relay).map((s) =>
  `| ${s.kind} | ${addr(s.relay.address)} | ${s.relay.trxBefore} / ${s.relay.trxAfter} | ${s.claim.totalFeeTrx} | ${n(s.claim.energyPaidByOrigin)} of ${n(s.claim.energyTotal)} | ${n(s.relay.sponsorEnergyBefore)} → ${n(s.relay.sponsorEnergyAfter)} |`);

const c = r.contracts;
const md = `# TRON Nile energy report: legacy vault against ring vault

Network: \`${r.network}\`
Run date: \`${r.runDate.slice(0, 10)}\` (${r.runDate})
Amount delivered per swap: \`${r.amountUsdt} USDT\`
Script: \`npm run measure:tron\` (\`scripts/tron/measure-tron-vault.mjs\`, rendered by \`scripts/tron/render-tron-vault.mjs\`); machine-readable evidence: \`reports/tron-vault.json\`.

Two vaults, same run, same token (\`MockTetherUSDT\`, ${addr(c.token)}), same owner ${addr(r.accounts.muunRelayer)}:
the TRON **legacy** \`MuunUSDTVault\` (${c.legacyVault.runtimeBytes} runtime bytes, one fresh \`reservations[swapId]\` slot per swap, deleted on claim) at ${addr(c.legacyVault.address)},
and the TRON **ring** \`MuunRingVault\` (${c.ringVault.runtimeBytes} runtime bytes, \`bytes32[2**32] ring\`, overwritten with \`CONSUMED\` on claim and rewritten by the next lock; no expiry, no refund) at ${addr(c.ringVault.address)}.
Their sponsored exits are \`SponsoredClaimGateway\` ${addr(c.legacyGateway.address)} and \`RingSponsoredClaimGateway\` ${addr(c.ringGateway.address)}, both deployed by the Energy sponsor ${addr(r.accounts.energySponsor)} with \`consume_user_resource_percent\` ${c.legacyGateway.consumeUserResourcePercent} / ${c.ringGateway.consumeUserResourcePercent}.

Round **first** writes ring indices ${r.ringIndexBase}..${r.ringIndexBase + 2} for the first time; round **reuse** rewrites them (the steady state). The legacy vault takes a fresh mapping slot every time, so its two rounds are the same operation twice. "Cold" = the recipient had never held the token; "warm" = it already did. Every figure is a receipt's \`energy_usage_total\`; Energy is priced at 100 sun (0.0001 TRX) when burned.

## Result: step by step

- What the table shows: for each round and step, the receipt's \`energy_usage_total\` of the same operation on the legacy vault and on the ring vault, and the difference (ring minus legacy, arithmetic on two receipts).

| Round | Step | legacy Energy | ring Energy | Δ ring − legacy | legacy tx | ring tx |
|---|---|---:|---:|---:|---|---|
${stepRows.join("\n")}

## Steady state per swap (round reuse)

- What the table shows: the round-reuse receipts added up per path (arithmetic on receipts), legacy against ring, and what each would cost in TRX if the Energy were burned at 100 sun.

| Path | legacy | ring | Δ ring − legacy | TRX if burned, legacy / ring |
|---|---:|---:|---:|---:|
${steadyRows.join("\n")}

## Reading the receipts

- Fresh-slot cost as paid on the ring: lock A first use ${n(ringFirstA)} against reuse ${n(ringReuseA)}, ${n(ringFirstA - ringReuseA)} Energy. The legacy vault pays it on every lock (first ${n(legacyFirstA)}, reuse ${n(legacyReuseA)}).
- Steady-state \`lock\`: ring ${n(ringReuseA)} against legacy ${n(legacyReuseA)}, ${n(legacyReuseA - ringReuseA)} Energy ${ringReuseA <= legacyReuseA ? "less" : "more"} per swap.
- Net per happy-path swap, warm: ${n(Math.abs(hwL - hwG))} Energy ${hwG <= hwL ? "less" : "more"} on the ring (${n(hwG)} against ${n(hwL)}; ${trxOf(Math.abs(hwL - hwG))} TRX at the burn price).
- The ring has no expiry, so no \`refund\` path to measure; an abandoned reservation keeps its index.

### The sponsored claims

Each was broadcast by a freshly activated relay that is not the claimant, holding zero TRX; the claimant only signed.

- What the table shows: per sponsored claim, the relay that broadcast it, its TRX balance around the claim, the fee it paid, how much of the Energy the gateway's origin (the sponsor) covered, and the sponsor's available Energy before and after.

| Vault | Relay | Relay TRX before / after | Relay fee (TRX) | Energy paid by gateway origin | Sponsor Energy before → after |
|---|---|---:|---:|---:|---:|
${sponsoredRows.join("\n")}

## Assertions

${Object.entries(r.checks).map(([k, v]) => `- ${v ? "PASS" : "FAIL"} - ${k}`).join("\n")}

Measured against \`MockTetherUSDT\`, the replica of \`TetherToken\`'s transfer path that bridge-vault's \`reports/TRON_GAS_REPORT.md\` (2026-08-26) cross-checked against the real Nile USDT; the vault-to-vault deltas do not depend on the token. Deployment, vault funding and sponsor staking are excluded from per-swap figures.
`;

await writeFile(resolve("reports", "tron-vault.md"), md);
console.log("wrote reports/tron-vault.md");
