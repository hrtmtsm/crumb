import { adminClient, checkedIdentity, refreshAccess, storeServices } from "../_shared/store.ts";

Deno.serve(async request => {
  if (request.method !== "POST") return new Response(null, { status: 405 });
  if (Number(request.headers.get("content-length") ?? 0) > 32000) return new Response(null, { status: 413 });
  try {
    const authorization = request.headers.get("authorization");
    if (!authorization?.startsWith("Bearer ")) return new Response(null, { status: 401 });
    const { data: { user }, error } = await adminClient().auth.getUser(authorization.slice(7));
    if (error || !user) return new Response(null, { status: 401 });
    const { signedTransaction } = await request.json();
    if (typeof signedTransaction !== "string" || signedTransaction.length > 24000) return new Response(null, { status: 400 });
    const services = storeServices();
    const transaction = await services.verifier.verifyAndDecodeTransaction(signedTransaction);
    if (checkedIdentity(transaction) !== user.id.toLowerCase()) return new Response(null, { status: 403 });
    return Response.json(await refreshAccess(transaction, services));
  } catch {
    // Fail closed. Never log receipts, credentials or account identifiers.
    return Response.json({ error: "Unable to verify purchase" }, { status: 503 });
  }
});
