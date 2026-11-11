// Picked up by `flutter test` for the files in test/a11y/ only (Flutter uses the nearest
// flutter_test_config.dart; yivi_core has none of its own, so the app's other tests are
// untouched). It adds the flutter_a11y_test findings sink, the per-screen log, the
// app's fonts and the preferences store.
import "dart:async";

import "package:flutter_a11y_test/flutter_a11y_test.dart";
import "package:flutter_test/flutter_test.dart";

import "support/a11y_app.dart";
import "support/a11y_harness.dart";
import "support/fonts.dart";

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  RuntimeFindingsSink.configure(); // .a11y/flutter/runtime-findings.json
  tearDownAll(RuntimeFindingsSink.flush);
  tearDownAll(ScreenLog.flush);
  await loadFonts();
  await initSharedPreferences();
  await testMain();
}
