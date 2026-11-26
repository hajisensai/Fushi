import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/pages/implementations/android_storage_move_prompt.dart'
    show libraryVanishedFeedbackPrefill;
import 'package:fushi/src/pages/implementations/feedback/feedback_compose_prefill.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/library_sentinel.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';

/// BUG-5492：书库消失哨兵。外部 `Android/data` 书库被整树删掉时，下次启动要留下现场、
/// 首页请用户上传日志；合法整树重写（条目没少）不误报；任何情况下都不动书库文件。
void main() {
  late Directory tmp;
  late Directory library;
  late Directory support;
  late String bucket;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_library_sentinel_');
    library = Directory(p.join(tmp.path, 'library'))..createSync();
    support = Directory(p.join(tmp.path, 'support'))..createSync();
    bucket = (LibrarySentinel.countedTopLevelNames.toList()..sort()).first;
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  File sentinelFile() =>
      File(p.join(library.path, LibrarySentinel.sentinelFileName));

  void addBooks(int n) {
    final Directory dir = Directory(p.join(library.path, bucket))
      ..createSync(recursive: true);
    for (int i = 0; i < n; i++) {
      File(p.join(dir.path, 'book_$i.epub')).writeAsStringSync('x');
    }
  }

  Future<LibrarySentinelResult> check(DateTime at) => LibrarySentinel.check(
    libraryRoot: library,
    supportRoot: support,
    now: at,
  );

  test('第一次启动布防，之后哨兵在就是 intact', () async {
    addBooks(3);
    expect(
      (await check(DateTime(2026, 11, 1))).status,
      LibrarySentinelStatus.armed,
    );
    expect(sentinelFile().existsSync(), isTrue);
    expect(
      File(p.join(support.path, LibrarySentinel.recordFileName)).existsSync(),
      isTrue,
    );
    expect(
      (await check(DateTime(2026, 11, 2))).status,
      LibrarySentinelStatus.intact,
    );
    expect(await LibrarySentinel.pendingIncident(support), isNull);
  });

  test('用户在应用里删书（哨兵还在）不算消失', () async {
    addBooks(3);
    await check(DateTime(2026, 11, 1));
    File(p.join(library.path, bucket, 'book_0.epub')).deleteSync();
    expect(
      (await check(DateTime(2026, 11, 2))).status,
      LibrarySentinelStatus.intact,
    );
  });

  test('书库整树被删：留下现场、重新布防、不动剩下的文件', () async {
    addBooks(3);
    await check(DateTime(2026, 11, 1, 8));
    await check(DateTime(2026, 11, 1, 9));
    // 外部清理：整个书库根没了，Fushi 下次启动重建了空目录。
    library.deleteSync(recursive: true);
    library.createSync();
    final File survivor = File(p.join(library.path, 'keep.txt'))
      ..writeAsStringSync('keep');

    final LibrarySentinelResult result = await check(DateTime(2026, 11, 2));
    expect(result.status, LibrarySentinelStatus.vanished);
    final LibraryVanishIncident incident = result.incident!;
    expect(incident.sentinelState, 'missing');
    expect(incident.lastSeenAt, DateTime(2026, 11, 1, 9));
    expect(incident.previousCounts, <String, int>{bucket: 3});
    expect(incident.currentCounts, isEmpty);
    expect(incident.describe(), contains('$bucket 3→0'));
    expect(survivor.readAsStringSync(), 'keep');
    expect(sentinelFile().existsSync(), isTrue, reason: '重新布防');

    final LibraryVanishIncident? pending =
        await LibrarySentinel.pendingIncident(support);
    expect(pending?.toJson(), incident.toJson());
    // 下一次启动哨兵已在：不再产生新现场，旧现场等用户处理。
    expect(
      (await check(DateTime(2026, 11, 3))).status,
      LibrarySentinelStatus.intact,
    );
    expect(await LibrarySentinel.pendingIncident(support), isNotNull);

    await LibrarySentinel.clearIncident(support);
    expect(await LibrarySentinel.pendingIncident(support), isNull);
    expect(
      (await check(DateTime(2026, 11, 4))).status,
      LibrarySentinelStatus.intact,
      reason: '清现场不破坏布防',
    );
  });

  test('哨兵换成别的 token 且条目变少：判 foreign', () async {
    addBooks(2);
    await check(DateTime(2026, 11, 1));
    sentinelFile().writeAsStringSync('someone-else');
    Directory(p.join(library.path, bucket)).deleteSync(recursive: true);
    final LibrarySentinelResult result = await check(DateTime(2026, 11, 2));
    expect(result.status, LibrarySentinelStatus.vanished);
    expect(result.incident!.sentinelState, 'foreign');
  });

  test('哨兵没了但条目没少（恢复备份 / 整树复制）：只重新布防', () async {
    addBooks(2);
    await check(DateTime(2026, 11, 1));
    sentinelFile().deleteSync();
    addBooks(4);
    expect(
      (await check(DateTime(2026, 11, 2))).status,
      LibrarySentinelStatus.rearmed,
    );
    expect(await LibrarySentinel.pendingIncident(support), isNull);
  });

  test('空书库第一次布防后哨兵丢了：没东西可丢，不误报', () async {
    await check(DateTime(2026, 11, 1));
    sentinelFile().deleteSync();
    expect(
      (await check(DateTime(2026, 11, 2))).status,
      LibrarySentinelStatus.rearmed,
    );
  });

  test('记录损坏按第一次布防处理', () async {
    addBooks(1);
    File(
      p.join(support.path, LibrarySentinel.recordFileName),
    ).writeAsStringSync('{not json');
    expect(
      (await check(DateTime(2026, 11, 1))).status,
      LibrarySentinelStatus.armed,
    );
  });

  test('书库根不可写（是个文件）：报 error，不抛', () async {
    final Directory bogus = Directory(p.join(tmp.path, 'file_not_dir'));
    File(bogus.path).writeAsStringSync('x');
    final LibrarySentinelResult result = await LibrarySentinel.check(
      libraryRoot: bogus,
      supportRoot: support,
    );
    expect(result.status, LibrarySentinelStatus.error);
  });

  test('反馈预填：分类「问题」（默认带日志），正文带现场', () {
    final LibraryVanishIncident incident = LibraryVanishIncident(
      detectedAt: DateTime(2026, 11, 2),
      lastSeenAt: DateTime(2026, 11, 1),
      previousRoot: '/ext/files/data',
      currentRoot: '/ext/files/data',
      previousCounts: const <String, int>{'books': 5},
      currentCounts: const <String, int>{},
      sentinelState: 'missing',
    );
    final FeedbackComposePrefill prefill = libraryVanishedFeedbackPrefill(
      incident,
    );
    expect(prefill.category, FeedbackCategory.bug);
    expect(prefill.body, contains(incident.describe()));
    expect(
      LibraryVanishIncident.fromJson(incident.toJson())?.toJson(),
      incident.toJson(),
    );
  });

  test('哨兵不算书库证据：迁移目标核对不会因为它挡住移回内部', () {
    expect(
      AppPaths.isLibraryEvidenceFileName(LibrarySentinel.sentinelFileName),
      isFalse,
    );
    expect(
      AppPaths.isLibraryEvidenceFileName(
        '${LibrarySentinel.sentinelFileName}.tmp',
      ),
      isFalse,
    );
    expect(AppPaths.isLibraryEvidenceFileName('book.epub'), isTrue);
  });
}
