import 'dart:io';

import 'package:flutter/services.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 给真实像素预览 / golden 测试加载 M3E 语义图标字体（FushiSymbols / FushiSymbolsFilled）。
///
/// `flutter test` 不会自动加载 pubspec 里声明的应用字体，不加载时语义图标在截图里
/// 是方块。在 `setUpAll` 里 `await loadFushiIconFonts();`（需要真实 IO 的测试体里用
/// `tester.runAsync` 包住）。多次调用只加载一次。
Future<void> loadFushiIconFonts() async {
  if (_loaded) return;
  _loaded = true;
  await _load(
    kFushiSymbolsFontFamily,
    'assets/icon_fonts/FushiSymbolsRounded.ttf',
  );
  await _load(
    kFushiSymbolsFilledFontFamily,
    'assets/icon_fonts/FushiSymbolsRoundedFilled.ttf',
  );
}

bool _loaded = false;

Future<void> _load(String family, String path) async {
  final Uint8List bytes = await File(path).readAsBytes();
  final FontLoader loader = FontLoader(family)
    ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
  await loader.load();
}
