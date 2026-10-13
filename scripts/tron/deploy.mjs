// Deploys the TRON contracts: the legacy pair (MuunUSDTVault + SponsoredClaimGateway) and
// the ring pair (MuunRingVault + RingSponsoredClaimGateway) over one MockTetherUSDT, and
// stakes the sponsor's Energy. Idempotent: anything already recorded in .env.nile is skipped.
import { readFileSync } from "node:fs";
import { loadEnv, client, trx, waitForReceipt, saveEnv, freshBalance } from "./lib/env.mjs";
import { needs, report, sponsorStaked, sponsorStakeTrx } from "./lib/budget.mjs";

const env = loadEnv();
const art = (dir, name) =>
  JSON.parse(readFileSync(new URL(`../../tron/out/${dir}/${name}.json`, import.meta.url), "utf8"));

const deployer = client(env, env.DEPLOYER_PRIVATE_KEY);
const sponsor = client(env, env.ENERGY_SPONSOR_PRIVATE_KEY);

async function deploy(t, key, dir, name, opts, params = []) {
  if (env[key]) {
    console.log(`${name.padEnd(22)} already at ${env[key]}`);
    return env[key];
  }
  const a = art(dir, name);
  const c = await t.contract().new({
    abi: a.abi,
    bytecode: a.bytecode.object.replace(/^0x/, ""),
    feeLimit: 400 * 1e6,
    callValue: 0,
    parameters: params,
    ...opts,
  });
  const addr = t.address.fromHex(c.address);
  saveEnv(key, addr);
  env[key] = addr;
  console.log(`${name.padEnd(22)} -> ${addr}  percent=${opts.userFeePercentage}`);
  return addr;
}

// Preflight: refuse to start a deploy that a role cannot pay for to the end.
const short = await report(deployer, env, await needs(deployer, env, { withRun: false }));
if (short.length) {
  console.error(`\nnot enough TRX: fund DEPLOYER at https://nileex.io/join/getJoinPage, then npm run fund:tron`);
  process.exit(1);
}
console.log();

// 0. The sponsor's Energy stake pays every sponsored claim (~48.6k Energy each; Nile gives
//    ~73.6 Energy per staked TRX per day). Staked once; later runs find it and skip.
{
  const staked = await sponsorStaked(sponsor, env);
  if (staked === 0) {
    const stake = sponsorStakeTrx(env);
    const tx = await sponsor.transactionBuilder.freezeBalanceV2(stake * 1e6, "ENERGY", env.ENERGY_SPONSOR_ADDRESS);
    const r = await sponsor.trx.sendRawTransaction(await sponsor.trx.sign(tx));
    if (r.code) throw new Error(Buffer.from(r.message, "hex").toString());
    await waitForReceipt(sponsor, r.txid);
    console.log(`staked ${stake} TRX for Energy on the sponsor`);
  } else {
    console.log(`sponsor already stakes ${trx(staked)} TRX for Energy`);
  }
}

// 1-2. Token and vault: ordinary contracts, caller pays Energy (percent=100).
const token = await deploy(deployer, "TRON_TOKEN_ADDRESS", "MockTetherUSDT.sol", "MockTetherUSDT",
  { userFeePercentage: 100, originEnergyLimit: 1e7 });
const vault = await deploy(deployer, "TRON_VAULT_ADDRESS", "MuunUSDTVault.sol", "MuunUSDTVault",
  { userFeePercentage: 100, originEnergyLimit: 1e7 }, [token, env.MUUN_ADDRESS]);

// 3. Gateways. A gateway's origin must be the sponsor, but a deploy is paid by the caller,
//    and the caller spends STAKED Energy before burning TRX. Deploying straight
//    from the sponsor would therefore consume the very Energy pool the gateway
//    exists to spend - and at ~78 Energy/min of regeneration that is a ~12h stall.
//    So: delegate the stake away, deploy (forcing a TRX burn), delegate it back.
//    The sponsor needs ~13 TRX liquid for that burn.
async function deploySponsored(key, name, vaultAddr) {
  if (env[key]) {
    console.log(`${name.padEnd(22)} already at ${env[key]}`);
    return env[key];
  }
  const acct = await sponsor.trx.getAccount(env.ENERGY_SPONSOR_ADDRESS);
  const frozenTotal = (acct.frozenV2 ?? []).find((f) => f.type === "ENERGY")?.amount ?? 0;
  // Stake backing Energy already consumed this window cannot be delegated away,
  // so subtract it (plus a margin) or the actuator rejects the delegation.
  const r0 = await sponsor.trx.getAccountResources(env.ENERGY_SPONSOR_ADDRESS);
  const perTrx = (r0.TotalEnergyLimit ?? 1) / (r0.TotalEnergyWeight ?? 1);
  const lockedByUse = Math.ceil(((r0.EnergyUsed ?? 0) / perTrx)) * 1e6;
  const frozen = frozenTotal - lockedByUse - 5e6;
  console.log(`\nparking ${trx(frozen)} of ${trx(frozenTotal)} TRX sponsor stake on DEPLOYER for the deploy...`);

  const del = await sponsor.transactionBuilder.delegateResource(
    frozen, env.DEPLOYER_ADDRESS, "ENERGY", env.ENERGY_SPONSOR_ADDRESS, false);
  const dr = await sponsor.trx.sendRawTransaction(await sponsor.trx.sign(del));
  if (dr.code) throw new Error(Buffer.from(dr.message, "hex").toString());
  await waitForReceipt(sponsor, dr.txid);

  const res = await sponsor.trx.getAccountResources(env.ENERGY_SPONSOR_ADDRESS);
  console.log(`sponsor Energy now ${((res.EnergyLimit ?? 0) - (res.EnergyUsed ?? 0)).toLocaleString()} (expected ~0)`);

  await deploy(sponsor, key, `${name}.sol`, name, { userFeePercentage: 0, originEnergyLimit: 1e7 }, [vaultAddr]);

  console.log("returning stake to sponsor...");
  const und = await sponsor.transactionBuilder.undelegateResource(
    frozen, env.DEPLOYER_ADDRESS, "ENERGY", env.ENERGY_SPONSOR_ADDRESS);
  const ur = await sponsor.trx.sendRawTransaction(await sponsor.trx.sign(und));
  if (ur.code) throw new Error(Buffer.from(ur.message, "hex").toString());
  await waitForReceipt(sponsor, ur.txid);
  return env[key];
}

await deploySponsored("TRON_GATEWAY_ADDRESS", "SponsoredClaimGateway", vault);

// 4-5. The ring vault and its gateway, same token and owner as the legacy pair.
const ringVault = await deploy(deployer, "TRON_RING_VAULT_ADDRESS", "MuunRingVault.sol", "MuunRingVault",
  { userFeePercentage: 100, originEnergyLimit: 1e7 }, [token, env.MUUN_ADDRESS]);
await deploySponsored("TRON_RING_GATEWAY_ADDRESS", "RingSponsoredClaimGateway", ringVault);

const res = await sponsor.trx.getAccountResources(env.ENERGY_SPONSOR_ADDRESS);
console.log(`\nsponsor Energy: ${((res.EnergyLimit ?? 0) - (res.EnergyUsed ?? 0)).toLocaleString()} available / ${(res.EnergyLimit ?? 0).toLocaleString()} per day`);
for (const r of ["DEPLOYER", "ENERGY_SPONSOR", "MUUN"]) {
  console.log(`${r.padEnd(15)} ${trx(await freshBalance(deployer, env[`${r}_ADDRESS`])).toFixed(2)} TRX`);
}
