import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 反馈 qLuedSmAnt：导入有声书时「引用原文件（不复制）」开关每次打开都回到关。
/// 两个导入对话框共用一个偏好键记住上次选择：打开时沿用，切换时写回。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget buildApp(Widget child) {
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(body: Center(child: child)),
      ),
    );
  }

  Finder referenceRow() => find.widgetWithText(
    AdaptiveSettingsSwitchRow,
    t.audiobook_reference_original,
  );

  bool rowValue(WidgetTester tester) =>
      tester.widget<AdaptiveSettingsSwitchRow>(referenceRow()).value;

  group('偏好', () {
    test('默认关；写入后重载仍保留', () async {
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final PreferencesRepository prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
      expect(prefs.audiobookImportReferenceOriginal, isFalse);
      await prefs.setAudiobookImportReferenceOriginal(value: true);
      final PreferencesRepository fresh = PreferencesRepository(db);
      await fresh.loadFromDb();
      expect(fresh.audiobookImportReferenceOriginal, isTrue);
    });
  });

  testWidgets('导入书对话框：打开沿用上次选择，切换写回偏好', (WidgetTester tester) async {
    expect(isDesktopPlatform, isTrue, reason: '开关只在桌面端出现，测试宿主须是桌面');
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1400);
    addTearDown(tester.view.reset);
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await tester.runAsync(prefs.loadFromDb);
    await tester.runAsync(
      () => prefs.setAudiobookImportReferenceOriginal(value: true),
    );

    await tester.pumpWidget(
      buildApp(
        BookImportDialog(
          prefs: prefs,
          repo: SrtBookRepository(db),
          audiobookRepo: AudiobookRepository(db),
          db: db,
          initialEpubPath: r'C:\b\My Novel.epub',
          initialAudioPaths: const <String>[r'C:\b\My Novel.m4b'],
          imageArchiveProbe: (String _) => false,
        ),
      ),
    );
    await tester.pump();

    await tester.ensureVisible(referenceRow());
    expect(rowValue(tester), isTrue);
    tester.widget<AdaptiveSettingsSwitchRow>(referenceRow()).onChanged!(false);
    await tester.pump();
    expect(rowValue(tester), isFalse);
    expect(prefs.audiobookImportReferenceOriginal, isFalse);
  });

  testWidgets('附加有声书对话框：打开沿用上次选择，切换写回偏好', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1400);
    addTearDown(tester.view.reset);
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await tester.runAsync(prefs.loadFromDb);

    await tester.pumpWidget(
      buildApp(
        AudiobookImportDialog(
          prefs: prefs,
          bookKey: 'book-1',
          repo: AudiobookRepository(db),
          initialAudioPaths: const <String>[r'C:\b\a.mp3'],
        ),
      ),
    );
    // _initExisting 一次 DB 往返。
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    await tester.ensureVisible(referenceRow());
    expect(rowValue(tester), isFalse);
    tester.widget<AdaptiveSettingsSwitchRow>(referenceRow()).onChanged!(true);
    await tester.pump();
    expect(rowValue(tester), isTrue);
    expect(prefs.audiobookImportReferenceOriginal, isTrue);
  });
}
