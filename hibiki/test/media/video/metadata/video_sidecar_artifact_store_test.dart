import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/metadata/video_sidecar_artifact_store.dart';
import 'package:hibiki/src/media/video/metadata/video_sidecar_writer.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

void main() {
  late HibikiDatabase database;
  late Directory temporaryDirectory;

  setUp(() async {
    database = HibikiDatabase.forTesting(NativeDatabase.memory());
    temporaryDirectory =
        await Directory.systemTemp.createTemp('sidecar_artifact_checker_');
  });

  tearDown(() async {
    await database.close();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('只有登记路径与当前 SHA-256 一致才识别为 Hibiki 生成物', () async {
    final File cover = File(p.join(temporaryDirectory.path, 'poster.jpg'));
    final List<int> generatedBytes = <int>[1, 2, 3, 4];
    await cover.writeAsBytes(generatedBytes);
    final DatabaseSidecarGeneratedArtifactChecker checker =
        DatabaseSidecarGeneratedArtifactChecker(database);

    expect(
      await checker.isUnmodifiedGeneratedArtifact(cover.path),
      isFalse,
      reason: '无 artifact 的第三方文件必须继续受保护',
    );

    final int now = DateTime.now().millisecondsSinceEpoch;
    await database.upsertVideoSidecarArtifact(
      VideoSidecarArtifactsCompanion.insert(
        artifactKind: 'cover',
        path: p.normalize(p.absolute(cover.path)),
        sha256: sha256.convert(generatedBytes).toString(),
        generatorVersion: 'test',
        writePolicy: 'missingOnly',
        createdAt: now,
        updatedAt: now,
      ),
    );

    expect(
      await checker.isUnmodifiedGeneratedArtifact(cover.path),
      isTrue,
      reason: 'artifact hash 与当前文件一致才是未改动的 Hibiki 生成物',
    );

    await cover.writeAsBytes(<int>[9, 8, 7, 6]);
    expect(
      await checker.isUnmodifiedGeneratedArtifact(cover.path),
      isFalse,
      reason: '用户修改后 hash 不一致，必须退回用户 sidecar 保护',
    );
  });

  test('重叠来源不能把另一来源的 artifact 当成自身可覆盖生成物', () async {
    final Directory nestedSource =
        Directory(p.join(temporaryDirectory.path, 'nested'));
    await nestedSource.create();
    final int sourceA = await _insertSource(
      database,
      'Source A',
      temporaryDirectory.path,
    );
    final int sourceB = await _insertSource(
      database,
      'Source B',
      nestedSource.path,
    );
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int runA = await _insertRun(database, sourceA, now);
    final int runB = await _insertRun(database, sourceB, now);
    final File cover = File(p.join(nestedSource.path, 'poster.jpg'));
    final List<int> sourceABytes = <int>[1, 2, 3, 4];
    await cover.writeAsBytes(sourceABytes);
    await database.upsertVideoSidecarArtifact(
      VideoSidecarArtifactsCompanion.insert(
        sourceId: Value<int?>(sourceA),
        runId: Value<int?>(runA),
        artifactKind: 'cover',
        path: p.normalize(p.absolute(cover.path)),
        sha256: sha256.convert(sourceABytes).toString(),
        generatorVersion: 'test',
        writePolicy: 'overwrite',
        createdAt: now,
        updatedAt: now,
      ),
    );
    final DatabaseSidecarArtifactStore storeA = DatabaseSidecarArtifactStore(
      database: database,
      sourceId: sourceA,
      runId: runA,
    );
    final DatabaseSidecarArtifactStore storeB = DatabaseSidecarArtifactStore(
      database: database,
      sourceId: sourceB,
      runId: runB,
    );

    expect(await storeA.findByPath(cover.path), isNotNull);
    expect(
      await storeB.findByPath(cover.path),
      isNull,
      reason: '路径重叠不代表 B 继承 A 的生成物所有权',
    );

    final VideoSidecarWriter writerB = VideoSidecarWriter(
      sourceRoot: nestedSource.path,
      artifactStore: storeB,
    );
    final SidecarWriteResult result = await writerB.write(
      SidecarWriteRequest(
        targetPath: cover.path,
        bytes: Uint8List.fromList(<int>[9, 8, 7, 6]),
        policy: SidecarWritePolicy.overwrite,
      ),
    );

    expect(result.status, SidecarWriteStatus.protectedExisting);
    expect(await cover.readAsBytes(), sourceABytes,
        reason: 'B 未经危险确认不得覆盖 A 生成的文件');
  });
}

Future<int> _insertSource(
  HibikiDatabase database,
  String label,
  String rootPath,
) =>
    database.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: label,
        mediaKind: 'video',
        rootPath: rootPath,
        createdAt: 1,
      ),
    );

Future<int> _insertRun(
  HibikiDatabase database,
  int sourceId,
  int now,
) =>
    database.insertVideoSourceScrapeRun(
      VideoSourceScrapeRunsCompanion.insert(
        sourceId: Value<int?>(sourceId),
        scope: 'source',
        status: 'running',
        startedAt: now,
        updatedAt: now,
      ),
    );
