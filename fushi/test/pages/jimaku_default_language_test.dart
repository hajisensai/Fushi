import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/subtitle_workbench_page.dart';

import '../helpers/test_platform_services.dart';

/// 「设置 → 视频 → 字幕 → 默认字幕语言」的生效链路专项测试
/// （`settings_schema_coverage_test` 的 `kCoveredElsewhere` 指向本文件）。
///
/// 该设置本身只是一个偏好；它的「生效」不在 reader CSS / 主题树里，而是在三个
/// Jimaku 界面打开时的**语言预选**上——没有该系列的语言记忆时用它兜底。故用
/// 三层咬住：偏好往返 → AppModel 归一（含仓库未就绪的回退）→ 字幕工作台宿主
/// （[AppSubtitleWorkbenchHost]，Jimaku 界面的语言预选都经它）真的拿它兜底。
FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

/// 只替换偏好读取与 HTTP 的 AppModel 替身：语言预选走的仍是生产代码路径。
class _FakeAppModel extends AppModel {
  _FakeAppModel({required this.defaultLanguage})
    : super(testPlatformServices());

  final String defaultLanguage;

  @override
  String get jimakuApiKey => 'key';

  @override
  String get jimakuDefaultLanguage => defaultLanguage;

  /// 每系列的语言记忆（与默认语言是两张独立的表）。
  Map<String, String> seriesLanguages = const <String, String>{};

  @override
  Map<String, String> get jimakuPreferredLanguages => seriesLanguages;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  group('偏好往返', () {
    late FushiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = _testDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      repo.dispose();
      await db.close();
    });

    test('默认「不限」，写入后读回同值', () async {
      expect(repo.jimakuDefaultLanguage, '');
      await repo.setJimakuDefaultLanguage('zh');
      expect(repo.jimakuDefaultLanguage, 'zh');
      await repo.setJimakuDefaultLanguage('');
      expect(repo.jimakuDefaultLanguage, '');
    });

    test('与每系列记忆是两张独立的表，互不覆盖', () async {
      await repo.setJimakuDefaultLanguage('ja');
      await repo.setJimakuPreferredLanguage('some series', 'zh');
      expect(repo.jimakuDefaultLanguage, 'ja');
      expect(repo.jimakuPreferredLanguages['some series'], 'zh');
    });
  });

  group('AppModel 归一', () {
    test('空 / 空白 → null（= 不限），有值 → 原码', () {
      expect(
        _FakeAppModel(defaultLanguage: '').jimakuDefaultLanguageOrNull,
        isNull,
      );
      expect(
        _FakeAppModel(defaultLanguage: '   ').jimakuDefaultLanguageOrNull,
        isNull,
      );
      expect(
        _FakeAppModel(defaultLanguage: 'ja').jimakuDefaultLanguageOrNull,
        'ja',
      );
    });

    test('偏好仓库未就绪 → 回退「不限」而不是抛', () {
      // 未 initialise 的 AppModel（启动早期 / 测试替身）：`_prefsRepo` 为 null。
      final AppModel model = AppModel(testPlatformServices());
      expect(model.jimakuDefaultLanguage, '');
      expect(model.jimakuDefaultLanguageOrNull, isNull);
    });
  });

  group('字幕工作台宿主兜底', () {
    test('该系列没有记忆 → 用默认语言', () {
      final AppSubtitleWorkbenchHost host = AppSubtitleWorkbenchHost(
        _FakeAppModel(defaultLanguage: 'zh'),
      );
      expect(host.preferredLanguageFor('series:1'), 'zh');
    });

    test('默认语言=不限 → null（跟随视频语言）', () {
      final AppSubtitleWorkbenchHost host = AppSubtitleWorkbenchHost(
        _FakeAppModel(defaultLanguage: ''),
      );
      expect(host.preferredLanguageFor('series:1'), isNull);
    });

    test('该系列有记忆 → 记忆压过默认语言', () {
      final _FakeAppModel model = _FakeAppModel(defaultLanguage: 'zh')
        ..seriesLanguages = const <String, String>{'series:1': 'ja'};
      final AppSubtitleWorkbenchHost host = AppSubtitleWorkbenchHost(model);
      expect(host.preferredLanguageFor('series:1'), 'ja');
      expect(host.preferredLanguageFor('series:2'), 'zh');
    });
  });
}
