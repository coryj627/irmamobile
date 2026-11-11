// The app the accessibility audit pumps: `YiviApp` (lib/yivi_core.dart) inside the same
// `ProviderScope` `runYiviApp()` builds, with nothing replaced inside the app.
//
// The substitutions are at the edges of the Dart code, where a device would answer:
// the bridge to the Go core (support/fake_core.dart), the services the app shell
// (yivi_app) injects from native SDKs, platform channels, and the asset bundle's
// package prefix. Each one is listed in README.md.
import "dart:convert";
import "dart:io";

import "package:flutter/services.dart";
import "package:flutter_riverpod/flutter_riverpod.dart";
import "package:flutter_riverpod/misc.dart";
import "package:flutter_test/flutter_test.dart";
import "package:local_auth/local_auth.dart";
import "package:material_ui/material_ui.dart";
import "package:package_info_plus/package_info_plus.dart";
import "package:shared_preferences/shared_preferences.dart";
import "package:streaming_shared_preferences/streaming_shared_preferences.dart";
import "package:visibility_detector/visibility_detector.dart";
import "package:yivi_core/package_name.dart";
import "package:yivi_core/src/data/irma_preferences.dart";
import "package:yivi_core/src/models/session.dart";
import "package:yivi_core/src/providers/irma_repository_provider.dart";
import "package:yivi_core/src/providers/preferences_provider.dart";
import "package:yivi_core/src/providers/store_review_provider.dart";
import "package:yivi_core/src/screens/pin/providers/biometric_provider.dart";
import "package:yivi_core/yivi_core.dart";

import "a11y_app.dart" as a11y_app;
import "fake_core.dart";
import "wallet_data.dart" as data;

/// The terms the app asks the user to accept (the URLs `runYiviApp` passes).
const termsUrlNl = "https://yivi.app/terms_and_conditions_v3/";
const termsUrlEn = "https://yivi.app/en/terms_and_conditions_v3/";

/// Channels the app sent a message to during this isolate's run, for the README's list
/// of what a device would have answered.
final Set<String> touchedChannels = <String>{};

/// The one `StreamingSharedPreferences` of this isolate. The package caches its instance
/// in a static, as a future; a future completed inside one test's fake-async zone never
/// calls back in the next test, so the instance is fetched once, outside any test (see
/// flutter_test_config.dart), and handed to the app's `IrmaPreferences` constructor.
late final StreamingSharedPreferences sharedPreferences;

Future<void> initSharedPreferences() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  sharedPreferences = await StreamingSharedPreferences.instance;
}

/// A camera preview that never receives a frame.
///
/// The scanner the app ships is `MobileScannerQrFactory` in the app shell
/// (yivi_app/lib/qr_scanner_factory.dart), a texture fed by the phone's camera; yivi_core
/// only knows the `QrScannerFactory` interface. Under `flutter test` there is no camera,
/// so the viewfinder area is the black a texture shows before its first frame. The
/// harness "scans" by calling [scan], which is what the real widget does on a detection.
class DarkCameraQrFactory implements QrScannerFactory {
  void Function(String code)? _onCodeFound;

  void scan(String code) => _onCodeFound?.call(code);

  @override
  Widget build({required void Function(String code) onCodeFound}) {
    _onCodeFound = onCodeFound;
    return const ColoredBox(color: Color(0xFF000000), child: SizedBox.expand());
  }
}

/// A phone's biometric sensor: enrolled fingerprint or none, and a scan that the user
/// cancels (so the PIN screen stays up).
class _Biometrics implements LocalAuthentication {
  _Biometrics({required this.enrolled});

  final bool enrolled;

  @override
  Future<bool> isDeviceSupported() async => enrolled;

  @override
  Future<bool> get canCheckBiometrics async => enrolled;

  @override
  Future<List<BiometricType>> getAvailableBiometrics() async =>
      enrolled ? const [BiometricType.fingerprint] : const [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #authenticate) {
      return Future<bool>.value(false);
    }
    if (invocation.memberName == #stopAuthentication) {
      return Future<bool>.value(true);
    }
    return super.noSuchMethod(invocation);
  }
}

/// The code the fake issuers below send by email and text message.
const verificationCode = "482915";

/// Yivi's email issuer (https://email-issuer.yivi.app), behind the provider the app has
/// for it: it "sends" the email, accepts [verificationCode] and then hands out the link
/// of the session in which the fake core issues the email address.
class _EmailIssuer implements EmailIssuerApi {
  _EmailIssuer(this.trouble);

  final Trouble trouble;

  @override
  Future<void> sendEmail({
    required String emailAddress,
    required String language,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (trouble == Trouble.issuerDown) {
      throw EmailIssuanceInternalServerError(
        message: '{"error":"error_internal"}',
      );
    }
  }

  @override
  Future<SessionPointer> verifyCode({
    required String email,
    required String verificationCode,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (verificationCode != a11y_app.verificationCode) {
      throw EmailIssuanceInvalidCodeError();
    }
    // As the app's own client of this API does (DefaultEmailIssuerApi.verifyCode).
    return (Pointer.fromString(data.sessionQr(data.emailIssuanceUrl))
          as SessionPointer)
      ..continueOnSecondDevice = true;
  }
}

/// Yivi's SMS issuer, likewise.
class _SmsIssuer implements SmsIssuerApi {
  _SmsIssuer(this.trouble);

  final Trouble trouble;

  @override
  Future<void> sendSms({
    required String phoneNumber,
    required String language,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (trouble == Trouble.issuerDown) {
      throw SmsIssuanceInternalServerError(
        message: '{"error":"error_internal"}',
      );
    }
  }

  @override
  Future<SessionPointer> verifyCode({
    required String phoneNumber,
    required String verificationCode,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (verificationCode != a11y_app.verificationCode) {
      throw SmsIssuanceInvalidCodeError();
    }
    // As the app's own client of this API does (DefaultEmailIssuerApi.verifyCode).
    return (Pointer.fromString(data.sessionQr(data.emailIssuanceUrl))
          as SessionPointer)
      ..continueOnSecondDevice = true;
  }
}

/// The device and install the app runs on.
class Device {
  const Device({
    this.rooted = false,
    this.biometrics = false,
    this.cameraGranted = true,
    this.preferences = const {},
  });

  /// What the root / jailbreak check reports.
  final bool rooted;

  /// Whether a fingerprint is enrolled (the app then offers biometric unlock).
  final bool biometrics;

  /// The answer to the camera permission request.
  final bool cameraGranted;

  /// Stored preferences of this install, by the app's own keys
  /// (lib/src/data/irma_preferences.dart). Empty: a fresh install.
  final Map<String, Object> preferences;
}

/// Preferences of an install whose user finished onboarding a while ago: terms accepted,
/// five-digit PIN, the rename notice ("IRMA is now Yivi") and the first-session
/// explanation already seen, and the biometric offer declined.
const settledPreferences = <String, Object>{
  "preference.accepted_terms_url": termsUrlNl,
  "preference.long_pin": false,
  "preference.show_name_changed_notification": false,
  "preference.completed_disclosure_permission_intro": true,
  "preference.biometric_prompt_dismissed": true,
};

/// Replaces what the host platform would provide. Call before the app is pumped.
Future<void> installPlatformFakes(WidgetTester tester, Device device) async {
  // What the "More" tab prints as the app version (yivi_app/pubspec.yaml).
  PackageInfo.setMockInitialValues(
    appName: "Yivi",
    packageName: "org.irmacard.cardemu",
    version: "8.4.0",
    buildNumber: "4194524",
    buildSignature: "",
  );

  // rootBundle caches the future of every string and manifest it has loaded; one
  // completed in an earlier test's fake-async zone would never call back in this test.
  rootBundle.clear();

  // A release build has no "DEBUG" ribbon; under `flutter test` MaterialApp would paint
  // one over the top-right corner of every screen, where the app has buttons.
  WidgetsApp.debugAllowBannerOverride = false;
  addTearDown(() => WidgetsApp.debugAllowBannerOverride = true);

  // `flutter test` paints every shadow as a solid black block (so goldens do not
  // depend on blur). The app's dialogs have an elevation of 24: they would be audited
  // inside a thick black frame that no user sees.
  // (Restored at the end of the journey, in `guarded`: flutter_test checks it before
  // tear-down callbacks run.)
  debugDisableShadows = false;

  // The app is in the foreground.
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

  // The package batches its callbacks on a 500 ms timer; a pending one at the end of a
  // test would fail it.
  VisibilityDetectorController.instance.updateInterval = Duration.zero;

  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.allMessagesHandler = (channel, handler, message) async {
    if (!channel.startsWith("flutter/")) touchedChannels.add(channel);
    return handler?.call(message);
  };
  addTearDown(() => messenger.allMessagesHandler = null);

  // The app names its assets `packages/yivi_core/assets/...` (lib/package_name.dart),
  // which is where they are in the bundle of an app that depends on yivi_core. This
  // test runs in the yivi_core package itself, whose test bundle has the same files
  // under `assets/...`, so the prefix is dropped here and the bytes come from the
  // package directory.
  messenger.setMockMessageHandler("flutter/assets", (message) async {
    final key = Uri.decodeFull(utf8.decode(message!.buffer.asUint8List()));
    const prefix = "packages/$packageName/";
    final file = File(
      key.startsWith(prefix)
          ? key.substring(prefix.length)
          : "build/unit_test_assets/$key",
    );
    if (!file.existsSync()) return null;
    return ByteData.sublistView(file.readAsBytesSync());
  });
  addTearDown(() => messenger.setMockMessageHandler("flutter/assets", null));

  void answer(String channel, Object? Function(MethodCall call) handler) {
    final methodChannel = MethodChannel(channel);
    messenger.setMockMethodCallHandler(
      methodChannel,
      (call) async => handler(call),
    );
    addTearDown(() => messenger.setMockMethodCallHandler(methodChannel, null));
  }

  // The app's own native code (yivi_core/android, yivi_core/ios).
  answer("yivi.app/root_detection", (call) => device.rooted);
  answer("privacy_screen", (call) => null);
  answer("irma.app/iiab", (call) => null);
  // permission_handler: 1 = granted, 4 = permanently denied (the user said no before;
  // the system does not ask again and the app points to the settings instead).
  final status = device.cameraGranted ? 1 : 4;
  answer(
    "flutter.baseflow.com/permissions/methods",
    (call) => switch (call.method) {
      "checkPermissionStatus" => status,
      "requestPermissions" => <int, int>{
        for (final permission in call.arguments as List)
          permission as int: status,
      },
      "checkServiceStatus" => 1,
      "shouldShowRequestPermissionRationale" => false,
      "openAppSettings" => true,
      _ => null,
    },
  );
  // Links to web pages and the share sheet open nothing.
  answer("plugins.flutter.io/url_launcher", (call) => false);
  answer("plugins.flutter.io/url_launcher_macos", (call) => false);
  answer("dev.fluttercommunity.plus/share", (call) => null);

  await sharedPreferences.clear();
  for (final MapEntry(:key, :value) in device.preferences.entries) {
    switch (value) {
      case final bool v:
        await sharedPreferences.setBool(key, v);
      case final String v:
        await sharedPreferences.setString(key, v);
      case final int v:
        await sharedPreferences.setInt(key, v);
      default:
        throw ArgumentError(
          "preference $key: unsupported ${value.runtimeType}",
        );
    }
  }
}

/// The widget `runYiviApp()` hands to `runApp`, with the same overrides: preferences,
/// the services the app shell injects, and (the one addition) the Go core.
///
/// What yivi_app injects from native SDKs is absent here, as in the F-Droid build for
/// most of it: no OCR processor (documents are entered by hand), no SMS retriever, no
/// face verification, no store review prompt.
Widget buildApp({
  required FakeYiviCore core,
  required DarkCameraQrFactory scanner,
  required Device device,
}) {
  final preferences = IrmaPreferences(
    sharedPreferences,
    mostRecentTermsUrlNl: termsUrlNl,
    mostRecentTermsUrlEn: termsUrlEn,
  );
  return ProviderScope(
    overrides: <Override>[
      preferencesProvider.overrideWithValue(preferences),
      ocrProcessorProvider.overrideWithValue(null),
      smsRetrieverProvider.overrideWithValue(null),
      qrScannerFactoryProvider.overrideWithValue(scanner),
      regulaFaceServiceProvider.overrideWith((ref) => null),
      storeReviewServiceProvider.overrideWithValue(null),
      irmaRepositoryProvider.overrideWith(
        (ref) => IrmaRepository(client: core, preferences: preferences),
      ),
      localAuthProvider.overrideWithValue(
        _Biometrics(enrolled: device.biometrics),
      ),
      emailIssuerApiProvider.overrideWithValue(_EmailIssuer(core.trouble)),
      smsIssuerApiProvider.overrideWithValue(_SmsIssuer(core.trouble)),
    ],
    // Without a language the app follows the system, which under `flutter test` is
    // the language of the machine running it.
    child: const YiviApp(defaultLanguage: Locale("en", "US")),
  );
}
