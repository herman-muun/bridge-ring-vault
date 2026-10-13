// TRON measurement: the legacy MuunUSDTVault against MuunRingVault on Nile, same
// token, same owner, same run. Mirrors scripts/measure-glamsterdam-vault.mjs:
//   round first - every ring index is written for the first time (the fresh-slot cost)
//   round reuse - the same indices are rewritten over CONSUMED (the steady state)
// Per vault and round, three swaps:
//   A - lock, claimBySig into a fresh (cold) recipient
//   B - lock, claimBySig into A's recipient (warm)
//   D - lock, then in round first claimBySig into a cold recipient; in round reuse the
//       Energy-sponsored gateway claim, broadcast by a fresh zero-TRX relay
// Only two sponsored claims per run (one per vault): the sponsor regenerates ~120k
// Energy a day and each costs ~48k. A claim does not depend on whether the index was
// fresh, so the reuse-round claim is the steady-state figure for both rounds.
import { readFileSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { sign } from "viem/accounts";
import { loadEnv, client, waitForReceipt, freshBalance } from "./lib/env.mjs";
import { freshZeroTrxRelay, freshAddress, freshSwapId, norm, sponsorEnergy, measure } from "./lib/poc.mjs";
import { needs, report } from "./lib/budget.mjs";

const env = loadEnv();
const abiOf = (name) =>
  JSON.parse(readFileSync(new URL(`../../tron/out/${name}.sol/${name}.json`, import.meta.url), "utf8")).abi;

for (const k of ["TRON_TOKEN_ADDRESS", "TRON_VAULT_ADDRESS", "TRON_GATEWAY_ADDRESS", "TRON_RING_VAULT_ADDRESS", "TRON_RING_GATEWAY_ADDRESS"]) {
  if (!env[k]) throw new Error(`${k} unset: run npm run deploy:tron first`);
}

const AMOUNT = Math.round(Number(env.AMOUNT_USDT ?? 10) * 1e6);
const TTL = Number(env.RESERVATION_TTL_SECONDS ?? 3600);
const TOKEN = env.TRON_TOKEN_ADDRESS;

const deployer = client(env, env.DEPLOYER_PRIVATE_KEY);
const muun = client(env, env.MUUN_PRIVATE_KEY);

// A run that runs dry halfway leaves nothing usable, so check the whole run's TRX first.
if ((await report(deployer, env, await needs(deployer, env, { withRun: true }))).length) {
  console.error("\nnot enough TRX for a run: npm run fund:tron");
  process.exit(1);
}
const tokenAbi = abiOf("MockTetherUSDT");

// The two vaults differ only in the claim shape: the legacy one carries an expiry,
// the ring one an index. Everything below goes through these adapters.
const VAULTS = {
  legacy: {
    address: env.TRON_VAULT_ADDRESS,
    gateway: env.TRON_GATEWAY_ADDRESS,
    abi: abiOf("MuunUSDTVault"),
    gatewayAbi: abiOf("SponsoredClaimGateway"),
    lockArgs: (s) => [s.swapId, s.claimant, AMOUNT, s.expiry],
    digest: (v, s, recipient) => v.claimDigest(s.swapId, AMOUNT, recipient, s.expiry).call(),
    claimArgs: (s, recipient, sig) => [s.swapId, AMOUNT, recipient, s.expiry, sig],
    isReservation: (v, s) => v.isReservation(s.swapId, s.claimant, AMOUNT, s.expiry).call(),
  },
  ring: {
    address: env.TRON_RING_VAULT_ADDRESS,
    gateway: env.TRON_RING_GATEWAY_ADDRESS,
    abi: abiOf("MuunRingVault"),
    gatewayAbi: abiOf("RingSponsoredClaimGateway"),
    lockArgs: (s) => [s.swapId, s.claimant, AMOUNT, s.idx],
    digest: (v, s, recipient) => v.claimDigest(s.swapId, AMOUNT, recipient).call(),
    claimArgs: (s, recipient, sig) => [s.swapId, AMOUNT, recipient, sig, s.idx],
    isReservation: (v, s) => v.isReservation(s.swapId, s.claimant, AMOUNT, s.idx).call(),
  },
};

async function usdtBalance(who) {
  return Number((await deployer.contract(tokenAbi, TOKEN).balanceOf(who).call()).toString());
}

/** True when a constant (dry-run) call of `method` reverts. Costs nothing. */
async function reverts(t, vault, method, args) {
  try {
    await t.contract(vault.abi, vault.address)[method](...args).call();
    return false;
  } catch {
    return true;
  }
}

async function waitForSponsorEnergy(needed) {
  for (let waited = 0; ; waited += 60) {
    const available = await sponsorEnergy(muun, env);
    if (available >= needed) {
      console.log(`  sponsor preflight: ${available.toLocaleString()} Energy available, need ~${needed.toLocaleString()}`);
      return;
    }
    if (waited % 600 === 0) console.log(`  sponsor has ${available.toLocaleString()}/${needed.toLocaleString()} Energy, waiting for regeneration`);
    await new Promise((r) => setTimeout(r, 60_000));
  }
}

/** One swap: lock, sign, claim (direct or through the gateway), with its checks. */
async function runSwap(kind, round, shape, { claimant, recipient, idx, viaGateway }) {
  const vault = VAULTS[kind];
  const v = muun.contract(vault.abi, vault.address);
  const s = { swapId: freshSwapId(), claimant: claimant.addr, expiry: Math.floor(Date.now() / 1000) + TTL, idx };
  const label = `${kind}:${round}:${shape}`;

  const lock = await measure(muun, vault.address, vault.abi, "lock", vault.lockArgs(s), `${label}:lock`);
  const signature = await sign({ hash: norm((await vault.digest(v, s, recipient)).toString()), privateKey: norm(claimant.pk), to: "hex" });

  // R1: a live ring index cannot be locked again.
  const liveSlotRefused = kind === "ring"
    ? await reverts(muun, vault, "lock", vault.lockArgs({ ...s, swapId: freshSwapId() }))
    : null;

  const recipientBefore = await usdtBalance(recipient);
  let claim, relay = null;
  if (viaGateway) {
    await waitForSponsorEnergy(52_000); // a sponsored claim took 48,614 at most
    const r = await freshZeroTrxRelay(deployer, env);
    const relayClient = client(env, r.pk);
    const before = await freshBalance(relayClient, r.addr);
    const sponsorBefore = await sponsorEnergy(muun, env);
    claim = await measure(relayClient, vault.gateway, vault.gatewayAbi, "claim", vault.claimArgs(s, recipient, signature), `${label}:gateway.claim`);
    relay = {
      address: r.addr, trxBefore: before, trxAfter: await freshBalance(relayClient, r.addr),
      sponsorEnergyBefore: sponsorBefore, sponsorEnergyAfter: await sponsorEnergy(muun, env),
    };
  } else {
    claim = await measure(muun, vault.address, vault.abi, "claimBySig", vault.claimArgs(s, recipient, signature), `${label}:claimBySig`);
  }
  const recipientAfter = await usdtBalance(recipient);

  const rec = {
    kind, round, shape, swapId: s.swapId, idx: idx ?? null, claimant: s.claimant, recipient,
    recipientColdBefore: recipientBefore === 0,
    delivered: recipientAfter - recipientBefore,
    reservationCleared: (await vault.isReservation(v, s)) === false,
    // R4: the same signature cannot claim twice.
    reclaimRefused: await reverts(muun, vault, "claimBySig", vault.claimArgs(s, recipient, signature)),
    liveSlotRefused, relay, lock, claim,
  };
  console.log(`  ${label.padEnd(20)} lock ${String(lock.energyTotal).padStart(6)} | ${viaGateway ? "gateway.claim" : "claimBySig   "} ${claim.energyTotal}`);
  return rec;
}

// ---------------------------------------------------------------- liquidity
for (const [kind, vault] of Object.entries(VAULTS)) {
  if ((await usdtBalance(vault.address)) < AMOUNT * 8) {
    const tok = deployer.contract(tokenAbi, TOKEN);
    await waitForReceipt(deployer, await tok.mint(1_000_000e6).send({ feeLimit: 100e6, shouldPollResponse: false }));
    await waitForReceipt(deployer, await tok.transfer(vault.address, 1_000_000e6).send({ feeLimit: 100e6, shouldPollResponse: false }));
    console.log(`seeded ${kind} vault with 1,000,000 mock USDT`);
  }
}

// Three ring indices nobody has written yet, so round first really is a first use.
const ring = muun.contract(VAULTS.ring.abi, VAULTS.ring.address);
let base;
for (;;) {
  base = env.RING_IDX_BASE !== undefined ? Number(env.RING_IDX_BASE) : Math.floor(Math.random() * 2 ** 31);
  const slots = await Promise.all([0, 1, 2].map((i) => ring.ring(base + i).call()));
  if (slots.every((x) => /^(0x)?0+$/.test(x.toString()))) break;
  if (env.RING_IDX_BASE !== undefined) throw new Error(`ring indices ${base}..${base + 2} already used`);
}
console.log(`ring indices ${base}..${base + 2}`);

const baselineReserved = {};
for (const [kind, vault] of Object.entries(VAULTS)) {
  baselineReserved[kind] = Number((await muun.contract(vault.abi, vault.address).reserved().call()).toString());
}

// ---------------------------------------------------------------- rounds
const swaps = [];
const claimant = freshAddress();
for (const round of ["first", "reuse"]) {
  for (const kind of ["legacy", "ring"]) {
    console.log(`\n${kind}, round ${round}`);
    const ab = freshAddress().addr;
    swaps.push(await runSwap(kind, round, "A", { claimant, recipient: ab, idx: base }));
    swaps.push(await runSwap(kind, round, "B", { claimant, recipient: ab, idx: base + 1 }));
    swaps.push(await runSwap(kind, round, "D", { claimant: freshAddress(), recipient: freshAddress().addr, idx: base + 2, viaGateway: round === "reuse" }));
  }
}

// ---------------------------------------------------------------- assertions
const finalReserved = {};
for (const [kind, vault] of Object.entries(VAULTS)) {
  finalReserved[kind] = Number((await muun.contract(vault.abi, vault.address).reserved().call()).toString());
}
const ringSwaps = swaps.filter((s) => s.kind === "ring");
const sponsored = swaps.filter((s) => s.relay);
const checks = [
  ["every swap delivered exactly the amount", swaps.every((s) => s.delivered === AMOUNT)],
  ["A recipients were cold, B recipients warm", swaps.every((s) => s.shape !== "A" || s.recipientColdBefore) && swaps.every((s) => s.shape !== "B" || !s.recipientColdBefore)],
  ["every reservation cleared by its claim", swaps.every((s) => s.reservationCleared)],
  ["no signature could claim twice (R4)", swaps.every((s) => s.reclaimRefused)],
  ["a live ring index refused a second lock (R1)", ringSwaps.every((s) => s.liveSlotRefused)],
  ["reserved() returned to baseline on both vaults", Object.keys(VAULTS).every((k) => finalReserved[k] === baselineReserved[k])],
  ["sponsored relays held 0 TRX before and after", sponsored.every((s) => s.relay.trxBefore === 0 && s.relay.trxAfter === 0)],
  ["sponsored claims burned no TRX", sponsored.every((s) => s.claim.totalFeeTrx === 0)],
  ["sponsored claim Energy was paid by the gateway's origin", sponsored.every((s) => s.claim.energyPaidByOrigin === s.claim.energyTotal)],
  ["direct claims were not sponsored", swaps.filter((s) => !s.relay).every((s) => s.claim.energyPaidByOrigin === 0)],
];
console.log();
for (const [what, ok] of checks) console.log(`${ok ? "PASS" : "FAIL"}  ${what}`);

// ---------------------------------------------------------------- report json
const contractInfo = async (addr) => {
  const c = await deployer.trx.getContract(addr);
  return { address: addr, runtimeBytes: (c.bytecode ?? "").length / 2, consumeUserResourcePercent: c.consume_user_resource_percent ?? 0 };
};
const out = {
  network: env.TRON_NETWORK ?? "nile",
  runDate: new Date().toISOString(),
  amountUsdt: AMOUNT / 1e6,
  ringIndexBase: base,
  contracts: {
    token: TOKEN,
    legacyVault: await contractInfo(env.TRON_VAULT_ADDRESS),
    legacyGateway: await contractInfo(env.TRON_GATEWAY_ADDRESS),
    ringVault: await contractInfo(env.TRON_RING_VAULT_ADDRESS),
    ringGateway: await contractInfo(env.TRON_RING_GATEWAY_ADDRESS),
  },
  accounts: { muunRelayer: env.MUUN_ADDRESS, energySponsor: env.ENERGY_SPONSOR_ADDRESS },
  swaps,
  checks: Object.fromEntries(checks),
};
await mkdir(resolve("reports"), { recursive: true });
await writeFile(resolve("reports", "tron-vault.json"), JSON.stringify(out, null, 2) + "\n");
console.log(`\nwrote reports/tron-vault.json`);
if (checks.some(([, ok]) => !ok)) {
  console.error(`\n${checks.filter(([, ok]) => !ok).length} assertion(s) failed`);
  process.exitCode = 1;
}
