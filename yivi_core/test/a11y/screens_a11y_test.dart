// Accessibility audit of the app's screens (flutter_a11y_test, layer "runtime"), on this
// fork only: dogfood of https://github.com/coryj627/flutter-a11y.
//
//   flutter test test/a11y
//
// Every journey starts the real app (`YiviApp` in the `ProviderScope` of `runYiviApp`,
// see support/a11y_app.dart) over a stand-in for the Go core (support/fake_core.dart)
// and walks to a screen the way a user does: tapping, typing the PIN, scanning a QR
// code, opening a link. No screen, bloc, provider or repository of the app is replaced.
//
// Findings are RECORDED, not asserted: the RuntimeFindingsSink configured in
// flutter_test_config.dart writes them to .a11y/flutter/runtime-findings.json, and
// `a11y_check_flutter scan` decides against the committed baseline what fails CI. What
// was and was not audited, with pump-time exceptions per screen, is written to
// .a11y/flutter/runtime-screens.json. See README.md in this directory.
import "package:flutter_test/flutter_test.dart";
import "package:material_ui/material_ui.dart" show Icons;

import "support/a11y_app.dart";
import "support/a11y_harness.dart";
import "support/fake_core.dart";
import "support/wallet_data.dart" as data;

const _pin = kPin;

/// A PIN the app accepts as secure (three different digits, no keyboard pattern).
const _newPin = "13579";

const _bookshop = "https://boekhandeldekker.example/yivi/session";
const _nijmegen = "https://www.nijmegen.example/yivi/session";

/// What every journey of a registered user starts with.
const _unlock = "pin $_pin";

/// From first launch to the PIN being chosen.
const _throughPinSetup = <Step>[
  "wait 3",
  "key enrollment_next_button",
  "key enrollment_next_button",
  "key enrollment_next_button",
  "key accept_terms_checkbox",
  "key enrollment_next_button",
  "pin $_newPin",
  "pin $_newPin",
];

/// Routes of routing.dart that no journey reaches, and why. The coverage test at the
/// end fails when a route is neither audited nor listed here, so a route added upstream
/// cannot go unnoticed.
const _notAudited = <String, String>{
  "/reset_pin":
      "opened from the screen for a remotely blocked account; it builds the same "
      "ResetPinScreen that the lock screen opens on its own navigator, audited as reset-pin",
  "/mrz":
      "an empty parent of the document routes (`Container()`); nothing navigates to it",
  "/mrz/manual_entry": "see /mrz",
  "/mrz/reader": "see /mrz",
  "/nfc": "see /mrz",
  "/modal_pin":
      "nothing in lib/ navigates to this route (`pushModalPin` has no caller)",
  "/unknown_session":
      "nothing in lib/ navigates to this route (`pushUnknownSessionScreen` has no caller)",
  "/home/notifications":
      "nothing in lib/ navigates to this route (`goNotificationsScreen` has no caller); the "
      "screen it builds is the Notifications tab, audited as notifications",
  "/issue_wizard":
      "needs an issue wizard of a requestor scheme; the app's mock scheme has none "
      '("IssueWizards": {}) and the requestor schemes are submodules that are not checked out',
  "/issue_wizard_success": "end of the issue wizard, see /issue_wizard",
  "/update_required":
      "shown when a scheme asks for a newer app build than the installed one; "
      "`IrmaRepository.getVersionInformation` reads that per `Platform.operatingSystem` and "
      "throws on any host but Android and iOS, so the core is served without scheme managers "
      "(support/fake_core.dart) and no update is ever required",
  "/mrz/reader/passport":
      "the camera view that reads a document's machine readable zone; shown only when the "
      "app shell injects an OCR processor (Google ML Kit, in yivi_app) and needs the camera "
      "plugin. Without one the app opens the manual entry screen, which is audited",
  "/mrz/reader/id_card": "see /mrz/reader/passport",
  "/mrz/reader/driving_licence": "see /mrz/reader/passport",
  "/mrz/reader/residence_permit": "see /mrz/reader/passport",
  "/mrz/manual_entry/residence_permit":
      "the residence permit is not in the credential store this harness serves; the route "
      "builds the same PassportMrzManualEntryScreen as the passport and identity card routes",
  "/nfc/id_card":
      "same NfcReadingScreen as /nfc/passport, which is audited before and after a failed read",
  "/nfc/driving_licence": "see /nfc/id_card",
  "/nfc/residence_permit": "see /nfc/id_card",
};

void main() {
  group("first run", () {
    testWidgets("introduction, terms, PIN, email, empty wallet", (
      tester,
    ) async {
      await journey(tester, wallet: Wallet.fresh, [
        "wait 3",
        "audit enrollment/introduction-1",
        "key enrollment_next_button",
        "audit enrollment/introduction-2",
        "key enrollment_next_button",
        "audit enrollment/introduction-3",
        "key enrollment_next_button",
        "audit enrollment/terms",
        "sem Optional @1",
        "audit enrollment/error-reporting-info",
        "back",
        "key accept_terms_checkbox",
        "key enrollment_next_button",
        "audit enrollment/choose-pin",
        "pin 12345",
        "audit enrollment/choose-pin-weak",
        "tap PIN possibly not secure",
        "audit enrollment/secure-pin-rules",
        "back",
        "tap Prefer a longer PIN?",
        "audit enrollment/choose-long-pin",
        "tap Prefer a shorter PIN?",
        "pin $_newPin",
        "audit enrollment/confirm-pin",
        "pin 13570",
        "audit enrollment/pin-mismatch-dialog",
        "tap OK",
        "pin $_newPin",
        "pin $_newPin",
        "audit enrollment/email",
        "type willeke",
        "audit enrollment/email-invalid",
        "type willeke.debruijn@example.nl",
        "key bottom_bar_primary",
        "wait 2",
        "audit enrollment/email-sent",
        "key bottom_bar_primary",
        "wait 2",
        "audit data/empty",
        "key nav_button_activity",
        "audit activity/empty",
        "key nav_button_notifications",
        "audit notifications/empty",
      ]);
    });

    testWidgets("skipping the email address; registration fails offline", (
      tester,
    ) async {
      await journey(tester, wallet: Wallet.fresh, trouble: Trouble.offline, [
        ..._throughPinSetup,
        "tap Skip",
        "audit enrollment/skip-email-dialog",
        "key dialog_confirm_button",
        "wait 2",
        "audit enrollment/failed",
      ]);
    });

    testWidgets("forgot PIN, start all over", (tester) async {
      await journey(tester, [
        "tap I forgot my PIN",
        "audit reset-pin",
        "tap Start all over",
        "audit reset-pin/delete-dialog",
        "key dialog_confirm_button",
        "wait 2",
        "audit enrollment/wallet-removed-dialog",
      ]);
    });
  });

  group("lock screen", () {
    testWidgets("PIN, wrong PIN, blocked", (tester) async {
      await journey(tester, [
        "audit pin",
        "sem Show PIN",
        "pin 11",
        "audit pin/entering-visible",
        "pin 111",
        "audit pin/wrong-dialog",
        "tap Try again",
        "pin 11111",
        "tap Try again",
        "pin 11111",
        "audit pin/blocked-dialog",
        "tap Try again",
        "audit pin/blocked",
      ]);
    });

    testWidgets("biometric unlock enabled", (tester) async {
      await journey(
        tester,
        device: const Device(
          biometrics: true,
          preferences: {
            "preference.accepted_terms_url": termsUrlNl,
            "preference.long_pin": false,
            "preference.show_name_changed_notification": false,
            "preference.completed_disclosure_permission_intro": true,
            "preference.biometric_enabled": true,
          },
        ),
        [
          "audit pin/biometric",
          _unlock,
          "key nav_button_more",
          "key open_settings_screen_button",
          "audit settings/biometric",
        ],
      );
    });

    testWidgets("biometric unlock offered after the first unlock", (
      tester,
    ) async {
      await journey(
        tester,
        device: const Device(
          biometrics: true,
          preferences: {
            "preference.accepted_terms_url": termsUrlNl,
            "preference.long_pin": false,
            "preference.show_name_changed_notification": false,
          },
        ),
        [_unlock, "audit pin/biometric-offer-dialog"],
      );
    });

    testWidgets("no connection", (tester) async {
      await journey(tester, trouble: Trouble.offline, [
        _unlock,
        "audit error/no-internet",
      ]);
    });

    testWidgets("account blocked at the keyshare server", (tester) async {
      await journey(tester, trouble: Trouble.blockedRemotely, [
        _unlock,
        "audit error/blocked",
      ]);
    });

    testWidgets("the core cannot start", (tester) async {
      await journey(tester, trouble: Trouble.cannotStart, [
        "audit error/startup",
        "tap Show technical details",
        "audit error/details-dialog",
      ]);
    });

    testWidgets("rooted device", (tester) async {
      await journey(
        tester,
        device: const Device(rooted: true, preferences: settledPreferences),
        ["audit rooted-warning"],
      );
    });

    testWidgets("rename notice for a user from before Yivi", (tester) async {
      await journey(
        tester,
        device: const Device(
          preferences: {
            "preference.accepted_terms_url": termsUrlNl,
            "preference.long_pin": false,
          },
        ),
        [_unlock, "audit name-changed"],
      );
    });

    testWidgets("new terms and conditions", (tester) async {
      await journey(
        tester,
        device: const Device(
          preferences: {
            "preference.accepted_terms_url":
                "https://yivi.app/terms_and_conditions_v2/",
            "preference.long_pin": false,
            "preference.show_name_changed_notification": false,
          },
        ),
        ["audit terms-changed"],
      );
    });

    testWidgets("a link opened while locked", (tester) async {
      await journey(tester, [
        "link $_bookshop/order",
        "audit pin/session-waiting",
        "sem Close",
        "audit pin/cancel-session-dialog",
      ]);
    });

    testWidgets("log out", (tester) async {
      await journey(tester, [
        _unlock,
        "key nav_button_more",
        "key log_out_button",
        "audit pin/logged-out",
      ]);
    });
  });

  group("data", () {
    testWidgets("cards, card details, delete, search", (tester) async {
      await journey(tester, [
        _unlock,
        "audit data",
        "key pbdf.gemeente.personalData_tile",
        "audit credential/personal-data",
        "back",
        "key pbdf.pbdf.surfnet-2_tile",
        "audit credential/expired",
        "back",
        "key pbdf.pbdf.email_tile",
        "audit credential/two-cards",
        tapIcon(Icons.more_horiz_sharp),
        "audit credential/options",
        "tap Delete data",
        "audit credential/delete-dialog",
        "key dialog_confirm_button",
        "wait 1",
        "audit credential/deleted",
        "back",
        "key search_button",
        "audit data/search",
        "type email",
        "audit data/search-results",
        "type passport",
        "audit data/search-no-results",
      ]);
    });

    testWidgets("add data, an email address", (tester) async {
      await journey(tester, [
        _unlock,
        "sem Obtain data",
        "audit add-data",
        "key pbdf.sidn-pbdf.email_tile",
        "audit add-data/details",
        "tap What can I do with this data?",
        "tap How does it work?",
        "audit add-data/details-expanded",
        "key bottom_bar_primary",
        "audit issue-email/enter",
        "type willeke.debruijn@example.nl",
        "key bottom_bar_primary",
        "wait 1",
        "audit issue-email/verify",
        "type 111111",
        "wait 1",
        "audit issue-email/invalid-code",
        "type $verificationCode",
        "wait 2",
        "audit issuance/permission",
        "key bottom_bar_primary",
        "wait 1",
        "audit issuance/pin",
        "pin $_pin",
        "wait 2",
        "audit issuance/success",
      ]);
    });

    testWidgets("add data, the issuer is down", (tester) async {
      await journey(tester, trouble: Trouble.issuerDown, [
        _unlock,
        "sem Obtain data",
        "key pbdf.sidn-pbdf.email_tile",
        "key bottom_bar_primary",
        "type willeke.debruijn@example.nl",
        "key bottom_bar_primary",
        "wait 1",
        "audit issue-email/error",
        "tap Show technical details",
        "audit issue-email/error-details",
      ]);
    });

    testWidgets("add data, a phone number", (tester) async {
      await journey(tester, [
        _unlock,
        "sem Obtain data",
        "key pbdf.sidn-pbdf.mobilenumber_tile",
        "key bottom_bar_primary",
        "audit issue-sms/enter",
        "key intl_dropdown_key",
        "audit! issue-sms/country-picker",
        "back",
        "type 612345678",
        "key bottom_bar_primary",
        "wait 1",
        "audit issue-sms/verify",
      ]);
    });

    testWidgets("add data, a passport", (tester) async {
      await journey(tester, [
        _unlock,
        "sem Obtain data",
        "key pbdf.pbdf.passport_tile",
        "key bottom_bar_primary",
        "audit document/passport-details",
        "key document_nr_input_field",
        "type NXC4F7KL2",
        "key passport_dob_field",
        "type 1965-03-10",
        "key passport_expiry_date_field",
        "type 2031-06-18",
        "key bottom_bar_primary",
        "wait 1",
        "audit document/nfc-start",
        "key bottom_bar_primary",
        "wait 2",
        "audit document/nfc-failed",
      ]);
    });

    testWidgets("add data, an identity card and a driving licence", (
      tester,
    ) async {
      await journey(tester, [
        _unlock,
        "sem Obtain data",
        "key pbdf.pbdf.idcard_tile",
        "key bottom_bar_primary",
        "audit document/id-card-details",
        "back",
        "back",
        "key pbdf.pbdf.drivinglicence_tile",
        "key bottom_bar_primary",
        "audit document/driving-licence-details",
      ]);
    });
  });

  group("activity and notifications", () {
    testWidgets("activity", (tester) async {
      await journey(tester, [
        _unlock,
        "key nav_button_activity",
        "audit activity",
        "tap Boekhandel Dekker",
        "audit activity/disclosure",
        "back",
        "tap Gemeente Nijmegen",
        "audit activity/signature",
        "back",
        "tap Data received",
        "audit activity/issuance",
        "back",
        "tap Data deleted",
        "audit activity/removal",
      ]);
    });

    testWidgets("notifications", (tester) async {
      await journey(tester, [
        _unlock,
        "key nav_button_notifications",
        "audit notifications",
      ]);
    });
  });

  group("more", () {
    testWidgets("settings, language, change PIN", (tester) async {
      await journey(tester, [
        _unlock,
        "key nav_button_more",
        "audit more",
        "key open_settings_screen_button",
        "audit settings",
        "key change_language_link",
        "audit language",
        "key use_system_language_toggle",
        "audit language/choose",
        "back",
        "key delete_link",
        "audit settings/delete-dialog",
        "key dialog_cancel_button",
        "key change_pin_link",
        "audit change-pin/current",
        "pin 11111",
        "audit change-pin/wrong-dialog",
        "tap Try again",
        "pin $_pin",
        "audit change-pin/new",
        "pin 24680",
        "audit change-pin/confirm",
        "pin 24680",
        "audit change-pin/confirm-dialog",
        "key dialog_confirm_button",
        "wait 1",
        "audit settings/pin-changed",
      ]);
    });

    testWidgets("frequently asked questions", (tester) async {
      await journey(tester, [
        _unlock,
        "key nav_button_more",
        "tap Frequently asked questions",
        "audit help",
        "tap How to use Yivi for logging onto a mobile website?",
        "audit help/answer",
      ]);
    });

    testWidgets("developer mode", (tester) async {
      await journey(tester, [
        _unlock,
        "key nav_button_more",
        for (var i = 0; i < 7; i++) "tap Version",
        "audit more/developer-mode",
        "tap Debugging",
        "audit debug",
        "back",
        "key open_settings_screen_button",
        "audit settings/developer-mode",
      ]);
    });
  });

  group("scanner", () {
    testWidgets("camera, not a Yivi code, a code the app cannot start", (
      tester,
    ) async {
      await journey(tester, [
        _unlock,
        "key nav_button_scanner",
        "audit! scanner",
        "scan-raw https://www.example.org/menu",
        "audit! scanner/not-a-yivi-code",
        "wait 4",
        'scan-raw {"wizard":"irma-demo-requestors.ivido.demo-client"}',
        "audit error/cannot-start-session",
      ]);
    });

    testWidgets("camera permission denied", (tester) async {
      await journey(
        tester,
        device: const Device(
          cameraGranted: false,
          preferences: settledPreferences,
        ),
        [
          _unlock,
          "key nav_button_scanner",
          "audit scanner/camera-permission-dialog",
        ],
      );
    });
  });

  group("sessions", () {
    testWidgets("first disclosure, from a QR code", (tester) async {
      await journey(
        tester,
        device: const Device(
          preferences: {
            "preference.accepted_terms_url": termsUrlNl,
            "preference.long_pin": false,
            "preference.show_name_changed_notification": false,
            "preference.biometric_prompt_dismissed": true,
          },
        ),
        [
          _unlock,
          "key nav_button_scanner",
          "scan $_bookshop/order",
          "audit disclosure/introduction",
          "tap Get going",
          "audit disclosure/overview",
          "tap What does this mean?",
          "audit disclosure/requestor-info",
          "back",
          "tap Change choice",
          "audit disclosure/change-choice",
          "tap w.debruijn@bibliotheek.example.nl",
          "key bottom_bar_primary",
          "tap Add optional data",
          "audit disclosure/add-optional",
          "key bottom_bar_primary",
          "audit disclosure/overview-with-optional",
          "key bottom_bar_primary",
          "audit disclosure/confirm-dialog",
          "key dialog_confirm_button",
          "wait 1",
          "audit disclosure/pin",
          "pin 11111",
          "audit disclosure/pin-wrong",
          "tap Try again",
          "pin $_pin",
          "wait 2",
          "audit disclosure/success",
        ],
      );
    });

    testWidgets("disclosure from a link, closing it", (tester) async {
      await journey(tester, [
        _unlock,
        "link $_bookshop/order",
        "sem Close",
        "audit disclosure/close-dialog",
      ]);
    });

    testWidgets("disclosure that ends in a phone call", (tester) async {
      await journey(tester, [
        _unlock,
        "link $_nijmegen/call-centre",
        "audit disclosure/call-overview",
        "key bottom_bar_primary",
        "key dialog_confirm_button",
        "wait 1",
        "pin $_pin",
        "wait 2",
        "audit disclosure/call-info",
      ]);
    });

    testWidgets("data that has to be obtained first", (tester) async {
      await journey(tester, [
        _unlock,
        "link $_nijmegen/idin",
        "audit disclosure/obtain-first",
      ]);
    });

    testWidgets("signature", (tester) async {
      await journey(tester, [
        _unlock,
        "key nav_button_scanner",
        "scan $_nijmegen/parking-permit",
        "audit signature/overview",
        "key bottom_bar_primary",
        "audit signature/confirm-dialog",
        "key dialog_confirm_button",
        "wait 1",
        "pin $_pin",
        "wait 2",
        "audit signature/success",
      ]);
    });

    testWidgets("unverified requestor", (tester) async {
      await journey(tester, [
        _unlock,
        "link https://demo.yivi.example/session/unverified",
        "audit disclosure/unverified-requestor",
      ]);
    });

    testWidgets("pairing code", (tester) async {
      await journey(tester, [
        _unlock,
        "key nav_button_scanner",
        "scan $_bookshop/pairing",
        "audit session/pairing-code",
      ]);
    });

    testWidgets("expired session", (tester) async {
      await journey(tester, [
        _unlock,
        "link $_bookshop/expired",
        "audit session/error-expired",
      ]);
    });

    testWidgets("no connection to the requestor", (tester) async {
      await journey(tester, [
        _unlock,
        "link $_bookshop/offline",
        "audit session/error-no-internet",
      ]);
    });

    testWidgets("unexpected answer from the requestor", (tester) async {
      await journey(tester, [
        _unlock,
        "link $_bookshop/broken",
        "audit session/error",
        "tap Show technical details",
        "audit session/error-details",
      ]);
    });

    testWidgets("credential offer with a transaction code", (tester) async {
      await journey(tester, [
        _unlock,
        "open ${data.diplomaOfferCode}",
        "audit issuance/transaction-code",
        "type 0000",
        "wait 1",
        "audit issuance/transaction-code-wrong",
      ]);
    });

    testWidgets("credential offer that continues in the browser", (
      tester,
    ) async {
      await journey(tester, [
        _unlock,
        "open ${data.diplomaOfferLogin}",
        "audit issuance/browser-pending",
      ]);
    });
  });

  // Last: the journeys above fill the log this reads.
  test("every route of the route table is audited or listed with a reason", () {
    final table = ScreenLog.routes;
    final audited = ScreenLog.auditedRoutes;
    final unaccounted = table
        .difference(audited)
        .difference(_notAudited.keys.toSet());
    final stale = _notAudited.keys.where(audited.contains).toList();
    ScreenLog.summary["routes"] = {
      "inRouteTable": table.length,
      "audited": table.intersection(audited).toList()..sort(),
      "notAudited": {
        for (final route in table.difference(audited).toList()..sort())
          route: _notAudited[route] ?? "NOT ACCOUNTED FOR",
      },
    };
    expect(table, isNotEmpty, reason: "no journey started the app");
    expect(
      unaccounted,
      isEmpty,
      reason: "routes neither audited nor listed in _notAudited",
    );
    expect(
      stale,
      isEmpty,
      reason: "routes listed in _notAudited that are audited now",
    );
    // A journey that stopped early is a harness failure (a label changed upstream),
    // not an accessibility result: its screens are in the log as "failed".
    expect(
      pendingFailures,
      isEmpty,
      reason: "journeys that did not reach their end",
    );
  });
}
