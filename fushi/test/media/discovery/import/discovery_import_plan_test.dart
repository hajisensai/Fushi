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

    test('有声书:单文件永远不够料,但缺的那一样要报准', () {
      // 孤立音频（TMW 单卷 m4b 的真实形状）缺的是字幕,不是音频。
      expect(
        (classifyDiscoveryFile(DiscoveryMediaKind.audiobook, 'x.mp3')
                as UnsupportedPlan)
            .blocker,
        DiscoveryImportBlocker.audiobookMissingSubtitle,
      );
      expect(
        (classifyDiscoveryFile(DiscoveryMediaKind.audiobook, r'D:\a\vol1.m4b')
                as UnsupportedPlan)
            .blocker,
        DiscoveryImportBlocker.audiobookMissingSubtitle,
      );
      // 孤立字幕/正文则确实缺音频。
      expect(
        (classifyDiscoveryFile(DiscoveryMediaKind.audiobook, 'x.srt')
                as UnsupportedPlan)
            .blocker,
        DiscoveryImportBlocker.audiobookMissingAudio,
      );
      expect(
        (classifyDiscoveryFile(DiscoveryMediaKind.audiobook, 'x.epub')
                as UnsupportedPlan)
            .blocker,
        DiscoveryImportBlocker.audiobookMissingAudio,
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

  // 顺序依赖守卫：文件系统枚举顺序不是稳定输入（NTFS 按名字、ext4 按目录哈希），
  // 分类层不得把这份偶然顺序带进用户可见的导入次序 —— CI 上曾据此偶发红。
  group('分类结果不依赖输入清单顺序', () {
    List<String> plannedPaths(List<String> input) {
      final MultiPlan plan = classifyDiscoveryDirectory(
        DiscoveryMediaKind.novel,
        input,
      ) as MultiPlan;
      return <String>[
        for (final DiscoveryImportPlan child in plan.children)
          switch (child) {
            ImportEpubPlan(:final String filePath) => filePath,
            ConvertTextPlan(:final String filePath) => filePath,
            ImportPdfPlan(:final String filePath) => filePath,
            _ => throw StateError('unexpected child: $child'),
          },
      ];
    }

    test('小说包:任意输入排列都导出同一顺序(路径字典序)', () {
      const List<String> expected = <String>[
        '/d/vol1/a.epub',
        '/d/vol1/b.txt',
        '/d/vol2/c.pdf',
      ];
      const List<String> files = <String>[
        '/d/vol1/a.epub',
        '/d/vol1/b.txt',
        '/d/vol2/c.pdf',
        '/d/cover.jpg',
      ];
      final List<List<String>> permutations = <List<String>>[
        files,
        files.reversed.toList(),
        <String>[
          '/d/vol1/b.txt',
          '/d/cover.jpg',
          '/d/vol2/c.pdf',
          '/d/vol1/a.epub',
        ],
        <String>[
          '/d/vol2/c.pdf',
          '/d/vol1/b.txt',
          '/d/cover.jpg',
          '/d/vol1/a.epub',
        ],
      ];
      for (final List<String> input in permutations) {
        expect(plannedPaths(input), expected, reason: input.join(','));
      }
    });

    test('有声书:多份正文/字幕时恒取字典序最小,与输入顺序无关', () {
      const List<String> files = <String>[
        '/d/z-later.epub',
        '/d/a-first.epub',
        '/d/z-later.srt',
        '/d/a-first.srt',
        '/d/02.mp3',
        '/d/01.mp3',
      ];
      for (final List<String> input in <List<String>>[
        files,
        files.reversed.toList(),
      ]) {
        final AlignAudiobookPlan plan = classifyDiscoveryDirectory(
          DiscoveryMediaKind.audiobook,
          input,
        ) as AlignAudiobookPlan;
        expect(plan.contentPath, '/d/a-first.epub', reason: input.join(','));
        expect(plan.subtitlePath, '/d/a-first.srt', reason: input.join(','));
        expect(plan.audioPaths, <String>['/d/01.mp3', '/d/02.mp3']);
      }
    });

    test('游戏:同层同体积平局按路径定二,与输入顺序无关', () {
      const Map<String, int> sizes = <String, int>{
        '/g/alpha.exe': 4096,
        '/g/beta.exe': 4096,
      };
      for (final List<String> input in <List<String>>[
        <String>['/g/beta.exe', '/g/alpha.exe'],
        <String>['/g/alpha.exe', '/g/beta.exe'],
      ]) {
        expect(
          pickGalgameMainExe(input, fileSizes: sizes),
          '/g/alpha.exe',
          reason: input.join(','),
        );
        expect(
          classifyDiscoveryDirectory(
            DiscoveryMediaKind.game,
            input,
            fileSizes: sizes,
          ),
          isA<RegisterGameExesPlan>().having(
            (RegisterGameExesPlan p) => p.exePaths,
            'exePaths',
            <String>['/g/alpha.exe'],
          ),
        );
      }
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
