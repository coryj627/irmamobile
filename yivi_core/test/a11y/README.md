# Runtime accessibility audit (dogfood of flutter-a11y)

This directory exists on the `a11y-dogfood` branch of the fork only. It pumps the real
app in `flutter test`, walks to each screen as a user would, and records what
[`flutter_a11y_test`](https://github.com/coryj627/flutter-a11y) (private) finds on the
rendered semantics tree. The findings are evidence for measuring that tool's rules on a
real application; they are recorded, never asserted, and nothing here is a verdict on
the app.

## Run

```sh
cd yivi_core
flutter pub get            # needs read access to coryj627/flutter-a11y
flutter test test/a11y     # about 80 s
```

Output, both ignored by git (`.a11y/.gitignore`):

- `.a11y/flutter/runtime-findings.json`: the findings, written by `RuntimeFindingsSink`;
  `a11y_check_flutter scan` merges them into its report.
- `.a11y/flutter/runtime-screens.json`: one entry per screen id with the route, the
  viewport it was audited at, the count per rule, pump-time exceptions, and the route
  coverage of the app's route table.

Environment:

- `A11Y_SCREENSHOTS=<dir>` writes a PNG of each screen as it is audited (for labellers).
- `A11Y_TEST_FONT=ahem` uses the default test font; `=roboto` see "Fonts".
- `A11Y_DEBUG=1` prints the stack of errors the harness records.

Two runs give byte-identical findings (666 findings on 121 screens at the time of
writing).

## Why it lives in yivi_core and not in yivi_app

Every screen, the router and `YiviApp` are in `yivi_core`. The app shell (`yivi_app`)
only passes native services to `runYiviApp`: the QR scanner (mobile_scanner), OCR
(ML Kit), the SMS retriever, face verification (Regula) and the store review prompt.
None of them has an implementation under `flutter test`, and the screens can be pumped
without them, so the shell would add heavy plugins and nothing to audit. Being in
`yivi_core` also keeps finding paths as `lib/...` of the package the workflow scans.

The cost: the app names its assets `packages/yivi_core/assets/...`, which only exists
in the bundle of an app that depends on yivi_core. The harness answers the
`flutter/assets` channel and drops that prefix (same files, read from the package
directory).

## Files

| File | What it is |
|---|---|
| `screens_a11y_test.dart` | The journeys, and the route coverage test |
| `flutter_test_config.dart` | Findings sink, per-screen log, fonts, preferences store (yivi_core has no test config of its own, so the app's other tests are untouched) |
| `support/a11y_app.dart` | The app as `runYiviApp` builds it, and the platform fakes |
| `support/fake_core.dart` | Stand-in for the Go core, as an `IrmaBridge` |
| `support/wallet_data.dart` | The wallet, credential store, activity log and sessions it serves |
| `support/a11y_harness.dart` | Step language, settling, auditing, logging |
| `support/fonts.dart` | Font loading |

## What had to be mocked

**The Go core.** The app's own `IrmaMockBridge` cannot run the app:

- it answers the launch handshake with the scheme and nothing else (no enrolment status,
  cards, PIN check or sessions; its source says "TODO: mock bridge needs to be updated
  for new session state model"), so the app stays on its splash screen until the 15 s
  start-up error;
- it does not even construct: it decodes `irmaConfigurationEventJson` with
  `IrmaConfigurationEvent.fromJson`, which now reads the key `irma_configuration`, while
  the JSON in `mock_data.dart` still has `IrmaConfiguration`
  (`type 'Null' is not a subtype of type 'Map<String, dynamic>' in type cast`).

`support/fake_core.dart` is a new `IrmaBridge` that answers each event the way
`irmagobridge/receive_event.go` does, from an in-memory wallet, with 150 ms latency.
It sends JSON decoded by the app's own `fromJson`. The real `IrmaRepository`,
`SessionRepository`, router, blocs and providers run on top of it.

**The data.** Names of credentials, attributes and issuers come from the app's
`mock_data.dart` (a snapshot of the production `pbdf` scheme). Written by hand, because
nothing in the checkout has them:

- the values on the cards (a fictional citizen), the two requestors, the activity log,
  the sessions;
- store entries for `pbdf.sidn-pbdf.email`, `pbdf.sidn-pbdf.mobilenumber`,
  `pbdf.pbdf.passport`, `.idcard` and `.drivinglicence`. The app chooses its built-in
  issuance screens by these ids, and they were added to the scheme after the snapshot;
- English category names ("Personal", "Health", "Education"); the snapshot has Dutch ones.

Known departures from a real wallet:

- The snapshot has no English FAQ texts, so the add-data details of the old credential
  types would show Dutch text; the audited details screen is one of the hand-written
  entries.
- Issuer logos live in the scheme submodules (`irma_configuration/`, not checked out).
  Cards of Yivi's own issuer carry the Yivi logo the app ships; the others show the
  app's initial-letter avatar.
- **The served scheme has no scheme managers.** `IrmaRepository.getVersionInformation`
  switches on `Platform.operatingSystem` per scheme manager and throws
  `Exception: Unsupported Platform.operatingSystem` on anything but Android and iOS. The
  router's redirects combine that stream (`RedirectionListenable`), so on a desktop host
  they never fire: no rooted-device warning, no rename notice, no return to onboarding
  after a wipe. With no scheme managers the stream works and those flows run; the price
  is that an update is never required and the debug scheme list is empty.

**Injected services** (what `yivi_app/lib/main.dart` passes to `runYiviApp`):

| Service | Here |
|---|---|
| QR scanner | A black box where the camera texture would be; the harness "scans" by calling the widget's `onCodeFound` |
| OCR processor | none: the app opens the manual entry screens for documents |
| SMS retriever, face verification, store review | none |

**Providers the app has for outside systems:** `localAuthProvider` (fingerprint enrolled
or not; a scan is always cancelled), `emailIssuerApiProvider` and `smsIssuerApiProvider`
(accept one code, reject others, or answer with a server error).

**Platform channels:** root detection, privacy screen, permission_handler (camera
granted, or permanently denied), url_launcher and share (open nothing). The NFC plugin
is not answered: starting a chip read fails, which shows the app's read-error state.
`runtime-screens.json` lists every channel the app touched.

**Preferences** are set per journey by the app's own keys (`Device.preferences`).

## Harness decisions that affect findings

- **Viewport** 412x915 logical px at DPR 3, as in flutter-a11y's
  `tool/score_realapps_runtime`. Before an audit the view is grown until the screen's
  vertical scrollables have nothing left to scroll (max 8000 px), so content below the
  fold is audited. Not grown (`audit!`): the scanner, and the country picker sheet,
  whose layout is a fraction of the screen height (it has `remainingScrollPx`).
- **Fonts.** The theme asks for `Open Sans`; the harness loads the Open Sans, Alexandria
  and IrmaIcons files from `fonts/`, plus MaterialIcons, Roboto and CupertinoIcons.
  Caveat that could not be checked without a device: yivi_core declares these fonts in
  its own pubspec and `yivi_app` declares none, so in the shipped app they are
  registered as `packages/yivi_core/Open Sans`, while `theme.dart` names the family
  without a package (`yivi_app/lib/credential_card_previews.dart` works around exactly
  this for previews). If that holds on a device, the app renders in the system font
  (Roboto on Android) and overflow findings here are slightly pessimistic, Open Sans
  being wider. `A11Y_TEST_FONT=roboto` audits that variant.
- **Shadows on.** `flutter test` paints shadows as solid black; the app's dialogs
  (elevation 24) would sit in a thick black frame. `debugDisableShadows` is false during
  a journey.
- **No debug banner; lifecycle state resumed; Android** as target platform (the
  `flutter test` default), English (`YiviApp(defaultLanguage: en_US)`), light theme (the
  app has no dark theme).
- **Audit config:** all 19 rules, `platform: null` (both tap-target guidelines), reflow
  at 2.0 text scale and 320 px, `sourceRoots` = `lib/`.
- **Dialogs, sheets and the lock screen are audited with what is under them.** The lock
  screen is an overlay stacked on the home screen, so home's widgets are in the tree
  while it shows. The overflow rules scan every `RenderFlex`, and report the bottom
  navigation bar's labels (`irma_nav_button.dart:54`) whether the bar is visible or
  covered: 105 of the 666 findings are at that line. Labellers should expect them on
  `pin*`, `error/blocked`, `error/no-internet`, `reset-pin*`, `terms-changed` and
  dialogs over a tab as well as on the tabs themselves.
- **One screen id per state.** A dialog over a screen is its own id and repeats the
  findings of the screen under it.
- **Dates.** Card and log dates are fixed; activity times are rendered in the host's
  time zone, and the "data expired" notification carries the time of the run.

## Exceptions

Recorded per screen in `runtime-screens.json` (`exceptions`, `asyncErrors`), not hidden.

- `issue-sms/country-picker`: every row of the country list (package
  intl_phone_number_input) reports the debug-only assertion "ListTile background color
  or ink splashes may be invisible" whenever it is built. Since flutter-a11y 0.4.1 a
  reflow pass that raises an error other than an overflow is aborted on its own and
  `auditScreen` throws `A11yReflowException` carrying the rest of the result (already
  in the findings file, with a `reflow-pass-aborted` diagnostic); the harness keeps
  that result and lists the aborted passes under `reflowNotRun` in the log, as
  `<rule> (<pass>): <first line of the error>`. Here the text scale 2.0x pass aborts,
  and so does putting the view back after it (the rows are rebuilt and assert again);
  after a failed restore `auditScreen` attempts no further pass, so the 320 px pass
  does not run either; since flutter-a11y 0.4.2 the engine names it among the
  failures ("not attempted, because the view could not be restored after text scale
  2.0x"), so the log lists it too (0.4.1 skipped it unnamed). Neither reflow rule is
  evaluated on this screen, as before. (Under 0.4.0 `reflowNotRun` held the first line
  of the rethrown error, and the screen was audited again with `reflow: false`; that
  retry is kept for any other `FlutterError`.)
- `issue-sms/verify` logs the assertions raised while the `back` step closes the
  country sheet (its rows are rebuilt during the transition), not leftovers of the
  previous audit.

## Screens audited (121)

| Group | Screens |
|---|---|
| `enrollment/` | introduction-1, -2, -3, terms, error-reporting-info, choose-pin, choose-pin-weak, secure-pin-rules, choose-long-pin, confirm-pin, pin-mismatch-dialog, email, email-invalid, email-sent, skip-email-dialog, failed, wallet-removed-dialog |
| `pin` | pin, entering-visible, wrong-dialog, blocked-dialog, blocked, biometric, biometric-offer-dialog, session-waiting, cancel-session-dialog, logged-out |
| `reset-pin` | reset-pin, delete-dialog |
| other start-up states | rooted-warning, name-changed, terms-changed |
| `error/` | startup, details-dialog, no-internet, blocked, cannot-start-session |
| `data` | data, empty, search, search-results, search-no-results |
| `credential/` | personal-data, two-cards, expired, options, delete-dialog, deleted |
| `add-data` | add-data, details, details-expanded |
| `issue-email/` | enter, verify, invalid-code, error, error-details |
| `issue-sms/` | enter, country-picker, verify |
| `document/` | passport-details, id-card-details, driving-licence-details, nfc-start, nfc-failed |
| `activity` | activity, empty, disclosure, signature, issuance, removal |
| `notifications` | notifications, empty |
| `more` | more, developer-mode |
| `settings` | settings, biometric, developer-mode, delete-dialog, pin-changed |
| `language` | language, choose |
| `change-pin/` | current, wrong-dialog, new, confirm, confirm-dialog |
| `help` | help, answer |
| `debug` | debug |
| `scanner` | scanner, not-a-yivi-code, camera-permission-dialog |
| `disclosure/` | introduction, overview, requestor-info, change-choice, add-optional, overview-with-optional, confirm-dialog, pin, pin-wrong, success, close-dialog, obtain-first, unverified-requestor, call-overview, call-info |
| `signature/` | overview, confirm-dialog, success |
| `issuance/` | permission, pin, success, transaction-code, transaction-code-wrong, browser-pending |
| `session/` | pairing-code, error-expired, error-no-internet, error, error-details |

Route coverage: 22 of the 41 routes in `routing.dart` are audited; the other 19 are
listed with a reason in `_notAudited` (and in `runtime-screens.json`). The last test
fails when a route is neither audited nor listed, or when a journey stops before its
end. Those are harness failures, not accessibility results.

## Not audited

Routes (see `_notAudited` for the exact text):

- `/update_required`: needs `Platform.operatingSystem` to be Android or iOS (above).
- `/mrz/reader/*` (camera reading a document's MRZ): needs the OCR processor of the app
  shell and the camera plugin.
- `/issue_wizard`, `/issue_wizard_success`: need an issue wizard of a requestor scheme;
  the mock scheme has none.
- `/nfc/id_card`, `/nfc/driving_licence`, `/nfc/residence_permit`,
  `/mrz/manual_entry/residence_permit`: same screens as the audited passport ones.
- `/reset_pin`: same `ResetPinScreen` as `reset-pin`.
- `/modal_pin`, `/unknown_session`, `/home/notifications`: nothing in `lib/` navigates
  to them. `/mrz`, `/mrz/manual_entry`, `/mrz/reader`, `/nfc`: empty parents.

Screens and states without a route:

- The splash screen and the onboarding animation: gone before a settled frame (the
  first audit of onboarding already shows the first introduction page).
- `ArrowBack` (the "go back to your browser" screen after a session started from a link):
  iOS only (`Platform.isIOS`). On the host, as on Android, the app asks to be sent to the
  background and returns to the Data tab.
- A successful NFC chip read, the face verification introduction, and the issuance that
  follows a document: need the NFC plugin and the passport issuer.
- "Obtain data" during a disclosure, "Reobtain", and the website issuers: open a
  browser (`url could not be opened` here).
- The certificate and scheme management screens behind the debug screen, and its
  session helper: developer tools; only the debug menu itself is audited.
- The store review dialogs: no review service is injected (as in the F-Droid build).
- OpenID4VCI transaction-code lockout, revoked and expiring-soon cards, problematic
  cards, the long-PIN lock screen, Dutch/German/French, landscape: not pumped.
- The scanner opened from the lock screen: same `ScannerScreen` as `scanner`.
