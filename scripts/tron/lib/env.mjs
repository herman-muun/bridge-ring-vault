import { readFileSync, writeFileSync } from "node:fs";
import tw from "tronweb";

const { TronWeb } = tw;

function parseEnvFile(path) {
  const out = {};
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return out;
  }
  for (const line of text.split("\n")) {
    const t = line.trim();
    if (!t || t.startsWith("#")) continue;
    const i = t.indexOf("=");
    if (i > 0) out[t.slice(0, i)] = t.slice(i + 1);
  }
  return out;
}

// .env holds shared/manual settings (including the TronGrid key); .env.nile holds
// the generated Nile keyset and takes precedence where both define a name.
export function loadEnv() {
  const shared = parseEnvFile(new URL("../../../.env", import.meta.url));
  const nile = parseEnvFile(new URL("../../../.env.nile", import.meta.url));
  const env = { ...shared, ...nile };
  // Accept either spelling of the TronGrid key.
  env.TRONGRID_API_KEY =
    env.TRONGRID_API_KEY || env.TRON_GRID_API_KEY || shared.TRON_GRID_API_KEY || "";
  return env;
}

export function client(env, privateKey) {
  const opts = { fullHost: env.TRON_FULL_HOST, privateKey };
  if (env.TRONGRID_API_KEY) opts.headers = { "TRON-PRO-API-KEY": env.TRONGRID_API_KEY };
  return new TronWeb(opts);
}

export const trx = (sun) => Number(sun) / 1e6;

// getTransactionInfo only answers once the block has solidified (~60-90s on Nile),
// which is far too slow for flow control. Poll the unconfirmed view instead; it
// carries the same receipt.energy_usage_total and fee fields we measure from.
export async function waitForReceipt(t, txid, timeoutMs = 90_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    for (const method of ["getUnconfirmedTransactionInfo", "getTransactionInfo"]) {
      const info = await t.trx[method](txid).catch(() => null);
      if (info && info.id) return info;
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(`no receipt for ${txid} after ${timeoutMs}ms`);
}

export function saveEnv(key, value, path = new URL("../../../.env.nile", import.meta.url)) {
  let s = readFileSync(path, "utf8");
  const line = `${key}=${value}`;
  s = new RegExp(`^${key}=.*$`, "m").test(s)
    ? s.replace(new RegExp(`^${key}=.*$`, "m"), line)
    : s.replace(/\n*$/, `\n${line}\n`);
  writeFileSync(path, s, { mode: 0o600 });
}

// TronGrid load-balances across full nodes whose views can lag. Polling until two
// reads agree does NOT detect a consistently-stale node - it just agrees with itself.
// Read confirmed state from the solidity node instead, which only advances on
// solidified blocks and is therefore never ahead of, or behind, itself.
export async function confirmedBalance(t, address) {
  const r = await fetch(`${t.fullNode.host}/walletsolidity/getaccount`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ address, visible: true }),
  });
  const j = await r.json();
  return j.balance ?? 0;
}

// The solidity node trails the head by ~19 blocks (~1 min) on Nile, which is right
// for final assertions but too slow for flow control. This reads the head instead.
export async function freshBalance(t, address) {
  const r = await fetch(`${t.fullNode.host}/wallet/getaccount`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ address, visible: true }),
  });
  const j = await r.json();
  return j.balance ?? 0;
}

// Waits until the solidified view reflects a transaction, so balance assertions
// taken afterwards cannot read pre-transaction state.
export async function waitSolidified(t, blockNumber, timeoutMs = 180_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const r = await fetch(`${t.fullNode.host}/walletsolidity/getnowblock`, { method: "POST" });
    const n = (await r.json())?.block_header?.raw_data?.number ?? 0;
    if (n >= blockNumber) return n;
    await new Promise((x) => setTimeout(x, 2000));
  }
  throw new Error(`block ${blockNumber} not solidified within ${timeoutMs}ms`);
}
