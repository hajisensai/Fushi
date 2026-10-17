import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/browser_default_detector.dart';
import 'package:fushi/src/lookup/browser_extension_installer.dart';

/// 浏览器扩展安装引导的「默认浏览器」探测：只测纯解析层（真系统调用不进单测）。
void main() {
  group('browserKindFromDefaultBrowserId', () {
    test('Windows UserChoice ProgId', () {
      expect(browserKindFromDefaultBrowserId('ChromeHTML'), BrowserKind.chrome);
      expect(browserKindFromDefaultBrowserId('MSEdgeHTM'), BrowserKind.edge);
      expect(browserKindFromDefaultBrowserId('BraveHTML'), BrowserKind.brave);
      expect(browserKindFromDefaultBrowserId('VivaldiHTM.ABC123'),
          BrowserKind.vivaldi);
      expect(browserKindFromDefaultBrowserId('OperaStable'), BrowserKind.opera);
    });

    test('macOS bundle id / Linux desktop file', () {
      expect(browserKindFromDefaultBrowserId('com.google.chrome'),
          BrowserKind.chrome);
      expect(browserKindFromDefaultBrowserId('com.microsoft.edgemac'),
          BrowserKind.edge);
      expect(browserKindFromDefaultBrowserId('brave-browser.desktop\n'),
          BrowserKind.brave);
      expect(browserKindFromDefaultBrowserId('google-chrome.desktop'),
          BrowserKind.chrome);
    });

    test('unsupported browsers map to null', () {
      expect(browserKindFromDefaultBrowserId('FirefoxURL-308046B0AF4A39CB'),
          isNull);
      expect(browserKindFromDefaultBrowserId('com.apple.safari'), isNull);
      expect(browserKindFromDefaultBrowserId(''), isNull);
    });
  });

  test('parseWindowsUserChoiceProgId reads the ProgId value', () {
    const String out = '\r\n'
        r'HKEY_CURRENT_USER\Software\Microsoft\Windows\Shell\Associations'
        r'\UrlAssociations\https\UserChoice'
        '\r\n    ProgId    REG_SZ    MSEdgeHTM\r\n\r\n';
    expect(parseWindowsUserChoiceProgId(out), 'MSEdgeHTM');
    expect(parseWindowsUserChoiceProgId('nothing here'), isNull);
  });

  test('parseWindowsRegDefaultValue ignores the localized value name', () {
    const String out = '\r\n    (默认)    REG_SZ    '
        r'C:\Program Files\Google\Chrome\Application\chrome.exe'
        '\r\n';
    expect(parseWindowsRegDefaultValue(out),
        r'C:\Program Files\Google\Chrome\Application\chrome.exe');
  });

  test('parseMacLaunchServicesHandler picks the https handler', () {
    const String out = '''
(
        {
        LSHandlerContentType = "public.html";
        LSHandlerRoleAll = "com.apple.safari";
    },
        {
        LSHandlerRoleAll = "com.brave.browser";
        LSHandlerURLScheme = https;
    },
        {
        LSHandlerRoleAll = "com.google.chrome";
        LSHandlerURLScheme = http;
    }
)''';
    expect(parseMacLaunchServicesHandler(out), 'com.brave.browser');
  });

  test('browserLaunchCommand hands the url to the named app', () {
    expect(
      browserLaunchCommand(BrowserKind.edge, 'edge://extensions', os: 'macos'),
      <String>['open', '-a', 'Microsoft Edge', 'edge://extensions'],
    );
    expect(
      browserLaunchCommand(BrowserKind.chrome, 'chrome://extensions',
          os: 'linux'),
      <String>['google-chrome', 'chrome://extensions'],
    );
    expect(
      browserLaunchCommand(BrowserKind.chrome, 'chrome://extensions',
          os: 'windows'),
      isNull,
    );
  });
}
