import { refreshAccess, storeServices } from "../_shared/store.ts";

// Apple has no Supabase JWT. Only a verified Apple JWS can reach any entitlement mutation.
Deno.serve(async request => {
  if (request.method !== "POST") return new Response(null, { status: 405 });
  if (Number(request.headers.get("content-length") ?? 0) > 80000) return new Response(null, { status: 413 });
  try {
    const { signedPayload } = await request.json();
    if (typeof signedPayload !== "string" || signedPayload.length > 72000) return new Response(null, { status: 400 });
    const services = storeServices();
    const notification = await services.verifier.verifyAndDecodeNotification(signedPayload);
    if (notification.notificationType === "TEST") return Response.json({ received: true });
    const signed = notification.data?.signedTransactionInfo;
    if (!signed) return Response.json({ received: true });
    const transaction = await services.verifier.verifyAndDecodeTransaction(signed);
    await refreshAccess(transaction, services);
    return Response.json({ received: true });
  } catch {
    return Response.json({ error: "Unable to process notification" }, { status: 503 });
  }
});
