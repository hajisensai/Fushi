import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/discovery/import/discovery_archive_extractor.dart';
import 'package:fushi/src/media/discovery/import/discovery_import_plan.dart';

void main() {
  group('classifyDiscoveryFile', () {
    test('压缩包一律先解压', () {
      for (final String path in <String>['a.zip', 'b.7z', 'c.RAR']) {
        expect(
          classifyDiscoveryFile(DiscoveryMediaKind.novel, path),
          isA<ExtractArchivePlan>(),
          reason: path,
        );
      }
    });

    test('小说:epub/pdf/文本各走各的导入', () {
      expect(
        classifyDiscoveryFile(DiscoveryMediaKind.novel, 'x.epub'),
        isA<ImportEpubPlan>(),
      );
      expect(
        classifyDiscoveryFile(DiscoveryMediaKind.novel, 'x.pdf'),
        isA<ImportPdfPlan>(),
      );
      expect(
        classifyDiscoveryFile(DiscoveryMediaKind.novel, 'x.txt'),
        isA<ConvertTextPlan>(),
      );
      expect(
        (classifyDiscoveryFile(DiscoveryMediaKind.novel, 'x.mp3')
                as UnsupportedPlan)
            .blocker,
        DiscoveryImportBlocker.unknownFileType,
      );
    });

    test('游戏:裸 exe 直接登记', () {
      final RegisterGameExesPlan plan = classifyDiscoveryFile(
        DiscoveryMediaKind.game,
        r'D:\games\atri.exe',
      ) as RegisterGameExesPlan;
      expect(plan.exePaths, <String>[r'D:\games\atri.exe']);
    });

    test('有声书:单文件永远不够料', () {
      expect(
        classifyDiscoveryFile(DiscoveryMediaKind.audiobook, 'x.mp3'),
        isA<UnsupportedPlan>(),
      );
    });
  });

  group('classifyDiscoveryDirectory', () {
    test('小说目录:全部书文件收成 MultiPlan', () {
      final MultiPlan plan = classifyDiscoveryDirectory(
        DiscoveryMediaKind.novel,
        <String>['/d/a.epub', '/d/b.txt', '/d/cover.jpg', '/d/c.pdf'],
      ) as MultiPlan;
      expect(plan.children, hasLength(3));
    });

    test('小说目录只有一本时不套 MultiPlan', () {
      expect(
        classifyDiscoveryDirectory(
          DiscoveryMediaKind.novel,
          <String>['/d/a.epub', '/d/cover.jpg'],
        ),
        isA<ImportEpubPlan>(),
      );
    });

    test('有声书:EPUB+字幕+音频齐 → 对齐计划;音频排序稳定', () {
      final AlignAudiobookPlan plan = classifyDiscoveryDirectory(
        DiscoveryMediaKind.audiobook,
        <String>['/d/02.mp3', '/d/book.epub', '/d/book.srt', '/d/01.mp3'],
      ) as AlignAudiobookPlan;
      expect(plan.contentPath, '/d/book.epub');
      expect(plan.subtitlePath, '/d/book.srt');
      expect(plan.audioPaths, <String>['/d/01.mp3', '/d/02.mp3']);
    });

    test('有声书:无 EPUB 退纯文本当正文', () {
      final AlignAudiobookPlan plan = classifyDiscoveryDirectory(
        DiscoveryMediaKind.audiobook,
        <String>['/d/a.mp3', '/d/book.txt', '/d/book.lrc'],
      ) as AlignAudiobookPlan;
      expect(plan.contentPath, '/d/book.txt');
    });

    test('有声书三缺一时给出稳定原因码', () {
      expect(
        (classifyDiscoveryDirectory(
          DiscoveryMediaKind.audiobook,
          <String>['/d/book.epub', '/d/book.srt'],
        ) as UnsupportedPlan)
            .blocker,
        DiscoveryImportBlocker.audiobookMissingAudio,
      );
      expect(
        (classifyDiscoveryDirectory(
          DiscoveryMediaKind.audiobook,
          <String>['/d/book.epub', '/d/a.mp3'],
        ) as UnsupportedPlan)
            .blocker,
        DiscoveryImportBlocker.audiobookMissingSubtitle,
      );
      expect(
        (classifyDiscoveryDirectory(
          DiscoveryMediaKind.audiobook,
          <String>['/d/book.srt', '/d/a.mp3'],
        ) as UnsupportedPlan)
            .blocker,
        DiscoveryImportBlocker.audiobookMissingText,
      );
    });

    test('游戏:无 exe → gameNoExecutable', () {
      expect(
        (classifyDiscoveryDirectory(
          DiscoveryMediaKind.game,
          <String>['/d/readme.txt'],
        ) as UnsupportedPlan)
            .blocker,
        DiscoveryImportBlocker.gameNoExecutable,
      );
    });
  });

  group('pickGalgameMainExe', () {
    test('剔除安装器/运行库,层级浅者优先,同层取最大', () {
      final String? picked = pickGalgameMainExe(
        <String>[
          '/g/unins000.exe',
          '/g/tools/config.exe',
          '/g/game.exe',
          '/g/launcher.exe',
          '/g/sub/deep.exe',
        ],
        fileSizes: <String, int>{
          '/g/game.exe': 100,
          '/g/launcher.exe': 5000,
        },
      );
      expect(picked, '/g/launcher.exe', reason: '同层按体积;deep.exe 层级更深被排除');
    });

    test('全是辅助名时退回全量再挑(配置器命名的本体不漏)', () {
      expect(
        pickGalgameMainExe(<String>['/g/setup.exe']),
        '/g/setup.exe',
      );
    });

    test('无 exe 返回 null', () {
      expect(pickGalgameMainExe(<String>['/g/a.txt']), isNull);
    });
  });

  group('sanitizeArchiveEntryPath', () {
    test('拒绝 zip-slip 与绝对路径', () {
      expect(sanitizeArchiveEntryPath('../evil.txt'), isNull);
      expect(sanitizeArchiveEntryPath('a/../../evil.txt'), isNull);
      expect(sanitizeArchiveEntryPath('/abs/path.txt'), isNull);
      expect(sanitizeArchiveEntryPath(r'C:\abs\path.txt'), isNull);
    });

    test('正常条目归一分隔符', () {
      expect(
        sanitizeArchiveEntryPath('a/b/c.txt'),
        'a${_sep}b${_sep}c.txt',
      );
      expect(sanitizeArchiveEntryPath(r'a\b.txt'), 'a${_sep}b.txt');
      expect(sanitizeArchiveEntryPath('./a/./b.txt'), 'a${_sep}b.txt');
    });
  });
}

final String _sep = Platform.pathSeparator;
