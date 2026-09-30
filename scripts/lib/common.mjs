// Runner plumbing: env, the devnet chain, retrying sends, reports. Same measurement shape as
// storage-proof-ring-swap and bridge-vault so the receipts stay comparable across repos.
import { config as loadEnv } from "dotenv";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import { dirname, resolve } from "node:path";
import { createPublicClient, http, keccak256, toHex } from "viem";
import { mainnet } from "viem/chains";

loadEnv({ path: resolve(".env"), quiet: true });

export const ZERO_BYTES32 = `0x${"00".repeat(32)}`;

/// Glamsterdam devnet "plataberget" (EIP-8037 / EIP-8038 gas rules). Public RPC as fallback.
/// GLAMSTERDAM_CHAIN_ID selects another chain with the same rules, e.g. the local geth 1.17.6
/// node of the glamsterdam-local repo (chain 70910475), which has no explorer.
const CHAIN_ID = Number(process.env.GLAMSTERDAM_CHAIN_ID ?? 7_091_047_534);
const LOCAL = CHAIN_ID !== 7_091_047_534;
const RPC_URL = process.env.GLAMSTERDAM_RPC_URL ?? (LOCAL ? "http://127.0.0.1:8545" : "https://rpc.plataberget.ethpandaops.io");
export const GLAMSTERDAM = {
  chain: {
    id: CHAIN_ID,
    name: LOCAL ? `local Glamsterdam node (chain ${CHAIN_ID})` : "Glamsterdam devnet (plataberget)",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [RPC_URL] } },
  },
  rpcUrl: RPC_URL,
  explorer: LOCAL ? null : "https://dora.plataberget.ethpandaops.io",
  label: LOCAL ? `local geth node with Amsterdam active (glamsterdam-local, chain ${CHAIN_ID})` : "Glamsterdam devnet (plataberget)",
  local: LOCAL,
};

export function requiredEnv(name) {
  const value = process.env[name];
  if (!value || value === "0x" || /^0x0{40}$/i.test(value)) throw new Error(`${name} is required and cannot be zero`);
  return value;
}
export function privateKeyEnv(name) {
  const value = process.env[name];
  if (!value || value === "0x") throw new Error(`${name} is required`);
  return value.startsWith("0x") ? value : `0x${value}`;
}
export function bigintEnv(name, fallback) {
  const value = process.env[name];
  return value === undefined || value === "" ? fallback : BigInt(value);
}

/// Mainnet read-only client for the fidelity check of the token copy; null when not configured.
export function mainnetClient() {
  const url = process.env.MAINNET_RPC_URL;
  if (!url) return null;
  return createPublicClient({ chain: mainnet, transport: http(url, { retryCount: 3, retryDelay: 1000 }), cacheTime: 0 });
}

export async function artifact(sourceName, contractName) {
  return JSON.parse(await readFile(resolve("out", sourceName, `${contractName}.json`), "utf8"));
}

export const freshSwapId = () => keccak256(toHex(randomBytes(32)));
export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/// HTTP-level failures, and an empty answer from a load-balanced node that lags behind the head
/// (a read pinned to a recent block or of a just-deployed contract comes back as "0x" there).
export const isHttpError = (e) =>
  /HTTP request failed|Status: 5\d\d|timed out|fetch failed|ECONNRESET|socket hang up|took too long|returned no data/i.test(`${e?.shortMessage ?? ""} ${e?.message ?? ""}`);

/// Retry transient failures only (the public RPC answers 503 now and then); real reverts throw.
export async function retryHttp(fn, { attempts = 40, delayMs = 3000 } = {}) {
  for (let i = 0; ; i++) {
    try { return await fn(); } catch (e) { if (!isHttpError(e) || i >= attempts) throw e; await sleep(delayMs); }
  }
}

export const reportPath = (name) => resolve("reports", name);
export async function writeReport(name, value) {
  const path = reportPath(name);
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(value, (_, v) => (typeof v === "bigint" ? v.toString() : v), 2)}\n`);
  return path;
}
