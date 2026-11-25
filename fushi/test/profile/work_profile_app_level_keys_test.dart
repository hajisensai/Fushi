import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/media_source.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/profile/work_profile_scope.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_preferences.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/shortcuts/visual/gamepad_glyphs.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/fake_anki_repository.dart';

/// GitHub #3089（反馈 e4QDDy1tKZ）：从播放器设置面板进快捷键页改键（此时一部带作品级配置
/// 的作品正打开），重启后改的键全部失效。
///
/// 根因：[WorkProfileScope.isWorkScopedPrefKey] 把阅读器命名空间 `src:reader_fushi:*`
/// 整个前缀当作品级键，快捷键绑定 JSON 也在其中——会话期间 `MediaSource.setPreference`
/// 把它写进作品绑定配置的 `profile_settings` 快照、不写 `preferences`；启动时
/// [loadShortcutRegistry] 读全局 `preferences`，于是读回旧值。
///
/// 这里走真实链路：真实 [ProfileViewModel.enterWorkSession] 装会话 → 真实
/// [saveShortcutRegistry] / [ReaderFushiSource.setGamepadGlyphBrand] 写 → 模拟重启
/// （离开作品 + 源缓存从库重读）→ 真实 [loadShortcutRegistry] 读。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  late FushiDatabase db;
  late ProfileRepository repo;
  late ProfileViewModel vm;
  late int boundId;
  late ReaderFushiSource source;
  final WorkProfileScope scope = WorkProfileScope.instance;
  final Object player = Object();

  const String shortcutDbKey =
      'src:$kReaderSourcePersistedKey:'
      'shortcut_bindings_json';
  const String gamepadDbKey = 'src:reader_fushi:gamepad_glyph_brand';
  const String lyricsHintDbKey = 'src:reader_fushi:lyrics_mode_hint_shown';
  const String readerFontDbKey = 'src:reader_fushi:font_size';

  // 视频「播放 / 暂停」改成 KeyG（默认绑定里从不含 KeyG）：解析出 KeyG = 读到的是这份
  // 自定义 JSON，而不是平台默认。
  final String customJson = jsonEncode(<String, dynamic>{
    ShortcutAction.videoTogglePlayPause.key: <String, dynamic>{
      'keyboard': <String>['KeyG'],
      'gamepad': <String>[],
      'mouse': <String>[],
    },
  });

  ShortcutAction? resolveG(FushiShortcutRegistry registry) =>
      registry.resolveKeyboard(
        LogicalKeyboardKey.keyG,
        modifiers: const <ModifierKey>{},
        scope: ShortcutScope.video,
      );

  Future<String?> profilePref(int profileId, String key) async {
    for (final ProfileSettingRow r in await db.getProfileSettings(profileId)) {
      if (r.category == ProfileKeys.categoryPref && r.key == key) {
        return r.value;
      }
    }
    return null;
  }

  /// 冷启动：没有任何作品会话，源缓存从库重读，再按启动顺序装快捷键注册表。
  Future<FushiShortcutRegistry> restartAndLoadRegistry() async {
    vm.leaveWorkSession(player);
    expect(scope.active, isNull);
    await source.refreshPreferencesFromDb();
    final FushiShortcutRegistry registry = FushiShortcutRegistry();
    await loadShortcutRegistry(registry, source, TargetPlatform.windows);
    return registry;
  }

  setUp(() async {
    scope.debugReset();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    MediaSource.setDatabase(db);
    source = ReaderFushiSource.instance;
    repo = ProfileRepository(db, FakeAnkiRepository());
    vm = ProfileViewModel(repo, () async {}, ProfileDraftCoordinator());
    await vm.stream.firstWhere(
      (ProfileUiState s) => !s.isLoading && s.profiles.isNotEmpty,
    );
    boundId = await repo.createProfile('bound');
    await repo.setBookProfile('video-bound', boundId);
    // 绑定配置的快照里有一份作品级阅读样式，证明会话确实装上了覆盖层。
    await db.upsertProfileSetting(
      ProfileSettingsCompanion.insert(
        profileId: boundId,
        category: ProfileKeys.categoryPref,
        key: readerFontDbKey,
        value: PrefCodec.encode(28.0),
      ),
    );
    await source.refreshPreferencesFromDb();
  });

  tearDown(() async {
    scope.debugReset();
    vm.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await db.close();
  });

  Future<void> openBoundWork() async {
    await vm.enterWorkSession(
      owner: player,
      bookUid: 'video-bound',
      mediaType: ProfileMediaKind.epub,
    );
    expect(scope.active?.profileId, boundId, reason: '作品会话已装上');
    await source.refreshPreferencesFromDb();
  }

  test('应用级键不是作品级键；阅读器其它键仍随作品走', () {
    expect(shortcutDbKey, 'src:reader_fushi:shortcut_bindings_json');
    for (final String key in <String>[
      shortcutDbKey,
      gamepadDbKey,
      lyricsHintDbKey,
    ]) {
      expect(WorkProfileScope.appLevelReaderPrefKeys, contains(key));
      expect(WorkProfileScope.isWorkScopedPrefKey(key), isFalse, reason: key);
    }
    expect(WorkProfileScope.isWorkScopedPrefKey(readerFontDbKey), isTrue);
  });

  test('作品会话期间改快捷键落全局 preferences，重启后 loadShortcutRegistry 读到', () async {
    await openBoundWork();
    expect(scope.overrides(readerFontDbKey), isTrue);
    expect(scope.overrides(shortcutDbKey), isFalse);

    final FushiShortcutRegistry live = FushiShortcutRegistry();
    live.loadFromJsonString(customJson, TargetPlatform.windows);
    expect(resolveG(live), ShortcutAction.videoTogglePlayPause);
    await saveShortcutRegistry(live, source);

    expect(
      await db.getPref(shortcutDbKey),
      PrefCodec.encode(live.toJsonString()),
      reason: '快捷键写进全局 preferences',
    );
    expect(
      await profilePref(boundId, shortcutDbKey),
      isNull,
      reason: '绑定配置的快照不应收到快捷键',
    );

    final FushiShortcutRegistry afterRestart = await restartAndLoadRegistry();
    expect(
      resolveG(afterRestart),
      ShortcutAction.videoTogglePlayPause,
      reason: '重启后改的键仍然生效',
    );
  });

  test('作品会话期间改手柄按钮图品牌落全局，重启后仍是改后的品牌', () async {
    await openBoundWork();
    await source.setGamepadGlyphBrand(GamepadBrand.playstation);

    expect(
      await db.getPref(gamepadDbKey),
      PrefCodec.encode(GamepadBrand.playstation.token),
    );
    expect(await profilePref(boundId, gamepadDbKey), isNull);

    await restartAndLoadRegistry();
    expect(source.gamepadGlyphBrand, GamepadBrand.playstation);
  });

  test('绑定配置快照里残留的快捷键不会在作品会话期间盖过全局那份', () async {
    // 修复前的版本在会话期间写进绑定配置快照的那份（默认绑定，不含 KeyG）。
    final FushiShortcutRegistry stale = FushiShortcutRegistry()
      ..resetToDefaults(TargetPlatform.windows);
    await db.upsertProfileSetting(
      ProfileSettingsCompanion.insert(
        profileId: boundId,
        category: ProfileKeys.categoryPref,
        key: shortcutDbKey,
        value: PrefCodec.encode(stale.toJsonString()),
      ),
    );
    await db.setPref(shortcutDbKey, PrefCodec.encode(customJson));

    await openBoundWork();
    expect(scope.active?.prefs.containsKey(shortcutDbKey), isFalse);
    final FushiShortcutRegistry registry = FushiShortcutRegistry();
    await loadShortcutRegistry(registry, source, TargetPlatform.windows);
    expect(
      resolveG(registry),
      ShortcutAction.videoTogglePlayPause,
      reason: '会话期间快捷键仍读全局',
    );
  });
}
