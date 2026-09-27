import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/cover_image.dart';
import 'package:fushi_engine/foundation/engine_platform_hooks.dart';
import 'package:fushi_engine/media/video/metadata/video_sidecar_writer.dart';
import 'package:path/path.dart' as p;
import 'package:transparent_image/transparent_image.dart';

import '../../../helpers/cover_cache_test_helpers.dart';

class _MemoryArtifactStore implements SidecarArtifactHashStore {
  final Map<String, SidecarArtifactRecord> records =
      <String, SidecarArtifactRecord>{};
  bool failFind = false;
  bool failUpsert = false;

  @override
  Future<SidecarArtifactRecord?> findByPath(String absolutePath) async {
    if (failFind) {
      throw StateError('find failed');
    }
    return records[absolutePath];
  }

  @override
  Future<void> upsert(SidecarArtifactRecord record) async {
    if (failUpsert) {
      throw StateError('upsert failed');
    }
    records[record.path] = record;
  }
}

void main() {
  late Directory temporary;
  late Directory source;
  late _MemoryArtifactStore store;
  late VideoSidecarWriter writer;

  // 宿主写后驱逐钩子：默认记录调用（本文件大多数用例是纯文件语义，不挂
  // painting binding）；真走 app 双键驱逐的那条用例自己换回真实现。
  final Future<void> Function(File) hostEvict = evictImageCacheForFile;
  late List<String> evicted;

  Uint8List bytes(String value) => Uint8List.fromList(utf8.encode(value));
  String hash(String value) => sha256.convert(utf8.encode(value)).toString();

  setUp(() async {
    evicted = <String>[];
    evictImageCacheForFile = (File file) async => evicted.add(file.path);
    temporary = await Directory.systemTemp.createTemp('fushi_writer_');
    source = await Directory(p.join(temporary.path, 'source')).create();
    store = _MemoryArtifactStore();
    writer = VideoSidecarWriter(
      sourceRoot: source.path,
      artifactStore: store,
      generatorVersion: 'test-v1',
    );
  });

  tearDown(() async {
    evictImageCacheForFile = hostEvict;
    if (await temporary.exists()) {
      await temporary.delete(recursive: true);
    }
  });

  test('missingOnly 新文件经同目录临时文件写入并记录 SHA-256', () async {
    final String target = p.join(source.path, 'movie.nfo');
    final SidecarWriteResult result = await writer.write(SidecarWriteRequest(
      targetPath: target,
      bytes: bytes('<movie/>'),
    ));

    expect(result.status, SidecarWriteStatus.written);
    expect(await File(target).readAsString(), '<movie/>');
    expect(result.sha256, hash('<movie/>'));
    expect(store.records[target]?.sha256, hash('<movie/>'));
    expect(store.records[target]?.generatorVersion, 'test-v1');
    expect(
      await source
          .list()
          .where((FileSystemEntity entity) =>
              p.basename(entity.path).contains('.fushi-'))
          .toList(),
      isEmpty,
    );
  });

  test('skip 永不写入，missingOnly 保留现有第三方文件', () async {
    final String skipped = p.join(source.path, 'skip.nfo');
    final SidecarWriteResult skipResult =
        await writer.write(SidecarWriteRequest(
      targetPath: skipped,
      bytes: bytes('new'),
      policy: SidecarWritePolicy.skip,
    ));
    expect(skipResult.status, SidecarWriteStatus.skippedByPolicy);
    expect(await File(skipped).exists(), isFalse);

    final String existing = p.join(source.path, 'existing.nfo');
    await File(existing).writeAsString('third-party');
    final SidecarWriteResult missingOnly =
        await writer.write(SidecarWriteRequest(
      targetPath: existing,
      bytes: bytes('new'),
      policy: SidecarWritePolicy.missingOnly,
    ));
    expect(missingOnly.status, SidecarWriteStatus.skippedExisting);
    expect(await File(existing).readAsString(), 'third-party');
    expect(store.records, isEmpty);
  });

  test('overwrite 保护第三方文件，危险确认可显式覆盖', () async {
    final String target = p.join(source.path, 'movie.nfo');
    await File(target).writeAsString('third-party');

    final SidecarWriteResult protected = await writer.write(SidecarWriteRequest(
      targetPath: target,
      bytes: bytes('generated'),
      policy: SidecarWritePolicy.overwrite,
    ));
    expect(protected.status, SidecarWriteStatus.protectedExisting);
    expect(await File(target).readAsString(), 'third-party');

    final SidecarWriteResult forced = await writer.write(SidecarWriteRequest(
      targetPath: target,
      bytes: bytes('generated'),
      policy: SidecarWritePolicy.overwrite,
      allowProtectedOverwrite: true,
    ));
    expect(forced.status, SidecarWriteStatus.written);
    expect(await File(target).readAsString(), 'generated');
    expect(store.records[target]?.sha256, hash('generated'));
  });

  test('overwrite 只更新 hash 未变化的 Fushi 生成物', () async {
    final String target = p.join(source.path, 'movie.nfo');
    await File(target).writeAsString('old');
    store.records[target] = SidecarArtifactRecord(
      path: target,
      sha256: hash('old'),
      generatorVersion: 'old-v1',
      writtenAt: DateTime.utc(2025),
    );

    final SidecarWriteResult result = await writer.write(SidecarWriteRequest(
      targetPath: target,
      bytes: bytes('new'),
      policy: SidecarWritePolicy.overwrite,
    ));
    expect(result.status, SidecarWriteStatus.written);
    expect(await File(target).readAsString(), 'new');
    expect(store.records[target]?.sha256, hash('new'));
    expect(store.records[target]?.generatorVersion, 'test-v1');
  });

  test('用户修改过 Fushi 生成物后普通 overwrite 保持保护', () async {
    final String target = p.join(source.path, 'movie.nfo');
    await File(target).writeAsString('user-edited');
    store.records[target] = SidecarArtifactRecord(
      path: target,
      sha256: hash('original-generated'),
      generatorVersion: 'old-v1',
      writtenAt: DateTime.utc(2025),
    );

    final SidecarWriteResult result = await writer.write(SidecarWriteRequest(
      targetPath: target,
      bytes: bytes('new'),
      policy: SidecarWritePolicy.overwrite,
    ));
    expect(result.status, SidecarWriteStatus.protectedModified);
    expect(await File(target).readAsString(), 'user-edited');
  });

  test('目标字节完全相同是 no-op，且不抢占第三方文件所有权', () async {
    final String target = p.join(source.path, 'movie.nfo');
    await File(target).writeAsString('same');

    final SidecarWriteResult result = await writer.write(SidecarWriteRequest(
      targetPath: target,
      bytes: bytes('same'),
      policy: SidecarWritePolicy.overwrite,
    ));
    expect(result.status, SidecarWriteStatus.unchanged);
    expect(store.records, isEmpty);
  });

  test('拒绝来源根目录前缀碰撞和不存在的父目录', () async {
    final String outsidePrefix = p.join(
      temporary.path,
      '${p.basename(source.path)}-other',
      'movie.nfo',
    );
    final SidecarWriteResult outside = await writer.write(SidecarWriteRequest(
      targetPath: outsidePrefix,
      bytes: bytes('x'),
    ));
    expect(outside.status, SidecarWriteStatus.rejectedOutsideRoot);

    final SidecarWriteResult skippedOutside =
        await writer.write(SidecarWriteRequest(
      targetPath: outsidePrefix,
      bytes: bytes('x'),
      policy: SidecarWritePolicy.skip,
    ));
    expect(skippedOutside.status, SidecarWriteStatus.skippedByPolicy);

    final SidecarWriteResult missingParent =
        await writer.write(SidecarWriteRequest(
      targetPath: p.join(source.path, 'missing', 'movie.nfo'),
      bytes: bytes('x'),
    ));
    expect(missingParent.status, SidecarWriteStatus.rejectedInvalidTarget);
  });

  test('符号链接父目录若解析到来源外则拒绝写入', () async {
    final Directory outside =
        await Directory(p.join(temporary.path, 'outside')).create();
    final Link link = Link(p.join(source.path, 'linked'));
    try {
      await link.create(outside.path);
    } on FileSystemException catch (error) {
      // Windows 未开启开发者模式时系统禁止创建测试软链接；此时至少确认是平台权限阻断，
      // 不能把未执行的边界断言误报为 writer 成功。
      expect(error.osError, isNotNull);
      return;
    }

    final SidecarWriteResult result = await writer.write(SidecarWriteRequest(
      targetPath: p.join(link.path, 'movie.nfo'),
      bytes: bytes('x'),
    ));
    expect(result.status, SidecarWriteStatus.rejectedSymbolicLink);
    expect(await File(p.join(outside.path, 'movie.nfo')).exists(), isFalse);
  });

  test('拒绝直接覆盖符号链接文件', () async {
    final File outside = File(p.join(temporary.path, 'outside.nfo'));
    await outside.writeAsString('outside');
    final Link link = Link(p.join(source.path, 'movie.nfo'));
    try {
      await link.create(outside.path);
    } on FileSystemException catch (error) {
      expect(error.osError, isNotNull);
      return;
    }

    final SidecarWriteResult result = await writer.write(SidecarWriteRequest(
      targetPath: link.path,
      bytes: bytes('x'),
      policy: SidecarWritePolicy.overwrite,
      allowProtectedOverwrite: true,
    ));
    expect(result.status, SidecarWriteStatus.rejectedSymbolicLink);
    expect(await outside.readAsString(), 'outside');
  });

  test('artifact store 失败不回滚已成功文件，摘要单独计数', () async {
    store.failUpsert = true;
    final String target = p.join(source.path, 'movie.nfo');
    final SidecarWriteSummary summary = await writer.writeAll(
      <SidecarWriteRequest>[
        SidecarWriteRequest(targetPath: target, bytes: bytes('x')),
        SidecarWriteRequest(
          targetPath: p.join(temporary.path, 'outside.nfo'),
          bytes: bytes('y'),
        ),
      ],
    );

    expect(await File(target).readAsString(), 'x');
    expect(summary.results, hasLength(2));
    expect(summary.writtenCount, 1);
    expect(summary.artifactStoreFailureCount, 1);
    expect(summary.failureCount, 1);
    expect(summary.results.first.artifactStoreError, isA<StateError>());
  });

  test('artifact 查询失败时保守保护现有文件', () async {
    final String target = p.join(source.path, 'movie.nfo');
    await File(target).writeAsString('old');
    store.failFind = true;

    final SidecarWriteResult result = await writer.write(SidecarWriteRequest(
      targetPath: target,
      bytes: bytes('new'),
      policy: SidecarWritePolicy.overwrite,
    ));
    expect(result.status, SidecarWriteStatus.protectedExisting);
    expect(result.error, isA<StateError>());
    expect(await File(target).readAsString(), 'old');
  });

  group('覆盖写后驱逐宿主图片解码缓存（BUG-2737）', () {
    test('覆盖写驱逐目标路径；新建 / 字节不变 / 被保护都不打扰宿主', () async {
      final String poster = p.join(source.path, 'poster.jpg');
      final SidecarWriteResult created = await writer.write(
        SidecarWriteRequest(targetPath: poster, bytes: bytes('old identity')),
      );
      expect(created.status, SidecarWriteStatus.written);
      expect(evicted, isEmpty, reason: '新建文件没有旧解码可清');

      final SidecarWriteResult same = await writer.write(SidecarWriteRequest(
        targetPath: poster,
        bytes: bytes('old identity'),
        policy: SidecarWritePolicy.overwrite,
      ));
      expect(same.status, SidecarWriteStatus.unchanged);
      expect(evicted, isEmpty, reason: '字节没变，缓存里的就是对的图');

      // 换身份重刮：图名只按图种派生，封面恒是同一个 poster 路径。
      final SidecarWriteResult replaced =
          await writer.write(SidecarWriteRequest(
        targetPath: poster,
        bytes: bytes('new identity'),
        policy: SidecarWritePolicy.overwrite,
      ));
      expect(replaced.status, SidecarWriteStatus.written);
      expect(evicted, <String>[poster]);

      final String thirdParty = p.join(source.path, 'banner.jpg');
      await File(thirdParty).writeAsString('third-party');
      final SidecarWriteResult protectedResult =
          await writer.write(SidecarWriteRequest(
        targetPath: thirdParty,
        bytes: bytes('generated'),
        policy: SidecarWritePolicy.overwrite,
      ));
      expect(protectedResult.status, SidecarWriteStatus.protectedExisting);
      expect(evicted, <String>[poster], reason: '没写的文件不驱逐');
    });

    test('app 装配下覆盖写把裸 FileImage 键与降采样键一起清掉', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      // 与 installEngineHostBindings 装的是同一份双键驱逐（守卫
      // media_cover_write_guard_test 钉着那一行绑定）。
      evictImageCacheForFile = (File file) => evictLocalCoverCache(file.path);
      PaintingBinding.instance.imageCache.clear();
      final String poster = p.join(source.path, 'poster.png');
      await writer.write(
        SidecarWriteRequest(targetPath: poster, bytes: kTransparentImage),
      );
      await populateBothCoverKeys(poster);

      final SidecarWriteResult replaced =
          await writer.write(SidecarWriteRequest(
        targetPath: poster,
        bytes: await _solidPng(),
        policy: SidecarWritePolicy.overwrite,
      ));

      expect(replaced.status, SidecarWriteStatus.written);
      await expectBothCoverKeysEvicted(poster);
      PaintingBinding.instance.imageCache.clear();
    });
  });
}

/// 与 [kTransparentImage] 字节不同的另一张可解码 PNG（2×2 纯色）。
Future<Uint8List> _solidPng() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    const ui.Rect.fromLTWH(0, 0, 2, 2),
    ui.Paint()..color = const ui.Color(0xFF3366FF),
  );
  final ui.Image image = await recorder.endRecording().toImage(2, 2);
  final ByteData? png = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return png!.buffer.asUint8List();
}
