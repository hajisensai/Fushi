import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/extension_management_tile.dart';
import 'package:fushi/src/utils/net/app_http_image.dart';
import 'package:fushi/utils.dart';

/// BUG-1715：扩展图标必须走应用代理出口，不得用 `Image.network`。
///
/// `NetworkImage` 用 Flutter 内部 HttpClient，接不进 `app_proxy.dart` 的出站
/// 代理层；桌面上扩展仓库索引经 `createAppHttpIoClient()` 走代理拉得到，逐条
/// 图标却直连 raw.githubusercontent.com 失败，整个列表全是占位图标（Android
/// 上全局 VPN 盖住所有流量所以看不出来）。图标与索引必须共用同一条出口策略。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  Future<void> pumpTile(WidgetTester tester, {required String? iconUrl}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(useMaterial3: true),
        home: Scaffold(
          body: MangaExtensionManagementTile(
            title: 'Fixture extension',
            subtitle: const Text('ja · 1.0'),
            iconUrl: iconUrl,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('图标经 AppHttpImage（应用代理出口）加载，而不是 NetworkImage',
      (WidgetTester tester) async {
    await pumpTile(tester, iconUrl: 'https://icons.example/pkg.png');

    final Iterable<Image> images = tester.widgetList<Image>(find.byType(Image));
    expect(images, isNotEmpty, reason: '有 iconUrl 时必须渲染网络图标');
    for (final Image image in images) {
      expect(
        image.image,
        isA<AppHttpImage>(),
        reason: 'BUG-1715：图标 provider 必须是 AppHttpImage，'
            'NetworkImage 结构上接不进应用代理层',
      );
      expect(image.image, isNot(isA<NetworkImage>()));
    }
    // flutter_test 的 HttpOverrides 对所有 HTTP 请求返回 400，加载必然失败；
    // errorBuilder 要稳稳落回占位图标，而不是把异常抛到测试框架。
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('无 iconUrl 时用占位图标，不发任何请求', (WidgetTester tester) async {
    await pumpTile(tester, iconUrl: null);
    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.extension_outlined), findsOneWidget);
  });

  test('AppHttpImage 以 url+scale 为缓存键：同 url 相等，异 url 不等', () {
    expect(
      const AppHttpImage('https://a.example/i.png'),
      equals(const AppHttpImage('https://a.example/i.png')),
    );
    expect(
      const AppHttpImage('https://a.example/i.png').hashCode,
      equals(const AppHttpImage('https://a.example/i.png').hashCode),
    );
    expect(
      const AppHttpImage('https://a.example/i.png'),
      isNot(equals(const AppHttpImage('https://b.example/i.png'))),
    );
    expect(
      const AppHttpImage('https://a.example/i.png'),
      isNot(equals(const AppHttpImage('https://a.example/i.png', scale: 2))),
    );
  });
}
