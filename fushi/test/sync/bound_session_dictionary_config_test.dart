import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/game_stream_client.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 拍板台 pr3602：游戏串流 / 视频遥控查词虽在 host 上执行，词典的隐藏与排序按接收端
/// 在词典管理里对这台 host 的设置（`dictionaries` 字段）。查词语言仍归 host，不带。
void main() {
  const FushiClientUrl host = FushiClientUrl(
    url: 'http://desk:8765',
    hostId: 'desk',
    token: 'desk-token',
  );
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() async {
    resetInterconnectRaceCache();
    debugInterconnectAddressProbeOverride =
        (FushiClientUrl candidate, String? hostId) async => true;
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[host]);
  });
  tearDown(() async {
    debugInterconnectAddressProbeOverride = null;
    resetInterconnectRaceCache();
    await db.close();
  });

  Future<Map<String, dynamic>> streamLookupBody({
    RemoteLookupDictionaryConfig? Function(FushiClientUrl candidate)?
    dictionaryConfigFor,
  }) async {
    Map<String, dynamic>? body;
    final InterconnectGameStreamDictionaryLookup lookup =
        InterconnectGameStreamDictionaryLookup(
          repo: repo,
          peer: host,
          dictionaryConfigFor: dictionaryConfigFor,
          httpClient: MockClient((http.Request request) async {
            body = jsonDecode(request.body) as Map<String, dynamic>;
            return http.Response.bytes(
              utf8.encode(
                jsonEncode(<String, dynamic>{
                  'type': 'dictionaryResult',
                  'result': null,
                  'dictionaryStylesRevision': 'r',
                  'dictionaryStyles': <String, String>{},
                }),
              ),
              200,
              headers: const <String, String>{
                'content-type': 'application/json; charset=utf-8',
              },
            );
          }),
        );
    await lookup.searchDictionary(
      term: '髪',
      wildcards: false,
      maximumTerms: 20,
    );
    return body!;
  }

  test('串流查词带上接收端对这台 host 的词典选择', () async {
    final List<String> askedHosts = <String>[];
    final Map<String, dynamic> body = await streamLookupBody(
      dictionaryConfigFor: (FushiClientUrl candidate) {
        askedHosts.add(remoteDictionaryHostIdOf(candidate));
        return const RemoteLookupDictionaryConfig(
          excluded: <String>{'B'},
          order: <String>['C', 'A'],
        );
      },
    );
    expect(askedHosts, <String>['desk']);
    expect(body['term'], '髪');
    expect(body[kRemoteLookupDictionariesField], <String, Object?>{
      'excluded': <String>['B'],
      'order': <String>['C', 'A'],
    });
    // 查词语言仍归 host。
    expect(body.containsKey(kRemoteLookupLanguageField), isFalse);
  });

  test('接收端没有可说的（null）⇒ 不发 dictionaries 字段，host 用自己的配置', () async {
    final Map<String, dynamic> body = await streamLookupBody(
      dictionaryConfigFor: (FushiClientUrl candidate) => null,
    );
    expect(body.containsKey(kRemoteLookupDictionariesField), isFalse);
    final Map<String, dynamic> legacy = await streamLookupBody();
    expect(legacy.containsKey(kRemoteLookupDictionariesField), isFalse);
  });

  test('串流与遥控的生产装配都接上 AppModel.remoteLookupDictionaryConfigFor', () {
    // 回归钉：词典选择要一路从 AppModel 传到绑定会话的查词客户端；任何一处漏传，接收端
    // 关掉的词典在串流 / 遥控里又会冒出来。
    const Map<String, String> wiring = <String, String>{
      'lib/src/pages/implementations/video_remote_page.dart':
          'dictionaryConfigFor: _appModel.remoteLookupDictionaryConfigFor',
      'lib/src/pages/implementations/game_stream_library_page.dart':
          'dictionaryConfigFor: appModel.remoteLookupDictionaryConfigFor',
      'lib/src/sync/sync_settings_schema.dart':
          'ctx.appModel.remoteLookupDictionaryConfigFor',
      'lib/src/pages/implementations/game_stream_join_page.dart':
          'dictionaryConfigFor: widget.dictionaryConfigFor',
      'lib/src/pages/implementations/game_stream_session_opener.dart':
          'dictionaryConfigFor: dictionaryConfigFor',
    };
    wiring.forEach((String path, String needle) {
      expect(
        File(path).readAsStringSync(),
        contains(needle),
        reason: '$path 应把接收端词典选择传下去',
      );
    });
  });
}
