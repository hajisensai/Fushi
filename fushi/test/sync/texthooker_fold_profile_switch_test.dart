import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/anki/anki_settings_drift_store.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/sync/texthooker_service.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-5609：「合并分段吐出的台词」开关（`gal_hook_fold_progressive_lines`）随 Profile
/// 走，但 [TexthookerService] 以前只在启动和改开关时被**推**一份副本；切 Profile 走的
/// `AppModel.refreshPrefCache` 只重载偏好缓存，副本停在旧 Profile 的值上。
///
/// 这里走真实的切换路径：[ProfileRepository.applyProfile] 把快照写回偏好表，再
/// [PreferencesRepository.refreshFromDb]（`refreshPrefCache` 的第一步）重载缓存，之后
/// 服务的折叠行为必须是新 Profile 的值。
class _InertAnkiRepo extends BaseAnkiRepository {
  _InertAnkiRepo({super.settingsStore});

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('n/a');

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async => const MineOutcome.success();

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;
}

/// 按同一引擎行逐段重绘的三拍追加，返回 buffer 里留下的条数（折叠时 1 条，不折 3 条）。
int _appendProgressiveSnapshots(TexthookerService service) {
  service.clear();
  int seq = 0;
  for (final String text in <String>[
    '今日はいい天気',
    '今日はいい天気ですね。',
    '今日はいい天気ですね。散歩に行こう。',
  ]) {
    service.appendLine(
      text,
      source: TexthookerLineSource.engineHook,
      sourceLabel: 'engine_hook',
      sourceSequence: ++seq,
      textThreadKey: 'thread-a',
    );
  }
  return service.entries.length;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('切 Profile 后折叠开关跟着新 Profile 走，不停在旧值', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final ProfileRepository profiles = ProfileRepository(
      db,
      _InertAnkiRepo(settingsStore: DriftAnkiSettingsStore(() => db)),
    );

    final TexthookerService service = TexthookerService.test();
    bindTexthookerPreferenceReaders(service, prefs);

    // Profile「开」：折叠开着（默认值，显式写一次让快照里有这一行）。
    await prefs.setGalHookFoldProgressiveLines(true);
    final int onId = await profiles.createProfile('fold-on');
    await profiles.snapshotCurrentSettings(onId);

    // Profile「关」：用户在这份 Profile 里关掉了折叠。
    await prefs.setGalHookFoldProgressiveLines(false);
    expect(service.foldProgressiveLines, isFalse, reason: '改开关后即时生效');
    final int offId = await profiles.createProfile('fold-off');
    await profiles.snapshotCurrentSettings(offId);

    await profiles.applyProfile(onId);
    await prefs.refreshFromDb();
    expect(prefs.galHookFoldProgressiveLines, isTrue);
    expect(service.foldProgressiveLines, isTrue);
    expect(_appendProgressiveSnapshots(service), 1, reason: '新 Profile 开着折叠');

    await profiles.applyProfile(offId);
    await prefs.refreshFromDb();
    expect(prefs.galHookFoldProgressiveLines, isFalse);
    expect(service.foldProgressiveLines, isFalse);
    expect(_appendProgressiveSnapshots(service), 3, reason: '新 Profile 关着折叠');
  });

  test('没接读取器时按默认开算', () {
    final TexthookerService service = TexthookerService.test();
    expect(
      service.foldProgressiveLines,
      PreferencesRepository.galHookFoldProgressiveLinesDefault,
    );
  });
}
