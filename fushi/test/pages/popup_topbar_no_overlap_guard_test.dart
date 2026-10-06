import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/effective_lookup_size.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';

import '../widgets/widget_test_helpers.dart';

/// BUG-826：查词弹窗顶栏（Flutter chrome）在窄宽时按钮重叠。
///
/// 旧实现把左端 A−/A+、**全宽居中**的 [headerWidget]（音频控制）、右端关闭三组用 [Stack]
/// 各自 [Align] 叠在同一水平带上——弹窗收窄到 [kLookupPopupMinWidth](250) 或 UI 缩放放大
/// 时，居中的音频行向两侧张开压到 A−/A+ 与关闭按钮上（重叠即设计）。修复分两处：
/// - [DictionaryPopupLayer] 顶栏改成一条 [Row]：左右按钮簇钉两端，header 夹在中段
///   [Expanded]/[Center] 的**有界宽度**里居中，Row 顺序排布天然不重叠；
/// - 音频行内部用 [FittedBox]`(scaleDown)` + `mainAxisSize.min`，窄宽下等比缩小不裁切。
void main() {
  // 模拟 reader 音频行：固定尺寸按钮 + 内部 FittedBox 收缩（与生产 header 同结构）。
  Widget shrinkableHeader() => const FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(
          key: Key('test-popup-header'),
          height: 40,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(width: 48, child: Icon(Icons.star_border)),
              SizedBox(width: 48, child: Icon(Icons.replay)),
              SizedBox(width: 48, child: Icon(Icons.play_arrow)),
              SizedBox(width: 48, child: Icon(Icons.play_circle_outline)),
            ],
          ),
        ),
      );

  Future<void> pumpLayer(
    WidgetTester tester,
    double width, {
    Widget? header,
  }) async {
    await tester.pumpWidget(
      buildTestApp(
        Align(
          // 左上钉死，让 widget 屏幕坐标从 (0,0) 起，绝对边界断言可用。
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: 240,
            child: DictionaryPopupLayer(
              result: null,
              isSearching: false,
              webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
              headerWidget: header ?? shrinkableHeader(),
              onClose: () {},
              onDismiss: () {},
              onTextSelected: (text, rect) {},
              onLinkClick: (query, rect) {},
              onMineEntry: (fields) async => const MinePopupResult(),
              onDuplicateCheck: (expression, reading) async => false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
      'narrow popup top bar keeps font buttons, header and close from '
      'overlapping (BUG-826)', (WidgetTester tester) async {
    // 最窄合法宽度（弹窗尺寸下限）——旧 Stack 在此宽必重叠。
    await pumpLayer(tester, kLookupPopupMinWidth);

    // header 内部 FittedBox 收缩，绝不横向溢出/裁切（无 RenderFlex overflow）。
    expect(tester.takeException(), isNull);

    Rect rectOf(Finder finder) {
      expect(finder, findsOneWidget, reason: '守卫需要唯一命中：$finder');
      return tester.getRect(finder);
    }

    // 2026-10 体验优化：窄宽（< kDictionaryPopupTopBarCompactWidth）下 A−/A+/AI
    // 收进「⋯」溢出菜单，左簇只剩一颗溢出按钮；原断言「A−/A+ 在 header 左侧」
    // 改为断言溢出按钮在 header 左侧（不重叠判据不变）。
    expect(find.byIcon(Icons.text_decrease), findsNothing);
    expect(find.byIcon(Icons.text_increase), findsNothing);
    final Rect overflow = rectOf(
      find.byKey(const ValueKey<String>('popup_topbar_overflow')),
    );
    final Rect close = rectOf(find.byIcon(Icons.close));
    final Rect header = rectOf(find.byKey(const Key('test-popup-header')));

    // 左簇（溢出按钮）在 header 左侧、右端关闭在 header 右侧——三者不水平重叠。
    expect(
      overflow.right,
      lessThanOrEqualTo(header.left + 0.5),
      reason: '左簇不得压到居中 header（BUG-826 重叠）。',
    );
    expect(
      header.right,
      lessThanOrEqualTo(close.left + 0.5),
      reason: '居中 header 不得压到右端关闭按钮（BUG-826 重叠）。',
    );

    // header 收缩后仍在弹窗宽度内（未越界）。
    expect(header.left, greaterThanOrEqualTo(-0.5));
    expect(header.right, lessThanOrEqualTo(kLookupPopupMinWidth + 0.5));
  });

  testWidgets(
      'wide popup keeps A-/A+ inline; narrow popup menu still zooms '
      '(2026-10 overflow)', (WidgetTester tester) async {
    await pumpLayer(tester, kDictionaryPopupTopBarCompactWidth + 40);
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.text_decrease), findsOneWidget);
    expect(find.byIcon(Icons.text_increase), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('popup_topbar_overflow')),
      findsNothing,
    );

    // 窄宽：菜单里能找到 A−/A+ 两项（WebView 未挂载时点了安全 no-op）。
    await pumpLayer(tester, kLookupPopupMinWidth);
    // result=null 的层现在画的是「加载中」（FushiDeferredLoading 的无限动画，
    // 不再是假空态「未找到」），pumpAndSettle 永远等不到静止；用有界 pump 走完
    // 菜单的开/关过渡即可。
    Future<void> pumpMenuTransition() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    await tester.tap(
      find.byKey(const ValueKey<String>('popup_topbar_overflow')),
    );
    await pumpMenuTransition();
    expect(find.byIcon(Icons.text_decrease), findsOneWidget);
    expect(find.byIcon(Icons.text_increase), findsOneWidget);
    await tester.tap(find.byIcon(Icons.text_increase));
    await pumpMenuTransition();
    // 选中后菜单关闭（不是点了没反应）。
    expect(find.byIcon(Icons.text_increase), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('mobile top action hit area is at least 44 (2026-10)', () {
    expect(dictionaryPopupTopActionExtent(mobile: true),
        greaterThanOrEqualTo(44));
    // 桌面保持压缩顶栏的 36（design-2026-08）。
    expect(dictionaryPopupTopActionExtent(mobile: false), 36);
  });

  test(
      'reader audio header shrinks to fit instead of clipping/overlapping '
      '(BUG-826)', () {
    // 源码守卫：reader 音频行必须内部 FittedBox(scaleDown) + mainAxisSize.min，窄宽等比
    // 缩小而非裁切/溢出。弹窗跑真 WebView 无法 headless 全量挂，故锁源码契约。
    final String src = File(
      'lib/src/pages/implementations/reader_fushi_page.dart',
    ).readAsStringSync();
    final int start = src.indexOf('Widget? buildPopupAudioControls()');
    expect(start, isNonNegative,
        reason: 'buildPopupAudioControls 必须存在（顶栏 header 构建入口）。');
    final int end = src.indexOf('// ── Helpers', start);
    expect(end, greaterThan(start));
    final String fn = src.substring(start, end);

    expect(
      fn.contains('FittedBox('),
      isTrue,
      reason: '音频行须用 FittedBox 在窄宽下等比缩小（BUG-826）。',
    );
    expect(
      fn.contains('fit: BoxFit.scaleDown'),
      isTrue,
      reason: 'FittedBox 须 scaleDown：够宽不放大、太窄才缩（BUG-826）。',
    );
    expect(
      fn.contains('mainAxisSize: MainAxisSize.min'),
      isTrue,
      reason: '音频行须 mainAxisSize.min，FittedBox 才能量到有限内在宽（BUG-826）。',
    );
  });

  // ── BUG-826 视频端：查词浮层顶栏加到 4 颗动作按钮后的窄宽实测 ──────────────
  //
  // 上面那条锁的是 reader 的源码契约，用的 header 语料是 4×48 的 SizedBox。视频端
  // 用的是真 [FushiIconButton]（icon 20 + 默认 padding gap 8 ×2 = **36px/颗**），
  // 尺寸不同、算术也不同：中段可用宽 = 弹窗宽 − 108（左 A−/A+ 各 36 + 右关闭 36），
  // 4 颗 = 144，弹窗宽下限 [kLookupPopupMinWidth] = 250 ⇒ 142 < 144。
  //
  // 这里用**真按钮**跑正反两面：不包 FittedBox 必 overflow（负向对照证明本条判据真
  // 在工作，不是恒绿），包了必不 overflow。
  //
  // 2026-10 体验优化后窄宽左簇收成一颗「⋯」（36），中段可用宽 = 250 − 72 = 178，
  // 4 颗（144）已放得下、裸 Row 不再溢出——负向对照失去意义。改用 5 颗（180 > 178）
  // 保持「裸 Row 必溢出、FittedBox 必不溢出」这对判据；生产视频 header 的按钮数
  // 只会更少，正向断言覆盖面不变。生产侧真的走了 FittedBox 这条结构，由
  // `test/pages/video_popup_cue_actions_guard_test.dart` 的源码扫描钉住。
  Widget realIconButtons() => Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          for (final IconData icon in <IconData>[
            Icons.replay,
            Icons.play_arrow,
            Icons.content_copy_outlined,
            Icons.star_border,
            Icons.skip_next,
          ])
            FushiIconButton(
              icon: icon,
              tooltip: 'action',
              size: 20,
              onTap: () {},
            ),
        ],
      );

  testWidgets(
      'video popup header with four real icon buttons does not overflow at '
      'min popup width (BUG-826)', (WidgetTester tester) async {
    // 负向对照：裸 Row（生产代码修复前的形态）在下限宽必 RenderFlex overflow。
    await pumpLayer(tester, kLookupPopupMinWidth,
        header: Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: realIconButtons(),
        ));
    final Object? bare = tester.takeException();
    expect(
      bare,
      isNotNull,
      reason: '负向对照失效：裸 Row 在最窄弹窗竟没溢出，说明这条判据已量不到真实尺寸，'
          '正向断言随之变成恒绿。请复核 FushiIconButton 尺寸或顶栏左右簇宽度。',
    );
    expect('$bare', contains('overflowed'));

    // 正向：包 FittedBox(scaleDown) + mainAxisSize.min 后等比缩小，零溢出。
    await pumpLayer(tester, kLookupPopupMinWidth,
        header: Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: realIconButtons(),
          ),
        ));
    expect(
      tester.takeException(),
      isNull,
      reason: 'FittedBox(scaleDown) 必须把按钮行缩到有界宽内，绝不横向溢出/裁切。',
    );
  });
}
