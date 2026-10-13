// Measurement helpers for measure-tron-vault.mjs.
import tronwebPkg from "tronweb";
import { trx, waitForReceipt } from "./env.mjs";

const { TronWeb } = tronwebPkg;

// A zero-TRX relay needs ~312 Bandwidth per contract call out of a 600/day rolling
// quota, so an account gets roughly one attempt per 24h. Rather than depend on a
// reused account's quota, mint a fresh one per run and activate it with
// createAccount, which leaves it holding exactly zero TRX.
export async function freshZeroTrxRelay(deployer, env) {
  const a = TronWeb.createRandom();
  const pk = a.privateKey.replace(/^0x/, "");
  const addr = TronWeb.address.fromPrivateKey(pk);
  const tx = await deployer.transactionBuilder.createAccount(addr, env.DEPLOYER_ADDRESS);
  const r = await deployer.trx.sendRawTransaction(await deployer.trx.sign(tx));
  if (r.code) throw new Error(Buffer.from(r.message, "hex").toString());
  await waitForReceipt(deployer, r.txid);
  return { pk, addr };
}

// Fresh recipients per run so the cold/warm measurement is repeatable: a recipient
// warmed by a previous run would silently turn the cold case into a warm one.
export function freshAddress() {
  const a = TronWeb.createRandom();
  const pk = a.privateKey.replace(/^0x/, "");
  return { pk, addr: TronWeb.address.fromPrivateKey(pk) };
}

export const hex32 = (b) => "0x" + Buffer.from(b).toString("hex");
export const freshSwapId = () => hex32(crypto.getRandomValues(new Uint8Array(32)));
export const norm = (h) => (h.startsWith("0x") ? h : "0x" + h);

export async function sponsorEnergy(t, env) {
  const r = await t.trx.getAccountResources(env.ENERGY_SPONSOR_ADDRESS);
  return (r.EnergyLimit ?? 0) - (r.EnergyUsed ?? 0);
}

/** Sends a contract call and returns a normalised measurement record. */
export async function measure(t, contractAddr, abi, method, args, label, feeLimit = 150e6) {
  const c = t.contract(abi, contractAddr);
  const submittedAt = Date.now();
  const txid = await c[method](...args).send({ feeLimit, shouldPollResponse: false });
  const info = await waitForReceipt(t, txid);
  const r = info.receipt ?? {};
  const block = await t.trx.getBlock(info.blockNumber).catch(() => null);
  const blockTs = block?.block_header?.raw_data?.timestamp ?? info.blockTimeStamp;
  if (r.result && r.result !== "SUCCESS") {
    throw new Error(`${label} failed: ${r.result} ${info.resMessage ? Buffer.from(info.resMessage, "hex").toString() : ""}`);
  }
  return {
    label, txid,
    blockNumber: info.blockNumber,
    energyTotal: r.energy_usage_total ?? 0,
    energyFromCallerStake: r.energy_usage ?? 0,
    energyPaidByOrigin: r.origin_energy_usage ?? 0,
    energyBurnedTrx: trx(r.energy_fee ?? 0),
    // net_usage is populated only when free/staked Bandwidth covered the tx; when the
    // account has none left it burns TRX instead and only net_fee appears. Report the
    // byte count either way, at the documented 1,000 sun/byte.
    bandwidthUsed: r.net_usage ?? 0,
    bandwidthBurnedTrx: trx(r.net_fee ?? 0),
    bandwidthBytes: (r.net_usage ?? 0) || Math.round((r.net_fee ?? 0) / 1000),
    bandwidthWasFree: (r.net_usage ?? 0) > 0,
    totalFeeTrx: trx(info.fee ?? 0),
    submittedAt: new Date(submittedAt).toISOString(),
    approximateSecondsToInclusion: blockTs ? Math.round((blockTs - submittedAt) / 100) / 10 : null,
  };
}
