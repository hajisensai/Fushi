import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audio_cd/audio_cd_import.dart';
import 'package:fushi/src/media/source_library/add_local_folder_source.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

/// BUG-3312：音频 CD 在 Windows 上只露出 `TrackNN.cda` 快捷方式，扫描器按扩展名
/// 白名单一条不收。导入入口先经 [importAudioCdIfPresent] 认出它。
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('audio_cd_import_'));
  tearDown(() => root.deleteSync(recursive: true));

  Directory dirWith(String name, List<String> files) {
    final Directory d = Directory(p.join(root.path, name))..createSync();
    for (final String f in files) {
      File(p.join(d.path, f)).writeAsBytesSync(const <int>[0]);
    }
    return d;
  }

  group('isAudioCdDirectory', () {
    test('a folder of only .cda shortcuts is an audio CD', () {
      expect(
        isAudioCdDirectory(
          dirWith('cd', <String>['Track01.cda', 'Track02.cda']).path,
        ),
        isTrue,
      );
    });

    test('real media next to .cda keeps the normal import', () {
      expect(
        isAudioCdDirectory(
          dirWith('mixed', <String>['Track01.cda', '01.flac']).path,
        ),
        isFalse,
      );
      expect(
        isAudioCdDirectory(dirWith('music', <String>['01.mp3']).path),
        isFalse,
      );
      expect(isAudioCdDirectory(dirWith('empty', <String>[]).path), isFalse);
    });

    test('only direct children count, and unreadable paths are not a CD', () {
      final Directory outer = dirWith('outer', <String>[]);
      Directory(p.join(outer.path, 'inner')).createSync();
      File(
        p.join(outer.path, 'inner', 'Track01.cda'),
      ).writeAsBytesSync(<int>[0]);
      expect(isAudioCdDirectory(outer.path), isFalse);
      expect(isAudioCdDirectory(p.join(root.path, 'missing')), isFalse);
    });
  });

  group('importAudioCdIfPresent', () {
    late FushiDatabase db;

    setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<BuildContext> pumpContext(WidgetTester tester) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );
      return captured;
    }

    testWidgets('a normal folder is left to the caller', (
      WidgetTester t,
    ) async {
      final BuildContext context = await pumpContext(t);
      final String dir = dirWith('music', <String>['01.flac']).path;
      expect(await importAudioCdIfPresent(context, db: db, dir: dir), isFalse);
    });

    testWidgets(
      '.cda outside a CD drive is hinted but still scanned, no rip dialog',
      (WidgetTester t) async {
        // 从光盘拷出来的文件夹：根上只有 .cda，真媒体可能在子目录里，必须照常扫描。
        final BuildContext context = await pumpContext(t);
        final String dir = dirWith('copied', <String>['Track01.cda']).path;
        expect(
          await importAudioCdIfPresent(context, db: db, dir: dir),
          isFalse,
        );
        await t.pump();
        expect(find.byType(AudioCdRipDialog), findsNothing);
        expect(await db.getMediaSourcesByKind('video'), isEmpty);
      },
    );
  });

  test(
    'importLocalFolderOnceAt scans through a temp source and deletes it',
    () async {
      // 抓好的 CD 落在数据根内，只能「仅此一次」导入、不能留下常驻来源行。
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory(),
      );
      addTearDown(db.close);
      final int existing = await db.insertMediaSource(
        MediaSourcesCompanion.insert(
          label: 'keep',
          mediaKind: 'video',
          rootPath: dirWith('kept', <String>[]).path,
          createdAt: 0,
        ),
      );
      int? scanningId;
      final SourceScanSummary? summary = await importLocalFolderOnceAt(
        db: db,
        mediaKind: 'video',
        path: dirWith('ripped', <String>[]).path,
        videoGroupingMode: 'folder',
        onScanning: (int id) => scanningId = id,
      );
      expect(summary, isNotNull);
      expect(summary!.error, isNull);
      expect(scanningId, isNot(existing));
      expect(
        (await db.getMediaSourcesByKind(
          'video',
        )).map((MediaSourceRow r) => r.id),
        <int>[existing],
      );
    },
  );
}
