# Rotolo Operations (Flutter)

A mobile app for Android and iOS that replaces WhatsApp for Harry Rotolo's real-estate operations. It covers daily reports, deals and email evidence, rent and payment review, outside-payment approval, maintenance tasks and staff activity.

The app supports demo mode and a Supabase-backed mode. The live report worker reuses the read-only vendor integrations and stores each report under the same run ID shown in the app. Live payments support submission and review. DoorLoop payment posting remains disabled. Device report alerts are opt-in from Settings once the Firebase sender is configured.

The UI follows the Claude Design prototype "Real Estate AI" (IBM Plex type, light and dark tokens in `lib/ui/theme.dart`). Tabs: Home, Reports, Payments, Tasks, More (Deals, Team activity, Notifications, Integrations, Settings). Staff see only the tabs for sections they may read.

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
