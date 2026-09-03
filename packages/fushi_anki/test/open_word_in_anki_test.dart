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
/// | `(did:1771332842760) ("dupe:1758278161949,たっぷり" OR …)` | `[1758347126448]` |
///
/// BUG-1915 把**查重**换成了 Anki 内建的第一字段 checksum，却把 ↗ 的反查留在按字段名
/// 查的老路上，于是同一个词一边说已制卡、一边说没有卡。`canAddNotes` 只回布尔、给不出
/// note id，所以「同源」不能靠复用它——`dupe:<笔记类型id>,<文本>` 是那条 checksum 判据
/// 的搜索语法版本，这里钉死 ↗ 走的就是它。
///
/// **不按名字查**：卡组范围先按名字**精确**解析成 id（[ankiDuplicateDeckIds]）再用
/// `did:`，最后只把 note id 以 `nid:a,b,c` 交给浏览器。原因是实测出来的——Anki 搜索
/// 的 `deck:` 是通配匹配（`deck:"e_grolls-…"` 与真名同样命中 10164 条、`deck:"e*"`
/// 圈走整棵树），而查重那侧是精确名（把一个字换成 `_` 或用 `正在背::*` 都判「不重复」）。
/// 名字留在查询串里 = 给判据留第二个漂移入口。真机 E2E：`与える` 在库里同时是一张
/// Kaishi（第一字段 `Word`）和一张 Lapis（`Expression`）笔记，同源查询两张都返回，
/// `nid:1758347125581,1788020832613` 一次列全；该库 `正在背` 树下有 44 个这样的词。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String kWord = 'たっぷり';
  const String kDeck = '正在背::Kaishi 1.5k  zh-CH';
  const int kKaishiMid = 1758278161949;
  const int kLapisMid = 1667218449922;
  const int kExistingNoteId = 1758347126448;
  const int kDeckDid = 1771332842760;

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
  /// - `findNotes` 只在查询串同时满足「带 **Kaishi 那个 mid 的 `dupe:` 子句**」
  ///   与「卡组范围覆盖 [kDeckDid]（或压根没限卡组）」时命中那张已存在的笔记；
  /// - 按第一字段**名**查（`"Expression:…"`）恒 0 命中——真机上就是如此，那张卡的
  ///   第一字段叫 `Word`；
  /// - `guiBrowse` 不做任何匹配，只回传 `nid:` 里点到的那些（真机行为：它就是个打开
  ///   动作）。**故意不让 guiBrowse 有判别力**：命中与否必须由上一步决定，否则又是
  ///   两条判据。
  ///
  /// 判别力：退回按字段名查、漏掉非当前笔记类型的 mid、或把卡组名当搜索词（`deck:`）
  /// 而不是 id，本组用例立刻变红。
  MockClient crossModelHost(
    List<Map<String, dynamic>> sink, {
    bool transportFails = false,
    bool guiBrowseReturnsNull = false,
    bool guiBrowseReturnsEmpty = false,
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
        case 'deckNamesAndIds':
          result = const <String, Object?>{
            kDeck: kDeckDid,
            '正在背': 1779901350674,
            '正在背::Lapis': 1771326371415,
            // 名字里带 `_` 的真实卡组：只要谁把它塞进 `deck:` 搜索串，`_` 就变成
            // 单字通配符，把下面那个兄弟卡组一起圈进来（本机实测）。
            'galgame_card_test': 1784372258515,
            'galgameXcard_test': 1784372258516,
          };
        case 'findNotes':
          final String query = (body['params'] as Map)['query'].toString();
          final bool sameSourceHit =
              query.contains('"dupe:$kKaishiMid,$kWord"');
          final bool inScope =
              !query.contains('did:') || query.contains('did:$kDeckDid');
          result = sameSourceHit && inScope
              ? const <int>[kExistingNoteId]
              : const <int>[];
        case 'guiBrowse':
          if (guiBrowseReturnsNull) break;
          if (guiBrowseReturnsEmpty) {
            result = const <int>[];
            break;
          }
          final String query = (body['params'] as Map)['query'].toString();
          final String ids = query.startsWith('nid:') ? query.substring(4) : '';
          result = <int>[
            for (final String s in ids.split(','))
              if (int.tryParse(s) case final int id) id,
          ];
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

  String queryOf(List<Map<String, dynamic>> sink, String action) =>
      (sink.singleWhere(
                  (Map<String, dynamic> b) => b['action'] == action)['params']
              as Map)['query']
          .toString();

  /// 判命中的那一句（同源的 `dupe:` 串）。
  String matchQuery(List<Map<String, dynamic>> sink) =>
      queryOf(sink, 'findNotes');

  /// 真正交给 Anki 浏览器的那一句。
  String browseQuery(List<Map<String, dynamic>> sink) =>
      queryOf(sink, 'guiBrowse');

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

    test('交给浏览器的那一句只有 nid:——词和卡组名都不进查询串', () async {
      await installSettings();
      final sink = <Map<String, dynamic>>[];
      await repoWith(crossModelHost(sink)).openWordInAnki(kWord, '');

      final String query = browseQuery(sink);
      expect(query, 'nid:$kExistingNoteId');
      // 名字进了搜索串就等于把判定交给 Anki 的通配匹配（`_`/`*`），那是第二条判据。
      expect(query, isNot(contains(kWord)));
      expect(query, isNot(contains('deck:')));
      expect(query, isNot(contains('dupe:')));
    });

    test('判命中的那一句：卡组按 id 过滤 + 每个笔记类型一个 dupe 子句', () async {
      await installSettings();
      final sink = <Map<String, dynamic>>[];
      await repoWith(crossModelHost(sink)).openWordInAnki(kWord, '');

      final String query = matchQuery(sink);
      expect(query, startsWith('(did:$kDeckDid) ('));
      expect(query, endsWith(')'));
      expect(query, contains('"dupe:$kLapisMid,$kWord"'));
      // 当前笔记类型之外的 mid 必须也在——本 bug 的整个要害就是那张 Kaishi 卡。
      expect(query, contains('"dupe:$kKaishiMid,$kWord"'));
      expect(query, contains(' OR '));
      // 绝不能退回按字段名查，也绝不能把卡组名塞回搜索串。
      expect(query, isNot(contains('Expression:')));
      expect(query, isNot(contains('deck:')));
    });

    test('scope=collection 时不带卡组过滤（与查重同一口径）', () async {
      await installSettings(scope: AnkiDuplicateScope.collection);
      final sink = <Map<String, dynamic>>[];
      await repoWith(crossModelHost(sink)).openWordInAnki(kWord, '');

      final String query = matchQuery(sink);
      expect(query, isNot(contains('did:')));
      expect(query, startsWith('('));
    });

    test('一张都没查到 → noMatch（不是 failed），且不去开浏览器', () async {
      await installSettings();
      final sink = <Map<String, dynamic>>[];
      // 词换一个：假机只对 たっぷり 命中。
      expect(
        await repoWith(crossModelHost(sink)).openWordInAnki('未収録', ''),
        AnkiOpenWordOutcome.noMatch,
      );
      // 空的 `nid:` 会把整库摊开，绝不能发出去。
      expect(
        sink.map((Map<String, dynamic> b) => b['action']),
        isNot(contains('guiBrowse')),
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

    // 上面那条担心（旧版 `guiBrowse` 不回列表 → 不许说「没有卡」）在改按 id 查之后
    // 是**结构性**成立的：返回值根本不参与判定。这条把它钉死——连「明确答空列表」
    // 都不该改变结局，否则就是又把第二条判据接回来了。
    test('guiBrowse 明确回空列表也不改变结局：判据在上一步的 findNotes', () async {
      await installSettings();
      final sink = <Map<String, dynamic>>[];
      expect(
        await repoWith(crossModelHost(sink, guiBrowseReturnsEmpty: true))
            .openWordInAnki(kWord, ''),
        AnkiOpenWordOutcome.opened,
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
        value: kWord,
        modelIds: const <int>[kLapisMid],
        deckIds: const <int>[kDeckDid],
      );
      expect(query, '(did:$kDeckDid) ("dupe:$kLapisMid,$kWord")');
    });

    test('值里的引号被转义（否则整条查询被解析器截断）', () {
      final String query = ankiDuplicateSearchQuery(
        value: 'a"b',
        modelIds: const <int>[7],
        deckIds: const <int>[],
      );
      expect(query, '("dupe:7,a\\"b")');
    });

    test('没有笔记类型 / 空词 → 空串（绝不发一条把整库摊开的搜索）', () {
      expect(
        ankiDuplicateSearchQuery(
          value: kWord,
          modelIds: const <int>[],
          deckIds: const <int>[kDeckDid],
        ),
        isEmpty,
      );
      expect(
        ankiDuplicateSearchQuery(
          value: '',
          modelIds: const <int>[kLapisMid],
          deckIds: const <int>[kDeckDid],
        ),
        isEmpty,
      );
    });

    test('多个卡组 id 也套括号：否则 `did:a OR did:b (X)` 查错范围', () {
      expect(ankiDeckIdFilter(const <int>[1, 2]), '(did:1 OR did:2)');
      expect(ankiDeckIdFilter(const <int>[]), isEmpty);
    });

    test('nid:a,b,c —— 全部同名笔记一次列出；空列表不产生查询串', () {
      expect(ankiNoteIdBrowseQuery(const <int>[1, 2, 3]), 'nid:1,2,3');
      expect(ankiNoteIdBrowseQuery(const <int>[7]), 'nid:7');
      expect(ankiNoteIdBrowseQuery(const <int>[]), isEmpty);
    });
  });

  /// 卡组名 → 卡组 id。这一组是「不按名字查」的判别力所在：名字一旦进 `deck:` 搜索串，
  /// `_` 就成了单字通配符（本机实测 `deck:"e_grolls-…"` 与真名同样命中 10164 条），
  /// 而画 ✓ 那侧是精确名（同样把一个字换成 `_` 就判「不重复」）。
  group('BUG-2051 卡组范围按 id 解析（不进 Anki 的通配匹配）', () {
    const Map<String, int> decks = <String, int>{
      '正在背': 100,
      '正在背::Lapis': 101,
      '正在背::Lapis::N5': 102,
      '正在背::Kaishi': 103,
      '别的': 200,
      'galgame_card_test': 300,
      // 只差一个字符的兄弟卡组：`deck:"galgame_card_test"` 会把它一起圈进来。
      'galgameXcard_test': 301,
    };

    test('deck：本组 + 子组，按名字前缀精确展开（对齐 checkChildren: true）', () {
      expect(
        ankiDuplicateDeckIds(
          deckName: '正在背::Lapis',
          scope: AnkiDuplicateScope.deck,
          deckNamesAndIds: decks,
        ),
        const <int>[101, 102],
      );
    });

    test('带 `_` 的卡组名只解析出它自己——兄弟卡组不得被通配进来', () {
      expect(
        ankiDuplicateDeckIds(
          deckName: 'galgame_card_test',
          scope: AnkiDuplicateScope.deck,
          deckNamesAndIds: decks,
        ),
        const <int>[300],
      );
    });

    test('deckRoot 取根卡组，整棵树都在范围内', () {
      expect(
        ankiDuplicateDeckIds(
          deckName: '正在背::Lapis::N5',
          scope: AnkiDuplicateScope.deckRoot,
          deckNamesAndIds: decks,
        ),
        const <int>[100, 101, 102, 103],
      );
    });

    test('collection / 空名 / 卡组已不存在 → 不加过滤（fail-open）', () {
      for (final AnkiDuplicateScope scope in AnkiDuplicateScope.values) {
        expect(
          ankiDuplicateDeckIds(
            deckName: '',
            scope: scope,
            deckNamesAndIds: decks,
          ),
          isEmpty,
        );
      }
      expect(
        ankiDuplicateDeckIds(
          deckName: '正在背::Lapis',
          scope: AnkiDuplicateScope.collection,
          deckNamesAndIds: decks,
        ),
        isEmpty,
      );
      expect(
        ankiDuplicateDeckIds(
          deckName: '已被删掉的卡组',
          scope: AnkiDuplicateScope.deck,
          deckNamesAndIds: decks,
        ),
        isEmpty,
      );
    });

    test('前缀相同但不是子组的卡组不被卷入（`Lapis2` ≠ `Lapis::*`）', () {
      expect(
        ankiDuplicateDeckIds(
          deckName: '正在背::Lapis',
          scope: AnkiDuplicateScope.deck,
          deckNamesAndIds: const <String, int>{
            '正在背::Lapis': 1,
            '正在背::Lapis2': 2,
            '正在背::Lapis::N5': 3,
          },
        ),
        const <int>[1, 3],
      );
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
