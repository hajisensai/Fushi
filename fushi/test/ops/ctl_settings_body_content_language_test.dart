import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_settings_body_content_language.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 默认内容语言 / 查词输入法语言：config get/set 写穿偏好，非法值 400。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late SettingsContext sc;

  SettingsCliValue valueOf(String id) =>
      (buildCtlContentLanguageBodyPages()
                  .expand((CtlBodyPage p) => p.items)
                  .singleWhere((SettingsItem i) => i.id == id)
              as SettingsCustomItem)
          .cliValue!;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    final Directory tempDir = Directory.systemTemp.createTempSync(
      'fushi_lang_cli_',
    );
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tempDir)
      ..wireDatabaseForTesting(db);
  });

  tearDown(() => db.close());

  Future<void> pumpContext(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              sc = SettingsContext(
                context: context,
                appModel: appModel,
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  test('parse: none/empty = unset, tags case-insensitive, unknown throws', () {
    expect(parseCtlContentLanguage(''), '');
    expect(parseCtlContentLanguage('NONE'), '');
    expect(parseCtlContentLanguage('zh-hans'), 'zh-Hans');
    expect(() => parseCtlContentLanguage('xx'), throwsArgumentError);
    expect(ctlContentLanguageOptions(), contains('ja'));
    expect(ctlContentLanguageOptions().first, kCtlContentLanguageUnset);
  });

  testWidgets('default content language writes through', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsCliValue cli = valueOf(
      'appearance.content_language.cli.value',
    );
    expect(cli.read(sc), 'none');
    expect(cli.options!(sc), ctlContentLanguageOptions());
    await cli.write(sc, 'ja');
    expect(prefs.defaultContentLanguage, 'ja');
    expect(cli.read(sc), 'ja');
    await expectLater(cli.write(sc, 'klingon'), throwsArgumentError);
    expect(prefs.defaultContentLanguage, 'ja');
    await cli.write(sc, 'none');
    expect(prefs.defaultContentLanguage, '');
  });

  testWidgets('item content language: book / video write through', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsCliAction cli =
        (buildCtlContentLanguageBodyPages()
                    .expand((CtlBodyPage p) => p.items)
                    .singleWhere((SettingsItem i) => i.id == kCtlItemLanguageId)
                as SettingsActionItem)
            .cli!;
    await db.insertEpubBook(
      EpubBooksCompanion.insert(
        bookKey: 'Bk',
        title: 'Bk',
        epubPath: '/Bk.epub',
        extractDir: '/Bk',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: 1000,
      ),
    );
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'v1',
        title: 'V',
        videoPath: '/v.mp4',
      ),
    );

    Future<Object?> run(Map<String, String> args) => cli.run!(sc, args);

    expect(await run(<String, String>{'key': 'book:Bk'}), <String, Object?>{
      'key': 'book:Bk',
      'language': 'auto',
    });
    await run(<String, String>{'key': 'book:Bk', 'language': 'zh-hant'});
    expect((await db.getEpubBook('Bk'))!.language, 'zh-Hant');
    await run(<String, String>{'key': 'book:Bk', 'language': 'auto'});
    expect((await db.getEpubBook('Bk'))!.language, isNull);

    await run(<String, String>{'key': 'video:v1', 'language': 'ja'});
    expect((await db.getVideoBookByBookUid('v1'))!.language, 'ja');

    await expectLater(
      run(<String, String>{'key': 'book:Bk', 'language': 'none'}),
      throwsArgumentError,
    );
    await expectLater(
      run(<String, String>{'key': 'book:nope', 'language': 'ja'}),
      throwsArgumentError,
    );
    await expectLater(
      run(<String, String>{'key': 'game:g', 'language': 'ja'}),
      throwsArgumentError,
    );
  });

  testWidgets('lookup IME language writes through', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsCliValue cli = valueOf('lookup.ime_language.cli.value');
    expect(cli.read(sc), 'none');
    // 写入会经 method channel 持久化给原生查词框：真异步，放 runAsync。
    await tester.runAsync(() async {
      await cli.write(sc, 'ko');
      expect(prefs.lookupImeLanguage, 'ko');
      expect(cli.read(sc), 'ko');
      await cli.write(sc, '');
      expect(prefs.lookupImeLanguage, '');
    });
  });
}
