import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi/src/media/video/scraper/scrape_identifier_words.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_schema_video.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

/// 识别词编辑对话框：保存真写穿偏好、取消不写、非法行有可见提示。
void main() {
  late FushiDatabase db;
  late AppModel appModel;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final Directory tempDir =
        Directory.systemTemp.createTempSync('hibiki_idwords_');
    addTearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo, databaseDirectory: tempDir)
      ..wireDatabaseForTesting(db);
  });
  tearDown(() async {
    await db.close();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
      child: MaterialApp(
        home: Consumer(builder: (BuildContext context, WidgetRef ref, _) {
          return Scaffold(
            body: Builder(builder: (BuildContext inner) {
              return TextButton(
                onPressed: () => showVideoScrapeIdentifierWordsDialog(
                  SettingsContext(
                    context: inner,
                    appModel: appModel,
                    ref: ref,
                    readerSource: ReaderFushiSource.instance,
                    refresh: () {},
                  ),
                ),
                child: const Text('open'),
              );
            }),
          );
        }),
      ),
    ));
    await tester.pumpAndSettle();
  }

  String storedWords() => appModel.prefsRepo.getPref(
        kVideoMetadataIdentifierWordsPref,
        defaultValue: '',
      ) as String;

  testWidgets('saving writes the word list through to preferences',
      (WidgetTester tester) async {
    await pump(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    const String words = 'Nekomoe\nKusuriya => Frieren';
    await tester.enterText(
      find.byKey(const ValueKey<String>(
        'video.library.metadata_identifier_words.field',
      )),
      words,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>(
      'video.library.metadata_identifier_words.save',
    )));
    await tester.pumpAndSettle();

    expect(storedWords(), words);
    expect(
      ScrapeIdentifierWords.parse(storedWords()).words,
      hasLength(2),
      reason: '写穿的文本必须还能解析回两条规则',
    );
  });

  testWidgets('cancelling leaves the stored word list untouched',
      (WidgetTester tester) async {
    await appModel.prefsRepo
        .setPref(kVideoMetadataIdentifierWordsPref, 'Nekomoe');
    await pump(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>(
        'video.library.metadata_identifier_words.field',
      )),
      'Kusuriya => Frieren',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>(
      'video.library.metadata_identifier_words.cancel',
    )));
    await tester.pumpAndSettle();

    expect(storedWords(), 'Nekomoe');
  });

  testWidgets('an invalid rule is reported instead of silently dropped',
      (WidgetTester tester) async {
    await pump(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>(
        'video.library.metadata_identifier_words.field',
      )),
      '[unclosed',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('第 1 行'), findsOneWidget);
  });
}
