// resolveSourceStreamHeaders：来源库网络视频打开时的认证头解析。
// 凭据红线回归：Authorization 只在打开时由凭据存储现算，绝不落
// MediaSources.configJson / VideoBooks.streamSpecJson。

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_library_credential_store.dart';
import 'package:fushi/src/media/source_library/source_stream_headers.dart';
import 'package:fushi/src/media/source_library/stream_auth_scope.dart';
import 'package:fushi_core/fushi_core.dart';

FushiDatabase _memDb() => FushiDatabase.forTesting(NativeDatabase.memory());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('webdav source + secret -> Basic auth header from credential store',
      () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);

    final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
      label: 'Remote WebDAV Vids',
      mediaKind: 'video',
      rootPath: 'https://dav.example.com/media',
      transport: const Value('webdav'),
      configJson: Value(encodeSourceConfig(<String, Object?>{
        'host': 'dav.example.com',
        'port': 443,
        'username': 'u',
        'useTls': false,
      })),
      createdAt: 1000,
    ));
    await SourceLibraryCredentialStore(db).saveSecret(sid, password: 'pw');

    final Map<String, String> headers = await resolveSourceStreamHeaders(
      db: db,
      sourceId: sid,
      targetUrl: 'https://dav.example.com/media/show/e01.mkv',
    );
    expect(headers, <String, String>{
      'Authorization': 'Basic ${base64Encode(utf8.encode('u:pw'))}',
    });
  });

  test('凭据绝不发给来源根之外的主机（m3u8 里的第三方直链）', () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);

    final int sid = await db.insertMediaSource(MediaSourcesCompanion.insert(
      label: 'Remote WebDAV Vids',
      mediaKind: 'video',
      rootPath: 'https://dav.example.com/media',
      transport: const Value('webdav'),
      configJson: Value(encodeSourceConfig(<String, Object?>{
        'host': 'dav.example.com',
        'port': 443,
        'username': 'u',
        'useTls': false,
      })),
      createdAt: 1000,
    ));
    await SourceLibraryCredentialStore(db).saveSecret(sid, password: 'pw');

    // 来源根下的 .m3u8 允许出现指向任意主机的绝对行，那些行入库时同样带本来源
    // 的 sourceId。不按目标地址收口就会把 NAS 明文账号密码发给第三方。
    for (final String hostile in <String>[
      'https://cdn.thirdparty.com/x.mkv', // 完全另一台主机
      'https://dav.example.com.evil.net/x.mkv', // 后缀伪装
      'http://dav.example.com/media/x.mkv', // 降级到 http
      'https://dav.example.com:8443/media/x.mkv', // 换端口
      'https://dav.example.com/media-evil/x.mkv', // 路径前缀蒙混
    ]) {
      expect(
        await resolveSourceStreamHeaders(
            db: db, sourceId: sid, targetUrl: hostile),
        isEmpty,
        reason: '$hostile 不在来源根内，绝不能带 Authorization',
      );
    }

    // 同根下的真实条目照常带认证，否则等于把功能修没了。
    expect(
      await resolveSourceStreamHeaders(
        db: db,
        sourceId: sid,
        targetUrl: 'https://dav.example.com/media/sub/dir/e02.mkv',
      ),
      isNotEmpty,
    );
  });

  group('isUrlWithinSourceRoot / isSameHttpOrigin', () {
    test('同 origin 且路径在根之下才算根内', () {
      const String root = 'https://h.example.com/dav';
      expect(isUrlWithinSourceRoot('https://h.example.com/dav/a.mkv', root),
          isTrue);
      expect(isUrlWithinSourceRoot('https://h.example.com/dav', root), isTrue);
      // 分段比较：/dav-evil 不能被 /dav 前缀匹配蒙混过去。
      expect(
          isUrlWithinSourceRoot('https://h.example.com/dav-evil/a.mkv', root),
          isFalse);
      expect(isUrlWithinSourceRoot('https://h.example.com/other/a.mkv', root),
          isFalse);
    });

    test('默认端口归一：http://h 与 http://h:80 同 origin', () {
      expect(isSameHttpOrigin('http://h/a', 'http://h:80/b'), isTrue);
      expect(isSameHttpOrigin('https://h/a', 'https://h:443/b'), isTrue);
      expect(isSameHttpOrigin('https://h/a', 'https://h:8443/b'), isFalse);
      expect(isSameHttpOrigin('http://h/a', 'https://h/b'), isFalse);
    });

    test('大小写主机名等价，非绝对 URL 一律 false', () {
      expect(
          isSameHttpOrigin(
              'https://H.Example.com/a', 'https://h.example.com/b'),
          isTrue);
      expect(isSameHttpOrigin('/relative/a.mkv', 'https://h/b'), isFalse);
      expect(isSameHttpOrigin('', 'https://h/b'), isFalse);
      expect(isSameHttpOrigin('D:/local/a.mkv', 'https://h/b'), isFalse);
    });
  });

  test('null sourceId / local source / missing source -> empty headers',
      () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);

    expect(
      await resolveSourceStreamHeaders(
          db: db, sourceId: null, targetUrl: 'https://any.example.com/a.mkv'),
      isEmpty,
    );

    final int localId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Local Vids',
        mediaKind: 'video',
        rootPath: 'D:/videos',
        createdAt: 1000,
      ),
    );
    expect(
      await resolveSourceStreamHeaders(
          db: db, sourceId: localId, targetUrl: 'D:/videos/a.mkv'),
      isEmpty,
      reason: 'local sources need no auth headers',
    );

    expect(
      await resolveSourceStreamHeaders(
          db: db, sourceId: 999999, targetUrl: 'https://h.example.com/a.mkv'),
      isEmpty,
      reason: 'a deleted source (FK setNull races) degrades to no headers',
    );
  });
}
