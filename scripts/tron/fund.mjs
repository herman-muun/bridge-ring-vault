// Tops ENERGY_SPONSOR and MUUN up from the faucet-funded DEPLOYER to what the remaining
// deploys plus one measurement run need (lib/budget.mjs). Only DEPLOYER needs the faucet.
// Re-run before each measurement: it sends only the shortfall.
import { loadEnv, client, trx, waitForReceipt, freshBalance } from "./lib/env.mjs";
import { needs, report } from "./lib/budget.mjs";

const env = loadEnv();
const t = client(env, env.DEPLOYER_PRIVATE_KEY);
const need = await needs(t, env, { withRun: true });

const transfers = [];
for (const role of ["ENERGY_SPONSOR", "MUUN"]) {
  const have = trx(await freshBalance(t, env[`${role}_ADDRESS`]));
  if (have < need[role]) transfers.push([role, Math.ceil(need[role] - have)]);
}

// Each transfer to a not-yet-activated account burns ~1.1 TRX of activation and bandwidth.
const deployerHas = trx(await freshBalance(t, env.DEPLOYER_ADDRESS));
const deployerNeeds = need.DEPLOYER + transfers.reduce((s, [, a]) => s + a + 2, 0);
if (deployerHas < deployerNeeds) {
  console.error(`DEPLOYER ${env.DEPLOYER_ADDRESS} has ${deployerHas.toFixed(2)} TRX and needs ~${Math.ceil(deployerNeeds)}`);
  console.error(`(its own ${need.DEPLOYER} + ${transfers.map(([r, a]) => `${a} for ${r}`).join(" + ") || "nothing"}).`);
  console.error(`Request ~${Math.ceil(deployerNeeds - deployerHas)} TRX more for it at https://nileex.io/join/getJoinPage, then re-run.`);
  process.exit(1);
}

for (const [role, amount] of transfers) {
  const r = await t.trx.sendTransaction(env[`${role}_ADDRESS`], amount * 1e6);
  const txid = r.txid ?? r.transaction?.txID;
  await waitForReceipt(t, txid);
  console.log(`${role.padEnd(15)} +${amount} TRX  tx ${txid}`);
}
console.log();
await report(t, env, need);
