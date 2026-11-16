import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/popup_settings_injection.dart'
    show popupCollapsedDictionaryNames;
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/profile/work_profile_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:path/path.dart' as p;

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

Dictionary _dict(
  String name, {
  required int order,
  bool hidden = false,
  bool kanjiHidden = false,
  bool collapsed = false,
}) => Dictionary(
  name: name,
  formatKey: 'yomichan',
  order: order,
  type: DictionaryType.term,
  metadata: <String, String>{
    if (kanjiHidden) kDictHasKanjiKey: 'true',
    if (kanjiHidden) kDictKanjiHiddenKey: 'true',
  },
  hiddenLanguages: hidden
      ? <String>[JapaneseLanguage.instance.languageCode]
      : const <String>[],
  collapsedLanguages: collapsed
      ? <String>[JapaneseLanguage.instance.languageCode]
      : const <String>[],
);

/// 反馈 r9SgiayKxa：书指定了非激活配置「英语」（英语词典开、日语词典关），激活配置
/// Default 里那些英语词典是关着的。引擎装载集合只看激活配置，于是英语词典根本没装进
/// 引擎，作品会话的过滤又把装着的日语词典全滤掉——一个词都查不到。
///
/// 契约：引擎装载集合 = 激活配置 ∪ 当前作品会话视图里开着的词典；弹窗的隐藏名单按
/// 作品会话视图给；会话装上 / 撤下时装载集合变了才重排（异步分批装载）。
void main() {
  group('DictionaryRepository.engineLoadStatesOf', () {
    test('没有作品会话：只看激活配置', () {
      final states = DictionaryRepository.engineLoadStatesOf(<Dictionary>[
        _dict('JP', order: 0),
        _dict('EN', order: 1, hidden: true),
      ], null);
      expect(states.map((s) => s.hidden).toList(), <bool>[false, true]);
    });

    test('激活配置关着、作品会话开着 → 装；两边都关 → 不装', () {
      final states = DictionaryRepository.engineLoadStatesOf(
        <Dictionary>[
          _dict('JP', order: 0),
          _dict('EN', order: 1, hidden: true),
          _dict('OFF', order: 2, hidden: true),
        ],
        <Dictionary>[
          _dict('JP', order: 0, hidden: true),
          _dict('EN', order: 1),
          _dict('OFF', order: 2, hidden: true),
        ],
      );
      expect(states.map((s) => s.hidden).toList(), <bool>[
        false,
        false,
        true,
      ], reason: '激活配置开着的仍要装（替对端 / 扩展查词按激活配置），作品配置开着的也要装');
    });

    test('混合词典汉字部分：激活配置关、作品会话开 → 取会话那行的开关', () {
      final Dictionary live = _dict('MIX', order: 0, kanjiHidden: true);
      final Dictionary overlay = live.copyWith(
        metadata: <String, String>{kDictHasKanjiKey: 'true'},
      );
      final states = DictionaryRepository.engineLoadStatesOf(
        <Dictionary>[live],
        <Dictionary>[overlay],
      );
      expect(isKanjiPartHiddenIn(states.single.metadata), isFalse);
    });
  });

  group('作品会话（真 ProfileRepository 视图）', () {
    late FushiDatabase db;
    late ProfileRepository repo;
    late ProfileViewModel vm;
    late DictionaryRepository dictRepo;
    final WorkProfileScope scope = WorkProfileScope.instance;
    final Object reader = Object();

    setUp(() async {
      scope.debugReset();
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      repo = ProfileRepository(db, FakeAnkiRepository());
      vm = ProfileViewModel(repo, () async {}, ProfileDraftCoordinator());
      await vm.stream.firstWhere(
        (ProfileUiState s) => !s.isLoading && s.profiles.isNotEmpty,
      );
      dictRepo = DictionaryRepository(db);
      await dictRepo.loadFromDb();

      // 绑定配置「英语」：EN 开且折叠、JP 关（先摆成这样快照进它）。
      final int boundId = await repo.createProfile('english');
      await dictRepo.persistDictionary(_dict('JP', order: 0, hidden: true));
      await dictRepo.persistDictionary(_dict('EN', order: 1, collapsed: true));
      await repo.snapshotCurrentSettings(boundId);
      // 激活配置（live）：JP 开、EN 关。
      await dictRepo.persistDictionary(_dict('JP', order: 0));
      await dictRepo.persistDictionary(_dict('EN', order: 1, hidden: true));
      await dictRepo.loadFromDb();
      await repo.setBookProfile('book-en', boundId);
    });

    tearDown(() async {
      scope.debugReset();
      vm.dispose();
      dictRepo.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await db.close();
    });

    test('进入 / 离开绑定作品：引擎排期跟着装载集合走，集合没变不重排，弹窗按会话视图', () async {
      final PreferencesRepository prefsRepo = PreferencesRepository(db);
      await prefsRepo.loadFromDb();
      final Directory tmpDir = Directory.systemTemp.createTempSync(
        'fushi_work_engine_load_',
      );
      // 走真实的异步排期路径（exists + 物化探测 + 分桶）：词典目录得真在、字节可读。
      // 不放 index.json，免得来源元数据回填去写库。
      final Directory dictDir = Directory(p.join(tmpDir.path, 'dicts'));
      for (final String name in <String>['JP', 'EN']) {
        File(p.join(dictDir.path, name, 'blobs.bin'))
          ..createSync(recursive: true)
          ..writeAsBytesSync(<int>[0]);
      }
      final String? prevCacheDir = FushiDicts.unionFilterCacheDirectory;
      FushiDicts.unionFilterCacheDirectory = p.join(tmpDir.path, 'cache');
      addTearDown(() {
        FushiDicts.dropPendingForTest();
        FushiDicts.unionFilterCacheDirectory = prevCacheDir;
        try {
          tmpDir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final AppModel app = AppModel(testPlatformServices())
        ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo,
          databaseDirectory: tmpDir,
        )
        ..wireDatabaseForTesting(db, dictionaryRepository: dictRepo)
        ..wireDictionaryResourceDirectoryForTesting(dictDir);
      FushiDicts.dropPendingForTest();
      final String jp = p.join(dictDir.path, 'JP');
      final String en = p.join(dictDir.path, 'EN');

      // 会话外：只装激活配置开着的 JP。
      expect(await app.debugRescheduleDictsForLookupViewForTest(), isTrue);
      expect(FushiDicts.debugPendingTermPathsForTest(), <String>[jp]);
      expect(app.hiddenDictionaryNames, <String>{'EN'}, reason: '会话外按激活配置');
      expect(popupCollapsedDictionaryNames(app), isEmpty);
      FushiDicts.dropPendingForTest();
      expect(
        await app.debugRescheduleDictsForLookupViewForTest(),
        isFalse,
        reason: '装载集合没变：不排期（否则下一次查词在 UI isolate 上同步整套重装）',
      );
      expect(FushiDicts.debugPendingTermPathsForTest(), isEmpty);

      await vm.enterWorkSession(
        owner: reader,
        bookUid: 'book-en',
        mediaType: ProfileMediaKind.epub,
      );
      expect(scope.lookupView, isNotNull, reason: '绑定作品装上了会话');
      expect(await app.debugRescheduleDictsForLookupViewForTest(), isTrue);
      expect(
        FushiDicts.debugPendingTermPathsForTest(),
        <String>[jp, en],
        reason:
            '作品配置开着的 EN 必须排进引擎，否则作品会话一个词都查不到；'
            '激活配置开着的 JP 仍装（替对端 / 扩展查词按激活配置）',
      );
      expect(dictRepo.engineTermDictionaryNames, <String>{'JP', 'EN'});
      expect(app.hiddenDictionaryNames, <String>{
        'JP',
      }, reason: '弹窗隐藏名单按作品会话视图：EN 查出来不能被滤掉');
      expect(popupCollapsedDictionaryNames(app), <String>[
        'EN',
      ], reason: '弹窗折叠名单与出结果同一口径：按作品会话视图');
      FushiDicts.dropPendingForTest();
      expect(
        await app.debugRescheduleDictsForLookupViewForTest(),
        isFalse,
        reason: '会话内再次通知（弹窗进程镜像会话写入）集合没变：不重排',
      );
      expect(FushiDicts.debugPendingTermPathsForTest(), isEmpty);

      vm.leaveWorkSession(reader);
      expect(await app.debugRescheduleDictsForLookupViewForTest(), isTrue);
      expect(FushiDicts.debugPendingTermPathsForTest(), <String>[
        jp,
      ], reason: '离开作品：装载集合缩回激活配置');
      expect(app.hiddenDictionaryNames, <String>{'EN'}, reason: '离开作品回到激活配置');
      expect(popupCollapsedDictionaryNames(app), isEmpty);
    });
  });

  // 源码守卫：会话变化走「集合变了才异步排期 + 分批装载」，不走同步排期（同步排期把整套
  // 重装推给下一次查词，在 UI isolate 上一口气装完）。
  // Tests run with CWD = `fushi/`.
  test('作品会话变化时按需异步重排引擎，不走同步排期', () {
    final String src = File('lib/src/models/app_model.dart').readAsStringSync();
    final int start = src.indexOf('Future<void> _reloadForWorkProfileScope()');
    expect(start, greaterThan(0));
    final int end = src.indexOf('\n  /// ', start);
    expect(end, greaterThan(start));
    final String body = src.substring(start, end);
    expect(body.contains('await _rescheduleDictsForLookupView()'), isTrue);
    expect(body.contains('await FushiDicts.loadPendingAsync()'), isTrue);
    expect(body.contains('_rebuildDictPathsCache()'), isFalse);
  });
}
