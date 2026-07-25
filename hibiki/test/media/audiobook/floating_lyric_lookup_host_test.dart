import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_lookup_host.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_controller.dart';

/// TODO-354 ① 行为守卫：书架/首页（无 reader）开的悬浮字幕点词必须路由进常驻主窗口
/// 查词宿主，而不再被 app 级 no-op handler 吞掉。
///
/// [FloatingLyricLookupNotifier] 是 app 级默认 handler 与 [FloatingLyricLookupHost]
/// 之间的请求总线。这里钉住其纯逻辑：
///  - requestLookup 推请求并 notify；
///  - 空白文本忽略（不 notify、不留挂起请求）；
///  - consume 取出后清空（避免 host 重建重复弹）。
///
/// 另钉住本表面补常驻热槽（BUG-094 预热复用）后的命中拦截判据
/// [FloatingLyricLookupHost.shouldBlockHitTest]：热槽常驻使
/// [DictionaryPopupController.entries] 永不为空，旧判据 `entries.isNotEmpty` 会把
/// 整层 [IgnorePointer] 永久翻成可命中，隐身热槽吃掉底下页面与悬浮歌词的所有点击。
void main() {
  final FloatingLyricLookupNotifier notifier =
      FloatingLyricLookupNotifier.instance;

  setUp(notifier.debugReset);
  tearDown(notifier.debugReset);

  test('requestLookup stores the request and notifies', () {
    int notified = 0;
    void listener() => notified++;
    notifier.addListener(listener);
    addTearDown(() => notifier.removeListener(listener));

    notifier.requestLookup('日本語', 1);

    expect(notified, 1);
    expect(notifier.pending, isNotNull);
    expect(notifier.pending?.text, '日本語');
    expect(notifier.pending?.index, 1);
  });

  test('requestLookup ignores blank text (no notify, no pending)', () {
    int notified = 0;
    void listener() => notified++;
    notifier.addListener(listener);
    addTearDown(() => notifier.removeListener(listener));

    notifier.requestLookup('   ', 0);

    expect(notified, 0, reason: '空白文本不应触发查词');
    expect(notifier.pending, isNull);
  });

  test('consume returns and clears the pending request', () {
    notifier.requestLookup('言葉', 0);
    expect(notifier.pending, isNotNull);

    final FloatingLyricLookupRequest? req = notifier.consume();
    expect(req?.text, '言葉');
    expect(notifier.pending, isNull, reason: 'consume 后应清空，避免重复弹');

    expect(notifier.consume(), isNull, reason: '二次 consume 应返回 null');
  });

  group('shouldBlockHitTest 命中拦截判据（热槽常驻后不得误拦）', () {
    test('热槽存在但无可见弹窗 → 不拦截命中（核心回归场景）', () {
      final DictionaryPopupController popup =
          DictionaryPopupController(lowMemory: false)..seedWarmSlot();
      expect(popup.entries, isNotEmpty,
          reason: '前置：热槽常驻后 entries 永不空（旧判据在此必然误拦）');
      expect(popup.hasVisiblePopup, isFalse);
      expect(FloatingLyricLookupHost.shouldBlockHitTest(popup), isFalse,
          reason: '隐身热槽（停屏外预热）不得拦截底下页面/悬浮歌词的点击');
      popup.dispose();
    });

    test('搜索期占位显示 → 拦截；endSearchUi 后放行', () {
      final DictionaryPopupController popup =
          DictionaryPopupController(lowMemory: false)..seedWarmSlot();
      popup.beginSearchUi(const Rect.fromLTWH(10, 10, 1, 1));
      expect(FloatingLyricLookupHost.shouldBlockHitTest(popup), isTrue,
          reason: '搜索期加载占位卡在屏上，本层要参与命中');
      popup.endSearchUi();
      expect(FloatingLyricLookupHost.shouldBlockHitTest(popup), isFalse);
      popup.dispose();
    });

    test('弹窗可见 → 拦截；dismiss 回隐身热槽 → 放行', () {
      final DictionaryPopupController popup =
          DictionaryPopupController(lowMemory: false)..seedWarmSlot();
      final DictionaryPopupEntry e = popup.beginTop(
        term: 'あ',
        rect: const Rect.fromLTWH(1, 2, 3, 4),
        reuseWarmSlot: true,
        replaceStack: false,
        visible: false,
      );
      popup.fillResult(e, result: null, allLoaded: true);
      popup.show(e);
      expect(FloatingLyricLookupHost.shouldBlockHitTest(popup), isTrue);
      popup.dismissAt(0);
      expect(popup.entries, isNotEmpty, reason: '热槽保留（隐身复位）');
      expect(FloatingLyricLookupHost.shouldBlockHitTest(popup), isFalse,
          reason: '关栈后热槽仍在但已隐身，必须立刻放行命中');
      popup.dispose();
    });
  });

  group('宿主接线源码守卫（BUG-094/135 热槽预热）', () {
    final String src =
        File('lib/src/media/audiobook/floating_lyric_lookup_host.dart')
            .readAsStringSync();

    test('IgnorePointer 判据走 shouldBlockHitTest，不再用 entries.isNotEmpty', () {
      expect(
          src, contains('FloatingLyricLookupHost.shouldBlockHitTest(_popup)'),
          reason: 'build 必须用可见性判据决定是否拦截命中');
      expect(src.contains('_popup.entries.isNotEmpty'), isFalse,
          reason: '热槽常驻后 entries.isNotEmpty 判据 = 永久吃掉点击（回归）');
    });

    test('热槽 seed + 顶层查词 reuseWarmSlot + Stack Clip.none', () {
      expect(src, contains('seedWarmSlot('),
          reason: '本表面必须 seed 常驻热槽，否则每次查词 WebView 冷载');
      expect(src, contains('reuseWarmSlot: true'), reason: '顶层查词必须原地复用热槽');
      expect(src, contains('clipBehavior: Clip.none'),
          reason: '停屏外的隐藏热槽会被默认 hardEdge 裁掉而失温');
    });
  });
}
