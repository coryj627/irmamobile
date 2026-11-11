// Real fonts for the audit. `flutter test` renders every glyph of its default font as a
// 1 em square, which makes text wider than on a device and the two overflow rules
// over-report (flutter_a11y_test README, "Fonts").
import "dart:convert";
import "dart:io";

import "package:flutter/services.dart";

/// Loads the fonts the app's theme and icons name.
///
/// - `Open Sans` and `Alexandria` (lib/src/theme/theme.dart) and `IrmaIcons`, from the
///   files yivi_core's pubspec.yaml declares.
/// - `MaterialIcons` and `Roboto` from the Flutter SDK's cache.
/// - `CupertinoIcons` from the cupertino_icons package, under the package-qualified
///   name `CupertinoIcons` icons ask for.
///
/// `A11Y_TEST_FONT=ahem` loads nothing (the default test font, to compare against).
/// `A11Y_TEST_FONT=roboto` registers Roboto under the names `Open Sans` and `Alexandria`;
/// see README.md, "Fonts", for why that may be what an Android phone shows.
Future<void> loadFonts() async {
  final mode = Platform.environment["A11Y_TEST_FONT"] ?? "app";
  if (mode == "ahem") return;

  Future<void> load(String family, Iterable<String> paths) async {
    final loader = FontLoader(family);
    for (final path in paths) {
      final file = File(path);
      if (!file.existsSync()) {
        throw StateError("a11y harness: font file missing: $path");
      }
      loader.addFont(
        file.readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
      );
    }
    await loader.load();
  }

  final flutterRoot = Platform.environment["FLUTTER_ROOT"];
  if (flutterRoot == null) {
    throw StateError("a11y harness: FLUTTER_ROOT is not set");
  }
  final materialFonts = "$flutterRoot/bin/cache/artifacts/material_fonts";
  final roboto = [
    for (final style in ["Regular", "Medium", "Bold"])
      "$materialFonts/Roboto-$style.ttf",
  ];
  await load("MaterialIcons", ["$materialFonts/MaterialIcons-Regular.otf"]);
  await load("Roboto", roboto);

  final declared = _pubspecFonts();
  for (final MapEntry(key: family, value: assets) in declared.entries) {
    final text = family != "IrmaIcons";
    await load(family, mode == "roboto" && text ? roboto : assets);
  }

  await load("packages/cupertino_icons/CupertinoIcons", [
    "${_packageRoot("cupertino_icons")}/assets/CupertinoIcons.ttf",
  ]);
}

/// Family name to asset paths, read from the `fonts:` section of pubspec.yaml (a small
/// line-based reader, to avoid a YAML dependency).
Map<String, List<String>> _pubspecFonts() {
  final result = <String, List<String>>{};
  String? family;
  var inFonts = false;
  for (final line in File("pubspec.yaml").readAsLinesSync()) {
    if (line == "  fonts:") {
      inFonts = true;
      continue;
    }
    if (!inFonts) continue;
    if (line.isNotEmpty && !line.startsWith("    ")) break;
    final trimmed = line.trim();
    if (trimmed.startsWith("- family:")) {
      family = trimmed.substring("- family:".length).trim();
      result[family] = [];
    } else if (trimmed.startsWith("- asset:") && family != null) {
      result[family]!.add(trimmed.substring("- asset:".length).trim());
    }
  }
  if (result.isEmpty) {
    throw StateError("a11y harness: no fonts in pubspec.yaml");
  }
  return result;
}

/// Directory of a dependency, from the package configuration `pub get` wrote.
String _packageRoot(String name) {
  final config =
      jsonDecode(File(".dart_tool/package_config.json").readAsStringSync())
          as Map<String, dynamic>;
  for (final package in config["packages"] as List) {
    if ((package as Map)["name"] == name) {
      final uri = Uri.parse(package["rootUri"] as String);
      return uri.isAbsolute
          ? uri.toFilePath()
          : Directory(".dart_tool").uri.resolveUri(uri).toFilePath();
    }
  }
  throw StateError("a11y harness: package $name is not a dependency");
}
