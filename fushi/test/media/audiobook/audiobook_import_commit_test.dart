import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import '../../helpers/source_guard.dart';

/// #3722 c13 遗留（并入 c48）：应用内「附加 / 换有声书」对话框换音频时不带 commit，
/// 旧音频在写库前就删了；写库失败时库里还指着已删的文件、新文件也没登记。
class _FailingAudioWrite extends QueryInterceptor {
  bool armed = false;

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (armed &&
        statement.contains('audiobooks') &&
        statement.contains('audio_paths_json')) {
      throw StateError('injected audiobooks audio write failure');
    }
    return super.runUpdate(executor, statement, args);
  }
}

void main() {
  late Directory root;
  late FushiDatabase db;
  late _FailingAudioWrite interceptor;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi_import_commit_');
    interceptor = _FailingAudioWrite();
    db = FushiDatabase.forTesting(
      NativeDatabase.memory().interceptWith(interceptor),
    );
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('写库失败：旧音频留在原名、行上的音频与字幕都停在换之前', () async {
    const String bookKey = 'book';
    final AudiobookRepository repo = AudiobookRepository(db);
    final Directory persistDir = Directory(p.join(root.path, 'persist'))
      ..createSync(recursive: true);
    final File oldAudio = File(p.join(persistDir.path, 'old.mp3'))
      ..writeAsStringSync('OLD');
    final String oldAlignment = p.join(persistDir.path, 'old.srt');
    await commitAudiobookImportRow(
      repo: repo,
      bookKey: bookKey,
      alignmentPath: oldAlignment,
      audioPaths: <String>[oldAudio.path],
    );

    final File newSource = File(p.join(root.path, 'new.mp3'))
      ..writeAsStringSync('NEW');
    final String newAlignment = p.join(persistDir.path, 'new.srt');
    interceptor.armed = true;

    await expectLater(
      AudiobookStorage.syncAudioFiles(
        persistDir,
        <String>[newSource.path],
        commit: (List<String> landed) => commitAudiobookImportRow(
          repo: repo,
          bookKey: bookKey,
          alignmentPath: newAlignment,
          audioPaths: landed,
        ),
      ),
      throwsStateError,
    );

    expect(oldAudio.existsSync(), isTrue, reason: '旧音频不得在写库成功前删除');
    final Audiobook? row = await repo.findByBookKey(bookKey);
    expect(row!.audioPaths, <String>[oldAudio.path]);
    expect(
      row.alignmentPath,
      oldAlignment,
      reason: '字幕两列与音频两列同一事务，音频写失败时字幕也不能换掉一半',
    );
  });

  test('对话框换音频走 syncAudioFiles 的 commit，不在同步之后另写库', () {
    final String source = maskComments(
      File(
        'lib/src/media/audiobook/audiobook_import_dialog.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n'),
    );
    final int sync = source.indexOf('AudiobookStorage.syncAudioFiles(');
    expect(sync, isNonNegative);
    final int callEnd = source.indexOf('\n      );\n', sync);
    expect(callEnd, greaterThan(sync));
    final String call = source.substring(sync, callEnd);
    expect(call, contains('commit: (List<String> landed)'));
    expect(call, contains('commitAudiobookImportRow('));
    expect(
      'widget.repo.replaceAudio('.allMatches(source),
      isEmpty,
      reason: '音频列只能在 commit 里写',
    );
  });
}
