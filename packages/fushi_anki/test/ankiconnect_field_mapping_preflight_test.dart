import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:http/http.dart' as http;

/// BUG-1900：制卡失败只给一句 AnkiConnect 透传的
/// `cannot create note because it is empty`，用户在「没选对卡组 / 笔记类型换了」时
/// 同样看到它，既看不出病因也不知道去哪儿改（用户 2026-08-28 报告 + 日志栈
/// `Anki.mineEntry` → `AnkiConnectService.addNote`）。
///
/// 根因不在文案：AnkiConnect 按字段**名**匹配，不认识的名字被服务端静默丢弃，而
/// `BaseAnkiRepository.fieldMappingsAfterFetch` 对非 Lapis 笔记类型直接
/// `return current.fieldMappings` —— 换了笔记类型，映射里的字段名可能一个都不属于
/// 新类型。整张卡到服务端全是空的，Anki 的 `fields_check()` 判首字段空后拒收。
/// 既有的 `fields.isEmpty` 守卫拦不住：map 非空，只是名字全错。
/// 对照组 AnkiDroid 后端按 `noteType.fields` 的**位置**取值，天然免疫。
///
/// 这里守三件事：① 名字对不上时**本地拦下、一个请求都不发**并给分类错误码；
/// ② 首字段空同样本地拦下；③ 正常情形只把属于该笔记类型的字段送出去。
class _RecordingClient extends http.BaseClient {
  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];

  /// 按 action 返回的假响应；未登记的 action 返回 `{"result":null,"error":null}`。
  final Map<String, Object?> results;

  _RecordingClient({this.results = const <String, Object?>{}});

  List<String> get actions =>
      requests.map((Map<String, dynamic> r) => r['action'] as String).toList();

  Map<String, dynamic>? get lastAddNote {
    for (final Map<String, dynamic> r in requests.reversed) {
      if (r['action'] == 'addNote') return r;
    }
    return null;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final String body =
        await (request as http.Request).finalize().bytesToString();
    final Map<String, dynamic> decoded =
        Map<String, dynamic>.from(jsonDecode(body) as Map);
    requests.add(decoded);
    final Object? result = results[decoded['action'] as String];
    final String payload =
        jsonEncode(<String, Object?>{'result': result, 'error': null});
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(payload)),
      200,
      request: request,
    );
  }
}

class _Repo extends AnkiConnectRepository {
  _Repo({required AnkiConnectService service, required this.settings})
      : super(service: service);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

AnkiSettings _settings({
  required List<String> noteTypeFields,
  required Map<String, String> fieldMappings,
}) =>
    AnkiSettings(
      selectedDeckId: 1,
      selectedNoteTypeId: 2,
      availableDecks: const <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
      availableNoteTypes: <AnkiNoteType>[
        AnkiNoteType(id: 2, name: 'Lapis', fields: noteTypeFields),
      ],
      fieldMappings: fieldMappings,
      // 关掉查重，免得先打一发 findNotes 干扰「一个请求都不该发」的断言。
      allowDupes: true,
    );

const String _payload = '{"expression":"勉強","reading":"べんきょう"}';

_Repo _repoWith(_RecordingClient client, AnkiSettings settings) => _Repo(
      service: AnkiConnectService(
        host: '127.0.0.1',
        port: 8765,
        client: client,
      ),
      settings: settings,
    );

void main() {
  test('配置的字段名一个都不属于当前笔记类型 → 本地拦下、不发任何请求、给可分类错误码', () async {
    final _RecordingClient client = _RecordingClient();
    // 用户在 Anki 里换了笔记类型：新类型的字段是 Expression/Sentence，
    // 而设置里留着上一个类型的 Word/Meaning。
    final _Repo repo = _repoWith(
      client,
      _settings(
        noteTypeFields: <String>['Expression', 'Sentence'],
        fieldMappings: <String, String>{
          'Word': '{expression}',
          'Meaning': '{glossary}',
        },
      ),
    );

    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: _payload,
      context: const AnkiMiningContext(sentence: ''),
    );

    expect(outcome.result, MineResult.error);
    expect(outcome.errorCode, AnkiErrorCode.fieldMappingMismatch,
        reason: '必须是可分类失败，主 app 才能给本地化、可操作的文案');
    expect(client.actions, isNot(contains('addNote')),
        reason: '明知必失败的卡不该送出去 —— 送出去换回的就是那句不可操作的 '
            '"cannot create note because it is empty"');
    // 诊断串要写清「配了什么 / 有什么可用」，用户照着就能改。
    expect(outcome.errorDetail, contains('Word'));
    expect(outcome.errorDetail, contains('Expression'));
  });

  test('字段名对得上但首字段渲染为空 → 本地拦下并给 firstFieldEmpty', () async {
    final _RecordingClient client = _RecordingClient();
    // Expression 是首字段却没被映射；Sentence 有内容。Anki 的 fields_check() 只看
    // 首字段，这张卡送出去照样被拒 —— 而既有的 every-empty 守卫拦不住它。
    final _Repo repo = _repoWith(
      client,
      _settings(
        noteTypeFields: <String>['Expression', 'Sentence'],
        fieldMappings: <String, String>{'Sentence': '{sentence}'},
      ),
    );

    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: _payload,
      context: const AnkiMiningContext(sentence: '勉強しています'),
    );

    expect(outcome.result, MineResult.error);
    expect(outcome.errorCode, AnkiErrorCode.firstFieldEmpty);
    expect(client.actions, isNot(contains('addNote')));
    expect(outcome.errorDetail, contains('Expression'));
  });

  test('正常情形：只把属于该笔记类型的字段送出，陌生键被剥掉', () async {
    final _RecordingClient client =
        _RecordingClient(results: <String, Object?>{'addNote': 1234});
    final _Repo repo = _repoWith(
      client,
      _settings(
        noteTypeFields: <String>['Expression', 'Sentence'],
        fieldMappings: <String, String>{
          'Expression': '{expression}',
          'Sentence': '{sentence}',
          // 上一个笔记类型的遗留键：服务端不认识，此前会被原样送出。
          'LegacyWord': '{expression}',
        },
      ),
    );

    final MineOutcome outcome = await repo.mineEntry(
      rawPayloadJson: _payload,
      context: const AnkiMiningContext(sentence: '勉強しています'),
    );

    expect(outcome.result, MineResult.success);
    final Map<String, dynamic>? add = client.lastAddNote;
    expect(add, isNotNull, reason: '这次应该真的建卡');
    final Map<String, dynamic> note =
        Map<String, dynamic>.from((add!['params'] as Map)['note'] as Map);
    final Map<String, dynamic> sent =
        Map<String, dynamic>.from(note['fields'] as Map);
    expect(sent.keys, containsAll(<String>['Expression', 'Sentence']));
    expect(sent.keys, isNot(contains('LegacyWord')),
        reason: '不属于当前笔记类型的键必须被剥掉，而不是丢给服务端静默忽略');
  });
}
