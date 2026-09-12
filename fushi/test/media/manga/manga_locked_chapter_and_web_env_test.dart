import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/cookie/manga_web_view_environment.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi_engine/utils/net/app_proxy.dart';

/// BUG-2479（锁定章判据）+ BUG-2478（WebView2 代理参数）的纯函数测试。
void main() {
  group('OnlineMangaChapter.locked', () {
    test('Mihon 章名前缀约定 = 锁定；普通章名不是', () {
      expect(OnlineMangaChapter.isLockedChapterName('\u{1F512} Vol.3'), isTrue);
      expect(
        OnlineMangaChapter.isLockedChapterName('\u{1F512} (Preview) Vol.3'),
        isTrue,
      );
      expect(OnlineMangaChapter.isLockedChapterName('  \u{1F512}x'), isTrue);
      expect(OnlineMangaChapter.isLockedChapterName('Vol.3'), isFalse);
      expect(OnlineMangaChapter.isLockedChapterName(''), isFalse);
      // 锁在中间不算：只认前缀，和扩展的写法一致。
      expect(OnlineMangaChapter.isLockedChapterName('Vol \u{1F512}'), isFalse);
    });

    test('v3 描述符往返保留 locked；缺省 false', () {
      const OnlineMangaChapter locked = OnlineMangaChapter(
        key: '/c/1',
        name: '\u{1F512} c1',
        locked: true,
        raw: <String, Object?>{},
      );
      final Map<String, Object?> json = locked.toJson();
      expect(json['locked'], isTrue);
      expect(OnlineMangaChapter.fromJson(json)!.locked, isTrue);

      const OnlineMangaChapter open = OnlineMangaChapter(
        key: '/c/2',
        name: 'c2',
        raw: <String, Object?>{},
      );
      expect(open.toJson().containsKey('locked'), isFalse);
      expect(OnlineMangaChapter.fromJson(open.toJson())!.locked, isFalse);
    });

    test('v1 旧描述符按章名前缀推出 locked', () {
      final OnlineMangaChapter? legacy = OnlineMangaChapter.fromLegacyMihonJson(
        <String, Object?>{'url': '/c/1', 'name': '\u{1F512} c1'},
      );
      expect(legacy!.locked, isTrue);
    });
  });

  group('MangaWebViewEnvironment.proxyArguments', () {
    test('手动 / 自动查到代理 → --proxy-server', () {
      expect(
        MangaWebViewEnvironment.proxyArguments(
          mode: kProxyModeManual,
          proxyHostPort: '127.0.0.1:34151',
        ),
        '--proxy-server=127.0.0.1:34151',
      );
      expect(
        MangaWebViewEnvironment.proxyArguments(
          mode: kProxyModeAuto,
          proxyHostPort: 'proxy.lan:8080',
        ),
        '--proxy-server=proxy.lan:8080',
      );
    });

    test('直连必须显式 --no-proxy-server，不能退回系统代理', () {
      expect(
        MangaWebViewEnvironment.proxyArguments(
          mode: kProxyModeDirect,
          proxyHostPort: '127.0.0.1:34151',
        ),
        '--no-proxy-server',
      );
    });

    test('自动且没查到代理 → 空串（跟系统）', () {
      expect(
        MangaWebViewEnvironment.proxyArguments(
          mode: kProxyModeAuto,
          proxyHostPort: null,
        ),
        '',
      );
      expect(
        MangaWebViewEnvironment.proxyArguments(
          mode: kProxyModeUnresolved,
          proxyHostPort: '',
        ),
        '',
      );
    });
  });
}
