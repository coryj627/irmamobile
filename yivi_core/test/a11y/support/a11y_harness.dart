// Pumping, settling, auditing and bookkeeping for test/a11y/screens_a11y_test.dart.
import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:math" as math;
import "dart:ui" as ui;

import "package:flutter/rendering.dart";
import "package:flutter_a11y_test/flutter_a11y_test.dart";
import "package:flutter_test/flutter_test.dart";
import "package:go_router/go_router.dart";
import "package:material_ui/material_ui.dart";
import "package:yivi_core/routing.dart";

import "a11y_app.dart";
import "fake_core.dart";
import "wallet_data.dart" as data;

/// Phone viewport every screen starts from (logical px, DPR 3), the same as
/// flutter-a11y's tool/score_realapps_runtime.
const Size kPhoneSize = Size(412, 915);
const double kPhoneDpr = 3;

/// Upper bound when the view is grown to lay out a whole scrolling screen.
const double kMaxViewHeight = 8000;

/// Where the per-screen log is written, next to the findings the sink writes.
const String kScreensFile = ".a11y/flutter/runtime-screens.json";

/// The PIN of the wallet the fake core starts with.
const String kPin = "12345";

/// Findings are attributed to the app's own widgets, never to the harness.
A11yAuditConfig auditConfig({bool reflow = true}) => A11yAuditConfig(
  platform: null,
  reflow: reflow,
  sourceRoots: ["${Directory.current.path}/lib/"],
);

/// The wallet a test starts with.
enum Wallet {
  /// A freshly installed app: not registered, no PIN, no cards.
  fresh,

  /// Registered, PIN set, nothing added yet.
  empty,

  /// Registered, with the cards and activity of support/wallet_data.dart.
  filled,
}

/// A running app.
class Shell {
  Shell(this.tester, this.core, this.scanner);

  final WidgetTester tester;
  final FakeYiviCore core;
  final DarkCameraQrFactory scanner;

  /// The path the app's router is at, and whether something sits on top of the page it
  /// names (a dialog, a bottom sheet, the lock screen's own navigator).
  ({String location, bool covered}) get place {
    final context = rootNavigatorKey.currentContext;
    if (context == null) return (location: "", covered: false);
    final router = GoRouter.of(context);
    final configuration = router.routerDelegate.currentConfiguration;
    // A page the app pushed (`context.push`) is on top of the location it was pushed
    // from; the configuration's own URI still names the latter.
    final last = configuration.matches.isEmpty
        ? null
        : configuration.matches.last;
    final location = last is ImperativeRouteMatch
        ? last.matches.uri.path
        : configuration.uri.path;
    final stack = <Route<dynamic>>[
      for (final element
          in find
              .byWidgetPredicate(
                (w) => "${w.runtimeType}" == "_ModalScopeStatus",
                skipOffstage: false,
              )
              .evaluate())
        // ignore: avoid_dynamic_calls
        (element.widget as dynamic).route as Route<dynamic>,
    ];
    return (
      location: location,
      covered: stack.isNotEmpty && stack.last is! PageRoute<dynamic>,
    );
  }
}

/// Every path of the app's route table (routing.dart), read from the running router.
Set<String> routeTable(BuildContext context) {
  final paths = <String>{};
  void visit(List<RouteBase> routes, String parent) {
    for (final route in routes) {
      var path = parent;
      if (route is GoRoute) {
        path = route.path.startsWith("/")
            ? "${parent == "/" ? "" : parent}${route.path}"
            : "$parent/${route.path}";
        if (route.builder != null || route.pageBuilder != null) paths.add(path);
      }
      visit(route.routes, path);
    }
  }

  visit(GoRouter.of(context).configuration.routes, "");
  return paths;
}

/// Per-isolate log of screens, written by [ScreenLog.flush].
abstract final class ScreenLog {
  static final Map<String, Map<String, Object?>> _screens = {};
  static final Set<String> _coreEventsIgnored = {};

  static void audited(
    String id,
    A11yAuditResult result,
    Map<String, Object?> meta,
  ) {
    final rules = <String, int>{};
    for (final finding in result.findings) {
      rules[finding.ruleID] = (rules[finding.ruleID] ?? 0) + 1;
    }
    _screens[id] = {
      "status": "audited",
      "findingCount": result.findings.length,
      "rules": {
        for (final rule in rules.keys.toList()..sort()) rule: rules[rule],
      },
      "needsReview": result.needsReview.length,
      if (result.diagnostics.isNotEmpty)
        "diagnostics": [for (final d in result.diagnostics) d.id]..sort(),
      ...meta,
    };
  }

  static void notAudited(
    String id,
    String status,
    String reason, [
    Map<String, Object?> meta = const {},
  ]) {
    _screens[id] = {"status": status, "reason": reason, ...meta};
  }

  static Map<String, Object?>? of(String id) => _screens[id];

  static Iterable<String> get ids => _screens.keys;

  /// The route table of the app, and the routes at which a screen was audited.
  static final Set<String> routes = {};

  static Set<String> get auditedRoutes => {
    for (final screen in _screens.values)
      if (screen["status"] == "audited" && screen["route"] != null)
        screen["route"]! as String,
  };

  /// Extra top-level entries of the log (the route coverage).
  static final Map<String, Object?> summary = {};

  static void flush() {
    if (_screens.isEmpty) return;
    final ids = _screens.keys.toList()..sort();
    final file = File(kScreensFile)..parent.createSync(recursive: true);
    file.writeAsStringSync(
      "${const JsonEncoder.withIndent("  ").convert({
        "viewport": "${kPhoneSize.width.toInt()}x${kPhoneSize.height.toInt()}@${kPhoneDpr.toInt()}",
        "font": Platform.environment["A11Y_TEST_FONT"] ?? "app",
        "channelsTouched": touchedChannels.toList()..sort(),
        "coreEventsIgnored": _coreEventsIgnored.toList()..sort(),
        ...summary,
        "screens": {for (final id in ids) id: _screens[id]},
      })}\n",
    );
  }
}

String _firstLine(Object e) =>
    "$e".split("\n").first.trim().replaceAll(RegExp("#[0-9a-f]{5}"), "#_");

/// First line of every exception pending in [tester], drained (hash codes removed so the
/// log is deterministic).
List<String> takeExceptions(WidgetTester tester) {
  _collect(tester);
  final out = _collected.toList();
  _collected.clear();
  return out;
}

/// Exceptions taken from the tester since the last [takeExceptions].
final List<String> _collected = <String>[];

/// Moves the tester's pending exceptions to [_collected]. Called after every pump of
/// [settle]: `tester.runAsync` rethrows an exception that is still pending, which would
/// end the journey on a debug-only assertion of a widget.
void _collect(WidgetTester tester) {
  for (
    Object? e = tester.takeException();
    e != null;
    e = tester.takeException()
  ) {
    _collected.add(_firstLine(e));
  }
}

/// Lets real asynchronous work finish (asset loads, the translation files, image and
/// SVG decoding run outside the fake clock), interleaved with frames, then lets
/// fake-clock timers and transitions end. Bounded: the app has animations that never
/// end (progress indicators, Lottie loops), which is why this is not `pumpAndSettle`.
Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
  _collect(tester);
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
    _collect(tester);
  }
  await _precacheImages(tester);
  for (var i = 0; i < 30 && tester.binding.hasScheduledFrame; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    _collect(tester);
  }
}

/// Asset and memory images decode on a real isolate, so without this they are still
/// blank when the frame is audited.
Future<void> _precacheImages(WidgetTester tester) async {
  final images = find.byType(Image, skipOffstage: false).evaluate().toList();
  await tester.runAsync(() async {
    for (final element in images) {
      if (!element.mounted) continue;
      await precacheImage(
        (element.widget as Image).image,
        element,
        onError: (_, _) {},
      );
    }
  });
  await tester.pump();
  _collect(tester);
}

/// Starts the app the way a cold start does and waits for its first real screen.
Future<Shell> launch(
  WidgetTester tester, {
  Wallet wallet = Wallet.filled,
  Device? device,
  Trouble trouble = Trouble.none,
}) async {
  tester.view.devicePixelRatio = kPhoneDpr;
  tester.view.physicalSize = kPhoneSize * kPhoneDpr;
  addTearDown(tester.view.reset);

  device ??= Device(
    preferences: wallet == Wallet.fresh ? const {} : settledPreferences,
  );
  await installPlatformFakes(tester, device);

  final core = FakeYiviCore(
    enrolled: wallet != Wallet.fresh,
    pin: kPin,
    trouble: trouble,
    credentials: wallet == Wallet.filled ? data.filledWallet : null,
    logs: wallet == Wallet.filled ? data.activityLog : null,
  );
  final shell = Shell(tester, core, DarkCameraQrFactory());
  await tester.pumpWidget(
    buildApp(core: core, scanner: shell.scanner, device: device),
  );
  // The translation files are read with real IO; nothing is on screen before that.
  for (var i = 0; i < 20; i++) {
    await settle(tester, rounds: 3);
    if (find.byType(Text).evaluate().isNotEmpty) break;
  }
  await settle(tester);
  final context = rootNavigatorKey.currentContext;
  if (context != null) ScreenLog.routes.addAll(routeTable(context));
  return shell;
}

/// One step of a [journey]: a line of the small step language below, or a function for
/// what the language cannot say.
///
/// - `audit <screen id>`: audit what is on screen (`audit! <id>` keeps the phone viewport)
/// - `tap <text>`: tap the first widget showing exactly that text (else containing it);
///   `tap <text> @1` the second one, and likewise for `sem` and `key`
/// - `sem <label>`: tap the first widget whose semantics label starts with that
/// - `key <key>`: tap the widget with that `Key`
/// - `pin <digits>`: type on the app's PIN keypad
/// - `type <text>`: type into the focused (else the first) text field
/// - `link <url>`: open a session link, as when the user taps one in the browser
/// - `scan <url>`: point the camera of the open scanner at a session's QR code
/// - `scan-raw <text>`: point it at a QR code with that content
/// - `open <url>`: open any other link the app is registered for
/// - `wait <seconds>`: let that much time pass in the app
/// - `back`: the system back gesture
/// - `background`: leave the app and come back after six minutes (it locks itself)
typedef Step = Object;

/// Runs [steps] against a freshly started app. A step that fails ends the journey: every
/// `audit` after it is recorded as not audited, with the failing step and what was on
/// screen, and the run goes on with the next journey.
Future<void> journey(
  WidgetTester tester,
  List<Step> steps, {
  Wallet wallet = Wallet.filled,
  Device? device,
  Trouble trouble = Trouble.none,
}) async {
  await guarded(tester, () async {
    final shell = await launch(
      tester,
      wallet: wallet,
      device: device,
      trouble: trouble,
    );
    try {
      for (var i = 0; i < steps.length; i++) {
        final step = steps[i];
        try {
          if (step is Future<void> Function(Shell)) {
            await step(shell);
            await settle(tester);
          } else {
            await _runStep(shell, step as String);
          }
        } catch (e) {
          final what = step is String ? step : "step ${i + 1}";
          final reason = '"$what" failed: ${_firstLine(e)}';
          final seen = describeScreen(tester);
          // ignore: avoid_print
          print("a11y journey stopped: $reason\n$seen");
          for (final later
              in steps
                  .skip(i)
                  .whereType<String>()
                  .where((s) => s.startsWith("audit"))) {
            ScreenLog.notAudited(
              later.substring(later.indexOf(" ") + 1),
              "failed",
              reason,
            );
          }
          pendingFailures.add(reason);
          takeExceptions(tester);
          return;
        }
      }
    } finally {
      ScreenLog._coreEventsIgnored.addAll(shell.core.ignored);
      shell.core.close();
    }
  });
}

Future<void> _runStep(Shell shell, String step) async {
  final tester = shell.tester;
  final space = step.indexOf(" ");
  final op = space < 0 ? step : step.substring(0, space);
  var arg = space < 0 ? "" : step.substring(space + 1);
  // `tap Delete @1`: the second match instead of the first.
  var index = 0;
  final nth = RegExp(r" @(\d+)$").firstMatch(arg);
  if (nth != null && const {"tap", "sem", "key"}.contains(op)) {
    index = int.parse(nth.group(1)!);
    arg = arg.substring(0, nth.start);
  }
  switch (op) {
    case "audit" || "audit!":
      final place = shell.place;
      await audit(
        tester,
        arg,
        route: place.location,
        covered: place.covered,
        grow: op == "audit",
      );
    case "show":
      // ignore: avoid_print
      print("--- ${shell.place}\n${describeScreen(tester)}");
    case "tap":
      await tapText(tester, arg, index: index);
    case "sem":
      await tapSemantics(tester, arg, index: index);
    case "key":
      await _tap(tester, () => find.byKey(Key(arg)), 'key "$arg"', index);
    case "pin":
      await enterPin(tester, arg);
    case "type":
      await typeText(tester, arg);
    case "link":
      shell.core.openUrl(
        "https://open.yivi.app/-/session#${Uri.encodeComponent(data.sessionQr(arg))}",
      );
      await _wait(tester, 1);
    case "scan":
      shell.scanner.scan(data.sessionQr(arg));
      await _wait(tester, 1);
    case "scan-raw":
      shell.scanner.scan(arg);
      await _wait(tester, 1);
    case "open":
      shell.core.openUrl(arg);
      await _wait(tester, 1);
    case "wait":
      await _wait(tester, int.parse(arg));
    case "back":
      await tester.binding.handlePopRoute();
      await settle(tester);
    case "background":
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 6));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
    default:
      throw ArgumentError('unknown step "$step"');
  }
}

Future<void> _wait(WidgetTester tester, int seconds) async {
  for (var i = 0; i < seconds * 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await settle(tester);
}

/// Largest distance any on-screen vertical scrollable can still scroll.
double _remainingScroll(WidgetTester tester) {
  var extent = 0.0;
  for (final element in find.byType(Scrollable).evaluate()) {
    final state = (element as StatefulElement).state as ScrollableState;
    final position = state.position;
    if (position.axis != Axis.vertical || !position.hasContentDimensions) {
      continue;
    }
    extent = math.max(extent, position.maxScrollExtent - position.pixels);
  }
  return extent;
}

/// Audits what is on screen under [screenId] and records it. Never throws: a failure is
/// recorded on the screen.
///
/// The view is first grown until the screen's vertical scrollables have nothing left to
/// scroll (or [kMaxViewHeight]), so content below the fold is laid out, has semantics and
/// is audited as if scrolled through; [grow] false keeps the phone viewport, for screens
/// whose layout is the viewport (the camera preview).
Future<A11yAuditResult?> audit(
  WidgetTester tester,
  String screenId, {
  String? route,
  bool covered = false,
  bool grow = true,
}) async {
  final meta = <String, Object?>{"route": ?route, if (covered) "covered": true};
  if (ScreenLog.of(screenId)?["status"] == "audited") {
    throw StateError("screen id $screenId is audited twice");
  }
  try {
    await settle(tester);
    final exceptions = takeExceptions(tester);

    var height = kPhoneSize.height;
    if (grow) {
      for (var i = 0; i < 8; i++) {
        final extent = _remainingScroll(tester);
        if (extent < 1 || height >= kMaxViewHeight) break;
        height = math.min(kMaxViewHeight, height + extent).ceilToDouble();
        tester.view.physicalSize = Size(kPhoneSize.width, height) * kPhoneDpr;
        await tester.pump();
        await settle(tester, rounds: 2);
      }
    }
    final remaining = _remainingScroll(tester);
    exceptions.addAll(takeExceptions(tester));

    await _screenshot(tester, screenId);
    A11yAuditResult result;
    String? reflowNotRun;
    try {
      result = await auditScreen(
        tester,
        screenId: screenId,
        config: auditConfig(),
      );
    } on FlutterError catch (e) {
      // The reflow phase rethrows any error a widget reports while it is laid out
      // again that is not an overflow, and the findings of the phases before it are
      // lost with it. A screen whose widgets report a debug-only assertion on every
      // build (see README.md, "Exceptions") is audited without the two reflow rules
      // rather than not at all; the log says so.
      reflowNotRun = _firstLine(e);
      tester.view.physicalSize = Size(kPhoneSize.width, height) * kPhoneDpr;
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      await tester.pump();
      exceptions.addAll(takeExceptions(tester));
      result = await auditScreen(
        tester,
        screenId: screenId,
        config: auditConfig(reflow: false),
      );
    }
    exceptions.addAll(takeExceptions(tester));
    final distinct = exceptions.toSet().toList()..sort();
    ScreenLog.audited(screenId, result, {
      ...meta,
      "viewport":
          "${kPhoneSize.width.toInt()}x${height.toInt()}@${kPhoneDpr.toInt()}",
      if (remaining >= 1) "remainingScrollPx": remaining.round(),
      "reflowNotRun": ?reflowNotRun,
      if (distinct.isNotEmpty) "exceptions": distinct,
    });
    // ignore: avoid_print
    print(
      "a11y $screenId at $route: ${result.findings.length} finding(s)"
      '${exceptions.isEmpty ? '' : ', ${exceptions.length} exception(s)'}',
    );
    tester.view.physicalSize = kPhoneSize * kPhoneDpr;
    await tester.pump();
    return result;
  } catch (e, stack) {
    if (Platform.environment["A11Y_DEBUG"] != null) {
      // ignore: avoid_print
      print("a11y audit error: $e\n$stack");
    }
    ScreenLog.notAudited(screenId, "failed", _firstLine(e), meta);
    // ignore: avoid_print
    print("a11y $screenId: NOT AUDITED: ${_firstLine(e)}");
    takeExceptions(tester);
    return null;
  }
}

/// With `A11Y_SCREENSHOTS=<directory>` in the environment, writes a PNG of each screen as
/// it is audited (at 1 px per logical px), for the people who label the findings.
Future<void> _screenshot(WidgetTester tester, String screenId) async {
  final directory = Platform.environment["A11Y_SCREENSHOTS"];
  if (directory == null || directory.isEmpty) return;
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final size = view.size;
  await tester.runAsync(() async {
    final image = await layer.toImage(
      Offset.zero & (size * kPhoneDpr),
      pixelRatio: 1 / kPhoneDpr,
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    final file = File("$directory/${screenId.replaceAll("/", "__")}.png")
      ..parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// Runs [body] so that an uncaught asynchronous error of the app is recorded on the
/// screens audited in this test instead of ending the run, and takes the app down at the
/// end so no timer of it outlives the test.
Future<void> guarded(WidgetTester tester, Future<void> Function() body) async {
  final before = ScreenLog._screens.keys.toSet();
  final asyncErrors = <String>[];
  final done = Completer<void>();
  String? failure;
  // ignore: unawaited_futures, the zone's body reports through [done]
  runZonedGuarded(
    () async {
      try {
        await body();
      } catch (e) {
        failure = _firstLine(e);
      } finally {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
          await settle(tester, rounds: 2);
          // The splash screen's start-up watchdog (15 s) and the idle lock (5 min).
          await tester.pump(const Duration(minutes: 6));
          takeExceptions(tester);
        } finally {
          debugDisableShadows = true;
          if (!done.isCompleted) done.complete();
        }
      }
    },
    (e, stack) {
      asyncErrors.add(_firstLine(e));
      if (Platform.environment["A11Y_DEBUG"] != null) {
        // ignore: avoid_print
        print("a11y async error: $e\n$stack");
      }
    },
  );
  await done.future;
  final mine = ScreenLog._screens.keys.toSet().difference(before);
  for (final id in mine) {
    if (asyncErrors.isNotEmpty) {
      ScreenLog._screens[id]!["asyncErrors"] = asyncErrors.toSet().toList()
        ..sort();
    }
    if (failure != null) ScreenLog._screens[id]!["testFailure"] = failure;
  }
  if (failure != null) {
    // ignore: avoid_print
    print("a11y test body stopped: $failure");
    pendingFailures.add(failure!);
  }
}

/// Journeys that stopped before their end. They are reported by the coverage test at the
/// end, not swallowed.
final List<String> pendingFailures = <String>[];

/// Waits for [target] to match something: lets pending loads finish, then scrolls the
/// screen's main list down a page at a time, as a user looking for a button would.
Future<void> _lookFor(WidgetTester tester, Finder Function() target) async {
  for (var i = 0; i < 6 && target().evaluate().isEmpty; i++) {
    await settle(tester, rounds: 3);
  }
  for (var i = 0; i < 12 && target().evaluate().isEmpty; i++) {
    ScrollPosition? furthest;
    for (final element in tester.elementList(find.byType(Scrollable))) {
      final position =
          ((element as StatefulElement).state as ScrollableState).position;
      if (position.axis != Axis.vertical || !position.hasContentDimensions) {
        continue;
      }
      if (furthest == null || position.extentAfter > furthest.extentAfter) {
        furthest = position;
      }
    }
    if (furthest == null || furthest.extentAfter < 1) break;
    furthest.jumpTo(math.min(furthest.maxScrollExtent, furthest.pixels + 400));
    await tester.pump(const Duration(milliseconds: 100));
    await settle(tester, rounds: 1);
  }
}

Future<void> _tap(
  WidgetTester tester,
  Finder Function() find,
  String what,
  int index,
) async {
  await _lookFor(tester, find);
  final all = find();
  if (all.evaluate().isEmpty) throw StateError("nothing with $what on screen");
  // Prefer what can actually be hit: a page under the current one can show the same
  // text.
  if (find().hitTestable().evaluate().length <= index) {
    await tester.ensureVisible(all.at(index));
    await tester.pump(const Duration(milliseconds: 300));
  }
  final hittable = find().hitTestable();
  final target = hittable.evaluate().length > index
      ? hittable.at(index)
      : find().at(index);
  await tester.tap(target, warnIfMissed: false);
  await settle(tester);
}

/// Taps the first widget showing exactly [text] (else containing it), scrolling to it
/// first, and lets the app react.
Future<void> tapText(WidgetTester tester, String text, {int index = 0}) {
  Finder find_() {
    final exact = find.text(text, findRichText: true);
    return exact.evaluate().isNotEmpty
        ? exact
        : find.textContaining(text, findRichText: true);
  }

  return _tap(tester, find_, 'text "$text"', index);
}

/// Taps the first widget whose semantics label starts with [label].
Future<void> tapSemantics(WidgetTester tester, String label, {int index = 0}) {
  final pattern = RegExp("^${RegExp.escape(label)}");
  return _tap(
    tester,
    () => find.bySemanticsLabel(pattern),
    'semantics label "$label"',
    index,
  );
}

/// A step that taps the [index]th [icon] on screen (for buttons with no text or label).
Future<void> Function(Shell) tapIcon(IconData icon, {int index = 0}) =>
    (shell) => _tap(shell.tester, () => find.byIcon(icon), "icon $icon", index);

/// Types [pin] on the app's own PIN keypad and waits for the core to answer.
Future<void> enterPin(WidgetTester tester, String pin) async {
  for (final digit in pin.split("")) {
    await tester.tap(
      find.byKey(Key("number_pad_key_$digit")).hitTestable().first,
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await settle(tester);
}

/// Types [text] into the focused text field, or the first one on screen.
Future<void> typeText(WidgetTester tester, String text) async {
  // A code field (pinput) shows boxes over an editable text that takes no taps.
  var fields = find.byType(EditableText).hitTestable();
  if (fields.evaluate().isEmpty) fields = find.byType(EditableText);
  if (fields.evaluate().isEmpty) throw StateError("no text field on screen");
  final focused = fields.evaluate().where(
    (e) => (e.widget as EditableText).focusNode.hasFocus,
  );
  final target = focused.isNotEmpty
      ? find.byElementPredicate((e) => e == focused.first)
      : fields.first;
  await tester.enterText(target, text);
  await settle(tester);
}

/// Labels of what is on screen, for working out a flow: every visible text, and every
/// semantics node with a tap action.
String describeScreen(WidgetTester tester) {
  final texts = <String>[];
  for (final element in find.byType(Text).hitTestable().evaluate()) {
    final widget = element.widget as Text;
    final value = widget.data ?? widget.textSpan?.toPlainText() ?? "";
    if (value.trim().isNotEmpty) texts.add(value.replaceAll("\n", " / "));
  }
  final tappable = <String>[];
  void visit(SemanticsNode node) {
    final data = node.getSemanticsData();
    if (data.hasAction(ui.SemanticsAction.tap) &&
        !data.flagsCollection.isHidden) {
      tappable.add(
        data.label.isEmpty
            ? "<${data.tooltip}|${data.value}>"
            : data.label.replaceAll("\n", " / "),
      );
    }
    node.visitChildren((child) {
      visit(child);
      return true;
    });
  }

  final root =
      tester.binding.renderViews.first.owner?.semanticsOwner?.rootSemanticsNode;
  if (root != null) visit(root);
  final keys = <String>{
    for (final element
        in find
            .byWidgetPredicate((w) => w.key is ValueKey<String>)
            .hitTestable()
            .evaluate())
      if ((element.widget.key! as ValueKey<String>).value.length < 60)
        (element.widget.key! as ValueKey<String>).value,
  };
  return "TEXT: ${texts.join(" | ")}\nTAP: ${tappable.join(" | ")}\nKEYS: ${keys.join(" ")}";
}
