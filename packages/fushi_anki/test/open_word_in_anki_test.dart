import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// BUG-2051：↗「在 Anki 中打开这个词的卡」必须与画 ✓ 的查重**同一条判据**。
///
/// 本机真机取证（2026-09-02，AnkiConnect 25.x，本文件的 fake 就是照它建的）：
/// 卡组 `正在背::Kaishi 1.5k  zh-CH` 里混装两种笔记类型——`Kaishi 1.5k zh-CH`
/// （第一字段名 `Word`，mid 1758278161949）与 `Lapis`（第一字段名 `Expression`）。
/// 词 `たっぷり` 已作为一张 Kaishi 卡存在（note 1758347126448）。实测三条查询：
///
/// | 查询 | 结果 |
/// |---|---|
/// | `canAddNotesWithErrorDetail`（画 ✓ 的判据） | 判重复 → 画 ✓ |
/// | `deck:"…" "Expression:たっぷり"`（↗ 旧的反查） | `[]` → 「没有找到已制的卡片」 |
/// | `deck:"…" ("dupe:1758278161949,たっぷり" OR …)` | `[1758347126448]` |
///
/// BUG-1915 把**查重**换成了 Anki 内建的第一字段 checksum，却把 ↗ 的反查留在按字段名
/// 查的老路上，于是同一个词一边说已制卡、一边说没有卡。`canAddNotes` 只回布尔、给不出
/// note id，所以「同源」不能靠复用它——`dupe:<笔记类型id>,<文本>` 是那条 checksum 判据
/// 的搜索语法版本，这里钉死 ↗ 走的就是它。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String kWord = 'たっぷり';
  const String kDeck = '正在背::Kaishi 1.5k  zh-CH';
  const int kKaishiMid = 1758278161949;
  const int kLapisMid = 1667218449922;
  const int kExistingCardId = 1758347126448;

  const AnkiNoteType lapis = AnkiNoteType(
    id: kLapisMid,
    name: 'Lapis',
    fields: <String>['Expression', 'Sentence'],
  );

  Future<void> installSettings({
    AnkiDuplicateScope scope = AnkiDuplicateScope.deck,
  }) async {
    final AnkiSettings settings = AnkiSettings(
      selectedDeckId: 21,
      selectedDeckName: kDeck,
      selectedNoteTypeId: lapis.id,
      selectedNoteTypeName: lapis.name,
      availableDecks: const <AnkiDeck>[AnkiDeck(id: 21, name: kDeck)],
      availableNoteTypes: const <AnkiNoteType>[lapis],
      fieldMappings: const <String, String>{'Expression': '{expression}'},
      duplicateScope: scope,
    );
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    await AnkiConnectRepository().saveSettings(settings);
  }

  /// 一台**照实测行为建模**的假 AnkiConnect：
  /// - `findNotes`（按字段名的老判据）恒 0 命中；
  /// - `guiBrowse` 只有在查询串里带上 **Kaishi 那个 mid 的 `dupe:` 子句**时才命中。
  ///
  /// 两条判据在这台机器上给出相反答案——这正是守卫的判别力所在：退回按字段名查、
  /// 或漏掉非当前笔记类型的 mid，本组用例立刻变红。
  MockClient crossModelHost(
    List<Map<String, dynamic>> sink, {
    bool transportFails = false,
    bool guiBrowseReturnsNull = false,
  }) {
    return MockClient((http.Request request) async {
      if (transportFails) throw const SocketExceptionStub();
      final Map<String, dynamic> body =
          jsonDecode(request.body) as Map<String, dynamic>;
      sink.add(body);
      final String action = body['action'] as String;
      Object? result;
      Object? error;
      switch (action) {
        case 'modelNamesAndIds':
          result = const <String, Object?>{
            'Lapis': kLapisMid,
            'Kaishi 1.5k zh-CH': kKaishiMid,
          };
        case 'findNotes':
          result = const <int>[];
        case 'guiBrowse':
          if (guiBrowseReturnsNull) break;
          final String query = (body['params'] as Map)['query'].toString();
          result = query.contains('"dupe:$kKaishiMid,$kWord"')
              ? const <int>[kExistingCardId]
              : const <int>[];
        case 'canAddNotesWithErrorDetail':
          result = const <Map<String, Object?>>[
            <String, Object?>{
              'canAdd': false,
              'error': 'cannot create note because it is a duplicate',
            },
          ];
        default:
          error = 'unsupported action';
      }
      return http.Response(
        jsonEncode(<String, Object?>{'result': result, 'error': error}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
  }

  AnkiConnectRepository repoWith(http.Client client) {
    AnkiConnectRepository.resetDuplicateCheckCooldown();
    return AnkiConnectRepository(
      service:
          AnkiConnectService(host: '127.0.0.1', port: 8765, client: client),
    );
  }

  String browseQuery(List<Map<String, dynamic>> sink) => (sink.singleWhere(
              (Map<String, dynamic> b) => b['action'] == 'guiBrowse')['params']
          as Map)['query']
      .toString();

  setUp(() {
    // 前台让位是 Win32 副作用，单测里注入无害替身（非 Windows 上本就是 null）。
    AnkiDesktopForeground.debugBackend = _NoopForeground();
  });
  tearDown(() {
    AnkiDesktopForeground.debugBackend = null;
  });

  group('BUG-2051 ↗ 与 ✓ 同源', () {
    test('✓ 判为已制卡的词，↗ 必须能打开（哪怕卡在别的笔记类型里）', () async {
      await installSettings();
      final sink = <Map<String, dynamic>>[];
      final AnkiConnectRepository repo = repoWith(crossModelHost(sink));

      // 同一台假机上，画 ✓ 的判据说「已制卡」。
      expect(await repo.isDuplicate(kWord, ''), isTrue);
      // ↗ 必须给出一致的答案。旧实现（findNotes 按字段名 + nid:）在这里恒 noMatch。
      expect(
        await repo.openWordInAnki(kWord, ''),
        AnkiOpenWordOutcome.opened,
      );
    });

    test('↗ 不再另发一条 findNotes——没有第二条判据可以漂移', () async {
      await installSettings();
      final sink = <Map<String, dynamic>>[];
      await repoWith(crossModelHost(sink)).openWordInAnki(kWord, '');

      expect(
        sink.map((Map<String, dynamic> b) => b['action']),
        isNot(contains('findNotes')),
      );
      expect(
        sink.map((Map<String, dynamic> b) => b['action']),
        containsAll(<String>['modelNamesAndIds', 'guiBrowse']),
      );
    });

    test('查询串：卡组过滤 + 每个笔记类型一个 dupe 子句，整组带括号', () async {
      await installSettings();
      final sink = <Map<String, dynamic>>[];
      await repoWith(crossModelHost(sink)).openWordInAnki(kWord, '');

      final String query = browseQuery(sink);
      expect(query, startsWith('deck:"$kDeck" ('));
      expect(query, endsWith(')'));
      expect(query, contains('"dupe:$kLapisMid,$kWord"'));
      // 当前笔记类型之外的 mid 必须也在——本 bug 的整个要害就是那张 Kaishi 卡。
      expect(query, contains('"dupe:$kKaishiMid,$kWord"'));
      expect(query, contains(' OR '));
      // 绝不能退回按字段名查。
      expect(query, isNot(contains('Expression:')));
    });

    test('scope=collection 时不带卡组过滤（与查重同一口径）', () async {
      await installSettings(scope: AnkiDuplicateScope.collection);
      final sink = <Map<String, dynamic>>[];
      await repoWith(crossModelHost(sink)).openWordInAnki(kWord, '');

      final String query = browseQuery(sink);
      expect(query, isNot(contains('deck:')));
      expect(query, startsWith('('));
    });

    test('Anki 应答「一张都没选中」→ noMatch（不是 failed）', () async {
      await installSettings();
      final sink = <Map<String, dynamic>>[];
      // 词换一个：假机只对 たっぷり 命中。
      expect(
        await repoWith(crossModelHost(sink)).openWordInAnki('未収録', ''),
        AnkiOpenWordOutcome.noMatch,
      );
    });

    // 旧版 AnkiConnect 的 `guiBrowse` 不回传命中列表（应答里 result 是 null）。
    // 那台机器上浏览器**已经打开**并过滤到了这条查询，只是给不出计数——把这个
    // 「未知」当成「零命中」，就是本 bug 那句「没有找到已制的卡片」换个成因重来。
    test('旧版 AnkiConnect 不回命中列表（result=null）→ opened，不是 noMatch', () async {
      await installSettings();
      final sink = <Map<String, dynamic>>[];
      expect(
        await repoWith(crossModelHost(sink, guiBrowseReturnsNull: true))
            .openWordInAnki(kWord, ''),
        AnkiOpenWordOutcome.opened,
      );
      // 浏览器该开的还是开了：请求确实发出去了。
      expect(
        sink.map((Map<String, dynamic> b) => b['action']),
        contains('guiBrowse'),
      );
    });

    test('service 层把「不回列表」与「空列表」分成两个值（null vs []）', () async {
      final sinkNull = <Map<String, dynamic>>[];
      final AnkiConnectService nullService = AnkiConnectService(
        host: '127.0.0.1',
        port: 8765,
        client: crossModelHost(sinkNull, guiBrowseReturnsNull: true),
      );
      expect(await nullService.guiBrowseQuery('deck:x'), isNull);

      final sinkEmpty = <Map<String, dynamic>>[];
      final AnkiConnectService emptyService = AnkiConnectService(
        host: '127.0.0.1',
        port: 8765,
        client: crossModelHost(sinkEmpty),
      );
      // 假机对「不带 Kaishi dupe 子句」的查询明确答空列表。
      expect(await emptyService.guiBrowseQuery('deck:x'), isEmpty);
    });

    test('后端不可达 → failed（与「这个词没有卡」区分开）', () async {
      await installSettings();
      final sink = <Map<String, dynamic>>[];
      expect(
        await repoWith(crossModelHost(sink, transportFails: true))
            .openWordInAnki(kWord, ''),
        AnkiOpenWordOutcome.failed,
      );
    });

    test('空词 → failed，且一个请求都不发', () async {
      await installSettings();
      final sink = <Map<String, dynamic>>[];
      expect(
        await repoWith(crossModelHost(sink)).openWordInAnki('', ''),
        AnkiOpenWordOutcome.failed,
      );
      expect(sink, isEmpty);
    });
  });

  group('BUG-2051 查询串构造', () {
    test('单个笔记类型也套括号：否则卡组条件只绑到第一个子句', () {
      final String query = ankiDuplicateSearchQuery(
        deckName: kDeck,
        value: kWord,
        scope: AnkiDuplicateScope.deck,
        modelIds: const <int>[kLapisMid],
      );
      expect(query, 'deck:"$kDeck" ("dupe:$kLapisMid,$kWord")');
    });

    test('值里的引号被转义（否则整条查询被解析器截断）', () {
      final String query = ankiDuplicateSearchQuery(
        deckName: '',
        value: 'a"b',
        scope: AnkiDuplicateScope.collection,
        modelIds: const <int>[7],
      );
      expect(query, '("dupe:7,a\\"b")');
    });

    test('没有笔记类型 / 空词 → 空串（绝不发一条把整库摊开的搜索）', () {
      expect(
        ankiDuplicateSearchQuery(
          deckName: kDeck,
          value: kWord,
          scope: AnkiDuplicateScope.deck,
          modelIds: const <int>[],
        ),
        isEmpty,
      );
      expect(
        ankiDuplicateSearchQuery(
          deckName: kDeck,
          value: '',
          scope: AnkiDuplicateScope.deck,
          modelIds: const <int>[kLapisMid],
        ),
        isEmpty,
      );
    });

    test('deckRoot 取根卡组（与 ankiDuplicateDeckFilter 同一口径）', () {
      final String query = ankiDuplicateSearchQuery(
        deckName: '正在背::Lapis',
        value: kWord,
        scope: AnkiDuplicateScope.deckRoot,
        modelIds: const <int>[kLapisMid],
      );
      expect(query, startsWith('deck:"正在背" ('));
    });
  });

  /// 没有「按词打开」原生能力的后端（AnkiDroid 只有按 note id 的 deep link）走基类
  /// 默认实现。它们的查重与反查本来就限定同一笔记类型（`checkForDuplicates` /
  /// `findNotesByContent` 都传 `models:[当前笔记类型]`），两者同源，不存在本 bug。
  group('BUG-2051 基类默认实现（AnkiDroid 车道）', () {
    test('多张命中打开最近一张（note id 最大），不弹选择框', () async {
      final _IdOnlyRepo repo = _IdOnlyRepo(const <MinedNoteRef>[
        MinedNoteRef(noteId: 200, preview: 'older'),
        MinedNoteRef(noteId: 300, preview: 'newest'),
      ]);
      expect(await repo.openWordInAnki('語', ''), AnkiOpenWordOutcome.opened);
      expect(repo.openedNoteId, 300);
    });

    test('一张都没有 → noMatch，不调打开', () async {
      final _IdOnlyRepo repo = _IdOnlyRepo(const <MinedNoteRef>[]);
      expect(await repo.openWordInAnki('語', ''), AnkiOpenWordOutcome.noMatch);
      expect(repo.openedNoteId, isNull);
    });

    test('打开失败 → failed（不冒充成功）', () async {
      final _IdOnlyRepo repo = _IdOnlyRepo(
        const <MinedNoteRef>[MinedNoteRef(noteId: 7)],
        openSucceeds: false,
      );
      expect(await repo.openWordInAnki('語', ''), AnkiOpenWordOutcome.failed);
    });
  });
}

/// 只会「按 note id 打开」的后端替身（AnkiDroid 形状）。
class _IdOnlyRepo extends BaseAnkiRepository {
  _IdOnlyRepo(this.matches, {this.openSucceeds = true});

  final List<MinedNoteRef> matches;
  final bool openSucceeds;
  int? openedNoteId;

  @override
  Future<List<MinedNoteRef>> findMatchingNotes(
          String expression, String reading) async =>
      matches;

  @override
  Future<bool> openNoteInAnki(int noteId) async {
    openedNoteId = noteId;
    return openSucceeds;
  }

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('unused');
  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async =>
      const MineOutcome.success();
  @override
  Future<bool> isDuplicate(String expression, String reading) async => true;
  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;
  @override
  Future<bool> createDeck(String name) async => false;
}

/// 前台让位替身：单测里不碰 Win32，也不让真实后端去找监听端口的进程。
class _NoopForeground implements AnkiDesktopForegroundBackend {
  @override
  int? findProcessListeningOnPort(int port) => null;
  @override
  int? findAnkiProcessId() => null;
  @override
  bool allowSetForegroundWindow(int pid) => false;
  @override
  bool isForegroundOwnedByProcess(int pid) => false;
  @override
  bool raiseTopWindowOfProcess(int pid) => false;
  @override
  String? processImagePath(int pid) => null;
}

/// MockClient 里制造传输层失败用的哨兵异常（不引入 dart:io 只为一个类型）。
class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
  @override
  String toString() => 'SocketException: connection refused';
}
