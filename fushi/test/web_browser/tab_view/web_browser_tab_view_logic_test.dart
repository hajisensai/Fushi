// 标签页 WebView 的纯逻辑：失败分类、UA / 文字大小 / 深色模式的平台分派、下载文件
// 名推断、长按 / 右键命中 → 菜单项、历史记录时机、权限映射、页内查找结果解析。
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/web_browser/data/web_browser_site_settings.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_context_menu.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_downloader.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_load_errors.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_page_scripts.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_page_settings.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_permissions.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_tab_actions.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_visit_recorder.dart';
import 'package:fushi/src/web_browser/tabs/web_browser_tab.dart';

void main() {
  group('加载失败分类', () {
    final Uri url = Uri.parse('https://example.com/a');

    test('主框架域名解析失败 → 失败页且标成 DNS', () {
      final WebBrowserLoadError? e = classifyWebBrowserMainFrameError(
        url: url,
        isForMainFrame: true,
        type: WebResourceErrorType.HOST_LOOKUP,
        description: 'net::ERR_NAME_NOT_RESOLVED',
      );
      expect(e, isNotNull);
      expect(e!.kind, WebBrowserLoadErrorKind.dnsFailed);
      expect(e.offline, isFalse);
      expect(e.url, url);
    });

    test('Android 断网报成 HOST_LOOKUP，靠 net::ERR 描述分出断网', () {
      expect(
        webBrowserLoadErrorKindOf(
          type: WebResourceErrorType.HOST_LOOKUP,
          description: 'net::ERR_INTERNET_DISCONNECTED',
        ),
        WebBrowserLoadErrorKind.offline,
      );
    });

    test('Android 各类 net::ERR → 类别', () {
      final Map<String, WebBrowserLoadErrorKind>
      cases = <String, WebBrowserLoadErrorKind>{
        'net::ERR_CONNECTION_REFUSED': WebBrowserLoadErrorKind.connectionFailed,
        'net::ERR_CONNECTION_RESET': WebBrowserLoadErrorKind.connectionFailed,
        'net::ERR_ADDRESS_UNREACHABLE':
            WebBrowserLoadErrorKind.connectionFailed,
        'net::ERR_CONNECTION_TIMED_OUT': WebBrowserLoadErrorKind.timedOut,
        'net::ERR_CERT_DATE_INVALID': WebBrowserLoadErrorKind.certificate,
        'net::ERR_SSL_PROTOCOL_ERROR': WebBrowserLoadErrorKind.certificate,
        'net::ERR_EMPTY_RESPONSE': WebBrowserLoadErrorKind.badResponse,
        'net::ERR_TOO_MANY_REDIRECTS': WebBrowserLoadErrorKind.tooManyRedirects,
        'net::ERR_FAILED': WebBrowserLoadErrorKind.generic,
      };
      cases.forEach((String description, WebBrowserLoadErrorKind kind) {
        expect(
          webBrowserLoadErrorKindOf(
            type: WebResourceErrorType.UNKNOWN,
            description: description,
          ),
          kind,
          reason: description,
        );
      });
    });

    test('WebView2：fork 按 COREWEBVIEW2_WEB_ERROR_STATUS 查表的描述 → 类别', () {
      // 与 packages/flutter_inappwebview_windows/windows/types/web_resource_error.h
      // 的 WebErrorStatusDescription 逐条对应（证书类原生侧不走 onReceivedError）。
      final Map<String, WebBrowserLoadErrorKind>
      cases = <String, WebBrowserLoadErrorKind>{
        // 0 UNKNOWN：WebView2 把连接被拒落在这里
        'Indicates that an unknown error occurred.':
            WebBrowserLoadErrorKind.generic,
        'Indicates that the host is unreachable.':
            WebBrowserLoadErrorKind.connectionFailed,
        'Indicates that the connection has timed out.':
            WebBrowserLoadErrorKind.timedOut,
        'Indicates that the server returned an invalid or unrecognized response.':
            WebBrowserLoadErrorKind.badResponse,
        'Indicates that the connection was stopped.':
            WebBrowserLoadErrorKind.connectionFailed,
        'Indicates that the connection was reset.':
            WebBrowserLoadErrorKind.connectionFailed,
        'Indicates that the Internet connection has been lost.':
            WebBrowserLoadErrorKind.offline,
        'Indicates that a connection to the destination was not established.':
            WebBrowserLoadErrorKind.connectionFailed,
        'Indicates that the provided host name was not able to be resolved.':
            WebBrowserLoadErrorKind.dnsFailed,
        'Indicates that the request redirect failed.':
            WebBrowserLoadErrorKind.tooManyRedirects,
        'Indicates that an unexpected error occurred.':
            WebBrowserLoadErrorKind.generic,
        'Indicates that the SSL certificate has expired.':
            WebBrowserLoadErrorKind.certificate,
      };
      cases.forEach((String description, WebBrowserLoadErrorKind kind) {
        expect(
          webBrowserLoadErrorKindOf(
            type: WebResourceErrorType.UNKNOWN,
            description: description,
          ),
          kind,
          reason: description,
        );
      });
    });

    test('iOS / macOS：NSURLError 类型 → 类别（描述是系统语言，不靠它）', () {
      final Map<WebResourceErrorType, WebBrowserLoadErrorKind> cases =
          <WebResourceErrorType, WebBrowserLoadErrorKind>{
            WebResourceErrorType.NOT_CONNECTED_TO_INTERNET:
                WebBrowserLoadErrorKind.offline,
            WebResourceErrorType.NETWORK_CONNECTION_LOST:
                WebBrowserLoadErrorKind.offline,
            WebResourceErrorType.HOST_LOOKUP: WebBrowserLoadErrorKind.dnsFailed,
            WebResourceErrorType.CANNOT_CONNECT_TO_HOST:
                WebBrowserLoadErrorKind.connectionFailed,
            WebResourceErrorType.TIMEOUT: WebBrowserLoadErrorKind.timedOut,
            WebResourceErrorType.SERVER_CERTIFICATE_UNTRUSTED:
                WebBrowserLoadErrorKind.certificate,
            WebResourceErrorType.SECURE_CONNECTION_FAILED:
                WebBrowserLoadErrorKind.certificate,
            WebResourceErrorType.BAD_SERVER_RESPONSE:
                WebBrowserLoadErrorKind.badResponse,
            WebResourceErrorType.TOO_MANY_REDIRECTS:
                WebBrowserLoadErrorKind.tooManyRedirects,
            WebResourceErrorType.UNKNOWN: WebBrowserLoadErrorKind.generic,
          };
      cases.forEach((WebResourceErrorType type, WebBrowserLoadErrorKind kind) {
        expect(
          webBrowserLoadErrorKindOf(type: type, description: '无法连接'),
          kind,
          reason: '$type',
        );
      });
    });

    test('导航被取消（iOS -999 / WebView2 OPERATION_CANCELED）不算失败', () {
      expect(
        classifyWebBrowserMainFrameError(
          url: url,
          isForMainFrame: true,
          type: WebResourceErrorType.CANCELLED,
          description: 'cancelled',
        ),
        isNull,
      );
      expect(
        classifyWebBrowserMainFrameError(
          url: url,
          isForMainFrame: true,
          type: WebResourceErrorType.UNKNOWN,
          description: 'Indicates that the operation was canceled.',
        ),
        isNull,
      );
    });

    test('WebView2 只给英文描述时按描述判断网', () {
      final WebBrowserLoadError? e = classifyWebBrowserMainFrameError(
        url: url,
        isForMainFrame: true,
        type: WebResourceErrorType.UNKNOWN,
        description: 'Indicates that the Internet connection has been lost.',
      );
      expect(e?.offline, isTrue);
    });

    test('子资源错误、非网页地址不显示失败页', () {
      expect(
        classifyWebBrowserMainFrameError(
          url: url,
          isForMainFrame: false,
          type: WebResourceErrorType.TIMEOUT,
          description: 'x',
        ),
        isNull,
      );
      expect(
        classifyWebBrowserMainFrameError(
          url: Uri.parse('about:blank'),
          isForMainFrame: true,
          type: WebResourceErrorType.TIMEOUT,
          description: 'x',
        ),
        isNull,
      );
    });

    test('失败页盖着时标签名不用引擎错误页的标题（WebView2「隐私错误」）', () {
      final WebBrowserTab tab = WebBrowserTab(
        id: 't',
        url: Uri.parse('https://example.com/a'),
      )..update(title: '隐私错误');
      tab.setError(
        WebBrowserLoadError(
          url: Uri.parse('https://example.com/a'),
          description: 'Indicates that the SSL certificate is not valid.',
          kind: WebBrowserLoadErrorKind.certificate,
        ),
      );
      expect(tab.displayTitle, 'example.com');
      tab.setError(null);
      expect(tab.displayTitle, '隐私错误');
    });

    test('非断网错误 → 普通失败文案', () {
      final WebBrowserLoadError? e = classifyWebBrowserMainFrameError(
        url: url,
        isForMainFrame: true,
        type: WebResourceErrorType.FAILED_SSL_HANDSHAKE,
        description: 'ssl',
      );
      expect(e, isNotNull);
      expect(e!.offline, isFalse);
      expect(e.kind, WebBrowserLoadErrorKind.certificate);
    });

    test('HTTP 4xx/5xx 只在页面空白时盖失败页（Cloudflare 验证页有正文不能挡）', () {
      expect(
        isWebBrowserHttpErrorCandidate(isForMainFrame: true, statusCode: 503),
        isTrue,
      );
      expect(
        isWebBrowserHttpErrorCandidate(isForMainFrame: true, statusCode: 302),
        isFalse,
      );
      expect(
        isWebBrowserHttpErrorCandidate(isForMainFrame: false, statusCode: 500),
        isFalse,
      );
      expect(
        shouldShowWebBrowserHttpError(
          pendingStatusCode: 503,
          visibleTextLength: 120,
          mediaElementCount: 0,
        ),
        isFalse,
      );
      expect(
        shouldShowWebBrowserHttpError(
          pendingStatusCode: 500,
          visibleTextLength: 0,
          mediaElementCount: 0,
        ),
        isTrue,
      );
      expect(
        shouldShowWebBrowserHttpError(
          pendingStatusCode: null,
          visibleTextLength: 0,
          mediaElementCount: 0,
        ),
        isFalse,
      );
    });
  });

  group('被顶掉的导航迟到的错误（BUG-3859）', () {
    final Uri first = Uri.parse('https://www.youtube.com/watch?v=a');
    final Uri second = Uri.parse(
      'https://www.youtube.com/watch?v=a&themeRefresh=1',
    );

    test('页面自己改址后，首个导航迟到的 connection stopped 不盖失败页', () {
      final WebBrowserNavigationLog log = WebBrowserNavigationLog()
        ..onStart(first)
        ..onStart(second);
      expect(log.isSuperseded(first), isTrue);
      expect(log.isSuperseded(second), isFalse);
    });

    test('当前导航自己的错误照常显示', () {
      final WebBrowserNavigationLog log = WebBrowserNavigationLog()
        ..onStart(first);
      expect(log.isSuperseded(first), isFalse);
    });

    test('没记录过的地址（重定向后）不算过期；只差锚点算同一次', () {
      final WebBrowserNavigationLog log = WebBrowserNavigationLog()
        ..onStart(first)
        ..onStart(
          Uri.parse('https://www.youtube.com/watch?v=a&themeRefresh=1#t'),
        );
      expect(log.isSuperseded(Uri.parse('https://example.com/')), isFalse);
      expect(log.isSuperseded(second), isFalse);
    });

    test('回到同一地址重新导航后，它的错误不再算过期', () {
      final WebBrowserNavigationLog log = WebBrowserNavigationLog()
        ..onStart(first)
        ..onStart(second)
        ..onStart(first);
      expect(log.isSuperseded(first), isFalse);
    });
  });

  group('退出网页全屏还原缩放', () {
    test('全屏后缩放被压到 0.76 → 退出时按比值拉回', () {
      final WebBrowserFullscreenZoomGuard g = WebBrowserFullscreenZoomGuard();
      expect(g.onScaleChanged(2.625), isNull); // 全屏前（原始值含屏幕密度）
      g.onEnterFullscreen();
      expect(g.onScaleChanged(1.0), isNull); // 全屏里的变化不动
      final double? f = g.onExitFullscreen();
      expect(f, closeTo(2.625, 1e-9));
    });

    test('退出后引擎才压缩放 → 事件里拉回；回到原值不再动', () {
      final WebBrowserFullscreenZoomGuard g = WebBrowserFullscreenZoomGuard()
        ..onScaleChanged(2.0)
        ..onEnterFullscreen();
      expect(g.onExitFullscreen(), isNull);
      expect(g.onScaleChanged(1.52), closeTo(2.0 / 1.52, 1e-9));
      expect(g.onScaleChanged(2.0), isNull);
      expect(g.restoring, isTrue);
    });

    test('用户触碰 / 新导航后停手，不和用户抢缩放', () {
      final WebBrowserFullscreenZoomGuard g = WebBrowserFullscreenZoomGuard()
        ..onScaleChanged(2.0)
        ..onEnterFullscreen()
        ..onExitFullscreen()
        ..stop();
      expect(g.onScaleChanged(3.0), isNull);
    });

    test('没进过全屏 / 不知道全屏前缩放 → 什么都不做', () {
      final WebBrowserFullscreenZoomGuard g = WebBrowserFullscreenZoomGuard();
      expect(g.onExitFullscreen(), isNull);
      // 进全屏前没收到过任何缩放事件：没有可还原的目标。
      g.onEnterFullscreen();
      expect(g.onExitFullscreen(), isNull);
      expect(g.restoring, isFalse);
      expect(g.onScaleChanged(1.0), isNull);
    });
  });

  group('桌面版 / UA / 文字大小 / 深色模式', () {
    const String androidUa =
        'Mozilla/5.0 (Linux; Android 14; Pixel 8; wv) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Version/4.0 Chrome/131.0.6778.39 Mobile '
        'Safari/537.36';

    test('只有手机提供桌面版网页', () {
      expect(webBrowserDesktopModeSupportedOn(TargetPlatform.android), isTrue);
      expect(webBrowserDesktopModeSupportedOn(TargetPlatform.iOS), isTrue);
      expect(webBrowserDesktopModeSupportedOn(TargetPlatform.windows), isFalse);
      expect(webBrowserDesktopModeSupportedOn(TargetPlatform.macOS), isFalse);
    });

    test('Android 桌面 UA 保留 Chrome 版本、去掉 Mobile / wv', () {
      final String ua = webBrowserDesktopUserAgentFrom(androidUa);
      expect(ua, contains('Chrome/131.0.6778.39'));
      expect(ua, contains('X11; Linux x86_64'));
      expect(ua, isNot(contains('Mobile')));
      expect(ua, isNot(contains('; wv')));
      expect(
        webBrowserDesktopUserAgentFrom(null),
        kWebBrowserFallbackDesktopUserAgent,
      );
    });

    test('Android 关桌面版时显式写回默认 UA；其它平台不碰 UA', () {
      expect(
        webBrowserUserAgentFor(
          platform: TargetPlatform.android,
          desktopMode: false,
          defaultUserAgent: androidUa,
        ),
        androidUa,
      );
      expect(
        webBrowserUserAgentFor(
          platform: TargetPlatform.android,
          desktopMode: true,
          defaultUserAgent: androidUa,
        ),
        isNot(contains('Mobile')),
      );
      expect(
        webBrowserUserAgentFor(
          platform: TargetPlatform.iOS,
          desktopMode: true,
          defaultUserAgent: androidUa,
        ),
        isNull,
      );
    });

    test('iOS 桌面版走 preferredContentMode；Android textZoom 走原生', () {
      final InAppWebViewSettings ios = InAppWebViewSettings();
      applyWebBrowserPageSettings(
        ios,
        platform: TargetPlatform.iOS,
        desktopMode: true,
        textZoom: 120,
        forceDark: true,
        defaultUserAgent: null,
      );
      expect(ios.preferredContentMode, UserPreferredContentMode.DESKTOP);
      final InAppWebViewSettings android = InAppWebViewSettings();
      applyWebBrowserPageSettings(
        android,
        platform: TargetPlatform.android,
        desktopMode: false,
        textZoom: 130,
        forceDark: true,
        defaultUserAgent: androidUa,
      );
      expect(android.textZoom, 130);
      expect(android.userAgent, androidUa);
    });

    test('文字大小：Android 原生（无脚本）、iOS text-size-adjust、桌面 zoom', () {
      expect(
        webBrowserTextZoomModeOn(TargetPlatform.android),
        WebBrowserTextZoomMode.nativeTextZoom,
      );
      expect(
        webBrowserTextZoomScript(150, WebBrowserTextZoomMode.nativeTextZoom),
        isNull,
      );
      expect(
        webBrowserTextZoomScript(150, WebBrowserTextZoomMode.textSizeAdjust),
        contains('text-size-adjust:150%'),
      );
      expect(
        webBrowserTextZoomScript(
          150,
          webBrowserTextZoomModeOn(TargetPlatform.windows),
        ),
        contains('zoom:150%'),
      );
    });

    test('深色模式五端都走页内保守反色（Android 原生在浅色 app 主题下不生效）', () {
      expect(webBrowserForceDarkNativeOn(TargetPlatform.android), isFalse);
      expect(webBrowserForceDarkNativeOn(TargetPlatform.windows), isFalse);
      expect(webBrowserForceDarkScript(enabled: true), contains('invert(1)'));
      expect(
        webBrowserForceDarkScript(enabled: false),
        isNot(contains('invert(1)')),
      );
    });
  });

  group('下载', () {
    test('Content-Disposition：filename* 优先并解码', () {
      expect(
        webBrowserContentDispositionFileName(
          "attachment; filename=\"a.txt\"; filename*=UTF-8''%E6%97%A5%E6%9C%AC.pdf",
        ),
        '日本.pdf',
      );
      expect(
        webBrowserContentDispositionFileName('attachment; filename="b c.zip"'),
        'b c.zip',
      );
      expect(webBrowserContentDispositionFileName('inline'), isNull);
    });

    test('文件名推断：Content-Disposition → 建议名 → 地址末段 → download，按 MIME 补扩展名', () {
      final Uri url = Uri.parse('https://x.test/files/%E6%9C%AC.epub?x=1');
      // WebView2 的建议名在重名时带「 (1)」：服务器给了文件名就以它为准。
      expect(
        inferWebBrowserDownloadFileName(
          url: url,
          suggestedFileName: 'cd (1).zip',
          contentDisposition: 'attachment; filename="cd.zip"',
        ),
        'cd.zip',
      );
      expect(
        inferWebBrowserDownloadFileName(url: url, suggestedFileName: 's.pdf'),
        's.pdf',
      );
      expect(
        inferWebBrowserDownloadFileName(
          url: url,
          contentDisposition: 'attachment; filename="cd.zip"',
        ),
        'cd.zip',
      );
      expect(inferWebBrowserDownloadFileName(url: url), '本.epub');
      expect(
        inferWebBrowserDownloadFileName(
          url: Uri.parse('https://x.test/'),
          mimeType: 'application/pdf; charset=binary',
        ),
        'download.pdf',
      );
      expect(
        inferWebBrowserDownloadFileName(
          url: Uri.parse('https://x.test/get'),
          mimeType: 'image/png',
        ),
        'get.png',
      );
    });

    test('文件名清洗：Windows 非法字符、结尾点与空格', () {
      expect(sanitizeWebBrowserFileName('a<b>:c?.txt. '), 'a_b__c_.txt');
      expect(sanitizeWebBrowserFileName('  '), isNull);
    });

    test('撞名追加 (1) (2)，.part 也算占用', () {
      final Set<String> existing = <String>{'/d/a.pdf', '/d/a (1).pdf.part'};
      final String path = uniqueWebBrowserDownloadPath(
        '/d',
        'a.pdf',
        (String p) => existing.contains(p.replaceAll(r'\', '/')),
      );
      expect(path.replaceAll(r'\', '/'), '/d/a (2).pdf');
    });

    test('进度写库节流：1% 或 1 MiB', () {
      expect(
        shouldReportWebBrowserDownloadProgress(
          lastReported: 0,
          received: 50,
          total: 10000,
        ),
        isFalse,
      );
      expect(
        shouldReportWebBrowserDownloadProgress(
          lastReported: 0,
          received: 100,
          total: 10000,
        ),
        isTrue,
      );
      expect(
        shouldReportWebBrowserDownloadProgress(
          lastReported: 0,
          received: 1024 * 1024,
          total: null,
        ),
        isTrue,
      );
    });

    test('iOS 走分享面板（下载中心合规门），其它平台进下载目录', () {
      expect(
        webBrowserDownloadDestinationFor(isIOS: true),
        WebBrowserDownloadDestination.shareSheet,
      );
      expect(
        webBrowserDownloadDestinationFor(isIOS: false),
        WebBrowserDownloadDestination.userDownloads,
      );
    });
  });

  group('长按 / 右键菜单', () {
    test('移动端命中：链接 / 图片链接 / 图片', () {
      expect(
        webBrowserHitTargetFromHitTest(
          InAppWebViewHitTestResult(
            type: InAppWebViewHitTestResultType.SRC_ANCHOR_TYPE,
            extra: 'https://a.test/x',
          ),
        ),
        WebBrowserHitTarget(link: Uri.parse('https://a.test/x')),
      );
      final WebBrowserHitTarget imageLink = webBrowserHitTargetFromHitTest(
        InAppWebViewHitTestResult(
          type: InAppWebViewHitTestResultType.SRC_IMAGE_ANCHOR_TYPE,
          extra: 'https://img.test/p.png',
        ),
        focusHref: Uri.parse('https://a.test/post'),
      );
      expect(imageLink.link, Uri.parse('https://a.test/post'));
      expect(imageLink.image, Uri.parse('https://img.test/p.png'));
      expect(
        webBrowserHitTargetFromHitTest(
          InAppWebViewHitTestResult(
            type: InAppWebViewHitTestResultType.EDIT_TEXT_TYPE,
          ),
        ).isEmpty,
        isTrue,
      );
    });

    test('javascript: 链接不算链接；相对地址按页面解析', () {
      expect(
        webBrowserHitTargetFromJs(<String, Object?>{
          'link': 'javascript:void(0)',
        }).isEmpty,
        isTrue,
      );
      expect(
        webBrowserHitTargetFromJs(<String, Object?>{
          'link': '/next',
          'image': 'img/a.jpg',
        }, base: Uri.parse('https://a.test/dir/page')),
        WebBrowserHitTarget(
          link: Uri.parse('https://a.test/next'),
          image: Uri.parse('https://a.test/dir/img/a.jpg'),
        ),
      );
    });

    test('菜单项：链接与图片各自一组；无痕 / OCR 按能力出现；data 图片不给地址类', () {
      final WebBrowserHitTarget both = WebBrowserHitTarget(
        link: Uri.parse('https://a.test'),
        image: Uri.parse('https://a.test/i.png'),
      );
      expect(
        webBrowserContextMenuItems(
          both,
          incognitoAvailable: true,
          ocrAvailable: true,
        ),
        WebBrowserContextMenuItem.values,
      );
      expect(
        webBrowserContextMenuItems(
          both,
          incognitoAvailable: false,
          ocrAvailable: false,
        ),
        isNot(
          anyOf(
            contains(WebBrowserContextMenuItem.openIncognitoTab),
            contains(WebBrowserContextMenuItem.ocrImage),
          ),
        ),
      );
      expect(
        webBrowserContextMenuItems(
          WebBrowserHitTarget(image: Uri.parse('data:image/png;base64,AAAA')),
          incognitoAvailable: true,
          ocrAvailable: true,
        ),
        <WebBrowserContextMenuItem>[
          WebBrowserContextMenuItem.saveImage,
          WebBrowserContextMenuItem.ocrImage,
        ],
      );
    });

    test('无痕：Android 默认（未探测到多 Profile）不提供，其余平台提供', () {
      expect(webBrowserIncognitoSupportedOn(TargetPlatform.android), isFalse);
      expect(webBrowserIncognitoSupportedOn(TargetPlatform.iOS), isTrue);
      expect(webBrowserIncognitoSupportedOn(TargetPlatform.windows), isTrue);
      expect(webBrowserIncognitoSupportedOn(TargetPlatform.linux), isTrue);
      expect(webBrowserIncognitoSupportedOn(TargetPlatform.macOS), isTrue);
    });
  });

  group('历史记录时机', () {
    late List<(String, String)> visits;
    late WebBrowserVisitRecorder recorder;

    setUp(() {
      visits = <(String, String)>[];
      recorder = WebBrowserVisitRecorder(
        record: (Uri url, String title) => visits.add((url.toString(), title)),
      );
    });

    test('整页加载：地址变化 + 标题 + 加载完成只记一次', () {
      recorder.onUrlChanged(Uri.parse('https://a.test/1'));
      recorder.onTitleChanged('One');
      recorder.onLoadStop(Uri.parse('https://a.test/1'), 'One');
      expect(visits, <(String, String)>[('https://a.test/1', 'One')]);
    });

    test('单页应用：先换地址后换标题，用新标题记', () {
      recorder.onLoadStop(Uri.parse('https://yt.test/'), 'Home');
      recorder.onUrlChanged(Uri.parse('https://yt.test/watch?v=1'));
      recorder.onTitleChanged('Video');
      expect(visits.last, ('https://yt.test/watch?v=1', 'Video'));
      expect(visits, hasLength(2));
    });

    test('待记期间又换地址：先记上一条；关标签页 flush 最后一条', () {
      recorder.onUrlChanged(Uri.parse('https://a.test/1'));
      recorder.onUrlChanged(Uri.parse('https://a.test/2'));
      expect(visits, <(String, String)>[('https://a.test/1', '')]);
      recorder.flush();
      expect(visits.last.$1, 'https://a.test/2');
    });

    test('同一地址重复事件不重复记；刷新后允许再记；非网页地址不记', () {
      recorder.onLoadStop(Uri.parse('https://a.test/1'), 'One');
      recorder.onUrlChanged(Uri.parse('https://a.test/1'));
      recorder.onLoadStop(Uri.parse('https://a.test/1'), 'One');
      expect(visits, hasLength(1));
      recorder.onReload();
      recorder.onLoadStop(Uri.parse('https://a.test/1'), 'One');
      expect(visits, hasLength(2));
      recorder.onLoadStop(Uri.parse('about:blank'), '');
      expect(visits, hasLength(2));
    });
  });

  group('网站权限', () {
    test('资源映射：摄像头 + 麦克风拆两项；认不出的资源整条拒绝', () {
      expect(
        webBrowserSitePermissionsFor(<PermissionResourceType>[
          PermissionResourceType.CAMERA_AND_MICROPHONE,
        ]),
        <WebBrowserSitePermission>[
          WebBrowserSitePermission.camera,
          WebBrowserSitePermission.microphone,
        ],
      );
      expect(
        webBrowserSitePermissionsFor(<PermissionResourceType>[
          PermissionResourceType.MIDI_SYSEX,
        ]),
        isNull,
      );
    });

    test('受保护内容（Widevine）：PROTECTED_MEDIA_ID 映射成 protectedContent，不再整条拒绝', () {
      expect(
        webBrowserSitePermissionsFor(<PermissionResourceType>[
          PermissionResourceType.PROTECTED_MEDIA_ID,
        ]),
        <WebBrowserSitePermission>[WebBrowserSitePermission.protectedContent],
      );
    });

    test('受保护内容没记住时默认允许；显式阻止照样阻止；其它权限 ask 不变', () {
      expect(
        webBrowserEffectiveDecision(
          WebBrowserSitePermission.protectedContent,
          WebBrowserPermissionDecision.ask,
        ),
        WebBrowserPermissionDecision.allow,
      );
      expect(
        webBrowserEffectiveDecision(
          WebBrowserSitePermission.protectedContent,
          WebBrowserPermissionDecision.block,
        ),
        WebBrowserPermissionDecision.block,
      );
      expect(
        webBrowserEffectiveDecision(
          WebBrowserSitePermission.camera,
          WebBrowserPermissionDecision.ask,
        ),
        WebBrowserPermissionDecision.ask,
      );
    });

    test('合并决定：任一阻止 → 阻止；全允许 → 允许；否则问', () {
      expect(
        combineWebBrowserPermissionDecisions(<WebBrowserPermissionDecision>[
          WebBrowserPermissionDecision.allow,
          WebBrowserPermissionDecision.block,
        ]),
        WebBrowserPermissionDecision.block,
      );
      expect(
        combineWebBrowserPermissionDecisions(<WebBrowserPermissionDecision>[
          WebBrowserPermissionDecision.allow,
          WebBrowserPermissionDecision.allow,
        ]),
        WebBrowserPermissionDecision.allow,
      );
      expect(
        combineWebBrowserPermissionDecisions(<WebBrowserPermissionDecision>[
          WebBrowserPermissionDecision.allow,
          WebBrowserPermissionDecision.ask,
        ]),
        WebBrowserPermissionDecision.ask,
      );
    });
  });

  test('页内查找结果解析', () {
    expect(parseWebBrowserFindResult('{"count":12,"current":3}'), (
      count: 12,
      current: 3,
    ));
    expect(parseWebBrowserFindResult(null), (count: 0, current: 0));
    expect(parseWebBrowserFindResult('oops'), (count: 0, current: 0));
  });
}
