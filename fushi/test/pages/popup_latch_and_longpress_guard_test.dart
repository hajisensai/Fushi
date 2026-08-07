import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 源码扫描守卫（BUG-912 #2 / #3 / BUG-914）。
///
/// 三条独立回归防护，都用源码文本断言（涉及私有 State / 静态字段，
/// 无法用 widget 测试直接触达）：
///
/// 1. BUG-912 #2：`dictionary_popup_webview.dart` 不得再有进程级
///    `_inlineAssetsLoadFailed` 永久失败闩。Windows/iOS 内联资产路径下，
///    一次瞬时读盘异常（文件锁 / 磁盘抖动）不该把整进程永久降级到不可靠
///    的 file:// 路径；成功后 `_inlineCss != null` 已能防重复读盘。
/// 2. BUG-914：同文件不得再有 `[dict-perf]` 热路径打点探针。
/// 3. BUG-912 #3：`reader_quick_settings_sheet.dart` 的 `_RepeatIconButton`
///    长按手势必须挂 `onLongPressCancel`，否则手势被取消（指针滑出 /
///    识别器被夺走）时 `_timer` 会持续连触直到 dispose。
void main() {
  String read(String path) => File(path).readAsStringSync();

  const String popupWebviewPath =
      'lib/src/pages/implementations/dictionary_popup_webview.dart';
  const String quickSettingsPath =
      'lib/src/media/audiobook/reader_quick_settings_sheet.dart';

  test('BUG-912 #2：弹窗内联资产不再有进程级永久失败闩', () {
    final String src = read(popupWebviewPath);
    expect(
      src.contains('_inlineAssetsLoadFailed'),
      isFalse,
      reason: '$popupWebviewPath 不应再有 _inlineAssetsLoadFailed 永久闩'
          '（一次瞬时读盘异常会把内联资产永久降级到 file://，无复位路径）',
    );
    // 门控只判 _inlineCss 非空即可防重复读盘；断言不含永久失败闩条件。
    final Match? gate = RegExp(
      r'if\s*\(\s*_inlineCss\s*!=\s*null([^)]*)\)\s*return;',
    ).firstMatch(src);
    expect(gate, isNotNull,
        reason: '应保留 `if (_inlineCss != null) return;` 防重复读盘守卫');
    expect(
      gate!.group(1)!.contains('Failed') || gate.group(1)!.contains('||'),
      isFalse,
      reason: '内联资产门控不应再叠加永久失败闩条件（BUG-912 #2）',
    );
  });

  test('BUG-914：弹窗注入热路径不再有 [dict-perf] 计时探针', () {
    final String src = read(popupWebviewPath);
    expect(
      src.contains('[dict-perf]'),
      isFalse,
      reason: '$popupWebviewPath 不应再有 [dict-perf] 打点（热路径噪声，BUG-914）',
    );
    expect(
      src.contains('swInject'),
      isFalse,
      reason: '$popupWebviewPath 不应再有 swInject 计时 Stopwatch（死变量，BUG-914）',
    );
  });

  test('BUG-912 #3：_RepeatIconButton 长按手势挂 onLongPressCancel', () {
    final String src = read(quickSettingsPath);
    final int classIdx = src.indexOf('class _RepeatIconButtonState');
    expect(classIdx, greaterThanOrEqualTo(0),
        reason: '$quickSettingsPath 应存在 _RepeatIconButtonState');
    final int buildIdx = src.indexOf('GestureDetector', classIdx);
    expect(buildIdx, greaterThanOrEqualTo(0),
        reason: '_RepeatIconButtonState.build 应有 GestureDetector');
    // 截取该 GestureDetector 到其 child 之间的构造参数块。
    final String body = src.substring(
        buildIdx, classIdx + 1600 < src.length ? classIdx + 1600 : src.length);
    expect(
      body.contains('onLongPressCancel'),
      isTrue,
      reason: '_RepeatIconButton 的 GestureDetector 必须挂 onLongPressCancel，'
          '否则手势被取消时 _timer 持续连触（BUG-912 #3）',
    );
  });
}
