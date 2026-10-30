import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';

import '../widgets/widget_test_helpers.dart';

/// BUG-3412：查词弹窗顶栏三组控件（左簇 A−/A+ 按钮组、中段宿主 header 按钮组、右簇
/// 关闭圆钮）在手机宽度上大小不一。
///
/// 根因：中段 header 按「较宽一簇」两侧对称预留，手机上左簇一宽，中段就放不下 4 颗，
/// header 自带的 FittedBox 把整组 scaleDown 到半大。修复后 header 拿两簇之间的全部
/// 剩余宽、能居中才居中，三组共用同一边长 / 同一图标尺寸。
void main() {
  final double extent = dictionaryPopupTopActionExtent(
    mobile: isMobilePlatform,
  );

  // 与生产 reader header（`buildPopupAudioControls`）同结构：FittedBox(scaleDown) 包一枚
  // DictionaryPopupToolGroup，4 颗按钮共用顶栏命中盒与图标尺寸。
  Widget readerLikeHeader() => FittedBox(
    key: const Key('test-popup-header'),
    fit: BoxFit.scaleDown,
    child: DictionaryPopupToolGroup(
      children: <Widget>[
        for (final IconData icon in <IconData>[
          Icons.star_border,
          Icons.replay_outlined,
          Icons.play_arrow_outlined,
          Icons.play_circle_outline,
        ])
          FushiIconButton(
            icon: icon,
            size: kDictionaryPopupTopActionIconSize,
            tooltip: 'action',
            constraints: dictionaryPopupTopActionConstraints(),
            padding: EdgeInsets.zero,
            onTap: () {},
          ),
      ],
    ),
  );

  Future<void> pumpLayer(WidgetTester tester, double width) async {
    await tester.pumpWidget(
      buildTestApp(
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: 300,
            child: DictionaryPopupLayer(
              result: null,
              isSearching: false,
              webViewKey: GlobalKey<DictionaryPopupWebViewState>(),
              headerWidget: readerLikeHeader(),
              // 历史 ← → 一组 + A−/A+ 一组：左簇比右簇宽得多，正是旧对称预留把中段
              // 挤小的形态（手机上的 A−/A+/制卡目标同理）。
              historyNav: DictionaryPopupHistoryNav(
                canGoBack: true,
                canGoForward: true,
                onBack: () {},
                onForward: () {},
              ),
              onClose: () {},
              onDismiss: () {},
              onTextSelected: (text, rect, _) {},
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

  Rect groupRectContaining(WidgetTester tester, IconData icon) {
    final Finder group = find.ancestor(
      of: find.byIcon(icon),
      matching: find.byType(DictionaryPopupToolGroup),
    );
    expect(group, findsOneWidget);
    return tester.getRect(group);
  }

  testWidgets('top bar groups and close button share one height on a phone '
      'width (BUG-3412)', (WidgetTester tester) async {
    // 手机竖屏宽（iPhone 390）——旧实现在此宽下中段被压到 ~50px、header 缩到 1/3。
    await pumpLayer(tester, 390);
    expect(tester.takeException(), isNull);

    final Rect zoomGroup = groupRectContaining(tester, Icons.text_increase);
    final Rect navGroup = groupRectContaining(tester, Icons.arrow_forward);
    final Rect headerGroup = groupRectContaining(tester, Icons.star_border);
    final Rect close = tester.getRect(
      find.ancestor(
        of: find.byIcon(Icons.close),
        matching: find.byType(FushiIconButton),
      ),
    );

    for (final Rect r in <Rect>[zoomGroup, navGroup, headerGroup, close]) {
      expect(r.height, moreOrLessEquals(extent, epsilon: 0.5));
    }
    expect(close.width, moreOrLessEquals(extent, epsilon: 0.5));
    // 中段 header 未被 FittedBox 缩小：4 颗按钮 + 胶囊左右内边距的原始宽。
    expect(headerGroup.width, greaterThanOrEqualTo(4 * extent - 0.5));

    // 图标渲染尺寸一致（缩放过的 header 图标会小一圈）。
    final Size closeIcon = tester.getSize(find.byIcon(Icons.close));
    final Size starIcon = tester.getRect(find.byIcon(Icons.star_border)).size;
    final Size zoomIcon = tester.getRect(find.byIcon(Icons.text_increase)).size;
    expect(starIcon.width, moreOrLessEquals(closeIcon.width, epsilon: 0.5));
    expect(zoomIcon.width, moreOrLessEquals(closeIcon.width, epsilon: 0.5));
    expect(closeIcon.width, kDictionaryPopupTopActionIconSize);

    // 三组同一中线（垂直居中对齐）。
    expect(headerGroup.center.dy, moreOrLessEquals(close.center.dy));
    expect(zoomGroup.center.dy, moreOrLessEquals(close.center.dy));

    // BUG-822 / BUG-826 不重叠不变式：header 落在左右两簇之间。
    expect(zoomGroup.right, lessThanOrEqualTo(headerGroup.left + 0.5));
    expect(headerGroup.right, lessThanOrEqualTo(close.left + 0.5));
  });

  testWidgets('header stays centred on the whole bar when there is room '
      '(BUG-3412 keeps user 10-09)', (WidgetTester tester) async {
    const double width = 640;
    await pumpLayer(tester, width);
    final Rect header = tester.getRect(
      find.byKey(const Key('test-popup-header')),
    );
    expect(header.center.dx, moreOrLessEquals(width / 2, epsilon: 0.5));
  });

  test('host headers use the shared top-bar icon size (BUG-3412)', () {
    String section(String path, String start, String end) {
      final String src = File(path).readAsStringSync();
      final int s = src.indexOf(start);
      expect(s, isNonNegative, reason: '$path 缺少 $start');
      return src.substring(s, src.indexOf(end, s));
    }

    final Map<String, String> sections = <String, String>{
      'reader': section(
        'lib/src/pages/implementations/reader_fushi_page.dart',
        'Widget? buildPopupAudioControls()',
        '// ── Helpers',
      ),
      'video': section(
        'lib/src/pages/implementations/video_fushi_page.dart',
        'Widget? buildPopupHeaderFor(int index)',
        '/// 关闭查词浮层栈中第',
      ),
      'mining target': section(
        'lib/src/pages/implementations/dictionary_popup_mining_target.dart',
        'class DictionaryPopupMiningTargetButton',
        'bool dictionaryPopupMiningTargetReady',
      ),
    };
    final RegExp literalSize = RegExp(r'size:\s*\d');
    sections.forEach((String host, String body) {
      expect(body, contains('kDictionaryPopupTopActionIconSize'));
      expect(
        literalSize.hasMatch(body),
        isFalse,
        reason: '$host 顶栏按钮不得手写图标尺寸，统一用 kDictionaryPopupTopActionIconSize',
      );
    });
  });
}
