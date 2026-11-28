// Server-only. Local Xcode receipts are deliberately not accepted here.
import { Buffer } from "node:buffer";
import { AppStoreServerAPIClient, Environment, SignedDataVerifier, Status, type JWSTransactionDecodedPayload } from "npm:@apple/app-store-server-library@3.1.0";
import { createClient } from "npm:@supabase/supabase-js@2";

export const products = new Set(["app.tabinote.meals.plus.monthly", "app.tabinote.meals.plus.yearly"]);
function required(key: string): string {
  const value = Deno.env.get(key);
  if (!value) throw new Error("Store configuration missing");
  return value;
}
export function storeServices() {
  const mode = required("APPLE_STORE_ENVIRONMENT");
  if (mode !== "Sandbox" && mode !== "Production") throw new Error("Unsupported environment");
  const environment = mode === "Production" ? Environment.PRODUCTION : Environment.SANDBOX;
  const appID = Deno.env.get("APPLE_APP_ID");
  if (environment === Environment.PRODUCTION && (!appID || !/^\d+$/.test(appID))) throw new Error("App ID required");
  const roots: string[] = JSON.parse(required("APPLE_ROOT_CA_BASE64_JSON"));
  if (!Array.isArray(roots) || !roots.length || !roots.every(x => typeof x === "string")) throw new Error("Trusted roots required");
  const bundle = "app.tabinote.meals";
  const verifier = new SignedDataVerifier(roots.map(x => Buffer.from(x, "base64")), true, environment, bundle, appID ? Number(appID) : undefined);
  const client = new AppStoreServerAPIClient(required("APPLE_IAP_PRIVATE_KEY").replaceAll("\\n", "\n"), required("APPLE_IAP_KEY_ID"), required("APPLE_IAP_ISSUER_ID"), bundle, environment);
  return { verifier, client };
}
export function adminClient() {
  return createClient(required("SUPABASE_URL"), required("SUPABASE_SERVICE_ROLE_KEY"), { auth: { persistSession: false, autoRefreshToken: false } });
}
export function checkedIdentity(transaction: JWSTransactionDecodedPayload): string {
  if (!transaction.productId || !products.has(transaction.productId) || transaction.bundleId !== "app.tabinote.meals" ||
      !transaction.originalTransactionId || !transaction.appAccountToken ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(transaction.appAccountToken)) {
    throw new Error("Unsupported purchase");
  }
  return transaction.appAccountToken.toLowerCase();
}

// Always query Apple's current status. Replaying an old, valid JWS cannot undo a later refund.
export async function refreshAccess(seed: JWSTransactionDecodedPayload, services: ReturnType<typeof storeServices>) {
  const user = checkedIdentity(seed);
  const checkedAt = Date.now();
  const response = await services.client.getAllSubscriptionStatuses(seed.originalTransactionId!);
  let expires = 0;
  let found = false;
  for (const group of response.data ?? []) {
    for (const item of group.lastTransactions ?? []) {
      if (!item.signedTransactionInfo) continue;
      const transaction = await services.verifier.verifyAndDecodeTransaction(item.signedTransactionInfo);
      if (!transaction.productId || !products.has(transaction.productId)) continue;
      if (checkedIdentity(transaction) !== user) throw new Error("Purchase account mismatch");
      found = true;
      if (transaction.revocationDate || transaction.isUpgraded) continue;
      let until = transaction.expiresDate ?? 0;
      if (item.status === Status.BILLING_GRACE_PERIOD && item.signedRenewalInfo) {
        const renewal = await services.verifier.verifyAndDecodeRenewalInfo(item.signedRenewalInfo);
        if (renewal.originalTransactionId !== transaction.originalTransactionId) throw new Error("Renewal mismatch");
        until = Math.max(until, renewal.gracePeriodExpiresDate ?? 0);
      } else if (item.status !== Status.ACTIVE) continue;
      expires = Math.max(expires, until);
    }
  }
  if (!found) throw new Error("No subscription status");
  const now = Date.now();
  const admin = adminClient();
  const { error } = await admin.rpc("crumb_apply_store_event", {
    p_user: user, p_expires: new Date(expires).toISOString(), p_revoked: expires <= now,
    p_event_at: new Date(checkedAt).toISOString(), p_original: seed.originalTransactionId,
  });
  if (error) throw new Error("Unable to update access");
  return { active: expires > now, expires_at: expires / 1000 };
}
