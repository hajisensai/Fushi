import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/audiobook/audiobook_material_library.dart';
import 'package:fushi/src/media/audiobook/audiobook_material_service.dart';
import 'package:fushi/src/media/discovery/import/discovery_import_plan.dart';

void main() {
  group('decode/encode 素材库目录', () {
    test('坏偏好值一律当空库,不炸', () {
      expect(decodeAudiobookMaterialDirs(null), isEmpty);
      expect(decodeAudiobookMaterialDirs(''), isEmpty);
      expect(decodeAudiobookMaterialDirs('   '), isEmpty);
      expect(decodeAudiobookMaterialDirs('not json'), isEmpty);
      expect(decodeAudiobookMaterialDirs('{"a":1}'), isEmpty);
      expect(decodeAudiobookMaterialDirs('[1,2,3]'), isEmpty);
      expect(decodeAudiobookMaterialDirs('["", "  "]'), isEmpty);
    });

    test('往返一致', () {
      final List<String> dirs = <String>[r'D:\srt', r'E:\books'];
      expect(
        decodeAudiobookMaterialDirs(encodeAudiobookMaterialDirs(dirs)),
        dirs,
      );
    });
  });

  group('AudiobookMaterialService 扫描', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('fushi_material_test');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('递归扫描并建索引,非素材文件不计入身份表', () async {
      final Directory sub = Directory('${root.path}/nested')
        ..createSync(recursive: true);
      File('${root.path}/某书 [B0B58GV92J].srt').writeAsStringSync('x');
      File('${sub.path}/某书 [B0B58GV92J].epub').writeAsStringSync('x');
      File('${sub.path}/封面.jpg').writeAsStringSync('x');

      final AudiobookMaterialService service = AudiobookMaterialService(
        readDirs: () => <String>[root.path],
      );
      final AudiobookMaterialScan scan = await service.scan();
      expect(scan.scannedFileCount, 3);
      expect(scan.missingDirs, isEmpty);
      expect(scan.index.subtitleByKey['B0B58GV92J'], isNotNull);
      expect(scan.index.contentByKey['B0B58GV92J'], isNotNull);
      expect(scan.index.identifiedWorkCount, 1);
    });

    test('不存在的目录如实记进 missingDirs,不抛异常', () async {
      final AudiobookMaterialService service = AudiobookMaterialService(
        readDirs: () => <String>['${root.path}/gone'],
      );
      final AudiobookMaterialScan scan = await service.scan();
      expect(scan.missingDirs, <String>['${root.path}/gone']);
      expect(scan.index.isEmpty, isTrue);
    });

    test('缓存生效;refresh 后才看得到新文件', () async {
      File('${root.path}/a [B0B58GV92J].srt').writeAsStringSync('x');
      final AudiobookMaterialService service = AudiobookMaterialService(
        readDirs: () => <String>[root.path],
      );
      expect((await service.scan()).scannedFileCount, 1);

      File('${root.path}/b [B0D4LQY5K7].srt').writeAsStringSync('x');
      // 缓存命中：还是 1。
      expect((await service.scan()).scannedFileCount, 1);
      expect((await service.refresh()).scannedFileCount, 2);
    });

    test('没配目录时不扫盘,直接空库', () async {
      final AudiobookMaterialService service = AudiobookMaterialService(
        readDirs: () => const <String>[],
      );
      final AudiobookMaterialScan scan = await service.scan();
      expect(scan.index.isEmpty, isTrue);
      expect(scan.scannedFileCount, 0);
    });
  });

  group('planAudiobookFromMaterials', () {
    const AudiobookMaterialMatch full = AudiobookMaterialMatch(
      subtitlePath: r'D:\m\x.srt',
      contentPath: r'D:\m\x.epub',
    );

    test('三件套齐才出计划,音频排序稳定', () {
      final AlignAudiobookPlan? plan = planAudiobookFromMaterials(
        audioPaths: <String>[r'D:\a\02.m4b', r'D:\a\01.m4b'],
        match: full,
      );
      expect(plan, isNotNull);
      expect(plan!.audioPaths, <String>[r'D:\a\01.m4b', r'D:\a\02.m4b']);
      expect(plan.contentPath, r'D:\m\x.epub');
      expect(plan.subtitlePath, r'D:\m\x.srt');
    });

    test('缺正文时不出计划——不拿字幕伪造原书', () {
      expect(
        planAudiobookFromMaterials(
          audioPaths: <String>[r'D:\a\01.m4b'],
          match: const AudiobookMaterialMatch(subtitlePath: r'D:\m\x.srt'),
        ),
        isNull,
      );
    });

    test('缺字幕或缺音频同样不出计划', () {
      expect(
        planAudiobookFromMaterials(
          audioPaths: <String>[r'D:\a\01.m4b'],
          match: const AudiobookMaterialMatch(contentPath: r'D:\m\x.epub'),
        ),
        isNull,
      );
      expect(
        planAudiobookFromMaterials(audioPaths: const <String>[], match: full),
        isNull,
      );
    });
  });

  test('音频文件名能反查身份键（对任何来路的已有音频都管用）', () {
    expect(
      audiobookKeyFromAudioPath(r'D:\audio\#真相をお話しします [B0B58GV92J].m4b'),
      'B0B58GV92J',
    );
    expect(audiobookKeyFromAudioPath(r'D:\audio\无标记.m4b'), isNull);
  });
}
