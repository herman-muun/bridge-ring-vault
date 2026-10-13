// What each role needs in liquid TRX, from the fees measured on Nile (rounded up):
//   MockTetherUSDT deploy 55.36, MuunUSDTVault 103.99, MuunRingVault 101.19,
//   SponsoredClaimGateway 12.76, RingSponsoredClaimGateway 13.04 (2026-08-26 and 2026-10-13);
//   one measure-tron-vault run burned 89.79 of MUUN's (2026-10-13).
// deploy.mjs refuses to start without enough, fund.mjs tops the roles up from DEPLOYER,
// measure-tron-vault.mjs checks before its first transaction.
import { trx, freshBalance } from "./env.mjs";

export const COST_TRX = {
  token: 56,
  legacyVault: 105,
  ringVault: 102,
  gateway: 14,
  runMuun: 95,
  runDeployer: 20, // seeding the vaults' mock USDT and activating the two zero-TRX relays
};

/** Staked TRX the sponsor needs. Each sponsored claim takes ~48.6k Energy and Nile gives
 *  ~73.6 Energy per staked TRX per day; 1,500 covers a run's two claims without waiting. */
export const sponsorStakeTrx = (env) => Number(env.SPONSOR_STAKE_TRX ?? 1500);

export async function sponsorStaked(t, env) {
  const acct = await t.trx.getAccount(env.ENERGY_SPONSOR_ADDRESS);
  return (acct.frozenV2 ?? []).find((f) => f.type === "ENERGY")?.amount ?? 0;
}

/** Liquid TRX per role for what is still to deploy, plus a run when `withRun`. */
export async function needs(t, env, { withRun }) {
  const missing = (k) => !env[k];
  const deployer =
    (missing("TRON_TOKEN_ADDRESS") ? COST_TRX.token : 0) +
    (missing("TRON_VAULT_ADDRESS") ? COST_TRX.legacyVault : 0) +
    (missing("TRON_RING_VAULT_ADDRESS") ? COST_TRX.ringVault : 0) +
    (withRun ? COST_TRX.runDeployer : 0);
  const sponsor =
    ((await sponsorStaked(t, env)) === 0 ? sponsorStakeTrx(env) : 0) +
    (missing("TRON_GATEWAY_ADDRESS") ? COST_TRX.gateway : 0) +
    (missing("TRON_RING_GATEWAY_ADDRESS") ? COST_TRX.gateway : 0);
  const muun = withRun ? COST_TRX.runMuun : 0;
  return { DEPLOYER: deployer, ENERGY_SPONSOR: sponsor, MUUN: muun };
}

/** Prints need against balance per role; returns the roles that are short. */
export async function report(t, env, need) {
  const short = [];
  for (const [role, n] of Object.entries(need)) {
    const have = trx(await freshBalance(t, env[`${role}_ADDRESS`]));
    const ok = have >= n;
    if (!ok) short.push(role);
    console.log(`${ok ? "ok   " : "SHORT"} ${role.padEnd(15)} ${env[`${role}_ADDRESS`]}  has ${have.toFixed(2).padStart(8)} TRX, needs ${n}`);
  }
  return short;
}
