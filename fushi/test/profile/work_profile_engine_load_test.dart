import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/dictionary_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/profile/work_profile_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

Dictionary _dict(
  String name, {
  required int order,
  bool hidden = false,
  bool kanjiHidden = false,
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
  collapsedLanguages: const <String>[],
);

/// 反馈 r9SgiayKxa：书指定了非激活配置「英语」（英语词典开、日语词典关），激活配置
/// Default 里那些英语词典是关着的。引擎装载集合只看激活配置，于是英语词典根本没装进
/// 引擎，作品会话的过滤又把装着的日语词典全滤掉——一个词都查不到。
///
/// 契约：引擎装载集合 = 激活配置 ∪ 当前作品会话视图里开着的词典；弹窗的隐藏名单按
/// 作品会话视图给；会话装上 / 撤下时引擎重排期。
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

      // 绑定配置「英语」：EN 开、JP 关（先摆成这样快照进它）。
      final int boundId = await repo.createProfile('english');
      await dictRepo.persistDictionary(_dict('JP', order: 0, hidden: true));
      await dictRepo.persistDictionary(_dict('EN', order: 1));
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

    test('进入绑定作品：作品配置开着的 EN 进引擎术语桶，弹窗不把它当隐藏词典', () async {
      final PreferencesRepository prefsRepo = PreferencesRepository(db);
      await prefsRepo.loadFromDb();
      final Directory tmpDir = Directory.systemTemp.createTempSync(
        'fushi_work_engine_load_',
      );
      addTearDown(() {
        try {
          tmpDir.deleteSync(recursive: true);
        } catch (_) {}
      });
      final AppModel app = AppModel(testPlatformServices())
        ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo,
          databaseDirectory: tmpDir,
        )
        ..wireDatabaseForTesting(db, dictionaryRepository: dictRepo);

      expect(app.hiddenDictionaryNames, <String>{'EN'}, reason: '会话外按激活配置');

      await vm.enterWorkSession(
        owner: reader,
        bookUid: 'book-en',
        mediaType: ProfileMediaKind.epub,
      );
      final List<Dictionary>? overlay = scope.lookupView?.dictionaries;
      expect(overlay, isNotNull, reason: '绑定作品装上了会话');

      final List<Dictionary> live = dictRepo.dictionaries;
      final states = DictionaryRepository.engineLoadStatesOf(live, overlay);
      final buckets = bucketDictPaths(<DictPathEntry>[
        for (int i = 0; i < live.length; i++)
          dictPathEntryOf(
            type: live[i].type,
            path: '/dicts/${live[i].name}',
            exists: true,
            hidden: states[i].hidden,
            metadata: states[i].metadata,
            order: live[i].order,
          ),
      ]);
      expect(
        buckets.term,
        containsAll(<String>['/dicts/JP', '/dicts/EN']),
        reason: '作品配置开着的 EN 必须在引擎里，否则作品会话一个词都查不到',
      );
      expect(app.hiddenDictionaryNames, <String>{
        'JP',
      }, reason: '弹窗隐藏名单按作品会话视图：EN 查出来不能被滤掉');

      vm.leaveWorkSession(reader);
      expect(app.hiddenDictionaryNames, <String>{'EN'}, reason: '离开作品回到激活配置');
    });
  });

  // 源码守卫：两条装载路径都经 [_engineLoadStates]，会话变化时引擎重排期。
  // Tests run with CWD = `fushi/`.
  test('AppModel 两条装载路径用并集判据，作品会话变化时重排引擎', () {
    final String src = File('lib/src/models/app_model.dart').readAsStringSync();
    expect(
      RegExp(r'hidden: states\[i\]\.hidden').allMatches(src).length,
      2,
      reason: '同步 / 异步两条装载路径都按 _engineLoadStates 判隐藏',
    );
    expect(
      src.contains('hidden: d.isHidden(JapaneseLanguage.instance)'),
      isFalse,
    );
    expect(
      src.contains('hidden: dictList[i].isHidden(JapaneseLanguage.instance)'),
      isFalse,
    );
    final int start = src.indexOf('Future<void> _reloadForWorkProfileScope()');
    expect(start, greaterThan(0));
    final int end = src.indexOf('\n  }\n', start);
    final String body = src.substring(start, end);
    expect(body.contains('_rebuildDictPathsCache();'), isTrue);
    expect(body.contains('dictRepo.clearDictionaryResultsCache();'), isTrue);
  });
}
