import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:fushi/src/utils/misc/official_links.dart';

/// 「设置 · 通用 · 官网」这一行真的打开官网，而不是复制粘贴 GitHub 那行时把 URL
/// 也一起抄了过来。两行并排、图标相近、只差一个 URL，是最容易静默串线的形状，所以
/// 两行都断言各自的落点。
///
/// 侧栏左上角品牌位的同一入口在 `test/widgets/nav_rail_brand_button_test.dart`。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final List<String> launchedUrls = <String>[];

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    launchedUrls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (MethodCall call) async {
        if (call.method == 'launch') {
          final Map<Object?, Object?> args =
              Map<Object?, Object?>.from(call.arguments as Map);
          launchedUrls.add(args['url'] as String);
        }
        return true;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      null,
    );
  });

  SettingsActionItem actionItem(String id) {
    return buildSystemDestination()
        .sections
        .expand((SettingsSection s) => s.items)
        .whereType<SettingsActionItem>()
        .firstWhere((SettingsActionItem i) => i.id == id);
  }

  test('system.website opens the official website', () async {
    final SettingsActionItem website = actionItem('system.website');
    expect(website.title, t.options_website);

    await website.onTap(_StubSettingsContext());

    expect(launchedUrls, <String>[kOfficialWebsiteUrl]);
    expect(kOfficialWebsiteUrl, 'https://fushi.moe');
  });

  test('system.github still opens the repository, not the website', () async {
    final SettingsActionItem github = actionItem('system.github');

    await github.onTap(_StubSettingsContext());

    expect(launchedUrls, <String>['https://github.com/hajisensai/fushi']);
  });

  test('openOfficialDownloadPage 落在下载页，而不是首页', () async {
    expect(await openOfficialDownloadPage(), isTrue);

    // 第三个官网入口，同样是「只差一段路径」的形状：漏了 /download 就退回首页，
    // 用户看不到推荐包那一节的分片直链和「导入选合并」的说明，而引导页把用户
    // 送到这里的全部理由就是那一节。
    expect(launchedUrls, <String>[kOfficialDownloadPageUrl]);
    expect(kOfficialDownloadPageUrl, 'https://fushi.moe/download');
    expect(
      kOfficialDownloadPageUrl.startsWith('$kOfficialWebsiteUrl/'),
      isTrue,
      reason: '下载页必须挂在官网域名下，换站点时两者一起走',
    );
  });
}

class _StubSettingsContext implements SettingsContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
