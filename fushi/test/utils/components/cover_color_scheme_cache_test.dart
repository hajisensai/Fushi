import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_continue_card_row.dart';

ImageProvider _img(String name) => AssetImage('cover/$name.png');

void main() {
  test('evicts least recently used entries beyond capacity', () {
    final CoverColorSchemeCache cache = CoverColorSchemeCache(capacity: 2);
    final ColorScheme a = ColorScheme.fromSeed(seedColor: Colors.red);
    final ColorScheme b = ColorScheme.fromSeed(seedColor: Colors.green);
    final ColorScheme c = ColorScheme.fromSeed(seedColor: Colors.blue);

    cache.debugStore(_img('a'), Brightness.light, a);
    cache.debugStore(_img('b'), Brightness.light, b);
    // 命中 a：a 变成最近使用，b 成为最旧。
    expect(cache.peek(_img('a'), Brightness.light), same(a));
    cache.debugStore(_img('c'), Brightness.light, c);

    expect(cache.length, 2);
    expect(cache.peek(_img('b'), Brightness.light), isNull);
    expect(cache.peek(_img('a'), Brightness.light), same(a));
    expect(cache.peek(_img('c'), Brightness.light), same(c));
  });

  test('brightness is part of the key', () {
    final CoverColorSchemeCache cache = CoverColorSchemeCache(capacity: 4);
    final ColorScheme light = ColorScheme.fromSeed(seedColor: Colors.red);
    cache.debugStore(_img('a'), Brightness.light, light);
    expect(cache.peek(_img('a'), Brightness.dark), isNull);
    expect(cache.peek(_img('a'), Brightness.light), same(light));
  });

  test('resolve returns cached value without recomputing', () async {
    final CoverColorSchemeCache cache = CoverColorSchemeCache(capacity: 4);
    final ColorScheme a = ColorScheme.fromSeed(seedColor: Colors.red);
    cache.debugStore(_img('a'), Brightness.light, a);
    expect(await cache.resolve(_img('a'), Brightness.light), same(a));
  });
}
