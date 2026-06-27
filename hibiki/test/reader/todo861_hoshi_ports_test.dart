import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki_core/hibiki_core.dart';

HibikiDatabase _testDb() => HibikiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );

String _read(String relPath) => File(relPath).readAsStringSync();

void main() {
  group('TODO-861① paragraph spacing persistence (ReaderSettings)', () {
    test('默认 0、写穿读回', () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final ReaderSettings s = ReaderSettings(db);
      await s.refreshFromDb();
      expect(s.paragraphSpacing, 0);
      await s.setParagraphSpacing(1.4);
      expect(s.paragraphSpacing, 1.4);
    });
  });

  group('TODO-861④ blur images persistence (ReaderSettings)', () {
    test('默认 false、写穿读回', () async {
      final HibikiDatabase db = _testDb();
      addTearDown(db.close);
      final ReaderSettings s = ReaderSettings(db);
      await s.refreshFromDb();
      expect(s.blurImages, isFalse);
      await s.setBlurImages(true);
      expect(s.blurImages, isTrue);
    });
  });

  group('TODO-861② scanNonJapaneseText persistence (PreferencesRepository)',
      () {
    late HibikiDatabase db;
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

    test('默认 true（向后兼容，不破坏现有查词）', () {
      expect(repo.scanNonJapaneseText, isTrue);
    });

    test('设 false 写穿读回', () async {
      await repo.setScanNonJapaneseText(false);
      expect(repo.scanNonJapaneseText, isFalse);
    });
  });

  group('TODO-861③ dictionary auto-update prefs (PreferencesRepository)', () {
    late HibikiDatabase db;
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

    test('autoUpdateDictionaries 默认 true', () {
      expect(repo.autoUpdateDictionaries, isTrue);
    });

    test('interval 默认 weekly', () {
      expect(repo.dictionaryUpdateIntervalName, 'weekly');
    });

    test('lastDictionaryUpdateAt 默认 null（从未）、写穿读回', () async {
      expect(repo.lastDictionaryUpdateAt, isNull);
      final DateTime when = DateTime(2026, 6, 28, 9, 30);
      await repo.setLastDictionaryUpdateAt(when);
      expect(repo.lastDictionaryUpdateAt, when);
    });

    test('interval 写穿读回', () async {
      await repo.setDictionaryUpdateIntervalName('daily');
      expect(repo.dictionaryUpdateIntervalName, 'daily');
    });
  });

  // ── 源码守卫：防回退 ────────────────────────────────────────────────
  group('TODO-861 source guards', () {
    test('② webview.part 不再硬编码 scanNonJapaneseText = true', () {
      final String src = _read(
        'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
      );
      expect(src, isNot(contains('window.scanNonJapaneseText = true;')),
          reason: '注入端必须读 pref，不能回退硬编码 true');
      expect(
          src,
          contains(
              r'window.scanNonJapaneseText = ${appModel.scanNonJapaneseText};'));
    });

    test('② selection 消费端仍含 scanNonJapaneseText === false 分支', () {
      final String src = _read('lib/src/reader/reader_selection_scripts.dart');
      expect(src, contains('scanNonJapaneseText === false'));
    });

    test('④ pagination 脚本 blurImages 时给大图加 blurred 类', () {
      final String src = _read('lib/src/reader/reader_pagination_scripts.dart');
      expect(src, contains('_hoshiBlurImage'));
      expect(src, contains("element.classList.add('blurred')"));
    });

    test('④ 点击派发处含「blurred 优先揭开吞放大」分支（防双触发）', () {
      final String src = _read(
        'lib/src/pages/implementations/reader_hibiki/webview.part.dart',
      );
      expect(src, contains('_hoshiRevealBlurredImage'));
    });
  });
}
