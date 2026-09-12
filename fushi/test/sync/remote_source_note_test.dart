import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:fushi_engine/sync/fushi_remote_api_handlers.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:fushi/src/sync/fushi_remote_mining_client.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/remote_source_note.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const String sourceId = '00112233-4455-4677-8899-aabbccddeeff';
final CardSourceLink sourceLink = CardSourceLink(
  kind: CardSourceKind.book,
  uid: 'book-uid',
  sourceId: sourceId,
  chapterIndex: 2,
  charOffset: 42,
);
final AnkiSourceNote original = AnkiSourceNote(
  sourceId: sourceId,
  noteId: 17,
  fields: <String, String>{'Sentence': 'original', 'Meaning': 'hand edit'},
);
final String ownerIdentity = sourcePeerPairingIdentity(
  const FushiClientUrl(
    url: 'https://owner:8765/',
    token: 'owner',
    fingerprintSha256: 'fp',
  ),
);

class _Service
    implements FushiRemoteMiningService, FushiRemoteSourceNoteService {
  int reads = 0;
  ForwardedMinePayload? prepared;
  Map<String, String>? patch;
  bool missing = false;
  @override
  Future<AnkiSourceNote?> readSourceNote(String id) async {
    reads++;
    return missing ? null : original;
  }

  @override
  Future<Map<String, String>> prepareForwardedSourceNote(
    ForwardedMinePayload payload,
  ) async {
    prepared = payload;
    return <String, String>{'Sentence': payload.sentence};
  }

  @override
  Future<void> patchSourceNote({
    required AnkiSourceNote original,
    required Map<String, String> fields,
  }) async {
    patch = fields;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected mining operation ${invocation.memberName}');
}

http.Response _json(Map<String, dynamic> json) =>
    http.Response(jsonEncode(json), 200);

void main() {
  test(
    'restoring a draft binds its paired owner before the first read',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(url: 'http://first:8765', token: 'first'),
        FushiClientUrl(
          url: 'https://owner:8765/',
          token: 'owner',
          fingerprintSha256: 'fp',
        ),
      ]);
      final List<String> hosts = <String>[];
      final FushiRemoteMiningClient client = FushiRemoteMiningClient(
        repo: repo,
        httpClient: MockClient((http.Request request) async {
          hosts.add(request.url.host);
          return _json(<String, dynamic>{
            'ok': true,
            'note': encodeRemoteSourceNote(original),
          });
        }),
        pinnedClientFactory: (String fingerprint) =>
            MockClient((http.Request request) async {
          hosts.add(request.url.host);
          return _json(<String, dynamic>{
            'ok': true,
            'note': encodeRemoteSourceNote(original),
          });
        }),
      );
      await client.bindSourcePeer(
        sourceId,
        'https://owner:8765',
        pairingIdentity: ownerIdentity,
      );
      expect((await client.readSourceNote(sourceId))!.noteId, 17);
      expect(hosts, <String>['owner']);
      await expectLater(
        client.bindSourcePeer(
          sourceId,
          'http://unpaired:8765',
          pairingIdentity: ownerIdentity,
        ),
        throwsStateError,
      );
      await expectLater(
        client.bindSourcePeer(
          sourceId,
          'http://first:8765',
          pairingIdentity: ownerIdentity,
        ),
        throwsStateError,
      );
      expect(hosts, <String>['owner']);
    },
  );
  for (final bool rotateToken in <bool>[true, false]) {
    test(
      'restart rejects same-origin draft after ${rotateToken ? 'token' : 'TLS pin'} rotation',
      () async {
        final FushiDatabase db = FushiDatabase.forTesting(
          DatabaseConnection(NativeDatabase.memory()),
        );
        addTearDown(db.close);
        final SyncRepository repo = SyncRepository(db);
        await repo.setFushiClientUrls(const <FushiClientUrl>[
          FushiClientUrl(
            url: 'https://owner:8765/',
            token: 'owner',
            fingerprintSha256: 'fp',
          ),
        ]);
        int requests = 0;
        http.Client clientForPin(String fingerprint) =>
            MockClient((http.Request request) async {
              requests++;
              return _json(<String, dynamic>{
                'ok': true,
                'note': encodeRemoteSourceNote(original),
              });
            });
        final FushiRemoteMiningClient first = FushiRemoteMiningClient(
          repo: repo,
          pinnedClientFactory: clientForPin,
        );
        await first.readSourceNote(sourceId);
        final String savedIdentity = first.sourcePeerIdentity(sourceId)!;
        expect(savedIdentity, ownerIdentity);
        await repo.setFushiClientUrls(<FushiClientUrl>[
          FushiClientUrl(
            url: 'https://owner:8765/',
            token: rotateToken ? 'new-device-token' : 'owner',
            fingerprintSha256: rotateToken ? 'fp' : 'new-device-pin',
          ),
        ]);
        // Empty in-memory bindings reproduce a process restart. The remote note
        // response is deliberately identical: copied Anki IDs cannot select a peer.
        final FushiRemoteMiningClient restarted = FushiRemoteMiningClient(
          repo: repo,
          pinnedClientFactory: clientForPin,
        );
        await expectLater(
          restarted.bindSourcePeer(
            sourceId,
            'https://owner:8765',
            pairingIdentity: savedIdentity,
          ),
          throwsStateError,
        );
        await expectLater(
          restarted.patchSourceNote(
            original: original,
            fields: <String, String>{'Sentence': 'must not write'},
          ),
          throwsStateError,
        );
        expect(requests, 1);
        expect(restarted.sourcePeerIdentity(sourceId), isNull);
      },
    );
  }
  test('forwarded source identity and media survive serialization', () {
    final ForwardedMinePayload payload = ForwardedMinePayload(
      rawPayloadJson: '{}',
      sentence: 'new sentence',
      sourceLink: sourceLink,
      collectionTag: 'series',
      coverBytes: Uint8List.fromList(<int>[1, 2, 3]),
    );
    final ForwardedMinePayload decoded = ForwardedMinePayload.fromJson(
      jsonDecode(jsonEncode(payload.toJson())) as Map<String, dynamic>,
    );
    expect(decoded.sourceLink!.toUri(), sourceLink.toUri());
    expect(decoded.coverBytes, <int>[1, 2, 3]);
    expect(decoded.collectionTag, 'series');
  });

  test('wire note rejects missing identity and nonstring snapshots', () {
    expect(
      () => decodeRemoteSourceNote(<String, dynamic>{'noteId': 17}),
      throwsFormatException,
    );
    expect(
      () => decodeRemoteSourceFields(<String, dynamic>{'Sentence': 7}),
      throwsFormatException,
    );
    final AnkiSourceNote decoded = decodeRemoteSourceNote(
      encodeRemoteSourceNote(original),
    );
    expect(decoded.fields, original.fields);
    expect(
      () => decoded.fields['Sentence'] = 'changed',
      throwsUnsupportedError,
    );
  });

  test('prepare rechecks existence and never creates a new note', () async {
    final _Service service = _Service();
    final Map<String, dynamic> body = ForwardedMinePayload(
      rawPayloadJson: '{}',
      sentence: 'new sentence',
      sourceLink: sourceLink,
    ).toJson();
    final Map<String, dynamic> result = await buildSourceNoteResponse(
      '/api/anki/source/prepare',
      body,
      mining: service,
    );
    expect(result['fields'], <String, String>{'Sentence': 'new sentence'});
    expect(service.reads, 1);
    service.missing = true;
    await expectLater(
      buildSourceNoteResponse(
        '/api/anki/source/prepare',
        body,
        mining: service,
      ),
      throwsStateError,
    );
  });

  test(
    'edit endpoints require server authentication before service calls',
    () async {
      final Directory dir = Directory.systemTemp.createTempSync(
        'fushi_source_test_',
      );
      final _Service service = _Service();
      final FushiSyncServer server = FushiSyncServer(
        syncDataDir: dir.path,
        port: 0,
        token: 'token',
        miningService: service,
      );
      await server.start();
      final http.Client client = http.Client();
      addTearDown(() async {
        client.close();
        await server.stop();
        dir.deleteSync(recursive: true);
      });
      final Uri uri = Uri.parse(
        'http://127.0.0.1:${server.port}/api/anki/source/read',
      );
      expect(
        (await client.post(
          uri,
          body: jsonEncode(<String, dynamic>{'sourceId': sourceId}),
        ))
            .statusCode,
        401,
      );
      expect(service.reads, 0);
      final http.Response response = await client.post(
        uri,
        headers: <String, String>{
          'Authorization': 'Basic ${base64Encode(utf8.encode('hibiki:token'))}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(<String, dynamic>{'sourceId': sourceId}),
      );
      expect(response.statusCode, 200);
      expect((jsonDecode(response.body) as Map)['ok'], true);
      expect(service.reads, 1);
    },
  );

  test(
    'read binds peer; patch failure never falls back to another collection',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(
          url: 'https://owner:8765',
          token: 'one',
          fingerprintSha256: 'fp',
        ),
        FushiClientUrl(url: 'http://other:8765', token: 'two'),
      ]);
      final List<String> seen = <String>[];
      int otherCalls = 0;
      final FushiRemoteMiningClient client = FushiRemoteMiningClient(
        repo: repo,
        httpClient: MockClient((http.Request request) async {
          otherCalls++;
          throw StateError('Must not reach the fallback collection');
        }),
        pinnedClientFactory: (String fingerprint) {
          expect(fingerprint, 'fp');
          return MockClient((http.Request request) async {
            seen.add(request.url.path);
            expect(
              request.headers['authorization'],
              'Basic ${base64Encode(utf8.encode('hibiki:one'))}',
            );
            if (request.url.path.endsWith('/read')) {
              return _json(<String, dynamic>{
                'ok': true,
                'note': encodeRemoteSourceNote(original),
              });
            }
            return http.Response('temporarily unavailable', 503);
          });
        },
      );
      final AnkiSourceNote? note = await client.readSourceNote(sourceId);
      expect(note!.noteId, 17);
      await expectLater(
        client.patchSourceNote(
          original: note,
          fields: <String, String>{'Sentence': 'new'},
        ),
        throwsStateError,
      );
      expect(seen, <String>['/api/anki/source/read', '/api/anki/source/patch']);
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(
          url: 'https://owner:8765',
          token: 'changed',
          fingerprintSha256: 'fp',
        ),
        FushiClientUrl(url: 'http://other:8765', token: 'two'),
      ]);
      await expectLater(
        client.patchSourceNote(
          original: note,
          fields: <String, String>{'Sentence': 'new'},
        ),
        throwsStateError,
      );
      expect(
        seen.length,
        2,
        reason: 'Changed pairing requires a new edit session.',
      );
      expect(otherCalls, 0);
    },
  );

  test(
    'preparation and patch without an original peer read are rejected',
    () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      addTearDown(db.close);
      final FushiRemoteMiningClient client = FushiRemoteMiningClient(
        repo: SyncRepository(db),
        httpClient: MockClient(
          (http.Request request) async => throw StateError('unexpected IO'),
        ),
      );
      await expectLater(
        client.prepareForwardedSourceNote(
          ForwardedMinePayload(
            rawPayloadJson: '{}',
            sentence: '',
            sourceLink: sourceLink,
          ),
        ),
        throwsStateError,
      );
      await expectLater(
        client.patchSourceNote(
          original: original,
          fields: <String, String>{'Sentence': 'new'},
        ),
        throwsStateError,
      );
    },
  );
}
