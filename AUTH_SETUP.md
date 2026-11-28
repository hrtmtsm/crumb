# Apple accounts for Crumb

## Implemented in the iOS app

- Welcome screen: native Continue with Apple and Continue without an account.
- First successful login: name/profile setup, then the recipe library.
- Guest-to-login entry from Profile → Account.
- Apple identity token exchanged with Supabase Auth using a fresh cryptographic nonce.
- Session and refresh token stored in the device-only Keychain, with refresh on expiration.
- Apple credential revocation handling, logout, and account deletion with Apple reauthentication.
- Guest recipes keep the existing SwiftData container. Each Supabase user UUID has a separate local container and UserDefaults suite. A second account never opens a previous account's recipes or profile settings.
- Japanese, English and Korean interface strings.

## Actual project

Supabase project: `ennerbywpvdcmpqaohmf` (Crumb).
Project URL: `https://ennerbywpvdcmpqaohmf.supabase.co`.
Native iOS Bundle ID: `app.tabinote.meals`.

The project URL is in Config/Defaults.xcconfig. Place the **publishable** key in the git-ignored Config/Local.xcconfig using Local.xcconfig.example as a template. Never use a secret or service_role key in iOS. SupabaseConfiguration rejects secret/service-role credentials.

Enable Apple under Supabase → Authentication → Sign In / Providers, and allow `app.tabinote.meals` as a Client ID. Native iOS ID-token login does not need the web OAuth callback flow. Do not disable nonce checking. Enable Sign in with Apple for the same App ID in the Apple Developer account; CrumbAuth.entitlements declares the iOS capability. The Device Preview configuration deliberately excludes that capability and uses a different Bundle ID.

## Server-side deletion — required before release

`supabase/functions/delete-account/index.ts` is the server implementation. It validates the caller and a fresh Apple identity, exchanges the authorization code on the server, revokes Apple access, removes the user's photo objects, and deletes the auth user (cascading owned rows).

Before deploying it, configure `APPLE_TEAM_ID`, `APPLE_CLIENT_ID`, `APPLE_KEY_ID`, and `APPLE_PRIVATE_KEY` in Edge Function secrets. The .p8 file must remain server-side. The function uses Supabase's automatic environment values for the service key. No real secrets are in the example.

Deploy using an authenticated Supabase CLI, or the dashboard Edge Function editor. The handlers validate tokens themselves; follow `supabase/config.toml` for gateway settings. Create the private `crumb-photos` bucket using the SQL migration before testing deletion. Deletion fails closed if Apple secrets, token validation, revocation, or storage deletion fails; the app must never report successful deletion from a missing/unconfigured function.

## Database foundation and what is not yet syncing

`supabase/archive/202611240001_accounts.proposal.sql` is an additive migration for profiles, menu books, recipes and private image storage, with per-user Row Level Security. Apply only after reviewing existing table/bucket names; it intentionally fails on naming conflicts instead of overwriting existing policies.

**This change implements authentication, not cloud recipe synchronization.** Recipes and profile edits still live locally in the scoped stores. It does not upload existing guest photos, migrate them into an account, or restore recipes from another device. Those require a separate, explicit import/sync implementation after the auth connection is tested. The welcome screen describes local storage accordingly.

## Validation

- Build and inspect the welcome screen, then choose Continue without an account. Existing records must remain visible.
- From Profile, open Apple login. Canceling the Apple sheet must leave the guest session and records unchanged.
- On an Apple-configured physical device, sign up with Apple and complete profile setup. Verify the new auth user in Supabase.
- Log out and verify guest data reappears. Sign in again and verify the same account's store opens. Use a second account to verify isolation.
- Test token expiration/refresh and Apple credential revocation.
- Test account deletion against a dedicated test account after deploying the function and Apple secrets. Do not use a real account for destructive testing.
- Before App Store submission: complete a public privacy policy, privacy disclosures, real-device Apple login, deletion/revocation, and recovery tests. Do not claim cloud backup/sync until it is implemented and tested.

## 2026-11-28 update

See `PLAN_SETUP.md` for the new library/plan schema applied to Supabase and the client sync implementation. Cloud remains disabled pending deployment and real-device validation. The earlier sections describe the original auth-only milestone; they do not imply that the new cloud functions are deployed.
