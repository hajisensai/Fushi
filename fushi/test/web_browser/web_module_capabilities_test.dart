import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/web_browser/web_module_capabilities.dart';

/// 浏览器模块说明文案按本平台真实能力分派：iOS 不宣传网页漫画 / 小说（在线源合规门），
/// 非 Windows 不宣传视频站点，移动端不提浏览器扩展。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  const WebModuleCapabilities windows = WebModuleCapabilities(
    videoSites: true,
    webReaders: true,
    browserExtension: true,
  );
  const WebModuleCapabilities macLinux = WebModuleCapabilities(
    videoSites: false,
    webReaders: true,
    browserExtension: true,
  );
  const WebModuleCapabilities android = WebModuleCapabilities(
    videoSites: false,
    webReaders: true,
    browserExtension: false,
  );
  const WebModuleCapabilities ios = WebModuleCapabilities(
    videoSites: false,
    webReaders: false,
    browserExtension: false,
  );

  test('引导文案：每个平台只介绍自己真有的能力', () {
    expect(webModuleOnboardingHint(windows), t.onboarding_feature_web_hint);
    expect(
      webModuleOnboardingHint(macLinux),
      t.onboarding_feature_web_reader_desktop_hint,
    );
    expect(
      webModuleOnboardingHint(android),
      t.onboarding_feature_web_reader_hint,
    );
    expect(webModuleOnboardingHint(ios), t.onboarding_feature_web_basic_hint);
  });

  test('引导文案内容：非 Windows 不提视频站点，iOS 不提网页漫画，移动端不提扩展', () {
    for (final WebModuleCapabilities c in <WebModuleCapabilities>[
      macLinux,
      android,
      ios,
    ]) {
      expect(webModuleOnboardingHint(c), isNot(contains('video')));
    }
    expect(webModuleOnboardingHint(ios), isNot(contains('comic')));
    expect(webModuleOnboardingHint(android), isNot(contains('extension')));
    expect(webModuleOnboardingHint(ios), isNot(contains('extension')));
  });

  test('广告拦截开关说明：按平台列真实场景', () {
    expect(webAdblockEnabledHint(windows), t.web_adblock_enabled_hint);
    expect(webAdblockEnabledHint(macLinux), t.web_adblock_enabled_sources_hint);
    expect(webAdblockEnabledHint(android), t.web_adblock_enabled_sources_hint);
    expect(webAdblockEnabledHint(ios), t.web_adblock_enabled_basic_hint);
    expect(webAdblockEnabledHint(android), isNot(contains('video')));
    expect(webAdblockEnabledHint(ios), isNot(contains('manga')));
  });
}
