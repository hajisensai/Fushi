import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/cookie/browser_cookie_import.dart';
import 'package:fushi/src/media/manga/cookie/browser_login_import.dart';

/// 「从浏览器导入登录」的共用实现（app 内浏览器 / 视频站点网页档 / 漫画源登录页同一份）。
/// 三处的接线测试分别在 test/web_browser/web_page_underlay_and_menu_test.dart 与
/// test/media/manga/mihon_web_login_page_test.dart。
void main() {
  const BrowserSiteCookie session = BrowserSiteCookie(
    name: 'sid',
    value: 'v',
    domain: '.example.com',
    path: '/',
    secure: true,
    hostOnly: false,
  );

  setUp(BrowserCookieImportGate.resetForTesting);
  tearDown(BrowserCookieImportGate.resetForTesting);

  BrowserLoginImport create({
    required Future<int> Function(List<BrowserSiteCookie>) write,
    List<int>? imported,
    List<bool>? failed,
    List<Uri>? opened,
  }) => BrowserLoginImport(
    write: write,
    openExternal: (Uri url) async => opened?.add(url),
    onImported: (int n) => imported?.add(n),
    onFailed: () => failed?.add(true),
  );

  test('成功一次即结束：阶段 imported、回调一次、同 nonce 再送被拒', () async {
    final List<int> imported = <int>[];
    final List<Uri> opened = <Uri>[];
    final BrowserLoginImport import = create(
      write: (List<BrowserSiteCookie> c) async => c.length,
      imported: imported,
      opened: opened,
    );
    await import.begin(Uri.parse('https://www.example.com/watch?v=1'));
    expect(opened, <Uri>[Uri.parse('https://www.example.com/')]);
    expect(import.pendingHost, 'example.com');
    final String nonce = BrowserCookieImportGate.pending!.nonce;
    expect(
      BrowserCookieImportGate.deliver(
        nonce: nonce,
        host: 'example.com',
        cookies: const <BrowserSiteCookie>[session],
      ),
      isTrue,
    );
    expect(import.waiting, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(import.phase, BrowserLoginImportPhase.imported);
    expect(import.importedCount, 1);
    expect(imported, <int>[1]);
    expect(
      BrowserCookieImportGate.deliver(
        nonce: nonce,
        host: 'example.com',
        cookies: const <BrowserSiteCookie>[session],
      ),
      isFalse,
    );
    import.dispose();
  });

  test('写不进去：阶段 failed，同样结束登记', () async {
    final List<bool> failed = <bool>[];
    final BrowserLoginImport import = create(
      write: (List<BrowserSiteCookie> _) async => 0,
      failed: failed,
    );
    await import.begin(Uri.parse('https://example.com/'));
    final String nonce = BrowserCookieImportGate.pending!.nonce;
    BrowserCookieImportGate.deliver(
      nonce: nonce,
      host: 'example.com',
      cookies: const <BrowserSiteCookie>[session],
    );
    await Future<void>.delayed(Duration.zero);
    expect(import.phase, BrowserLoginImportPhase.failed);
    expect(failed, <bool>[true]);
    expect(BrowserCookieImportGate.pending, isNull);
    import.dispose();
  });

  test('再点一次 = 新登记（旧 nonce 作废）；dispose 撤登记', () async {
    final BrowserLoginImport import = create(
      write: (List<BrowserSiteCookie> c) async => c.length,
    );
    await import.begin(Uri.parse('https://example.com/'));
    final String first = BrowserCookieImportGate.pending!.nonce;
    await import.begin(Uri.parse('https://example.com/'));
    final String second = BrowserCookieImportGate.pending!.nonce;
    expect(second, isNot(first));
    expect(
      BrowserCookieImportGate.deliver(
        nonce: first,
        host: 'example.com',
        cookies: const <BrowserSiteCookie>[session],
      ),
      isFalse,
    );
    import.dispose();
    expect(BrowserCookieImportGate.pending, isNull);
  });

  test('登记只经共用实现：lib/ 里别处不直接 BrowserCookieImportGate.begin', () {
    final List<String> offenders = <String>[
      for (final FileSystemEntity f in Directory(
        'lib',
      ).listSync(recursive: true))
        if (f is File &&
            f.path.endsWith('.dart') &&
            !f.path
                .replaceAll(r'\', '/')
                .endsWith('media/manga/cookie/browser_login_import.dart') &&
            !f.path
                .replaceAll(r'\', '/')
                .endsWith('media/manga/cookie/browser_cookie_import.dart') &&
            f.readAsStringSync().contains('BrowserCookieImportGate.begin('))
          f.path,
    ];
    expect(
      offenders,
      isEmpty,
      reason: '「从浏览器导入登录」一律用 BrowserLoginImport（一次即结束、可取消的等待条）',
    );
  });
}
