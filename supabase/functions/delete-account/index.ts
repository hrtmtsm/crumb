// Deploy only after configuring Apple secrets in Supabase Edge Function secrets.
// No Apple .p8, service_role key, or client secret belongs in the iOS app.
import { createClient } from "npm:@supabase/supabase-js@2";
import { importPKCS8, SignJWT } from "npm:jose@6";

Deno.serve(async (request: Request) => {
  const failure = (status: number) =>
    Response.json({ error: "Unable to delete account" }, { status });
  if (request.method !== "POST") return failure(405);
  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const publicKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const authorization = request.headers.get("Authorization");
    if (!authorization?.startsWith("Bearer ")) return failure(401);
    const client = createClient(url, publicKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: { user }, error } = await client.auth.getUser(
      authorization.slice(7),
    );
    if (error || !user) return failure(401);
    const { authorizationCode, idToken, nonce } = await request.json();
    if (
      ![authorizationCode, idToken, nonce].every((value) =>
        typeof value === "string" && value.length > 0 && value.length < 16000
      )
    ) return failure(400);
    // Verify the fresh Apple identity with Supabase and compare it to the caller. Never trust a client-supplied user ID.
    const { data: fresh, error: freshError } = await client.auth
      .signInWithIdToken({ provider: "apple", token: idToken, nonce });
    if (freshError || fresh.user?.id !== user.id) return failure(403);
    const team = Deno.env.get("APPLE_TEAM_ID");
    const keyID = Deno.env.get("APPLE_KEY_ID");
    const clientID = Deno.env.get("APPLE_CLIENT_ID");
    const privateKey = Deno.env.get("APPLE_PRIVATE_KEY");
    if (!team || !keyID || !clientID || !privateKey) return failure(503);
    const key = await importPKCS8(privateKey.replaceAll("\\n", "\n"), "ES256");
    const secret = await new SignJWT({})
      .setProtectedHeader({ alg: "ES256", kid: keyID }).setIssuer(team)
      .setSubject(clientID)
      .setAudience("https://appleid.apple.com").setIssuedAt().setExpirationTime(
        "5m",
      ).sign(key);
    const exchange = await fetch("https://appleid.apple.com/auth/token", {
      method: "POST",
      body: new URLSearchParams({
        client_id: clientID,
        client_secret: secret,
        code: authorizationCode,
        grant_type: "authorization_code",
      }),
    });
    if (!exchange.ok) return failure(502);
    const apple = await exchange.json();
    const token = apple.refresh_token ?? apple.access_token;
    if (!token) return failure(502);
    const revoke = await fetch("https://appleid.apple.com/auth/revoke", {
      method: "POST",
      body: new URLSearchParams({
        client_id: clientID,
        client_secret: secret,
        token,
        token_type_hint: apple.refresh_token ? "refresh_token" : "access_token",
      }),
    });
    if (!revoke.ok) return failure(502);
    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    // Stop new cloud writes before clearing immutable media. Invited books belong to their owners.
    const { error: revokePlanError } = await admin.from("crumb_plan_access").update({ revoked: true }).eq("user_id", user.id);
    if (revokePlanError) return failure(502);
    const folders = [`u/${user.id}`, user.id]; // Include the previous flat layout for older test installs.
    for (let offset = 0;; offset += 100) {
      const { data: books, error: booksError } = await admin.from("crumb_books").select("id").eq("owner_id", user.id).range(offset, offset + 99);
      if (booksError) return failure(502);
      for (const book of books ?? []) folders.push(`b/${book.id}`);
      if (!books || books.length < 100) break;
    }
    for (const folder of folders) {
      while (true) {
        const { data: files, error: listError } = await admin.storage.from("crumb-photos").list(folder, { limit: 100, offset: 0 });
        if (listError) return failure(502);
        if (!files?.length) break;
        if (files.some(file => !file.id)) return failure(409);
        const { error: removeError } = await admin.storage.from("crumb-photos").remove(files.map(file => `${folder}/${file.name}`));
        if (removeError) return failure(502);
      }
    }
    const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
    if (deleteError) return failure(502);
    return new Response(null, { status: 204 });
  } catch {
    return failure(500); // Don't log tokens, authorization codes, private keys, or payloads.
  }
});
