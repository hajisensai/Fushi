import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/profile/work_profile_scope.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';

/// 反馈 kEFPY4cuKZ：作品级配置（book / 语言 / 媒体类型绑定）只在这部作品的会话里生效
/// ——阅读样式、有声书悬浮字幕样式、查词词典——不再切换 App 的全局配置；离开作品后全局
/// 配置不变（它从头到尾就没被写过）。
///
/// 取代旧的「绑定直接切激活配置 + 回退点」机制（反馈 #emN0S3Kypf / PR #2088）：那套机制
/// 改的是全局 `active_profile_id` 与 `preferences` 表，退出作品后能不能还原全靠下一次
/// 打开无绑定条目，用户看到的就是「进一本书，整个 App 的主题 / 词典都换了且回不来」。
void main() {
  late FushiDatabase db;
  late ProfileRepository repo;
  late ProfileViewModel vm;
  late int defaultId;
  late int boundId;
  final WorkProfileScope scope = WorkProfileScope.instance;

  const String lyricFontKey = 'floating_lyric_font_size';
  const String readerFontKey = 'src:reader_fushi:font_size';
  const String globalOnlyKey = 'dictionary_font_size';

  setUp(() async {
    scope.debugReset();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = ProfileRepository(db, FakeAnkiRepository());
    vm = ProfileViewModel(repo, () async {}, ProfileDraftCoordinator());
    final ProfileUiState loaded = await vm.stream.firstWhere(
      (ProfileUiState s) => !s.isLoading && s.profiles.isNotEmpty,
    );
    defaultId = loaded.activeProfileId;
    boundId = await repo.createProfile('bound');
    await repo.setBookProfile('book-bound', boundId);

    // 全局（激活配置的 live 偏好）。
    await db.setPref(lyricFontKey, PrefCodec.encode(20.0));
    await db.setPref(readerFontKey, PrefCodec.encode(22.0));
    await db.setPref(globalOnlyKey, PrefCodec.encode(15.0));
    // 绑定配置的快照。
    for (final MapEntry<String, String> e in <String, String>{
      lyricFontKey: PrefCodec.encode(34.0),
      readerFontKey: PrefCodec.encode(28.0),
      globalOnlyKey: PrefCodec.encode(99.0),
    }.entries) {
      await db.upsertProfileSetting(
        ProfileSettingsCompanion.insert(
          profileId: boundId,
          category: ProfileKeys.categoryPref,
          key: e.key,
          value: e.value,
        ),
      );
    }
  });

  tearDown(() async {
    scope.debugReset();
    vm.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await db.close();
  });

  final Object reader = Object();

  Future<void> openBook(String bookUid, {Object? owner}) => vm.enterWorkSession(
    owner: owner ?? reader,
    bookUid: bookUid,
    mediaType: ProfileMediaKind.epub,
  );

  Future<String?> profilePref(int profileId, String key) async {
    for (final ProfileSettingRow r in await db.getProfileSettings(profileId)) {
      if (r.category == ProfileKeys.categoryPref && r.key == key) {
        return r.value;
      }
    }
    return null;
  }

  test('进入绑定作品：激活配置与全局偏好表都不动，作品级键按绑定配置读', () async {
    await openBook('book-bound');

    expect(await repo.getActiveProfileId(), defaultId);
    expect(await db.getPref(lyricFontKey), PrefCodec.encode(20.0));
    expect(await db.getPref(readerFontKey), PrefCodec.encode(22.0));
    expect(scope.active?.profileId, boundId);
    expect(scope.lookupView?.profileId, boundId, reason: '查词按绑定配置的词典');

    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    expect(prefs.floatingLyricFontSize, 34.0, reason: '悬浮字幕样式按作品配置');
    expect(prefs.getPref(globalOnlyKey), 15.0, reason: '覆盖层之外的设置仍是 App 全局的');

    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();
    expect(settings.fontSize, 28.0, reason: '阅读样式按作品配置');
  });

  test('会话内改作品级设置写进绑定配置的快照，全局偏好不变；离开后读回全局', () async {
    await openBook('book-bound');
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();

    await prefs.setFloatingLyricFontSize(40.0);
    await settings.setFontSize(30.0);

    expect(await db.getPref(lyricFontKey), PrefCodec.encode(20.0));
    expect(await db.getPref(readerFontKey), PrefCodec.encode(22.0));
    expect(await profilePref(boundId, lyricFontKey), PrefCodec.encode(40.0));
    expect(await profilePref(boundId, readerFontKey), '30.0');
    expect(prefs.floatingLyricFontSize, 40.0);

    vm.leaveWorkSession(reader);
    expect(scope.active, isNull);
    expect(prefs.floatingLyricFontSize, 20.0);
    await settings.refreshFromDb();
    expect(settings.fontSize, 22.0);
    expect(await repo.getActiveProfileId(), defaultId);
  });

  test('无绑定作品没有覆盖层；同一持有者换到无绑定作品即撤层', () async {
    await openBook('book-free');
    expect(scope.active, isNull);

    await openBook('book-bound');
    expect(scope.active?.profileId, boundId);
    await openBook('book-free');
    expect(scope.active, isNull);
    expect(await repo.getActiveProfileId(), defaultId);
  });

  test('绑定的就是激活配置时不装覆盖层（直接用 live 设置）', () async {
    await repo.setBookProfile('book-default', defaultId);
    await openBook('book-default');
    expect(scope.active, isNull);
  });

  test('最近进入的作品生效，任一持有者离开只撤自己那层', () async {
    final int second = await repo.createProfile('bound2');
    await repo.setBookProfile('book-bound2', second);
    final Object game = Object();
    await openBook('book-bound');
    await openBook('book-bound2', owner: game);
    expect(scope.active?.profileId, second);

    vm.leaveWorkSession(reader);
    expect(scope.active?.profileId, second);
    vm.leaveWorkSession(game);
    expect(scope.active, isNull);
  });

  test('解析期间就离开的作品，迟到的覆盖层不会装上', () async {
    final Future<void> entering = openBook('book-bound');
    vm.leaveWorkSession(reader);
    await entering;
    expect(scope.active, isNull);
  });

  test('没有页面生命周期的会话（gal hook）在结束信号到来时撤层', () async {
    final ValueNotifier<bool> running = ValueNotifier<bool>(true);
    final Object session = Object();
    await vm.enterWorkSession(
      owner: session,
      bookUid: 'book-bound',
      mediaType: ProfileMediaKind.game,
      endWhen: (listenable: running, ended: () => !running.value),
    );
    expect(scope.active?.profileId, boundId);
    running.value = false;
    expect(scope.active, isNull);
    running.dispose();
  });

  test('旧版绑定切换留下的回退点：启动时回到用户自己选的配置并清掉', () async {
    await db.setPref('active_profile_id', '$boundId');
    await repo.setFallbackProfileId(defaultId);
    final ProfileViewModel fresh = ProfileViewModel(
      repo,
      () async {},
      ProfileDraftCoordinator(),
    );
    await fresh.loaded;
    await fresh.stream.firstWhere(
      (ProfileUiState s) => s.activeProfileId == defaultId,
    );
    expect(await repo.getActiveProfileId(), defaultId);
    expect(await repo.getFallbackProfileId(), isNull);
    fresh.dispose();
  });

  test('作品级键只覆盖阅读样式 / 悬浮字幕样式，不含字体目录与窗口位置', () {
    expect(WorkProfileScope.isWorkScopedPrefKey(readerFontKey), isTrue);
    expect(WorkProfileScope.isWorkScopedPrefKey(lyricFontKey), isTrue);
    expect(WorkProfileScope.isWorkScopedPrefKey(globalOnlyKey), isFalse);
    expect(
      WorkProfileScope.isWorkScopedPrefKey('src:reader_fushi:font_catalog'),
      isFalse,
    );
    expect(
      WorkProfileScope.isWorkScopedPrefKey('src:reader_fushi:app_ui_fonts'),
      isFalse,
    );
    expect(
      WorkProfileScope.isWorkScopedPrefKey(kFloatingLyricWindowRectPrefKey),
      isFalse,
    );
    expect(WorkProfileScope.isWorkScopedPrefKey('active_profile_id'), isFalse);
  });

  // 源码守卫。Tests run with CWD = `fushi/`.
  test('作品入口不再切换 App 的激活配置；本机查词按作品会话过滤词典', () {
    final String vmSrc = File(
      'lib/src/profile/profile_view_model.dart',
    ).readAsStringSync();
    expect(vmSrc.contains('autoApplyBinding'), isFalse);
    expect(vmSrc.contains('setFallbackProfileId(currentActiveId)'), isFalse);

    final String main = File('lib/main.dart').readAsStringSync();
    expect(
      main.contains('mediaType: ProfileMediaKind.browser'),
      isFalse,
      reason: '浏览器查词不得切换 App 的激活配置',
    );

    final String appModel = File(
      'lib/src/models/app_model.dart',
    ).readAsStringSync();
    expect(
      'profileView: WorkProfileScope.instance.lookupView'
          .allMatches(appModel)
          .length,
      2,
      reason: 'searchDictionary / searchDictionaryWithRuby 都要按作品会话的词典查',
    );

    for (final String path in <String>[
      'lib/src/pages/implementations/reader_fushi_page.dart',
      'lib/src/pages/implementations/video_fushi_page.dart',
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    ]) {
      expect(
        File(
          path,
        ).readAsStringSync().contains('WorkProfileScope.instance.leave(this)'),
        isTrue,
        reason: '$path 离开作品时必须撤掉作品级配置覆盖层',
      );
    }
  });
}
