# Crumb Plus implementation and test status

Updated 2026-11-28. This is a test implementation, not a live subscription launch.

## Product rules

- Free: one personal My Menu, local recipes/photos, categories, ingredients/directions, search.
- Plus: additional owned books, cloud sync/recovery, creating invitations. Joining an invited book is free and does not consume My Menu.
- Collaboration follows the owner's server-confirmed plan. Buying Plus as an invited member does not reactivate an expired owner's book.
- After expiry: local My Menu editing, all cached viewing, recipe card sharing and JSON export remain available. Additional owned books and expired-owner shared books become read only. No subscription expiry deletes records.
- There is no lifetime product. Monthly/yearly test prices are ¥500 / ¥3,600; these are local hypotheses, not App Store prices. No introductory offer/trial is configured yet.

## Try it without App Store Connect

1. Open `crumb.xcodeproj`, choose **crumb Purchase Preview**, and select an iPhone simulator.
2. Run, skip onboarding if desired, and Continue without an account. This build has a separate bundle ID (`app.tabinote.meals.purchases`) and separate records from the normal app.
3. My Menu menu → New menu book opens Crumb Plus. Choose monthly/yearly → Get Plus. Apple's confirmation explicitly says Xcode and that no charge will occur.
4. After purchase, create an extra book. Profile → Crumb Plus contains Restore purchases / Manage subscription. Book management offers JSON export even without Plus.
5. In Xcode's StoreKit transaction manager, test expiry, refund, renewal, cancellation, approval pending and restore. Cancellation should preserve access until the paid period ends.

Local Xcode entitlements only unlock local test books. The cloud deliberately rejects them; there is no client-set paid flag or hidden server bypass.

## Implemented components

- StoreKit 2 verified transactions, account token binding, update listener, restoration, expiry refresh and localized dynamic product prices.
- A single policy shared by action guards and editor/save/delete checks; backend independently checks owner access.
- Account-isolated local databases/preferences. Guest data stays separate and is not automatically imported/uploaded.
- Three-way snapshot sync, immutable content-addressed private images, revisions and atomic multi-book writes; concurrent edits preserve both copies.
- Profile/avatar, categories and private custom plates have account state sync. Recipe photos and originals are scoped to the book; invitations disclose access to originals.
- Single-use 7-day invitations, maximum 9 invited members, revocation of unused links, and leaving a shared book. Invitations are sent by the person through the share sheet.
- Native `crumb://join/<code>` and pasted-code entry. Universal web invitation links are not implemented.
- Server-side Apple signature verification using Apple's library and online certificate checks. The verifier queries Apple's current subscription status rather than trusting a replayed old receipt. App Store notifications also refresh current state.

## Supabase state

Project `ennerbywpvdcmpqaohmf`: the schema corresponding to `supabase/migrations/202611280001_library_and_plans.sql` was applied successfully in the dashboard on 2026-11-28. Five private tables, secured RPCs and the private `crumb-photos` bucket were created. No personal photos, test accounts or beta plan grants were uploaded/created.

The earlier auth-only proposal has moved to `supabase/archive`; do not apply it as an additional migration. Because this schema was applied through the dashboard, record/repair its migration version before using a CLI migration push; do not run CREATE statements over the existing tables.

`CRUMB_CLOUD_ENABLED = NO` remains intentional. Enable only after two-account/two-device recovery and sharing tests, account deletion setup, and the receipt service deployment. A free account can read its prior cloud records but cannot upload personal My Menu changes; a shared member can upload while the owner's server plan is active.

The user explicitly approved syncing signed-in account recipe/food/original/plate photos to this Crumb project. This is not permission to merge or upload the separate guest library.

## Server deployment requirements

Deploy `verify-entitlement`, `store-notifications`, and the updated `delete-account` functions from this repo using Supabase CLI/dashboard. They are not deployed in this change. `supabase/config.toml` disables gateway JWT checks because the handlers validate the native user token with Supabase Auth or the Apple JWS themselves. Do not remove those checks in the handlers.

Configure server secrets only (never in iOS, git or chat):

- `APPLE_STORE_ENVIRONMENT`: Sandbox for sandbox testing, Production for launch. Xcode is rejected.
- `APPLE_APP_ID`: App Store Connect's numeric app ID, required for Production.
- `APPLE_ROOT_CA_BASE64_JSON`: JSON array of official Apple root CA DER certificates encoded as base64, downloaded from Apple PKI. Do not trust roots supplied by a client/receipt.
- `APPLE_IAP_PRIVATE_KEY`, `APPLE_IAP_KEY_ID`, `APPLE_IAP_ISSUER_ID`: App Store Connect In-App Purchase API key.
- Deletion additionally requires `APPLE_TEAM_ID`, `APPLE_CLIENT_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` for Sign in with Apple revocation. These are distinct from the IAP API key.
- Supabase supplies its service role key to the server environment; it must never be in a client build.

Register monthly/yearly auto-renewable products in one subscription group with the IDs in `PlusStore.swift`. Configure App Store Server Notifications V2 to the notification function. Verify test notification, signed renewals, refunds, expiry and grace period on the server. Cancellation of auto-renewal must not immediately revoke the paid period.

For cloud-only beta testing before App Store Connect registration, an administrator may grant a finite server-side `beta` access period to an explicitly selected test user. None was granted automatically. Local StoreKit receipts never grant cloud rights.

## Verification performed

- Actual Xcode simulator build and launch succeeded.
- Manual Xcode-environment monthly purchase and restore succeeded without a charge; Plus became active and an additional book was created. The final normal and Purchase Preview builds both succeeded, and Purchase Preview was left running.
- XCTest: merge conflicts, retries, concurrent deletion/edit, fresh-device pull and Free/Plus/invited policy passed (4 tests).
- StoreKit automated purchase/restore/expiry/refund/account-mismatch test is present but **skipped**, not passed: iOS 26.5's StoreKitTest mutation calls returned SKInternalErrorDomain code 3 / notEntitled. Previous test entitlements could not be cleared. Rerun on a fixed runtime or use the transaction manager/sandbox after registration.
- Isolated PGlite SQL tests passed: Free restrictions, private-table isolation, owner-paid collaboration, consumed/revoked invites, atomic revision conflict rollback, storage access, expiry, membership removal and old-refund replay prevention. This harness replaces unavailable pgcrypto with a test-only adapter; production crypto entropy and real Supabase Storage HTTP were not tested by it.
- All three Edge Functions passed Deno type checking. Real Apple signatures/OCSP/API calls and deployed function behavior remain untested without App Store configuration.

Re-run SQL tests using a temporary install of `@electric-sql/pglite@0.3.14` and `PGLITE_MODULE=/absolute/path/to/pglite/dist/index.js node supabase/tests/library-policy.mjs`. Run native tests with ⌘U in Purchase Preview. StoreKit tests must be serial.

## Before selling

Complete real-device Apple login, two-account sharing, offline edits/reconnect, sign-out during upload, fresh-device recovery, and destructive deletion tests with disposable accounts. Set real public privacy/terms URLs (`CRUMB_PRIVACY_URL`, `CRUMB_TERMS_URL`, Xcode escaped HTTPS syntax) and final storefront pricing. Purchases outside the local preview are blocked until cloud and both HTTPS policy URLs are configured.

Also establish storage quotas/rate limits and orphan-media cleanup/retention. Immutable old images are retained until account deletion/maintenance; subscription expiry never removes them. Account deletion removes owned books and their images (including their shared members' contributions), and private account media; contributions in someone else's book remain with that book. Test interrupted/in-flight deletion and scheduled cleanup before launch. Deleting the app account does not itself cancel Apple's subscription.

## Recipe editor, nutrition and Ask Crumb (2026-11-28)

The editor now accepts typed ingredients, on-device dictation and imported recipes in the same fields. Photo styling is inline in the original editor layout, alongside the existing category and date sections. Importing into a nonempty draft asks before replacing/appending, and failed imports retain the source link. Amounts, units and baseline servings are separate. Steps store ingredient UUID references; displayed serving changes scale those references without modifying cooking times or the saved baseline. Optional JSON fields preserve older saved recipes and the existing SwiftData schema.

Ask Crumb is not Plus gated. Variations are reviewed in the existing editor and saved as new recipes with an origin reference. Meal cards reference existing recipes and embed new drafts; saving a meal does not duplicate existing recipes. An individual new dish can later be saved separately. Chats and proposals are retained locally per recipe/account. Preview images are optional, labeled AI preview, load after the draft, and never block review/save. The two supplied six-frame sheets are cropped in row-major order; cooking uses 100 ms/frame, stops when processing ends, and Reduce Motion uses a static frame.

Nutrition is Plus-only; ingredient scaling remains free. `NutritionData/usda-foods.json` contains 7,793 records with all four required nutrients from USDA FoodData Central SR Legacy. The first small set has conservative name aliases, standard item weights and selected densities; other foods can be searched and explicitly matched. Unknown weights are omitted and disclosed, not shown as zero nutrition. Item-weight assumptions can be edited and saved. Estimates are calculated from ingredient weights and food data, never invented by the assistant. Recipe edits are reflected on reopening; display serving changes do not change per-person values.

Data source: https://fdc.nal.usda.gov/download-datasets/ and the official `FoodData_Central_sr_legacy_food_csv_2018-04.zip`. Rebuild with `python3 scripts/build_food_database.py /path/to/archive.zip`. Standard household weights are explicit application assumptions, not guaranteed weights for every item. The data is bundled, so nutrition does not require a USDA API key or a network connection.

### AI connection

Development only: use the private Xcode `crumb AI Dev` scheme environment variable `OPENAI_API_KEY`. A descriptive key name is `crumb-assistant-dev`. Do not put keys in source, shared schemes, screenshots, or the iOS bundle. Release builds ignore this direct-key route. The user restored API access on 2026-11-28. Actual Responses API requests returned HTTP 200/completed, and live text and image generation subsequently succeeded in the simulator. Text defaults to `gpt-4.1`, images to `gpt-image-1.5`; development overrides are `OPENAI_RECIPE_MODEL` and `OPENAI_IMAGE_MODEL`.

Production: deploy `supabase/functions/ask-crumb`, apply `202611280002_assistant_quota.sql`, and configure server-only `OPENAI_API_KEY` (for example named `crumb-assistant-production`), `OPENAI_RECIPE_MODEL` and `OPENAI_IMAGE_MODEL` as needed. Then enable `CRUMB_AI_ENABLED=YES`. The function validates the signed-in Supabase user, uses fixed structured schemas, and atomically limits requests per user (100 text requests/day, 12 images/day; intent classification also consumes a text request). The function and migration are prepared but have not been deployed/applied. The app currently keeps production AI disabled. Photo preview generation sends recipe proposal text, not the user's food photo. Transcripts/page data are sent only when AI structuring is configured; local speech recognition itself stays on-device.

YouTube imports use accessible description data only. Missing ingredients/steps are not fabricated from a title; the source remains available for manual entry. Successful recognition of spontaneous speech requires a supported physical device and on-device speech availability. Without AI, explicitly headed transcript sections can be imported; unstructured speech is retained as notes for review.

### Share extension and signing

The recipe share extension and app use `group.app.tabinote.meals`; the main production bundle remains `app.tabinote.meals`, the extension `app.tabinote.meals.share`. Register/enable this group on both identifiers and use a developer team supporting App Groups and Sign in with Apple. The currently selected Personal Team cannot provision these capabilities. Device/Purchase Preview configurations deliberately have no capability entitlements so local previews remain buildable; the App Group share inbox is unavailable in those configurations. Manual Import link continues to work. Production share-extension operation has not been validated on a provisioned iPhone.

The existing StoreKit monthly/yearly products are reused: `app.tabinote.meals.plus.monthly` and `app.tabinote.meals.plus.yearly`. App Store Connect products, server purchase verification, policy URLs and a registered developer team remain launch requirements; there is no production purchase claim from local testing.

### Verification and remaining checks

Xcode tests cover old JSON decoding, fractions/counts/To taste, 2-to-4 scaling with unchanged original/free-text times, per-person nutrition invariance, unknown/partial nutrition and editable weights, the bundled USDA data, origin-linked variation persistence and meal reference persistence. Injected test-only assistant responses cover image failure, cancellation and replacing one meal dish while retaining others. These fixtures are not a fallback presented to users as live AI output.

The unified editor was opened in the simulator and typed ingredients, baseline servings, step text and an ingredient-reference chip were confirmed through normal UI controls. A public BBC Good Food recipe was imported, applied to the same editor, saved to My Menu and reopened through normal simulator controls. Changing the displayed servings from 2 to 4 changed flour 100→200 g, eggs 2→4 and milk 300→600 ml. Nutrition still used the stored 100 g flour / 2-egg baseline and displayed the item-weight assumption and excluded oil. Ask Crumb opened with the current dish title and kept the conversation with a Retry action when the connection was disabled. A clearly labeled Pancakes (import test) record remains in the local simulator test library. Live dictation, production App Group sharing, two-device cloud sync and production purchases still require end-to-end checks. Live AI/image checks are recorded below. StoreKitTest's entitlement-reset issue and the physical-device segmentation test remain explicit skips, as noted above. Server function type checking and localization resource checks pass; this feature's newly introduced UI copy is English by request.

Latest native test run: 29 tests, 27 passed, 2 explicitly skipped, zero failures. The updated app subsequently built and launched successfully for the manual import/scaling/nutrition checks.


### Live AI verification after API access was restored

Using the private `crumb AI Dev` scheme on the iPhone 17 Pro simulator:

- Generated a chicken soup curry variation, then requested a 300 g firm-tofu version for 2 people through free input. The editor contained tofu quantities and updated directions with ingredient UUID references. Its AI image visibly contained tofu, not chicken. Selected Use as cover and saved it as a separate recipe; the original chicken dish remained present. The adapted-from link was visible after reopening.
- Generated a 2-person meal around that saved tofu curry, with a clear soup and cabbage side under a 15-minute side-dish constraint. Replaced only the soup with miso soup. Reviewed/saved the three-dish meal with its AI table preview as cover. Relaunching showed both the separate variation and the single meal card in My Menu. Existing recipes were linked; the new side dishes were embedded until individually saved.
- Opened the saved meal and saved its miso soup individually through the same editor. The meal then displayed the miso soup as a Linked recipe and retained the cabbage as a New recipe.
- Asked an ordinary tofu-cooking question. Classification was answer, with no recipe/dishes returned and no image generation. Thinking and recipe-generation pending states were observed; fixture tests also cover cancellation and failed previews.

Live testing exposed an equivalent but unexpected AI payload layout: a variation's recipe appeared in its single unlinked dish rather than the top-level recipe field. The client now safely accepts that shape for variations/extraction, while rejecting existing-recipe links as draft payloads. Both server and development instructions explicitly specify the intended field layout. A regression test covers this case. Development logs contain only action/status/count metadata, never credentials, transcripts or recipe contents.

A layout stall while continuing an image-heavy chat was also found. Chat rows now use a bounded-history-compatible regular stack, fixed image aspect ratios and deferred, nonanimated scroll-to-bottom after a new turn. Meal generation, replacing a dish and another ordinary answer all completed in the same image-heavy chat after this change. The recipe editor uses its original navigation-bar save action, including Save as new recipe for variation drafts.

The current key is development-only. A simulator paste action unexpectedly inserted the device clipboard's credential into the chat field; it was cleared without sending. The credential appeared in the local interaction output, so revoke/replace that development key before further use. No credential was written into source, the shared scheme or the exported project. Production AI remains disabled and the authenticated server deployment remains a separate launch requirement.


### Personal Team physical-device preview (2026-11-28)

`crumb AI Dev` now runs the Device Preview configuration rather than Debug, preserving its private environment settings. Device Preview explicitly defines DEBUG so the development-only API route remains available. Both the app and extension have empty capability entitlements in that configuration; Debug/Release keep Sign in with Apple and App Groups.

The physical iPhone already had three free-profile apps installed, so installing another `.preview` identifier hit Xcode's free-profile installed-app limit. Device Preview now uses `app.tabinote.meals` and `app.tabinote.meals.share`, updating the existing Crumb app instead of adding another app. Its display name is crumb Preview. This uses the existing app data container; no app or recipe was deleted. Purchase Preview remains a separate `.purchases` app. Use a developer team supporting the required capabilities for production authentication and App Group sharing.

After these changes, Xcode advanced past signing and installation-limit errors. Following the device unlock, the actual iOS Launch report confirmed Success in Launch crumb on the physical iPhone 17, with No issues. The app is displayed as crumb Preview; use crumb AI Dev → Run for this Personal Team setup. The normal Debug/Release capability settings are retained.


### Recipe editor layout (2026-11-28)

At the user's clarification, the original photo-first creation flow and editor layout were restored. My Menu + opens the existing camera/photo selector, then the editor. The photo/crop control, dish name, short note, category pills, inline shape/plate controls and compact date row retain their original order. The regular editor uses its original navigation-bar save action. Styling is directly available in the editor rather than behind the added Style photo/Choose plate sheets.

Only the recipe-input area uses the new inline Ingredients and Directions editor, with separate amount/unit rows, baseline servings, step ingredient references, and the Record recipe/Import link actions. Existing recipe data, custom/preset plates, styling and cropping implementations are retained. AI proposal review still supports optional generated covers and saving a variation as a separate recipe.

Swift syntax and three-language resource checks passed. The updated app built, launched and attached to the physical iPhone 17 through the Device Preview configuration.


### Ingredient labels and keyboard visibility (2026-11-28)

Add ingredient now uses an explicit, compact icon/text stack instead of an adaptive system label. The ingredient name gets the remaining row width with a stable leading alignment; amount/unit columns are 56/64 points to prevent squeezing the name on smaller phones. New rows receive focus only after insertion into layout.

The recipe editor shares one focus state across dish name, note, category composer, ingredient name/amount/unit, directions, source and legacy notes. Stable scroll targets and keyboard-frame notifications keep the active control in view after focus and keyboard-size changes. Keyboard-only bottom space lets the final rows scroll clear of the keyboard toolbar. Multiline inputs have bounded visible heights while retaining their complete saved text. The existing photo, shape, plate and date layout stays in place.

Manual simulator checks used a bundled sample photo in an unsaved editor: repeated additions to four ingredient rows, name focus, decimal keyboard, unit field, a long multiline direction with its final cursor visible, and returning from the bottom to the dish-name field with the software keyboard visible. The Add ingredient label stayed together. A temporary fixture used to bypass the simulator's inaccessible system photo picker was removed before the final device build; normal camera/photo selection is retained. No test recipe was saved.

The native simulator build and the keyboard checks above succeeded. Swift syntax and localization checks pass. A separate command-line device build was blocked by its execution environment being unable to reach CoreSimulatorService/asset-catalog runtimes; this was not a Swift compiler error. Xcode device selection subsequently stopped responding after the physical phone disconnected. Installation of this latest keyboard fix on the physical iPhone remains pending reconnection and is not claimed as verified.

### Recipe editor rollback (2026-11-28)
Restored the previous recipe editing entry and separate Ingredients / Directions segmented page, including the original ingredient chips and add fields. Photo styling, plates, saved models, import and assistant data are preserved. Swift syntax and localization checks passed; physical build and launch remain unverified because Xcode was unresponsive.

### Inline Recipe form and keyboard visibility (2026-11-28)
Replaced the separate Ingredients / Directions editing destination with a Recipe section directly below Date: Record recipe / Import link, base Serves, editable ingredient rows (name, amount, unit), then numbered multiline Directions. Existing recipe storage, import application/confirmation, voice capture and header Save are reused. Old freeform notes remain editable when present.

Recipe fields use native text editing with a shared local focus value, deferred focus after row insertion, decimal keyboard and fraction/unit/Next/Done accessory. The outer scroll view uses iOS keyboard safe-area sizing; a caret-aware coordinator only applies the missing scroll distance after keyboard/frame, selection, text or field-size changes. No fixed keyboard-height padding or unconditional Recipe scroll-to-center remains. Steps cap their visible editing height and scroll internally to retain the insertion caret.

UI verified on iPhone 17e (6.1-inch / 390 × 844 pt, iOS 26.5): material-row focus and name→amount Next with decimal keyboard, adding a second ingredient, adding two steps, seven-line step caret visibility, fraction and unit shortcuts, Done→tap the same amount to reopen with ½ g preserved and form still at Recipe, and import/record sheet entry/cancellation with input preserved. Small-width toolbar clipping found during testing was corrected using an equally spaced accessory stack. The final accessory has an opaque white background and warm ink tint. Live recording and network extraction were not re-run; existing processors and import confirmation are reused unchanged.

Final native Xcode simulator build/launch succeeded after removing the fixture; My Menu → Add recipe returned to the normal camera/photo chooser. A standalone CLI build was blocked by the restricted execution environment being unable to connect to CoreSimulatorService for asset compilation; native Xcode built the same sources. The simulator system photo picker exposed no actionable accessibility items, so a temporary bundled-photo draft was used for editor interaction tests. It was removed before delivery and no test recipe was saved. Physical iPhone installation was not performed in this turn.

### Return to the simple recipe editor (2026-11-28)
At user request, removed the inline ingredient grid, custom UIKit typing fields, accessory shortcuts and inline Directions form. Restored the original ingredient-chip composer and separate Ingredients / Directions editing page from the saved baseline. Recipe models, existing recipe contents, photo/plate styling, voice and link import are preserved. Swift syntax, localization and diff checks passed; this rollback has not been launched on a device.

### Menu / Add / Explore root navigation (2026-11-28)
Added persistent bottom navigation: Menu on the left, a central Add recipe action, and Explore on the right. Menu keeps its own navigation path and the current book; Add reuses the existing photo-first editor and book permission checks. The duplicate header Add action was removed.

Explore reuses Ask Crumb without requiring a saved recipe. General conversation has a separate account-scoped history key. Optional current-recipe context avoids phantom source records, origin links or meal components. Recipe-specific Ask Crumb remains supported. Explore drafts use the selected writable menu book (falling back to My Menu when read-only). A regression test covers creating a draft without an origin; the test was added but not yet run. The Supabase instruction template was updated locally for context-free Explore; production deployment remains a separate setup step.

UI checks on iPhone 17e / iOS 26.5: Menu ↔ Explore switching, persisted Explore conversation, and a real development-provider reply to the cooking starter succeeded. Composer is pinned inside its own page; root controls are outside page layout and hide while the keyboard is shown. Native simulator builds succeeded. No physical-device deployment or production backend deployment was performed for this navigation change.
