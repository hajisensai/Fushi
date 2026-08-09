import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_lookup_host.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';

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

  // ---------------------------------------------------------------------------
  // TODO-2584：`shouldBlockHitTest` 为什么**有意**不接对话框隐藏计数
  // ---------------------------------------------------------------------------
  //
  // BUG-797/1040（弹窗层 visible）、BUG-1327（barrier）、BUG-1364（搜索期占位卡）三处
  // 都必须与 `_popupHidingDialogDepth` 相与，于是本判据看上去像"第四处漏网"。逐条复核
  // 后结论是**不改**：它与那三处极性相反。那三处是「往树里放一个会画、会吃点击的东西」，
  // 漏接计数 = 对话框被盖住 / 点不着；这里 `true` 只是把外层 `IgnorePointer` 的
  // `ignoring` 翻成 **false**（"不强制忽略"），本身不拦截任何东西——拦不拦由子项决定，
  // 而两个子项在对话框期间都已让位。
  //
  // 下面两条用**真的** `parkedPopupLayer` 复刻本 host 的图层形态直接观测点击落到谁身上：
  // 第一条是负向控制（子项在场时确实吃得掉点击，证明 harness 不是空跑），第二条钉死
  // 「子项让位后即便 `ignoring == false`，点击照常穿到底下」。
  group('对话框期间点击穿透（shouldBlockHitTest 有意不接对话框计数）', () {
    const Size screen = Size(800, 600); // = flutter_test 默认视口，停屏外才真在屏外。

    Widget harness({
      required DictionaryPopupController popup,
      required bool childrenYielded,
      required VoidCallback onUnderTap,
    }) {
      Widget opaqueBlock(Color color) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
            child: ColoredBox(color: color),
          );
      return Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: <Widget>[
            // 底下的页面 / 对话框。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onUnderTap,
                child: const SizedBox.expand(),
              ),
            ),
            IgnorePointer(
              // 真实接线：本 host 的 build 就是这一句。
              ignoring: !FloatingLyricLookupHost.shouldBlockHitTest(popup),
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  // 搜索期占位卡的让位形态（BUG-1364 后：Visibility 收成零尺寸）。
                  Positioned(
                    left: 0,
                    top: 0,
                    width: 200,
                    height: 200,
                    child: Visibility(
                      visible: !childrenYielded,
                      child: opaqueBlock(const Color(0xFF00FF00)),
                    ),
                  ),
                  // 弹窗层的让位形态（BUG-797 后：真 parkedPopupLayer 停到屏外）。
                  parkedPopupLayer(
                    pos: const Rect.fromLTWH(0, 0, 200, 200),
                    visible: !childrenYielded,
                    screen: screen,
                    child: opaqueBlock(const Color(0xFF0000FF)),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    testWidgets('负向控制：子项在场时确实吃掉点击', (WidgetTester tester) async {
      final DictionaryPopupController popup =
          DictionaryPopupController(lowMemory: false)
            ..beginSearchUi(const Rect.fromLTWH(10, 10, 1, 1));
      addTearDown(popup.dispose);
      int underTaps = 0;
      await tester.pumpWidget(harness(
        popup: popup,
        childrenYielded: false,
        onUnderTap: () => underTaps++,
      ));
      await tester.pump();
      await tester.tapAt(const Offset(50, 50));
      await tester.pump();
      expect(underTaps, 0, reason: 'harness 若连"子项吃点击"都复现不了，下一条的穿透就证明不了任何东西');
    });

    testWidgets('对话框期间：ignoring 仍为 false，但点击照常穿到底下',
        (WidgetTester tester) async {
      final DictionaryPopupController popup =
          DictionaryPopupController(lowMemory: false)
            ..beginSearchUi(const Rect.fromLTWH(10, 10, 1, 1));
      addTearDown(popup.dispose);
      expect(FloatingLyricLookupHost.shouldBlockHitTest(popup), isTrue,
          reason: '前置：对话框不改变搜索状态，本判据仍为真 ⇒ ignoring == false');
      int underTaps = 0;
      await tester.pumpWidget(harness(
        popup: popup,
        childrenYielded: true,
        onUnderTap: () => underTaps++,
      ));
      await tester.pump();
      await tester.tapAt(const Offset(50, 50));
      await tester.pump();
      expect(underTaps, 1,
          reason: '子项都已让位（占位卡零尺寸 / 弹窗层停屏外），Stack 自身 hitTestSelf '
              '恒假 ⇒ `ignoring: false` 不拦截任何东西，给它再与一次计数是纯对称性改动');
    });
  });
}
