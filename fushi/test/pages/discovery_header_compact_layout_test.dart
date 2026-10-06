import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/discovery_header.dart';

/// 2026-10-04 用户截图：「浏览 › 发现」的书 / 漫画 / 视频三个页签头部三种形态——
/// 手机上书域搜索框被来源下拉挤成「搜…」，漫画域只剩一道竖线，视频域却是整条
/// 长搜索框。共享头部 [DiscoveryHeaderControls] 窄屏改为两行：搜索框独占整行，
/// 来源下拉 + 附加按钮在第二行。
void main() {
  Future<void> pumpHeader(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final TextEditingController controller = TextEditingController();
    final FocusNode focusNode = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focusNode.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: DiscoveryHeaderControls(
              sources: const <DiscoverySourceOption>[
                DiscoverySourceOption(id: 'long', label: '一个名字相当长的在线来源（日本語）'),
              ],
              selectedSourceId: kDiscoveryAllSourcesId,
              onSourceSelected: (String _) {},
              searchController: controller,
              searchFocusNode: focusNode,
              searchHintText: '搜索全部来源里的作品标题',
              onSearchSubmitted: (String _) {},
              trailing: <Widget>[
                IconButton(
                  key: const ValueKey<String>('trailing-ai'),
                  onPressed: () {},
                  icon: const Icon(Icons.auto_awesome_outlined),
                ),
                IconButton(
                  key: const ValueKey<String>('trailing-refresh'),
                  onPressed: () {},
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  const ValueKey<String> searchKey = ValueKey<String>('discovery_search_field');
  const ValueKey<String> menuKey = ValueKey<String>('discovery_source_menu');

  testWidgets('手机宽度：搜索框独占整行，来源下拉与按钮在下一行', (WidgetTester tester) async {
    await pumpHeader(tester, const Size(390, 844));

    final Rect search = tester.getRect(find.byKey(searchKey));
    final Rect menu = tester.getRect(find.byKey(menuKey));
    final Rect refresh = tester.getRect(
      find.byKey(const ValueKey<String>('trailing-refresh')),
    );
    final Rect screen = Offset.zero & const Size(390, 844);

    // 整行：左右只让出页面内边距，远宽于此前被挤剩的几十像素。
    expect(search.width, greaterThan(screen.width * 0.8));
    expect(menu.top, greaterThanOrEqualTo(search.bottom));
    expect(refresh.top, greaterThanOrEqualTo(search.bottom));
    // 第二行：下拉填满按钮之外的宽度、与按钮同一行、与搜索框左缘对齐。
    expect(menu.left, closeTo(search.left, 0.5));
    expect(menu.right, lessThanOrEqualTo(refresh.left));
    expect(menu.center.dy, closeTo(refresh.center.dy, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('宽屏：来源下拉、搜索框、按钮仍在同一行', (WidgetTester tester) async {
    await pumpHeader(tester, const Size(1200, 800));

    final Rect search = tester.getRect(find.byKey(searchKey));
    final Rect menu = tester.getRect(find.byKey(menuKey));
    expect(menu.top, search.top);
    expect(menu.height, search.height);
    expect(menu.right, lessThanOrEqualTo(search.left));
    expect(tester.takeException(), isNull);
  });
}
