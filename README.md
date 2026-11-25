# Rotolo Operations (Flutter)

A mobile app for Android and iOS that replaces WhatsApp for Harry Rotolo's real-estate operations. It covers daily reports, deals and email evidence, rent and payment review, outside-payment approval, maintenance tasks and staff activity.

The app supports demo mode and a Supabase-backed mode. The live report worker reuses the read-only vendor integrations and stores each report under the same run ID shown in the app. Live payments support submission, private JPEG/PNG receipt images, and review. DoorLoop payment posting remains disabled. Device report alerts are opt-in from Settings once the Firebase sender is configured.

The app opens to **Assistant**. Ask a question, choose a suggested question, or start an email. Answers show charts when a comparison helps. **Reports** keeps the daily briefs, and **More** holds the detailed records and settings available to the signed-in user.

## Documents
- [docs/01-n8n-inventory.md](docs/01-n8n-inventory.md): what the 7 exported n8n workflows actually do, their credentials, defects and gaps.
- [docs/02-backend-contracts.md](docs/02-backend-contracts.md): report JSON contract v1.0, endpoints, refresh, push and the payment flow.
- [docs/03-implementation-plan.md](docs/03-implementation-plan.md): phases, validation gates and the decisions still needed.
- [n8n/README.md](n8n/README.md): the two new n8n workflows that deliver real reports to the app, and how to set them up.

## Run

```sh
flutter pub get
flutter run            # demo mode: tap a demo account chip (password "demo"), then Sign in
flutter run --dart-define-from-file=config/supabase.json   # live Supabase project (invite-only accounts)
```

`config/supabase.json` holds only the project URL and the publishable key, which are public by design. Never put the service-role key or database password in this repo or the app.

Apply the Supabase migrations in order and give each invited user an active profile with the appropriate access. Follow the [n8n deployment steps](n8n/README.md) to enable **Reports → Generate report**. Demo reports stay accessible from Reports and are excluded from the live Home and operations screens.

### Assistant email

The app previews one recipient, subject, and message for approval before it calls `send-assistant-email`. It asks for an exact address if a request names a person. Demo mode simulates the confirmation.

To turn on live sending, apply the `assistant_email_attempts` migration, deploy `send-assistant-email` with JWT verification, and set these Supabase Edge Function secrets:

- `ROTOLO_EMAIL_FROM` is the authorized Gmail sender. It must match the verified email of an active owner or admin account in Rotolo.
- `ROTOLO_EMAIL_GOOGLE_CLIENT_ID`, `ROTOLO_EMAIL_GOOGLE_CLIENT_SECRET`, and `ROTOLO_EMAIL_GOOGLE_REFRESH_TOKEN` come from an approved Google OAuth connection with the `gmail.send` scope. Keep these server-side.

Email sending has its own connection. The Gmail report connection continues to collect attorney correspondence.

## Test

```sh
flutter test                         # unit, flow and phone-layout tests
supabase/tests/run_local.sh          # schema, RLS and payment state machine on a throwaway local Postgres 14+
# On a booted simulator/emulator, drive every screen and save screenshots:
SCREENSHOT_DIR=/tmp/shots flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/app_walkthrough_test.dart -d <device id>
```

## Layout

```
lib/core/      money (integer cents), data-quality labels, timezone formatting, push routing
lib/models/    contract v1.0 models (defensive parsing; missing values are null, never 0)
lib/data/      OpsRepository interface + SyntheticRepository (applies the same rules as the DB)
lib/state/     Riverpod providers (data providers depend only on session + data version) and view models
lib/ui/        theme tokens, component kit, router, shell, screens
assets/fixtures/synthetic_reports.json   synthetic reports in contract v1.0
assets/fonts/                             IBM Plex Sans/Mono (SIL OFL 1.1)
supabase/migrations/                      schema, RLS, RPCs (+ payment comments, deal evidence reviews)
```

Vendor keys and the report worker secret stay in n8n credentials. Supabase stores the worker secret hash. The app uses the Supabase publishable key and the signed-in user’s session.

### Device report alerts

The **Rotolo Operations** Firebase project contains the existing Android and iOS
app IDs. Firebase client settings are in `lib/core/firebase_options.dart`.

Apply `supabase/migrations/20261123000000_report_push.sql` and deploy the
`report-push` Edge Function. Set `ROTOLO_FCM_SERVICE_ACCOUNT` in Supabase
Edge Function secrets to the JSON credential of a dedicated Firebase service
account with the [Firebase Cloud Messaging API Admin role](https://cloud.google.com/iam/docs/roles-permissions/firebasecloudmessaging).
To attach the function to n8n, regenerate the report worker with the existing
`--credential-id` and the public Supabase legacy anon JWT via `--edge-anon-jwt`,
or add the corresponding **Send device alerts** HTTP step after the report
receipt. Leave gateway JWT verification enabled. The worker sends its existing
`x-ingest-secret` header as well. The JWT at the gateway never grants database
service-role access.

For iPhone delivery, add the APNs authentication key to the Firebase iOS app,
and sign the physical-device build with a provisioning profile that includes
Push Notifications. Users can enable **Send report alerts to this device**
under Settings. A report alert contains generic text and a report ID.

### Account recovery and release builds

- Allow the exact redirect `com.rotolo.operations://password-reset` in Supabase Auth. Users request a link from **Forgot password?** and open it on the same device to enter a new password.
- The receipt and report-alert server changes are in `20261123100000_private_receipts_and_quiet_hours.sql`. Report push skips opted-in quiet hours from 9 p.m. to 7 a.m. Eastern. The report remains in the app.
- Android release signing uses the project's upload key. Configure `storeFile`, `storePassword`, `keyAlias`, and `keyPassword` in the ignored `android/key.properties` file. Keep the keystore and its passwords outside Git. Use a provisioning profile and distribution certificate for the Rotolo iOS bundle ID.
