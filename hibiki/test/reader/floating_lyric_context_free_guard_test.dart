import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-953 守卫：悬浮歌词样式必须 context-free。
///
/// 根因：`_readerFloatingLyricStyle` 经 [AudiobookSession.installReaderSurfaces]
/// 注入到**进程级** session，悬浮窗样式可能在 reader 页 dispose / 未 mounted 之后
/// 被求值（退出书籍后台听书）。旧实现浅色强调色取 `Theme.of(context).colorScheme
/// .primary`，求值时 `State.context`（`_element!`）为 null →
/// "Null check operator used on a null value" → 有声书加载崩溃
/// （AudiobookSession.start → showFloatingLyricOverlay → floatingLyricStyle）。
///
/// 修复：accent 统一走 context-free 的 `_readerLyricAccentColor()`
/// （`appModel.buildColorScheme(...).primary`，与 ThemeData 的 ColorScheme 同源）。
/// 本守卫锁死整支 lyrics.part.dart 不再依赖 `Theme.of(context)`，防回归。
void main() {
  const String path =
      'lib/src/pages/implementations/reader_hibiki/lyrics.part.dart';

  late String src;

  setUpAll(() {
    src = File(path).readAsStringSync().replaceAll('\r\n', '\n');
  });

  test('lyrics.part.dart 全文不出现 Theme.of(context)（含悬浮窗样式 / 歌词渲染）', () {
    expect(
      src.contains('Theme.of(context)'),
      isFalse,
      reason: '悬浮歌词样式在进程级 session 求值，State.context 可能为 null；'
          '强调色必须走 context-free 的 _readerLyricAccentColor()',
    );
  });

  test('存在 context-free 强调色 helper _readerLyricAccentColor', () {
    expect(src.contains('Color _readerLyricAccentColor()'), isTrue,
        reason: '应抽出 context-free accent helper 统一三处用色');
    final int idx = src.indexOf('Color _readerLyricAccentColor()');
    expect(idx, greaterThan(0));
    final int end = src.indexOf('\n  }', idx);
    final String body = src.substring(idx, end);
    expect(body.contains('appModel.buildColorScheme('), isTrue,
        reason:
            'accent 浅色支必须取自 appModel.buildColorScheme（与 ThemeData 同源、context-free）');
    expect(body.contains('context'), isFalse,
        reason: 'accent helper 体内绝不可触碰 State.context');
  });

  test('悬浮窗样式 getter 用 _readerLyricAccentColor 取强调色', () {
    final int idx =
        src.indexOf('FloatingLyricStyle _readerFloatingLyricStyle(');
    expect(idx, greaterThan(0));
    final int end = src.indexOf('\n  }', idx);
    final String body = src.substring(idx, end);
    expect(body.contains('_readerLyricAccentColor()'), isTrue,
        reason: '悬浮窗样式 accent 必须经 context-free helper');
    expect(body.contains('Theme.of('), isFalse);
  });
}
