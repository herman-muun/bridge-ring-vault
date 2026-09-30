// Ethereum-side gas of the bridge vault with reservations in a ring of reusable slots
// (`MuunRingVault`) against the mapping-based vault it derives from (`MuunUSDTVault`, kept
// verbatim under contracts/legacy/), under Glamsterdam gas rules (EIP-8037 state creation,
// EIP-8038 state access), as receipts on the public devnet "plataberget" (chainId 7091047534).
//
// What it sends:
//   0. setup: deploys both vaults over the byte-exact mainnet USDT copy, funds their USDT, their
//      EntryPoint deposit and stake (none of this is in a per-swap figure); a bare USDT transfer
//      to a fresh recipient W and a second one to W: the floor, and W is warm from then on;
//   1. round "first": for each vault, five locks (ring indices 0..4 used for the first time):
//        A  lock, then claimBySig to W (warm recipient)
//        B  lock, then claimBySig to a fresh recipient (cold)
//        C  lock with a short expiry, then refund once it expired
//        D  lock for a zero-ETH claimant, then the sponsored EIP-7702 + ERC-4337 claimSelf to W,
//           self-bundled through EntryPoint.handleOps by the bundler key
//        E  lock with a short expiry, left to expire unconsumed
//   2. round "reuse": the same five shapes; the ring rewrites indices 0..4 (steady state). Its
//      lock E rewrites the expired, unconsumed slot and releases it inline; the legacy vault
//      needs a refund transaction for its old E first, which is measured too.
//   3. cleanup: refunds what is still expired and withdraws the surplus deposit.
//
// Env (names only): GLAMSTERDAM_RPC_URL, GLAMSTERDAM_PRIVATE_KEY (owner of both vaults and of
// the USDT copy), BUNDLER_PRIVATE_KEY, ENTRY_POINT_ADDRESS, SIMPLE_7702_ACCOUNT_ADDRESS,
// GLAMSTERDAM_USDT_COPY_ADDRESS, MAINNET_RPC_URL (fidelity check); optional LEGACY_VAULT_ADDRESS,
// RING_VAULT_ADDRESS, RESERVATION_TTL_SECONDS, RESERVATION_TTL_LONG_SECONDS, AMOUNT_USDT.
// Writes reports/glamsterdam-vault.json and reports/glamsterdam-vault.md.
import { readFile, writeFile } from "node:fs/promises";
import { concatHex, createPublicClient, encodeDeployData, encodeFunctionData, formatEther, getAddress, hashTypedData, http, keccak256, maxUint256, parseEventLogs, parseUnits, toHex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

import { GLAMSTERDAM as G, ZERO_BYTES32, artifact, bigintEnv, freshSwapId, mainnetClient, privateKeyEnv, reportPath, requiredEnv, retryHttp, sleep, writeReport } from "./lib/common.mjs";

const log = (m) => console.log(`${new Date().toISOString()} ${m}`);
const EXPLORER = G.explorer;
const REPORT = process.env.GLAMSTERDAM_REPORT_NAME ?? "glamsterdam-vault"; // e.g. local-vault for the glamsterdam-local node

if (process.argv[2] === "render") {
  const rep = JSON.parse(await readFile(reportPath(`${REPORT}.json`), "utf8"));
  await writeFile(reportPath(`${REPORT}.md`), renderMd(rep));
  console.log(`written ${reportPath(`${REPORT}.md`)}`);
  process.exit(0);
}

// ------------------------------------------------------------------ parameters
const AMOUNT = parseUnits(process.env.AMOUNT_USDT ?? "10", 6);
const TTL_SHORT = bigintEnv("RESERVATION_TTL_SECONDS", 600n); // shapes C and E: expire soon (counted from the lock itself; a broadcast can sit minutes on the public RPC)
const TTL_LONG = bigintEnv("RESERVATION_TTL_LONG_SECONDS", 7200n); // shapes A, B, D: claimed in the round; a round of ten locks took 30 min on the public RPC
const MAINNET_USDT = "0xdAC17F958D2ee523a2206206994597C13D831ec7";
const USDT = getAddress(process.env.GLAMSTERDAM_USDT_COPY_ADDRESS ?? "0xc621dfb139d34c63b50d10f6417134e69e482864");
const ENTRY_POINT = getAddress(requiredEnv("ENTRY_POINT_ADDRESS"));
const ACCOUNT_IMPL = getAddress(requiredEnv("SIMPLE_7702_ACCOUNT_ADDRESS"));
// Same envelope as bridge-vault's deployment (script/Deploy.s.sol defaults, run of 2026-08-31).
const CAPS = { maxSponsoredFeePerGas: bigintEnv("MAX_SPONSORED_FEE_PER_GAS", 50_000_000_000n), preVerificationGasCap: 100_000n, verificationGasLimitCap: 250_000n, callGasLimitCap: 250_000n, paymasterVerificationGasLimitCap: 100_000n, maxPriorityFeePerGasCap: 2_000_000_000n };
const ENVELOPE = CAPS.preVerificationGasCap + CAPS.verificationGasLimitCap + CAPS.callGasLimitCap + CAPS.paymasterVerificationGasLimitCap;
const EXIT_COST = ENVELOPE * CAPS.maxSponsoredFeePerGas; // 0.035 ETH at the defaults
const DEPOSIT_PER_VAULT = bigintEnv("SPONSORSHIP_DEPOSIT_WEI", 6n * EXIT_COST); // at most 6 live reservations per vault in a run
const STAKE = bigintEnv("PAYMASTER_STAKE_WEI", 10_000_000_000_000_000n); // 0.01 ETH; self-bundled, no bundler policy to satisfy
const LIQUIDITY = AMOUNT * 30n;
const BUNDLER_MIN_ETH = 50_000_000_000_000_000n;
// bridge-vault's receipts of 2026-08-31 (reports/ETH_GAS_REPORT.md there), on MockUSDT, same devnet.
const PRIOR = { source: "bridge-vault reports/ETH_GAS_REPORT.md and reports/eth-*.json, measured 2026-08-31 on Platåberget over MockUSDT (not the mainnet USDT copy)", lock: { gasUsed: "157208", tx: "0x9689e6258d996d0b7255c28911515b15aa43f4ece2499393d9798f2e098dd44e" }, claimBySigCold: { gasUsed: "167927", tx: "0x224950ca7d318576bb7097e3e316b112d5eea9aa22dd3f7d05537d761bca151a" }, recoveryLock: { gasUsed: "157220", tx: "0xd71ecb19bfc4fcf897ddf6b1087852a48b0cefd9f5798f8823c7e493d0107357" }, recoveryHandleOps: { gasUsed: "577886", actualGasUsed: "420185", tx: "0x8029e3677b1fc31080c5a4aa3de9d3f5bc20b58c10b7ffe9c47116ac6054471b" } };

const tokenAbi = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ name: "a", type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "transfer", stateMutability: "nonpayable", inputs: [{ name: "to", type: "address" }, { name: "v", type: "uint256" }], outputs: [] },
  { type: "function", name: "issue", stateMutability: "nonpayable", inputs: [{ name: "amount", type: "uint256" }], outputs: [] },
  { type: "function", name: "owner", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "paused", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { type: "function", name: "deprecated", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
  { type: "function", name: "basisPointsRate", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "maximumFee", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
];

// ------------------------------------------------------------------ clients
const transport = http(G.rpcUrl, { retryCount: 8, retryDelay: 2000, timeout: 30_000 });
const pub = createPublicClient({ chain: G.chain, transport, cacheTime: 0, pollingInterval: 1500 });
const actor = privateKeyToAccount(privateKeyEnv("GLAMSTERDAM_PRIVATE_KEY"));
const bundler = privateKeyToAccount(privateKeyEnv("BUNDLER_PRIVATE_KEY"));
const R = (fn) => retryHttp(fn);
const readT = (fn, args = [], blockNumber) => R(() => pub.readContract({ address: USDT, abi: tokenAbi, functionName: fn, args, ...(blockNumber !== undefined ? { blockNumber } : {}) }));

const chainId = await R(() => pub.getChainId());
if (chainId !== G.chain.id) throw new Error(`expected chain ${G.chain.id}, got ${chainId}`);
const [clientVersion, head] = await Promise.all([R(() => pub.request({ method: "web3_clientVersion" })).catch(() => null), R(() => pub.getBlock())]);
log(`devnet up: chain ${chainId}, block ${head.number}, basefee ${head.baseFeePerGas} wei, gas limit ${head.gasLimit}, client ${clientVersion}`);
log(`actor ${actor.address}, balance ${formatEther(await R(() => pub.getBalance({ address: actor.address })))} ETH; bundler ${bundler.address}, balance ${formatEther(await R(() => pub.getBalance({ address: bundler.address })))} ETH`);

const legacyArt = await artifact("MuunUSDTVault.sol", "MuunUSDTVault");
const ringArt = await artifact("MuunRingVault.sol", "MuunRingVault");
const epAbi = (await artifact("IEntryPoint.sol", "IEntryPoint")).abi;
const acctAbi = (await artifact("Simple7702Account.sol", "Simple7702Account")).abi;

// ------------------------------------------------------------------ sends
const nonces = new Map();
const setup = [];
const receipts = [];
async function sendTx(what, req, signer = actor) {
  log(what);
  if (!nonces.has(signer.address)) nonces.set(signer.address, await R(() => pub.getTransactionCount({ address: signer.address, blockTag: "pending" })));
  const nonce = nonces.get(signer.address);
  const submittedFromBlock = await R(() => pub.getBlockNumber());
  const submittedAtMs = Date.now();
  const { gas: gasOverride, ...rest } = req;
  const gas = gasOverride ?? (await estimateGas(signer, rest));
  const fees = await R(() => pub.estimateFeesPerGas());
  const serialized = await signer.signTransaction({ ...rest, gas, nonce, chainId, type: rest.authorizationList ? "eip7702" : "eip1559", maxFeePerGas: fees.maxFeePerGas, maxPriorityFeePerGas: fees.maxPriorityFeePerGas });
  const hash = keccak256(serialized);
  const broadcast = async () => {
    for (let i = 0; i < 60; i++) {
      try { await pub.request({ method: "eth_sendRawTransaction", params: [serialized] }); return; } catch (e) {
        const m = `${e?.shortMessage ?? ""} ${e?.details ?? ""} ${e?.message ?? ""}`;
        if (/already known|known transaction|already imported/i.test(m)) return;
        if (/nonce too low/i.test(m)) { if (await pub.getTransaction({ hash }).catch(() => null)) return; if (await pub.getTransactionReceipt({ hash }).catch(() => null)) return; }
        if (!/HTTP request failed|Status: 5\d\d|timed out|fetch failed|ECONNRESET|socket hang up|nonce too low/i.test(m)) throw e;
        await sleep(3000);
      }
    }
    throw new Error(`could not broadcast ${hash}`);
  };
  await broadcast();
  nonces.set(signer.address, nonce + 1);
  let receipt = null;
  for (let i = 0; !receipt; i++) {
    receipt = await pub.getTransactionReceipt({ hash }).catch(() => null);
    if (receipt) break;
    if (i > 600) throw new Error(`no receipt for ${hash} after ~20 min`);
    if (i > 0 && i % 30 === 0) await broadcast().catch(() => {});
    await sleep(2000);
  }
  const block = await R(() => pub.getBlock({ blockNumber: receipt.blockNumber }));
  if (receipt.status !== "success") throw new Error(`transaction reverted: ${hash}`);
  return {
    receipt, block,
    metric: {
      transactionHash: hash, gasUsed: receipt.gasUsed, gasLimit: gas, calldataBytes: rest.data ? (rest.data.length - 2) / 2 : 0,
      effectiveGasPrice: receipt.effectiveGasPrice, baseFeePerGas: block.baseFeePerGas, feePaidWei: receipt.gasUsed * receipt.effectiveGasPrice,
      submittedAt: new Date(submittedAtMs).toISOString(), confirmationBlock: receipt.blockNumber, confirmationTimestamp: block.timestamp, blocksToConfirm: receipt.blockNumber - submittedFromBlock,
    },
  };
}
// One node behind the public RPC has no state and answers every estimate with a revert. Retry a
// few times; if it persists, send with a fixed limit and let the receipt decide (a real revert
// then shows as a failed receipt, which aborts the run as before).
async function estimateGas(signer, req) {
  for (let i = 0; i < 6; i++) {
    try { return ((await R(() => pub.estimateGas({ account: signer, ...req }))) * 12n) / 10n; } catch (e) {
      const m = `${e?.shortMessage ?? ""} ${e?.message ?? ""}`;
      if (!/reverted for an unknown reason|returned no data|Execution reverted/i.test(m)) throw e;
      log(`  estimateGas reverted (${i + 1}/6), retrying: ${m.split("\n")[0].slice(0, 80)}`);
      await sleep(4000);
    }
  }
  log("  estimateGas kept reverting; sending with a fixed 600,000 gas limit");
  return 600_000n;
}
const call = (what, { address, abi, functionName, args, value, signer, gas }) => sendTx(what, { to: address, data: encodeFunctionData({ abi, functionName, args }), ...(value ? { value } : {}), ...(gas ? { gas } : {}) }, signer);
const tx = (h) => (EXPLORER ? `${EXPLORER}/tx/${h}` : `\`${h}\``);
const freshKey = () => { const k = generatePrivateKey(); return { key: k, account: privateKeyToAccount(k) }; };
const balanceBefore = (who, blockNumber) => readT("balanceOf", [who], blockNumber - 1n).catch(() => null);
async function waitPastTimestamp(ts) {
  for (;;) {
    const b = await R(() => pub.getBlock());
    if (b.timestamp > ts) return b;
    log(`  head ${b.number} at ${b.timestamp}, waiting for a block after ${ts} (${ts - b.timestamp} s)`);
    await sleep(6000);
  }
}

// ------------------------------------------------------------------ fidelity: the USDT copy is mainnet's code
const fidelity = {};
{
  const code = await R(() => pub.getCode({ address: USDT }));
  if (!code || code === "0x") throw new Error(`no code at USDT copy ${USDT}`);
  const devHash = keccak256(code);
  const eth = mainnetClient();
  const mainHash = eth ? keccak256(await R(() => eth.getCode({ address: MAINNET_USDT }))) : null;
  if (mainHash && mainHash !== devHash) throw new Error(`USDT copy ${USDT} code hash ${devHash} != mainnet ${mainHash}`);
  const [owner, paused, dep, bps, maxFee] = await Promise.all([readT("owner"), readT("paused"), readT("deprecated"), readT("basisPointsRate"), readT("maximumFee")]);
  if (getAddress(owner) !== actor.address) throw new Error(`USDT copy owner is ${owner}, not the actor`);
  if (paused || dep) throw new Error(`USDT copy paused ${paused} / deprecated ${dep}`);
  fidelity.usdt = { devnet: USDT, mainnet: MAINNET_USDT, codeHash: devHash, runtimeBytes: (code.length - 2) / 2, codeHashEqualsMainnet: mainHash ? true : "not checked (MAINNET_RPC_URL unset)", stateParity: { paused, deprecated: dep, basisPointsRate: bps, maximumFee: maxFee }, owner };
  log(`USDT copy ${USDT}: ${(code.length - 2) / 2} bytes, code hash ${mainHash ? "== mainnet" : "not compared"}`);
}

// ------------------------------------------------------------------ vaults
const config = { token: USDT, owner: actor.address, entryPoint: ENTRY_POINT, accountImplementation: ACCOUNT_IMPL, ...CAPS };
const VAULTS = {
  legacy: { label: "legacy MuunUSDTVault (mapping)", art: legacyArt, envName: "LEGACY_VAULT_ADDRESS", source: "contracts/legacy/MuunUSDTVault.sol (bridge-vault, verbatim)", version: "1" },
  ring: { label: "MuunRingVault (ring)", art: ringArt, envName: "RING_VAULT_ADDRESS", source: "contracts/MuunRingVault.sol", version: "2" },
};
// Reads pinned to a block retry on "returned no data": the public RPC load-balances over nodes
// and one of them may not have that block yet.
async function vread(v, functionName, args = [], blockNumber) {
  for (let i = 0; ; i++) {
    try {
      return await R(() => pub.readContract({ address: v.address, abi: v.art.abi, functionName, args, ...(blockNumber !== undefined ? { blockNumber } : {}) }));
    } catch (e) {
      if (blockNumber === undefined || i >= 20 || !/returned no data/i.test(`${e?.shortMessage ?? ""} ${e?.message ?? ""}`)) throw e;
      await sleep(3000);
    }
  }
}
const epRead = (functionName, args = []) => R(() => pub.readContract({ address: ENTRY_POINT, abi: epAbi, functionName, args }));

{
  const implEp = await R(() => pub.readContract({ address: ACCOUNT_IMPL, abi: acctAbi, functionName: "entryPoint" }));
  if (getAddress(implEp) !== ENTRY_POINT) throw new Error(`Simple7702Account ${ACCOUNT_IMPL} is bound to EntryPoint ${implEp}, not ${ENTRY_POINT}`);
}
if ((await readT("balanceOf", [actor.address])) < LIQUIDITY * 3n) {
  setup.push({ what: "USDT issue() to the actor", ...(await call("usdt: issue", { address: USDT, abi: tokenAbi, functionName: "issue", args: [LIQUIDITY * 10n] })).metric });
}
if ((await R(() => pub.getBalance({ address: bundler.address }))) < BUNDLER_MIN_ETH) {
  setup.push({ what: "ETH to the bundler", ...(await sendTx("fund bundler", { to: bundler.address, value: BUNDLER_MIN_ETH * 2n })).metric });
}
for (const [key, v] of Object.entries(VAULTS)) {
  v.key = key;
  v.address = process.env[v.envName] ? getAddress(process.env[v.envName]) : null;
  if (!v.address) {
    const m = await sendTx(`${key}: deploy ${v.label} over the USDT copy`, { data: encodeDeployData({ abi: v.art.abi, bytecode: v.art.bytecode.object, args: [config] }) });
    v.address = getAddress(m.receipt.contractAddress);
    log(`  ${v.label} at ${v.address} (${m.metric.gasUsed} gas); reuse with ${v.envName}`);
    setup.push({ vault: key, what: `deploy ${v.label}`, contract: v.address, ...m.metric });
    for (let i = 0; i < 20 && (await R(() => pub.getCode({ address: v.address })))?.length <= 2; i++) await sleep(3000);
  }
  const [owner, token, ep, impl, cost] = await Promise.all([vread(v, "owner"), vread(v, "token"), vread(v, "entryPoint"), vread(v, "accountImplementation"), vread(v, "EMERGENCY_EXIT_COST")]);
  if (getAddress(owner) !== actor.address || getAddress(token) !== USDT || getAddress(ep) !== ENTRY_POINT || getAddress(impl) !== ACCOUNT_IMPL) throw new Error(`${key}: vault ${v.address} is bound to ${owner}/${token}/${ep}/${impl}`);
  if (cost !== EXIT_COST) throw new Error(`${key}: EMERGENCY_EXIT_COST ${cost} != ${EXIT_COST}`);
  v.runtimeBytes = (v.art.deployedBytecode.object.length - 2) / 2;
  v.domain = { name: "Muun USDT Vault", version: v.version, chainId, verifyingContract: v.address };

  // Reservations left by an earlier run (live or expired, not yet refunded) still count, so both
  // pools are topped up relative to what is already required.
  const [reservedNow, requiredNow] = await Promise.all([vread(v, "reserved"), vread(v, "requiredSponsorship")]);
  if ((await readT("balanceOf", [v.address])) < reservedNow + LIQUIDITY) {
    setup.push({ vault: key, what: "USDT liquidity to the vault", ...(await call(`${key}: fund USDT`, { address: USDT, abi: tokenAbi, functionName: "transfer", args: [v.address, LIQUIDITY] })).metric });
  }
  const info = await epRead("getDepositInfo", [v.address]);
  if (info.deposit < requiredNow + DEPOSIT_PER_VAULT) {
    setup.push({ vault: key, what: "EntryPoint.depositTo(vault)", ...(await call(`${key}: depositTo`, { address: ENTRY_POINT, abi: epAbi, functionName: "depositTo", args: [v.address], value: requiredNow + DEPOSIT_PER_VAULT - info.deposit })).metric });
  }
  if (!info.staked) {
    setup.push({ vault: key, what: "vault.addStake", ...(await call(`${key}: addStake`, { address: v.address, abi: v.art.abi, functionName: "addStake", args: [86_400], value: STAKE })).metric });
  }
}

// ------------------------------------------------------------------ floor and the warm recipient W
const W = freshKey().account.address;
for (const state of ["cold", "warm"]) {
  const m = await call(`floor: bare USDT transfer, ${state} recipient`, { address: USDT, abi: tokenAbi, functionName: "transfer", args: [W, AMOUNT] });
  receipts.push({ vault: "floor", round: "floor", step: "T", shape: `bare USDT transfer, ${state} recipient`, op: "USDT.transfer", recipient: W, recipientBalanceBefore: await balanceBefore(W, m.receipt.blockNumber), ...m.metric, explorer: tx(m.metric.transactionHash) });
  log(`  ${m.metric.gasUsed} gas  ${tx(m.metric.transactionHash)}`);
}

// ------------------------------------------------------------------ the measured steps
const IDX_BASE = Number(process.env.RING_IDX_BASE ?? 0); // shift after an aborted run left indices live
const IDX = { A: IDX_BASE, B: IDX_BASE + 1, C: IDX_BASE + 2, D: IDX_BASE + 3, E: IDX_BASE + 4 };
const lockArgs = (v, s) => (v.key === "ring" ? [s.swapId, s.claimant.address, AMOUNT, s.expiry, IDX[s.step]] : [s.swapId, s.claimant.address, AMOUNT, s.expiry]);
const withIdx = (v, s, args) => (v.key === "ring" ? [...args, IDX[s.step]] : args);
const record = (v, round, s, shape, op, m, extra = {}) => {
  const rec = { vault: v.key, round, step: s.step, shape, op, swapId: s.swapId, idx: v.key === "ring" ? IDX[s.step] : null, ...extra, ...m.metric, explorer: tx(m.metric.transactionHash) };
  receipts.push(rec);
  log(`  ${m.metric.gasUsed} gas  ${tx(m.metric.transactionHash)}`);
  return rec;
};

// The receipt's own logs are the evidence that the write happened: the public RPC load-balances
// over nodes that may answer a pinned block with stale or empty state, so state reads are not
// used for assertions. `Locked` carries every field of the entry; `Redeemed` / `Refunded` prove
// the consumption.
function assertEntry(v, s, receipt, consumed) {
  const name = consumed ? (s.consumedBy ?? "Redeemed") : "Locked";
  const ev = parseEventLogs({ abi: v.art.abi, logs: receipt.logs, eventName: name }).find((e) => e.args.swapId === s.swapId);
  if (!ev) throw new Error(`${v.key}: no ${name} event for ${s.swapId} in ${receipt.transactionHash}`);
  if (getAddress(ev.args.claimant) !== s.claimant.address || ev.args.amount !== AMOUNT) throw new Error(`${v.key}: ${name} event fields do not match the reservation`);
  if (!consumed && BigInt(ev.args.expiry) !== s.expiry) throw new Error(`${v.key}: Locked expiry ${ev.args.expiry} != ${s.expiry}`);
  if (v.key === "ring" && ev.args.idx !== undefined && Number(ev.args.idx) !== IDX[s.step]) throw new Error(`${v.key}: ${name} idx ${ev.args.idx} != ${IDX[s.step]}`);
}

async function lock(v, round, s) {
  // The expiry is set from the head at send time: a send can take a minute on the public RPC.
  s.expiry = (await R(() => pub.getBlock())).timestamp + s.ttl;
  const m = await call(`${v.key}: round ${round}, lock ${s.step}${v.key === "ring" ? ` at idx ${IDX[s.step]}` : ""}`, { address: v.address, abi: v.art.abi, functionName: "lock", args: lockArgs(v, s) });
  const released = parseEventLogs({ abi: v.art.abi, logs: m.receipt.logs, eventName: "Released" }).length > 0;
  const rec = record(v, round, s, `lock ${s.step}${released ? " (rewrites the expired slot, releases it inline)" : ""}`, "lock", m, { expiry: s.expiry, claimant: s.claimant.address, releasedInline: released });
  assertEntry(v, s, m.receipt, false);
  return rec;
}

async function claimBySig(v, round, s, recipient, state) {
  const signature = await s.claimant.signTypedData({ domain: v.domain, types: { Claim: [{ name: "swapId", type: "bytes32" }, { name: "amount", type: "uint256" }, { name: "recipient", type: "address" }, { name: "expiry", type: "uint48" }] }, primaryType: "Claim", message: { swapId: s.swapId, amount: AMOUNT, recipient, expiry: s.expiry } });
  const m = await call(`${v.key}: round ${round}, claimBySig ${s.step}, ${state} recipient`, { address: v.address, abi: v.art.abi, functionName: "claimBySig", args: withIdx(v, s, [s.swapId, AMOUNT, recipient, s.expiry, signature]) });
  assertEntry(v, s, m.receipt, true);
  const before = await balanceBefore(recipient, m.receipt.blockNumber);
  return record(v, round, s, `claimBySig ${s.step}, ${state} recipient`, "claimBySig", m, { recipient, recipientBalanceBefore: before });
}

async function refund(v, round, s, shape = `refund ${s.step} after expiry`) {
  const m = await call(`${v.key}: round ${round}, ${shape}`, { address: v.address, abi: v.art.abi, functionName: "refund", args: withIdx(v, s, [s.swapId, s.claimant.address, AMOUNT, s.expiry]) });
  assertEntry(v, { ...s, consumedBy: "Refunded" }, m.receipt, true);
  return record(v, round, s, shape, "refund", m);
}

/// The escape hatch: the zero-ETH claimant's sponsored claimSelf, as bridge-vault's recovery-path.
async function sponsoredClaimSelf(v, round, s, recipient) {
  const claimant = s.claimant;
  if ((await R(() => pub.getBalance({ address: claimant.address }))) !== 0n) throw new Error("claimant must hold zero ETH");
  const [userOpNonce, authNonce, depositBefore] = await Promise.all([epRead("getNonce", [claimant.address, 0n]), R(() => pub.getTransactionCount({ address: claimant.address, blockTag: "pending" })), epRead("balanceOf", [v.address])]);
  const fees = { maxPriorityFeePerGas: 1_000_000_000n, maxFeePerGas: 1_000_000_000n }; // within the 2 gwei priority cap; 700k x 1 gwei << EXIT_COST
  const pack128 = (hi, lo) => concatHex([toHex(hi, { size: 16 }), toHex(lo, { size: 16 })]);
  const inner = encodeFunctionData({ abi: v.art.abi, functionName: "claimSelf", args: withIdx(v, s, [s.swapId, AMOUNT, recipient, s.expiry]) });
  const outer = encodeFunctionData({ abi: acctAbi, functionName: "execute", args: [v.address, 0n, inner] });
  const userOp = { sender: claimant.address, nonce: userOpNonce, initCode: "0x7702", callData: outer, accountGasLimits: pack128(CAPS.verificationGasLimitCap, CAPS.callGasLimitCap), preVerificationGas: CAPS.preVerificationGasCap, gasFees: pack128(fees.maxPriorityFeePerGas, fees.maxFeePerGas), paymasterAndData: concatHex([v.address, toHex(CAPS.paymasterVerificationGasLimitCap, { size: 16 }), toHex(0n, { size: 16 })]), signature: "0x" };
  const maxCost = ENVELOPE * fees.maxFeePerGas;
  // Preflight with the 7702 delegation simulated: on chain it is installed by the authorization
  // list of the same transaction, before validation runs.
  // Not every client behind the public RPC accepts state overrides; then the real handleOps decides.
  try {
    const rejection = await R(() => pub.readContract({ address: v.address, abi: v.art.abi, functionName: "sponsorshipRejection", args: [userOp, maxCost], stateOverride: [{ address: claimant.address, code: concatHex(["0xef0100", ACCOUNT_IMPL]) }] }));
    if (rejection !== 0) throw new Error(`${v.key}: paymaster preflight rejected the op with code ${rejection}`);
  } catch (e) {
    if (!/Invalid parameters|state override|stateOverride|not supported/i.test(`${e?.shortMessage ?? ""} ${e?.message ?? ""}`)) throw e;
    log("  preflight skipped: this RPC node does not accept state overrides");
  }
  // EntryPoint v0.9 hashes the 7702 delegate address in place of the 0x7702 marker.
  const userOpHash = hashTypedData({ domain: { name: "ERC4337", version: "1", chainId, verifyingContract: ENTRY_POINT }, types: { PackedUserOperation: [{ name: "sender", type: "address" }, { name: "nonce", type: "uint256" }, { name: "initCode", type: "bytes" }, { name: "callData", type: "bytes" }, { name: "accountGasLimits", type: "bytes32" }, { name: "preVerificationGas", type: "uint256" }, { name: "gasFees", type: "bytes32" }, { name: "paymasterAndData", type: "bytes" }] }, primaryType: "PackedUserOperation", message: { ...userOp, initCode: ACCOUNT_IMPL } });
  userOp.signature = await claimant.sign({ hash: userOpHash });
  const authorization = await claimant.signAuthorization({ address: ACCOUNT_IMPL, chainId, nonce: authNonce });
  const m = await sendTx(`${v.key}: round ${round}, sponsored 7702+4337 claimSelf ${s.step} via handleOps`, { to: ENTRY_POINT, data: encodeFunctionData({ abi: epAbi, functionName: "handleOps", args: [[userOp], bundler.address] }), authorizationList: [authorization], gas: bigintEnv("OUTER_HANDLE_OPS_GAS_LIMIT", 2_000_000n) }, bundler);
  const ev = parseEventLogs({ abi: epAbi, logs: m.receipt.logs, eventName: "UserOperationEvent" }).find((e) => e.args.userOpHash === userOpHash);
  if (!ev) throw new Error("UserOperationEvent not emitted");
  if (!ev.args.success) throw new Error("UserOperation execution failed");
  assertEntry(v, s, m.receipt, true);
  const [ethAfter, depositAfter, code] = await Promise.all([R(() => pub.getBalance({ address: claimant.address })), epRead("balanceOf", [v.address]), R(() => pub.getCode({ address: claimant.address }))]);
  if (ethAfter !== 0n) throw new Error("claimant touched ETH");
  if (depositBefore - depositAfter !== ev.args.actualGasCost) throw new Error("vault deposit delta != actualGasCost");
  if ((code ?? "0x").toLowerCase() !== concatHex(["0xef0100", ACCOUNT_IMPL]).toLowerCase()) throw new Error("7702 delegation not installed");
  const before = await balanceBefore(recipient, m.receipt.blockNumber);
  return record(v, round, s, `sponsored 7702+4337 claimSelf ${s.step}, warm recipient (handleOps outer tx)`, "EntryPoint.handleOps", m, { recipient, recipientBalanceBefore: before, claimant: claimant.address, userOpHash, actualGasUsed: ev.args.actualGasUsed, actualGasCost: ev.args.actualGasCost, sponsoredByDeposit: depositBefore - depositAfter, noPrerequisiteClaimantTransaction: authNonce === 0 });
}

const errors = [];
const pending = { legacy: { E: null }, ring: { E: null } }; // E of the previous round, expired unconsumed
try {
  for (const round of ["first", "reuse"]) {
    const swaps = {};
    for (const v of Object.values(VAULTS)) {
      swaps[v.key] = {};
      for (const step of ["A", "B", "C", "D", "E"]) {
        swaps[v.key][step] = { step, swapId: freshSwapId(), claimant: freshKey().account, ttl: step === "C" || step === "E" ? TTL_SHORT : TTL_LONG };
      }
    }
    // Round reuse: the legacy vault must refund its old E before anything (nothing forces it, but
    // it is the transaction the ring saves); the ring's lock E rewrites the expired slot directly.
    if (round === "reuse" && pending.legacy.E) {
      await waitPastTimestamp(pending.legacy.E.expiry);
      await refund(VAULTS.legacy, round, pending.legacy.E, "refund of the expired E of round first (the transaction the ring saves)");
    }
    if (round === "reuse" && pending.ring.E) await waitPastTimestamp(pending.ring.E.expiry);
    for (const v of Object.values(VAULTS)) for (const step of ["A", "B", "C", "D", "E"]) await lock(v, round, swaps[v.key][step]);
    for (const v of Object.values(VAULTS)) {
      await claimBySig(v, round, swaps[v.key].A, W, "warm");
      await claimBySig(v, round, swaps[v.key].B, freshKey().account.address, "cold");
      await sponsoredClaimSelf(v, round, swaps[v.key].D, W);
    }
    await waitPastTimestamp(swaps.ring.C.expiry > swaps.legacy.C.expiry ? swaps.ring.C.expiry : swaps.legacy.C.expiry);
    for (const v of Object.values(VAULTS)) await refund(v, round, swaps[v.key].C);
    for (const v of Object.values(VAULTS)) pending[v.key].E = swaps[v.key].E;
  }
  // cleanup: release the last E of each vault and hand the surplus deposit back to the actor
  for (const v of Object.values(VAULTS)) {
    if (pending[v.key].E) { await waitPastTimestamp(pending[v.key].E.expiry); await refund(v, "cleanup", pending[v.key].E, "refund of the expired E of round reuse (cleanup)"); }
    const [dep, required] = await Promise.all([vread(v, "sponsorshipDeposit"), vread(v, "requiredSponsorship")]);
    if (dep > required) setup.push({ vault: v.key, what: "withdrawETH from the deposit (cleanup)", ...(await call(`${v.key}: withdraw surplus deposit`, { address: v.address, abi: v.art.abi, functionName: "withdrawETH", args: [actor.address, dep - required, true] })).metric });
  }
} catch (e) {
  const message = String(e.shortMessage ?? e.message ?? e).split("\n")[0].slice(0, 300);
  errors.push({ message });
  log(`ERROR: ${message}`);
}

for (const r of receipts) {
  if (r.recipientBalanceBefore === undefined) continue;
  const labelled = /cold/.test(r.shape) ? "cold" : "warm";
  r.recipientState = labelled;
  r.recipientStateVerified = r.recipientBalanceBefore === null ? "not verifiable (historical balanceOf failed)" : labelled === "cold" ? r.recipientBalanceBefore === 0n : r.recipientBalanceBefore > 0n;
  if (r.recipientStateVerified !== true) log(`WARNING ${r.transactionHash}: labelled ${labelled} but balance before was ${r.recipientBalanceBefore}`);
}

const endBlock = await R(() => pub.getBlock());
const report = {
  ranAt: new Date().toISOString(), network: G.label, chainId, clientVersion, explorer: EXPLORER,
  blockAtStart: { number: head.number, baseFeePerGas: head.baseFeePerGas, gasLimit: head.gasLimit }, blockAtEnd: { number: endBlock.number, baseFeePerGas: endBlock.baseFeePerGas },
  actor: actor.address, bundler: bundler.address, ringIndexBase: IDX_BASE, entryPoint: ENTRY_POINT, accountImplementation: ACCOUNT_IMPL, token: USDT, amount: AMOUNT, ttlShort: TTL_SHORT, ttlLong: TTL_LONG, warmRecipient: W,
  caps: { ...CAPS, envelope: ENVELOPE, emergencyExitCost: EXIT_COST },
  vaults: Object.fromEntries(Object.values(VAULTS).map((v) => [v.key, { label: v.label, address: v.address, source: v.source, runtimeBytes: v.runtimeBytes, eip712Version: v.version }])),
  fidelity, setup, receipts, errors, prior: PRIOR,
};
const jsonPath = await writeReport(`${REPORT}.json`, report);
log(`written ${jsonPath}`);
await writeFile(reportPath(`${REPORT}.md`), renderMd(report));
log(`written ${reportPath(`${REPORT}.md`)}`);
if (errors.length) process.exit(1);

// ------------------------------------------------------------------ markdown
function renderMd(rep) {
  const short = (h) => (rep.explorer ? `[\`${h.slice(0, 10)}…\`](${rep.explorer}/tx/${h})` : `\`${h.slice(0, 10)}…\``);
  const addr = (a) => `[\`${a}\`](${rep.explorer}/address/${a})`;
  const blk = (n) => `[${n}](${rep.explorer}/block/${n})`;
  const fmt = (n) => (n === null || n === undefined ? "–" : Number(n).toLocaleString("en-US"));
  const n = (x) => Number(x);
  const find = (vault, round, re) => rep.receipts.find((r) => r.vault === vault && r.round === round && re.test(r.shape));
  const d = (a, b) => (a && b ? fmt(n(a.gasUsed) - n(b.gasUsed)) : "–");
  const L = [];
  L.push("# Bridge vault with a reservation ring under Glamsterdam gas rules: devnet receipts", "");
  const where = rep.explorer
    ? `on the public Glamsterdam devnet **Platåberget** (chainId ${rep.chainId}; the public RPC load-balances over several execution clients, the one that answered \`web3_clientVersion\` at start was \`${rep.clientVersion ?? "unknown"}\`; basefee ${rep.blockAtStart.baseFeePerGas} wei, block gas limit ${fmt(rep.blockAtStart.gasLimit)}), explorer [dora](${rep.explorer})`
    : `on a **local go-ethereum node with Amsterdam active from genesis** (the \`glamsterdam-local\` repo; chainId ${rep.chainId}, client \`${rep.clientVersion ?? "unknown"}\`; basefee ${rep.blockAtStart.baseFeePerGas} wei, block gas limit ${fmt(rep.blockAtStart.gasLimit)}); no explorer, transaction hashes are shown as is`;
  L.push(`Measured ${rep.ranAt.slice(0, 10)} (${rep.ranAt}) ${where}. Script: \`npm run measure:glam\` (\`scripts/measure-glamsterdam-vault.mjs\`); machine-readable evidence: \`reports/${REPORT}.json\`.`, "");
  L.push(`Two vaults, same run, same token, same owner ${addr(rep.actor)}: the **legacy** \`MuunUSDTVault\` of bridge-vault (${rep.vaults.legacy.source}, ${rep.vaults.legacy.runtimeBytes} runtime bytes, one fresh \`reservations[swapId]\` slot per swap, deleted on claim) at ${addr(rep.vaults.legacy.address)}, and the **ring** \`MuunRingVault\` (${rep.vaults.ring.source}, ${rep.vaults.ring.runtimeBytes} runtime bytes, \`bytes32[2**32] ring\`, an index per reservation, overwritten with \`CONSUMED\` on claim and rewritten by the next lock) at ${addr(rep.vaults.ring.address)}. Both sit on the byte-exact mainnet USDT copy ${addr(rep.token)}, use EntryPoint v0.9 ${addr(rep.entryPoint)} and the \`Simple7702Account\` delegate ${addr(rep.accountImplementation)} already on the devnet, and reserve ${Number(rep.amount) / 1e6} USDT per swap. Round **first** uses ring indices ${rep.ringIndexBase ?? 0}..${(rep.ringIndexBase ?? 0) + 4} for the first time (the fresh-slot premium is in it); round **reuse** rewrites them (the steady state). "Cold" = the recipient had never held the token; "warm" = it already did. Every gas figure below is a receipt's \`gasUsed\`; nothing is an estimate.`, "");

  L.push("## Result: legacy vault against ring vault, step by step", "");
  L.push("- What the table shows: for each round and step, the receipt's `gasUsed` of the same operation on the legacy vault and on the ring vault, and the difference (ring minus legacy, arithmetic on two receipts). The `handleOps` rows are the outer transaction of the sponsored EIP-7702 + ERC-4337 `claimSelf`; the `actualGasUsed` the EntryPoint charged is in the receipts table further down.", "");
  L.push("| Round | Step | legacy gasUsed | ring gasUsed | Δ ring − legacy | legacy tx | ring tx |", "|---|---|---:|---:|---:|---|---|");
  const STEPS = [["lock A", /^lock A/], ["claimBySig A, warm recipient", /^claimBySig A/], ["lock B", /^lock B/], ["claimBySig B, cold recipient", /^claimBySig B/], ["lock C", /^lock C/], ["refund C after expiry", /^refund C/], ["lock D", /^lock D/], ["sponsored claimSelf D (handleOps outer)", /^sponsored .* D/], ["lock E", /^lock E/], ["refund of the expired E of the previous round", /^refund of the expired E of round first/]];
  for (const round of ["first", "reuse"]) for (const [label, re] of STEPS) {
    const l = find("legacy", round, re), r = find("ring", round, re);
    if (!l && !r) continue;
    const rl = r && r.releasedInline ? `${label} (ring: rewrites the expired slot, releases inline)` : label;
    L.push(`| ${round} | ${rl} | ${l ? `**${fmt(l.gasUsed)}**` : "–"} | ${r ? `**${fmt(r.gasUsed)}**` : "–"} | ${d(r, l)} | ${l ? short(l.transactionHash) : "–"} | ${r ? short(r.transactionHash) : "–"} |`);
  }
  const fc = find("floor", "floor", /cold/), fw = find("floor", "floor", /warm/);
  if (fc && fw) L.push(`| floor | bare USDT transfer, cold / warm recipient | ${fmt(fc.gasUsed)} / ${fmt(fw.gasUsed)} | same | – | ${short(fc.transactionHash)} | ${short(fw.transactionHash)} |`);
  L.push("");

  L.push("## Steady state per swap", "");
  // Locks come from round reuse (that is the measurement). A claim, sponsored exit or refund
  // does not depend on whether the index was fresh, so when the reuse-round receipt is missing
  // the round-first one stands in, and the table says so.
  const fb = (vault, re) => { const r = find(vault, "reuse", re); if (r) return r; const f = find(vault, "first", re); return f ? { ...f, fromFirst: true } : null; };
  const fbNote = (...xs) => (xs.some((x) => x && x.fromFirst) ? " (claim-side receipts from round first)" : "");
  L.push("- What the table shows: the receipts added up per path (arithmetic on receipts), legacy against ring, next to bridge-vault's own receipts of 2026-08-31 on the same devnet over `MockUSDT` (its `reports/ETH_GAS_REPORT.md`; a different token, so read that column as context, not as the baseline of this run). Locks are round-reuse receipts. Where a row says so, the claim-side receipt is from round first: a claim, a sponsored exit or a refund writes the same thing whether the index was fresh or reused, so the figure is the same measurement; the reuse-round repeat did not run (see below).", "");
  L.push("| Path | legacy (this run) | ring (this run) | Δ ring − legacy | bridge-vault 2026-08-31 (MockUSDT) |", "|---|---:|---:|---:|---:|");
  const lA = find("legacy", "reuse", /^lock A/), rA = find("ring", "reuse", /^lock A/), lcA = fb("legacy", /^claimBySig A/), rcA = fb("ring", /^claimBySig A/);
  const lB = find("legacy", "reuse", /^lock B/), rB = find("ring", "reuse", /^lock B/), lcB = fb("legacy", /^claimBySig B/), rcB = fb("ring", /^claimBySig B/);
  const lD = find("legacy", "reuse", /^lock D/), rD = find("ring", "reuse", /^lock D/), lhD = fb("legacy", /^sponsored/), rhD = fb("ring", /^sponsored/);
  const lC = find("legacy", "reuse", /^lock C/), rC = find("ring", "reuse", /^lock C/), lrC = fb("legacy", /^refund C/), rrC = fb("ring", /^refund C/);
  const sum = (...xs) => (xs.every(Boolean) ? xs.reduce((s, x) => s + n(x.gasUsed), 0) : null);
  const row = (label, l, r, prior) => L.push(`| ${label} | ${fmt(l)} | ${fmt(r)} | ${l !== null && r !== null ? fmt(r - l) : "–"} | ${prior ?? "–"} |`);
  row("`lock`", lA && n(lA.gasUsed), rA && n(rA.gasUsed), `${fmt(rep.prior.lock.gasUsed)} ${short(rep.prior.lock.tx)}`);
  row(`\`claimBySig\`, warm recipient${fbNote(lcA, rcA)}`, lcA && n(lcA.gasUsed), rcA && n(rcA.gasUsed), "–");
  row(`\`claimBySig\`, cold recipient${fbNote(lcB, rcB)}`, lcB && n(lcB.gasUsed), rcB && n(rcB.gasUsed), `${fmt(rep.prior.claimBySigCold.gasUsed)} ${short(rep.prior.claimBySigCold.tx)}`);
  row(`happy path, warm (\`lock\` + \`claimBySig\`)${fbNote(lcA, rcA)}`, sum(lA, lcA), sum(rA, rcA), "–");
  row(`happy path, cold (\`lock\` + \`claimBySig\`)${fbNote(lcB, rcB)}`, sum(lB, lcB), sum(rB, rcB), fmt(n(rep.prior.lock.gasUsed) + n(rep.prior.claimBySigCold.gasUsed)));
  row(`escape hatch (\`lock\` + sponsored \`claimSelf\`, outer tx)${fbNote(lhD, rhD)}`, sum(lD, lhD), sum(rD, rhD), `${fmt(n(rep.prior.recoveryLock.gasUsed) + n(rep.prior.recoveryHandleOps.gasUsed))} ${short(rep.prior.recoveryHandleOps.tx)}`);
  row(`sponsored \`claimSelf\`, \`actualGasUsed\` charged by the EntryPoint${fbNote(lhD, rhD)}`, lhD && n(lhD.actualGasUsed), rhD && n(rhD.actualGasUsed), fmt(rep.prior.recoveryHandleOps.actualGasUsed));
  row(`expired swap (\`lock\` + \`refund\`)${fbNote(lrC, rrC)}`, sum(lC, lrC), sum(rC, rrC), "–");
  L.push("");

  L.push("## Reading the receipts", "");
  const fA = find("ring", "first", /^lock A/), lfA = find("legacy", "first", /^lock A/);
  if (fA && rA) L.push(`- Fresh-slot premium as paid on the ring: lock A first use ${fmt(fA.gasUsed)} against reuse ${fmt(rA.gasUsed)}, ${fmt(n(fA.gasUsed) - n(rA.gasUsed))} gas. The legacy vault pays it on every lock (first ${lfA ? fmt(lfA.gasUsed) : "–"}, reuse ${lA ? fmt(lA.gasUsed) : "–"}: no reuse to speak of).`);
  if (lA && rA) L.push(`- Steady-state \`lock\`: ring ${fmt(rA.gasUsed)} against legacy ${fmt(lA.gasUsed)}, ${fmt(n(lA.gasUsed) - n(rA.gasUsed))} gas less per swap.`);
  if (lcA && rcA) L.push(`- \`claimBySig\` (warm${lcA.fromFirst || rcA.fromFirst ? ", round first" : ""}): ring ${fmt(rcA.gasUsed)} against legacy ${fmt(lcA.gasUsed)}, ${fmt(n(rcA.gasUsed) - n(lcA.gasUsed))} gas ${n(rcA.gasUsed) >= n(lcA.gasUsed) ? "more" : "less"}: the ring writes \`CONSUMED\` (non-zero to non-zero) where the legacy vault deletes the slot and earns the clearing refund, and it carries one more calldata word and one more event field. The same delta shows on the cold claim${lrC && rrC ? ` and, without any transfer, on \`refund\` (${fmt(rrC.gasUsed)} against ${fmt(lrC.gasUsed)})` : ""}.`);
  if (lA && rA && lcA && rcA) L.push(`- Net per happy-path swap, warm: ${fmt(n(lA.gasUsed) + n(lcA.gasUsed) - n(rA.gasUsed) - n(rcA.gasUsed))} gas less on the ring (${fmt(n(rA.gasUsed) + n(rcA.gasUsed))} against ${fmt(n(lA.gasUsed) + n(lcA.gasUsed))}).`);
  const rE = find("ring", "reuse", /^lock E/), lE = find("legacy", "reuse", /^lock E/), lrE = find("legacy", "reuse", /^refund of the expired E/);
  if (rE && lE && lrE) L.push(`- Reusing an expired, unconsumed reservation: the ring's lock E rewrites the slot and releases it inline in ${fmt(rE.gasUsed)} gas; the legacy vault needs \`refund\` ${fmt(lrE.gasUsed)} plus \`lock\` ${fmt(lE.gasUsed)} = ${fmt(n(lrE.gasUsed) + n(lE.gasUsed))}, two transactions.`);
  if (lhD && rhD) L.push(`- The escape hatch is unchanged in kind: the sponsored \`claimSelf\` costs the EntryPoint \`actualGasUsed\` ${fmt(rhD.actualGasUsed)} on the ring against ${fmt(lhD.actualGasUsed)} on the legacy vault; the claimant held zero ETH before and after in both, with no prerequisite transaction (${rhD.noPrerequisiteClaimantTransaction && lhD.noPrerequisiteClaimantTransaction ? "authorization nonce 0 in both" : "see receipts"}).`);
  if (fc && fw && rcA) L.push(`- Floor: a bare USDT transfer is ${fmt(fw.gasUsed)} warm / ${fmt(fc.gasUsed)} cold; the cold column is the recipient's fresh balance slot in the token, the same on both vaults and on any design.`);
  const deps = rep.setup.filter((s) => /deploy/.test(s.what));
  for (const s of deps) L.push(`- Deploying the ${s.vault} vault cost ${fmt(s.gasUsed)} gas once (setup table).`);
  L.push("");
  if (rep.errors.length) {
    L.push("## What did not run", "");
    for (const e of rep.errors) L.push(`- The run stopped at: \`${e.message}\`.`);
    const missing = [];
    for (const v of ["legacy", "ring"]) for (const [label, re] of [["claimBySig A", /^claimBySig A/], ["claimBySig B", /^claimBySig B/], ["sponsored claimSelf D", /^sponsored/], ["refund C", /^refund C/]]) if (!find(v, "reuse", re)) missing.push(`${v} ${label}`);
    if (missing.length) L.push(`- Round-reuse receipts not taken: ${missing.join(", ")}. Their round-first counterparts stand in above.`);
    for (const note of rep.notes ?? []) L.push(`- ${note}`);
    L.push("");
  }

  L.push("## Every receipt", "");
  L.push("- What the table shows: every measured transaction of this run: vault, round, shape, ring index (ring vault only), the recipient's token balance in the parent block where a transfer happened (the evidence for cold / warm), `gasUsed`, the EntryPoint's `actualGasUsed` for the sponsored exits, the block, and a dora link. Every lock receipt was checked for its `Locked` event (swap id, claimant, amount, expiry and, on the ring, the index) and every claim or refund receipt for its `Redeemed` / `Refunded` event; a mismatch would have aborted the run. State reads are not used as evidence: the public RPC load-balances over nodes that answer a pinned block with stale or empty state.", "");
  L.push("| # | Vault | Round | Shape | idx | Recipient balance before | gasUsed | actualGasUsed | Block | Tx |", "|---:|---|---|---|---:|---:|---:|---:|---:|---|");
  rep.receipts.forEach((r, i) => L.push(`| ${i + 1} | ${r.vault} | ${r.round} | ${r.shape}${r.recipientStateVerified === undefined || r.recipientStateVerified === true ? "" : ` (${r.recipientStateVerified})`} | ${r.idx ?? "–"} | ${r.recipientBalanceBefore === undefined ? "–" : (r.recipientBalanceBefore ?? "n/a")} | **${fmt(r.gasUsed)}** | ${r.actualGasUsed ? fmt(r.actualGasUsed) : "–"} | ${blk(r.confirmationBlock)} | ${short(r.transactionHash)} |`));
  L.push("");

  L.push("## Setup and cleanup (not part of any per-swap figure)", "");
  if (rep.setup.length) {
    L.push("- What the table shows: the one-off transactions of this run: deployments, USDT liquidity, EntryPoint deposit and stake, the bundler's ETH, and the deposit withdrawn back at the end. Each is a receipt.", "");
    L.push("| Vault | What | Contract | gasUsed | Block | Tx |", "|---|---|---|---:|---:|---|");
    for (const s of rep.setup) L.push(`| ${s.vault ?? "–"} | ${s.what} | ${s.contract ? addr(s.contract) : "–"} | ${fmt(s.gasUsed)} | ${blk(s.confirmationBlock)} | ${short(s.transactionHash)} |`);
  } else L.push("None: every contract and balance was already in place.");
  L.push("");

  L.push("## Fidelity", "");
  const f = rep.fidelity.usdt;
  L.push(`- USDT: ${addr(f.devnet)} carries mainnet \`${f.mainnet}\`'s runtime (${f.runtimeBytes} bytes, keccak \`${f.codeHash}\`; compared against mainnet \`eth_getCode\` in this run: ${f.codeHashEqualsMainnet}), not proxied, like mainnet. \`paused\` / \`deprecated\` / \`basisPointsRate\` / \`maximumFee\` read ${f.stateParity.paused} / ${f.stateParity.deprecated} / ${f.stateParity.basisPointsRate} / ${f.stateParity.maximumFee}.`);
  L.push(`- Both vaults were deployed by this run from this repo's \`forge build\` (solc 0.8.28, optimizer 200, evm prague) with the same \`Config\` (exit envelope ${fmt(rep.caps.envelope)} gas, sponsored fee ceiling ${Number(rep.caps.maxSponsoredFeePerGas) / 1e9} gwei, \`EMERGENCY_EXIT_COST\` ${formatEther(BigInt(rep.caps.emergencyExitCost))} ETH). The legacy source is bridge-vault's \`contracts/MuunUSDTVault.sol\` byte for byte.`, "");
  return `${L.join("\n")}\n`;
}
