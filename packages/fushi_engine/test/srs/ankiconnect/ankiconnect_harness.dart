import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_handler.dart';
import 'package:fushi_engine/srs/ankiconnect/srs_ankiconnect_media.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_style_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import '../support/srs_test_storage.dart';
import 'package:fushi_engine/srs/srs_storage.dart';

const String kAcProfile = '01928c3e-0000-7000-8000-0000000000ac';

/// 一个 profile 的内存库 + 兼容层，外加记录宿主回调的桶。
class AcHarness {
  AcHarness._(this.store);

  final SrsDbStore store;
  late SrsAnkiConnectHandler handler;

  final Map<String, Uint8List> media = <String, Uint8List>{};
  final List<(String?, List<String>)> browsed = <(String?, List<String>)>[];
  final List<String> edited = <String>[];
  int syncs = 0;
  String? apiKey;
  SrsAnkiMediaPolicy policy = const SrsAnkiMediaPolicy();
  final List<Uri> fetched = <Uri>[];

  static Future<AcHarness> create({
    Map<String, List<InternetAddress>> dns =
        const <String, List<InternetAddress>>{},
    SrsStyleStore? styles,
    List<String> Function(List<String> fields)? dupeNormBatch,
  }) async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final SrsStorage srsStorage = await openTestSrsStorage();
    int t = DateTime.utc(2026, 10, 14, 12).millisecondsSinceEpoch;
    final SrsDbStore store = await SrsDbStore.open(
      db: srsStorage.db,
      core: srsStorage.core,
      profileUid: kAcProfile,
      deviceId: 'dev',
      trustedClock: SrsTrustedClock(wallClockMs: () => t++, bootId: 'boot'),
      styles: styles,
    );
    final AcHarness h = AcHarness._(store);
    h.handler = SrsAnkiConnectHandler(
      store: () async => store,
      instanceId: 'inst-123',
      apiKey: () => h.apiKey,
      profileName: () => 'User 1',
      onSync: () => h.syncs++,
      onGuiBrowse: (String? q, List<String> ids) async =>
          h.browsed.add((q, ids)),
      onGuiEditNote: (String id) async => h.edited.add(id),
      mediaSink: (String name, Uint8List bytes) async {
        h.media[name] = bytes;
        return name;
      },
      mediaPolicy: () => h.policy,
      resolveHost: (String host) async =>
          dns[host] ?? (throw SocketException('no such host $host')),
      fetchUrl: (Uri uri, InternetAddress a) async {
        h.fetched.add(uri);
        return SrsAnkiFetchResult.ok(Uint8List.fromList(<int>[1, 2, 3]));
      },
      dupeNormBatch: dupeNormBatch,
    );
    return h;
  }

  /// 发一个 v6 请求，返回 `{result, error}`。
  Future<Map<String, Object?>> call(
    String action, [
    Map<String, Object?>? params,
    String? key,
  ]) async =>
      (await handler.handle(<String, Object?>{
            'action': action,
            'version': 6,
            'params': ?params,
            'key': ?key,
          })
          as Map<String, Object?>);

  /// 成功时取 result；出错就让测试失败并带上错误串。
  Future<Object?> ok(String action, [Map<String, Object?>? params]) async {
    final Map<String, Object?> r = await call(action, params);
    if (r['error'] != null) {
      throw StateError('$action failed: ${r['error']}');
    }
    return r['result'];
  }
}

/// Yomitan anki-note-builder 产出的笔记形状（Lapis 字段）。
Map<String, Object?> yomitanNote(
  String expression, {
  String deck = 'Default',
  String model = 'Lapis',
  String reading = '',
  String duplicateScope = 'collection',
  String? scopeDeckName,
  bool checkChildren = false,
  bool checkAllModels = false,
  bool allowDuplicate = true,
  List<String> tags = const <String>['yomitan'],
}) => <String, Object?>{
  'deckName': deck,
  'modelName': model,
  'fields': <String, Object?>{
    'Expression': expression,
    'ExpressionReading': reading,
    'Sentence': '<b>$expression</b>の例文。',
  },
  'tags': tags,
  'options': <String, Object?>{
    'allowDuplicate': allowDuplicate,
    'duplicateScope': duplicateScope,
    'duplicateScopeOptions': <String, Object?>{
      'deckName': scopeDeckName,
      'checkChildren': checkChildren,
      'checkAllModels': checkAllModels,
    },
  },
};

/// Yomitan backend._stripNotesArray + allowDuplicate=false（查重前的形状）。
Map<String, Object?> yomitanStripped(Map<String, Object?> note) {
  final Map<String, Object?> fields = (note['fields']! as Map)
      .cast<String, Object?>();
  final MapEntry<String, Object?> first = fields.entries.first;
  return <String, Object?>{
    ...note,
    'fields': <String, Object?>{first.key: first.value},
    'options': <String, Object?>{
      ...(note['options']! as Map).cast<String, Object?>(),
      'allowDuplicate': false,
    },
  };
}

/// Yomitan anki-connect.js `_getNoteQuery`：`_escapeQuery` 只去掉双引号。
String yomitanQuery(Map<String, Object?> note) {
  String esc(String s) => s.replaceAll('"', '');
  final Map<String, Object?> options = (note['options']! as Map)
      .cast<String, Object?>();
  String q = '';
  switch (options['duplicateScope']) {
    case 'deck':
      q = '"deck:${esc(note['deckName']! as String)}" ';
    case 'deck-root':
      q = '"deck:${esc((note['deckName']! as String).split('::').first)}" ';
  }
  final Map<String, Object?> fields = (note['fields']! as Map)
      .cast<String, Object?>();
  final MapEntry<String, Object?> f = fields.entries.first;
  return '$q"${f.key.toLowerCase()}:${esc(f.value! as String)}"';
}
