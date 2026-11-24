import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_fit_title.dart';
import 'package:material_ui/material_ui.dart';

/// [fushiFitTitleFontSize] 的字号缓存：同输入复用、任一输入变了重算、有界、
/// 字体集变化整表作废。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const TextStyle style = TextStyle(fontWeight: FontWeight.w900, height: 0.92);

  double? fit(String text, {Size box = const Size(300, 120)}) =>
      fushiFitTitleFontSize(
        text: text,
        style: style,
        box: box,
        minSize: 10,
        maxSize: 200,
        direction: TextDirection.ltr,
      );

  setUp(debugFushiFitTitleCacheClear);
  tearDown(debugFushiFitTitleCacheClear);

  test('同一输入复用：结果相同、不新增条目', () {
    final double? first = fit('Watermark title here');
    expect(first, isNotNull);
    expect(debugFushiFitTitleCacheLength, 1);
    expect(fit('Watermark title here'), first);
    expect(debugFushiFitTitleCacheLength, 1);
  });

  test('任一输入变了就重算（新条目），结果与独立计算一致', () {
    final double? wide = fit('Watermark title here');
    final double? narrow = fit(
      'Watermark title here',
      box: const Size(120, 120),
    );
    expect(debugFushiFitTitleCacheLength, 2);
    expect(narrow, isNot(wide));
    // 换样式（字重）也是新键。
    fushiFitTitleFontSize(
      text: 'Watermark title here',
      style: style.copyWith(fontWeight: FontWeight.w400),
      box: const Size(300, 120),
      minSize: 10,
      maxSize: 200,
      direction: TextDirection.ltr,
    );
    expect(debugFushiFitTitleCacheLength, 3);
    // 清空后重算得到同样的值（缓存不改变结果）。
    debugFushiFitTitleCacheClear();
    expect(fit('Watermark title here', box: const Size(120, 120)), narrow);
  });

  test('放不下（null）也记住', () {
    expect(fit('A very long title', box: const Size(40, 12)), isNull);
    expect(debugFushiFitTitleCacheLength, 1);
    expect(fit('A very long title', box: const Size(40, 12)), isNull);
    expect(debugFushiFitTitleCacheLength, 1);
  });

  test('空标题 / 空盒子不进缓存', () {
    expect(fit('   '), isNull);
    expect(fit('x', box: Size.zero), isNull);
    expect(debugFushiFitTitleCacheLength, 0);
  });

  test('有界：超过容量从最久未用的淘汰', () {
    for (int i = 0; i < 600; i++) {
      fit('T$i');
    }
    expect(debugFushiFitTitleCacheLength, 512);
  });

  test('字体集变化（systemFonts）整表作废', () async {
    fit('Watermark title here');
    expect(debugFushiFitTitleCacheLength, 1);
    await PaintingBinding.instance.handleSystemMessage(<String, Object?>{
      'type': 'fontsChange',
    });
    expect(debugFushiFitTitleCacheLength, 0);
  });
}
