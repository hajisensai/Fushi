// resolveSourceStreamHeaders：来源库网络视频打开时的认证头解析。
// 凭据红线回归：Authorization 只在打开时由凭据存储现算，绝不落
// MediaSources.configJson / VideoBooks.streamSpecJson。

import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_library_credential_store.dart';
import 'package:fushi/src/media/source_library/source_stream_headers.dart';
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

    final Map<String, String> headers =
        await resolveSourceStreamHeaders(db: db, sourceId: sid);
    expect(headers, <String, String>{
      'Authorization': 'Basic ${base64Encode(utf8.encode('u:pw'))}',
    });
  });

  test('null sourceId / local source / missing source -> empty headers',
      () async {
    final FushiDatabase db = _memDb();
    addTearDown(db.close);

    expect(await resolveSourceStreamHeaders(db: db, sourceId: null), isEmpty);

    final int localId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Local Vids',
        mediaKind: 'video',
        rootPath: 'D:/videos',
        createdAt: 1000,
      ),
    );
    expect(
      await resolveSourceStreamHeaders(db: db, sourceId: localId),
      isEmpty,
      reason: 'local sources need no auth headers',
    );

    expect(
      await resolveSourceStreamHeaders(db: db, sourceId: 999999),
      isEmpty,
      reason: 'a deleted source (FK setNull races) degrades to no headers',
    );
  });
}
