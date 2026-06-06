import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

void main() {
  group('ReaderHibikiSource shelf actions', () {
    test('bookshelf home actions do not expose the tweaks button', () {
      final String source = File(
        'lib/src/media/sources/reader_hibiki_source.dart',
      ).readAsStringSync();
      final String historySource = File(
        'lib/src/pages/implementations/reader_hibiki_history_page.dart',
      ).readAsStringSync();

      final int actionsStart = source.indexOf('List<Widget> getActions');
      final int importButtonStart =
          source.indexOf('Widget buildBookImportButton');
      final String actionsBody = source.substring(
        actionsStart,
        importButtonStart,
      );

      expect(actionsStart, isNonNegative);
      expect(importButtonStart, isNonNegative);
      expect(actionsBody, contains('buildBookImportButton'));
      expect(actionsBody, isNot(contains('buildTweaksButton')));
      expect(source, isNot(contains('Widget buildTweaksButton')));
      expect(historySource, isNot(contains('buildTweaksButton')));
    });
  });

  group('ReaderHibikiSource.isExternalUrl (BUG-097 内链不外开)', () {
    test('内部 hoshi.local 书内 URL 永不当外部链接(未解析时不弹系统浏览器)', () {
      expect(
        ReaderHibikiSource.isExternalUrl(
            'https://hoshi.local/epub/OEBPS/ch2.xhtml'),
        isFalse,
      );
      expect(
        ReaderHibikiSource.isExternalUrl(
            'https://hoshi.local/epub/text/note.xhtml#n1'),
        isFalse,
      );
    });

    test('真正的外部 http/https/mailto 链接 → 外部打开', () {
      expect(
        ReaderHibikiSource.isExternalUrl('https://example.com/page'),
        isTrue,
      );
      expect(
        ReaderHibikiSource.isExternalUrl('http://example.com/'),
        isTrue,
      );
      expect(
        ReaderHibikiSource.isExternalUrl('mailto:a@b.com'),
        isTrue,
      );
    });

    test('非外部 scheme / 无法解析 → 不外开', () {
      expect(ReaderHibikiSource.isExternalUrl('hoshi://book/foo'), isFalse);
      expect(ReaderHibikiSource.isExternalUrl('about:blank'), isFalse);
      expect(ReaderHibikiSource.isExternalUrl('://broken'), isFalse);
    });
  });

  group('ReaderHibikiSource custom font helpers', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('hibiki_font_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('canonicalizes allowed custom font paths before building CSS',
        () async {
      final fontsDir = Directory(p.join(tempDir.path, 'fonts'));
      await fontsDir.create();
      final fontFile = File(p.join(fontsDir.path, 'font.ttf'));
      await fontFile.writeAsBytes(<int>[0, 1, 0, 0]);
      final rawPath = p.join(fontsDir.path, '..', 'fonts', 'font.ttf');

      final result = ReaderHibikiSource.customFontCssForEntries(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'Test Font',
            'path': rawPath,
            'enabled': true,
          },
        ],
        allowedDirectories: <String>[fontsDir.path],
      );

      expect(
        result.fontFaces,
        contains(Uri.encodeComponent(p.canonicalize(fontFile.path))),
      );
      expect(result.fontFaces, isNot(contains('..')));
    });

    test('rejects custom font paths outside the allowed directories', () async {
      final fontsDir = Directory(p.join(tempDir.path, 'fonts'));
      final outsideDir = Directory(p.join(tempDir.path, 'outside'));
      await fontsDir.create();
      await outsideDir.create();
      final outsideFont = File(p.join(outsideDir.path, 'font.ttf'));
      await outsideFont.writeAsBytes(<int>[0, 1, 0, 0]);

      final result = ReaderHibikiSource.customFontCssForEntries(
        <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'Outside Font',
            'path': outsideFont.path,
            'enabled': true,
          },
        ],
        allowedDirectories: <String>[fontsDir.path],
      );

      expect(result.fontFamily, isEmpty);
      expect(result.fontFaces, isEmpty);
    });
  });

  group('MediaSource preference cache invalidation', () {
    test(
        'refreshPreferencesFromDb drops keys deleted from the DB '
        '(profile switch with no custom value restores default)', () async {
      final db = HibikiDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      MediaSource.setDatabase(db);

      final source = ReaderHibikiSource.instance;
      await source.refreshPreferencesFromDb();

      // Profile A: a custom shortcut binding is persisted.
      await source.setPreference<String>(
        key: 'shortcut_bindings_json',
        value: '{"reader_page_forward":{"keyboard":["KeyN"],"gamepad":[]}}',
      );
      expect(
        source.getPreference<String?>(
            key: 'shortcut_bindings_json', defaultValue: null),
        isNotNull,
      );

      // Switching to Profile B (no custom shortcuts): applyProfile deletes the
      // pref row that is absent from the new profile.
      await db.deletePref('src:reader_ttu:shortcut_bindings_json');
      await source.refreshPreferencesFromDb();

      // The stale Profile A value must not survive in the in-memory cache.
      expect(
        source.getPreference<String?>(
            key: 'shortcut_bindings_json', defaultValue: null),
        isNull,
      );
    });
  });
}
