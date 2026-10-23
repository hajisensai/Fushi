import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/collections/book_series_key.dart';
import 'package:fushi_engine/media/manga/manga_archive_importer.dart'
    show kMangaArchiveFileExtensions;
import 'package:fushi_engine/media/manga/manga_folder_plan.dart';
import 'package:path/path.dart' as p;

/// 引擎 `planMangaFolders`：app 源库扫描与无头服务端库扫描共用的卷归组规则。
/// 三条规则各钉一例，外加排序与 `dart:io` 入口。
void main() {
  group('planMangaFolders 单文件卷', () {
    test('缺省载体表 = 导入器能吃的压缩包 / 纯图 EPUB；PDF 只在调用方追加时收', () {
      final String root = p.join('library', 'series');
      final List<String> files = <String>[
        p.join(root, 'v1.cbz'),
        p.join(root, 'v2.ZIP'),
        p.join(root, 'v3.rar'),
        p.join(root, 'v4.cbr'),
        p.join(root, 'v5.cb7'),
        p.join(root, 'v6.epub'),
        p.join(root, 'v7.pdf'),
        p.join(root, 'notes.txt'),
      ];
      expect(
        planMangaFolders(rootPath: root, filePaths: files).carrierPaths,
        files.sublist(0, 6),
      );
      expect(
        planMangaFolders(
          rootPath: root,
          filePaths: files,
          carrierExtensions: <String>{...kMangaArchiveFileExtensions, '.pdf'},
        ).carrierPaths,
        files.sublist(0, 7),
      );
    });

    test('包旁 sidecar 归 ZIP 容器卷；7-Zip 卷旁的 .mokuro 仍独立成卷', () {
      final String root = p.join('library', 'series');
      final MangaFolderPlan plan = planMangaFolders(
        rootPath: root,
        filePaths: <String>[
          p.join(root, 'a.cbz'),
          p.join(root, 'a.mokuro'),
          p.join(root, 'b.zip'),
          p.join(root, 'b.zip.mokuro'),
          p.join(root, 'c.rar'),
          p.join(root, 'c.mokuro'),
          // 不同名的 manifest 不被认领，避免第 1 卷绑到第 2 卷的 OCR。
          p.join(root, 'd.cbz'),
          p.join(root, 'd2.mokuro'),
        ],
      );

      expect(plan.mokuroSidecars, <String, String>{
        p.join(root, 'a.cbz'): p.join(root, 'a.mokuro'),
        p.join(root, 'b.zip'): p.join(root, 'b.zip.mokuro'),
      });
      expect(plan.mokuroPaths, <String>[
        p.join(root, 'c.mokuro'),
        p.join(root, 'd2.mokuro'),
      ]);
    });

    test('与单文件卷同目录 / 祖先目录的散图不成卷；兄弟目录的散图照常成卷', () {
      final String root = p.join('library', 'series');
      final MangaFolderPlan withCover = planMangaFolders(
        rootPath: root,
        filePaths: <String>[
          p.join(root, 'cover.jpg'),
          p.join(root, 'vol-1.cbz'),
        ],
      );
      expect(withCover.imageFolders, isEmpty);
      expect(withCover.carrierPaths, <String>[p.join(root, 'vol-1.cbz')]);

      final MangaFolderPlan mixed = planMangaFolders(
        rootPath: root,
        filePaths: <String>[
          p.join(root, 'loose', '001.jpg'),
          p.join(root, 'packed', 'vol-2.cbz'),
          p.join(root, 'packed', 'cover.jpg'),
        ],
      );
      expect(mixed.imageFolders, <String>[p.join(root, 'loose')]);
      expect(mixed.carrierPaths, <String>[p.join(root, 'packed', 'vol-2.cbz')]);
    });

    test('散装章节子目录不因旁边多了一个包而整卷丢掉', () {
      final String root = p.join('library', 'shelf');
      final MangaFolderPlan plan = planMangaFolders(
        rootPath: root,
        filePaths: <String>[
          // 系列 A：章节是散图子目录，旁边另有一个番外包 → A 仍是一卷散图，包另成一卷。
          p.join(root, 'A', 'ch01', '001.jpg'),
          p.join(root, 'A', 'ch02', '001.jpg'),
          p.join(root, 'A', 'extra.cbz'),
          // 包旁的封面单独看是「封面」，但 A 里还有没包认领的章节目录，A 仍成卷。
          p.join(root, 'A', 'cover.jpg'),
          // 系列 B：封面在系列目录、包在卷子目录 → 封面不是一卷。
          p.join(root, 'B', 'cover.jpg'),
          p.join(root, 'B', 'v1', 'v1.cbz'),
        ],
      );

      expect(plan.imageFolders, <String>[p.join(root, 'A')]);
      expect(plan.carrierPaths, <String>[
        p.join(root, 'A', 'extra.cbz'),
        p.join(root, 'B', 'v1', 'v1.cbz'),
      ]);
    });

    test('扫描根之外的载体被忽略', () {
      final String root = p.join('library', 'series');
      final MangaFolderPlan plan = planMangaFolders(
        rootPath: root,
        filePaths: <String>[p.join('library', 'other', 'x.cbz')],
      );
      expect(plan.carrierPaths, isEmpty);
      expect(plan.isEmpty, isTrue);
    });
  });

  group('planMangaFolders (pure)', () {
    test('根目录直接有页图 → 根本身一卷，子目录页图不再拆卷', () {
      final String root = p.join('library', 'volume-01');
      final MangaFolderPlan plan = planMangaFolders(
        rootPath: root,
        filePaths: <String>[
          p.join(root, '001.jpg'),
          p.join(root, 'chapter', '002.png'),
          p.join(root, 'notes.txt'),
        ],
      );

      expect(plan.imageFolders, <String>[root]);
      expect(plan.mokuroPaths, isEmpty);
    });

    test('根目录没有页图 → 每个含页图的直接子目录一卷，深层归属直接子目录', () {
      final String root = p.join('library', 'series');
      final String volume1 = p.join(root, 'volume-01');
      final String volume2 = p.join(root, 'volume-02');
      final MangaFolderPlan plan = planMangaFolders(
        rootPath: root,
        filePaths: <String>[
          p.join(volume2, 'images', '001.webp'),
          p.join(volume2, 'images', 'extra', '002.webp'),
          p.join(volume1, '001.jpg'),
          p.join(volume1, 'notes.txt'),
          p.join(root, 'readme.txt'),
        ],
      );

      expect(plan.imageFolders, <String>[volume1, volume2]);
    });

    test('候选目录与 .mokuro 所在目录有祖先/后代关系时让位给 manifest', () {
      final String root = p.join('library', 'series');
      final String mokuroVolume = p.join(root, 'volume-01');
      final String nestedMokuro = p.join(root, 'volume-02');
      final String plainVolume = p.join(root, 'volume-03');
      final MangaFolderPlan plan = planMangaFolders(
        rootPath: root,
        filePaths: <String>[
          // 同级：mokuro 与候选目录相同。
          p.join(mokuroVolume, 'volume-01.mokuro'),
          p.join(mokuroVolume, 'images', '001.jpg'),
          // 后代：mokuro 在候选目录更深处。
          p.join(nestedMokuro, 'inner', 'volume-02.mokuro'),
          p.join(nestedMokuro, 'inner', '001.jpg'),
          // 无 mokuro 的裸图卷保留。
          p.join(plainVolume, '001.jpg'),
        ],
      );

      expect(plan.mokuroPaths, <String>[
        p.join(mokuroVolume, 'volume-01.mokuro'),
        p.join(nestedMokuro, 'inner', 'volume-02.mokuro'),
      ]);
      expect(plan.imageFolders, <String>[plainVolume]);
    });

    test('根目录页图被根级 .mokuro 覆盖时整根让位', () {
      final String root = p.join('library', 'series');
      final MangaFolderPlan plan = planMangaFolders(
        rootPath: root,
        filePaths: <String>[
          p.join(root, 'volume-01.mokuro'),
          p.join(root, 'images', '001.jpg'),
        ],
      );

      expect(plan.mokuroPaths, hasLength(1));
      expect(plan.imageFolders, isEmpty);
      expect(plan.isEmpty, isFalse);
    });

    test('卷目录与 .mokuro 都按小写字典序，与枚举顺序无关', () {
      final String root = p.join('library', 'series');
      final MangaFolderPlan plan = planMangaFolders(
        rootPath: root,
        filePaths: <String>[
          p.join(root, 'b-vol', '001.jpg'),
          p.join(root, 'A-vol', '001.jpg'),
          p.join(root, 'c-vol', '001.jpg'),
          p.join(root, 'mk', 'Z.mokuro'),
          p.join(root, 'mk', 'a.mokuro'),
        ],
      );

      expect(plan.imageFolders, <String>[
        p.join(root, 'A-vol'),
        p.join(root, 'b-vol'),
        p.join(root, 'c-vol'),
      ]);
      expect(plan.mokuroPaths, <String>[
        p.join(root, 'mk', 'a.mokuro'),
        p.join(root, 'mk', 'Z.mokuro'),
      ]);
    });

    test('根之外的路径与非页图文件被忽略；空输入为空', () {
      final String root = p.join('library', 'series');
      final MangaFolderPlan plan = planMangaFolders(
        rootPath: root,
        filePaths: <String>[
          p.join('library', 'other', '001.jpg'),
          p.join(root, 'vol', 'cover.txt'),
        ],
      );
      expect(plan.isEmpty, isTrue);
      expect(
        planMangaFolders(rootPath: root, filePaths: const <String>[]).isEmpty,
        isTrue,
      );
    });
  });

  // 反馈 n4KC1azJvw（manga-series-volume-folders-flattened）：`库根/系列/卷N/页图`
  // 被整个系列合成一本 ~2000 页的漫画。系列目录下的卷子目录全都像卷号时下探一层。
  group('planMangaFolders 系列目录下探一层', () {
    final String root = p.join('library');
    final String series = p.join(root, 'ONE PIECE');

    test('库/系列/Vol01..03 → 3 卷，各带系列归属与「系列名 卷名」标题', () {
      final MangaFolderPlan plan = planMangaFolders(
        rootPath: root,
        filePaths: <String>[
          for (final String v in <String>[
            'Vol01',
            'Vol02',
            'Vol03',
          ]) ...<String>[
            p.join(series, v, '001.jpg'),
            // 卷目录更深处的子目录仍归属这一卷。
            p.join(series, v, 'ch1', '002.jpg'),
          ],
        ],
      );

      expect(plan.imageFolders, <String>[
        p.join(series, 'Vol01'),
        p.join(series, 'Vol02'),
        p.join(series, 'Vol03'),
      ]);
      expect(
        plan.seriesVolumes[p.join(series, 'Vol02')],
        MangaSeriesVolume(
          seriesDir: series,
          seriesTitle: 'ONE PIECE',
          title: 'ONE PIECE Vol02',
          volume: 2,
        ),
      );
      expect(plan.seriesVolumeDirs, <String, List<String>>{
        series: plan.imageFolders,
      });
      expect(plan.imageFolders.map(plan.imageFolderTitle).toList(), <String>[
        'ONE PIECE Vol01',
        'ONE PIECE Vol02',
        'ONE PIECE Vol03',
      ]);
    });

    test('第N巻 / v01 / 纯数字 / （N） / Volume N / 已带系列名 都算卷号', () {
      final Map<List<String>, List<String>> cases =
          <List<String>, List<String>>{
            <String>['第1巻', '第2巻']: <String>['ONE PIECE 第1巻', 'ONE PIECE 第2巻'],
            <String>['v01', 'v02']: <String>['ONE PIECE v01', 'ONE PIECE v02'],
            <String>['01', '02', '10']: <String>[
              'ONE PIECE 01',
              'ONE PIECE 02',
              'ONE PIECE 10',
            ],
            <String>['（1）', '（2）']: <String>['ONE PIECE （1）', 'ONE PIECE （2）'],
            <String>['Volume 1', 'Volume 2']: <String>[
              'ONE PIECE Volume 1',
              'ONE PIECE Volume 2',
            ],
            <String>['第1卷', '第2册']: <String>['ONE PIECE 第1卷', 'ONE PIECE 第2册'],
            <String>['#1', '#2']: <String>['ONE PIECE #1', 'ONE PIECE #2'],
            // 卷目录名已带系列名：标题原样，不再拼成「ONE PIECE ONE PIECE 01」。
            <String>['ONE PIECE 01', 'one piece 02']: <String>[
              'ONE PIECE 01',
              'one piece 02',
            ],
          };
      cases.forEach((List<String> names, List<String> titles) {
        final MangaFolderPlan plan = planMangaFolders(
          rootPath: root,
          filePaths: <String>[
            for (final String n in names) p.join(series, n, '001.png'),
          ],
        );
        expect(plan.imageFolders, hasLength(names.length), reason: '$names');
        expect(
          plan.imageFolders.map(plan.imageFolderTitle).toList(),
          titles,
          reason: '$names',
        );
        for (final String folder in plan.imageFolders) {
          expect(
            plan.seriesVolumes[folder]?.seriesTitle,
            'ONE PIECE',
            reason: folder,
          );
        }
      });
    });

    test('拼出的标题经 parseBookSeriesKey 解析回同一系列与卷号（合集归组靠它）', () {
      final MangaFolderPlan plan = planMangaFolders(
        rootPath: root,
        filePaths: <String>[
          for (final String n in <String>['Vol01', '第2巻', '03'])
            p.join(series, n, '001.png'),
        ],
      );
      final List<BookSeriesKey> keys = <BookSeriesKey>[
        for (final String folder in plan.imageFolders)
          parseBookSeriesKey(plan.imageFolderTitle(folder))!,
      ];
      expect(keys.map((BookSeriesKey k) => k.seriesTitle).toSet(), <String>{
        'ONE PIECE',
      });
      expect(keys.map((BookSeriesKey k) => k.volume).toList()..sort(), <num>[
        1,
        2,
        3,
      ]);
    });

    test('反例：系列/ch01..ch03 章节目录 → 整个系列一卷（不拆）', () {
      for (final List<String> names in <List<String>>[
        <String>['ch01', 'ch02', 'ch03'],
        <String>['Chapter 01', 'Chapter 02'],
        <String>['第1話', '第2話'],
        <String>['Extra 1', 'Extra 2'],
      ]) {
        final MangaFolderPlan plan = planMangaFolders(
          rootPath: root,
          filePaths: <String>[
            for (final String n in names) p.join(series, n, '001.png'),
          ],
        );
        expect(plan.imageFolders, <String>[series], reason: '$names');
        expect(plan.seriesVolumes, isEmpty, reason: '$names');
        expect(plan.imageFolderTitle(series), 'ONE PIECE');
      }
    });

    test('混合（部分像卷号、部分不像）→ 维持现状，整个系列一卷', () {
      final MangaFolderPlan plan = planMangaFolders(
        rootPath: root,
        filePaths: <String>[
          p.join(series, 'Vol01', '001.png'),
          p.join(series, 'Vol02', '001.png'),
          p.join(series, 'extra', '001.png'),
        ],
      );
      expect(plan.imageFolders, <String>[series]);
      expect(plan.seriesVolumes, isEmpty);
    });

    test('系列目录自己有直接页图 / 只有一个卷目录 → 维持现状', () {
      final MangaFolderPlan withCover = planMangaFolders(
        rootPath: root,
        filePaths: <String>[
          p.join(series, 'cover.jpg'),
          p.join(series, 'Vol01', '001.png'),
          p.join(series, 'Vol02', '001.png'),
        ],
      );
      expect(withCover.imageFolders, <String>[series]);
      expect(withCover.seriesVolumes, isEmpty);

      final MangaFolderPlan single = planMangaFolders(
        rootPath: root,
        filePaths: <String>[p.join(series, 'Vol01', '001.png')],
      );
      expect(single.imageFolders, <String>[series]);
      expect(single.seriesVolumes, isEmpty);
    });

    test('多个系列并存：各自下探，与普通卷 / 章节系列互不影响', () {
      final String other = p.join(root, 'Bleach');
      final String chapters = p.join(root, 'Oneshots');
      final String plain = p.join(root, 'Standalone');
      final MangaFolderPlan plan = planMangaFolders(
        rootPath: root,
        filePaths: <String>[
          p.join(series, 'Vol01', '001.png'),
          p.join(series, 'Vol02', '001.png'),
          p.join(other, '01', '001.png'),
          p.join(other, '02', '001.png'),
          p.join(chapters, 'ch01', '001.png'),
          p.join(chapters, 'ch02', '001.png'),
          p.join(plain, '001.png'),
        ],
      );
      expect(plan.imageFolders, <String>[
        p.join(other, '01'),
        p.join(other, '02'),
        p.join(series, 'Vol01'),
        p.join(series, 'Vol02'),
        chapters,
        plain,
      ]);
      expect(plan.seriesVolumeDirs.keys.toSet(), <String>{series, other});
      expect(plan.imageFolderTitle(p.join(other, '01')), 'Bleach 01');
      expect(plan.imageFolderTitle(chapters), 'Oneshots');
    });

    test('卷目录被 .mokuro 认领时让位，其余卷照常下探', () {
      final MangaFolderPlan plan = planMangaFolders(
        rootPath: root,
        filePaths: <String>[
          p.join(series, 'Vol01', 'Vol01.mokuro'),
          p.join(series, 'Vol01', '001.png'),
          p.join(series, 'Vol02', '001.png'),
        ],
      );
      expect(plan.mokuroPaths, <String>[
        p.join(series, 'Vol01', 'Vol01.mokuro'),
      ]);
      expect(plan.imageFolders, <String>[p.join(series, 'Vol02')]);
      expect(plan.seriesVolumes.keys, <String>[p.join(series, 'Vol02')]);
    });

    test('网络来源（URL 路径语义）同样下探', () {
      const String remoteRoot = 'https://dav.example/manga';
      final MangaFolderPlan plan = planMangaFolders(
        rootPath: remoteRoot,
        context: p.url,
        filePaths: <String>[
          '$remoteRoot/ONE PIECE/Vol01/001.png',
          '$remoteRoot/ONE PIECE/Vol02/001.png',
        ],
      );
      expect(plan.imageFolders, <String>[
        '$remoteRoot/ONE PIECE/Vol01',
        '$remoteRoot/ONE PIECE/Vol02',
      ]);
      expect(
        plan.imageFolderTitle('$remoteRoot/ONE PIECE/Vol01', context: p.url),
        'ONE PIECE Vol01',
      );
    });
  });

  group('parseBookVolumeFolderName', () {
    test('裸卷号与「系列名 + 卷号」算卷目录，章节 / 附录不算', () {
      const String s = 'ONE PIECE';
      for (final String yes in <String>[
        'Vol01',
        'Vol.1',
        'vol_02',
        'Volume 3',
        'v04',
        '第5巻',
        '6巻',
        '第7卷',
        '第8册',
        '#9',
        '(10)',
        '（11）',
        '１２',
        '13',
        'ONE PIECE 14',
        'ＯＮＥ ＰＩＥＣＥ 第15巻',
      ]) {
        expect(
          parseBookVolumeFolderName(yes, seriesFolderName: s),
          isNotNull,
          reason: yes,
        );
      }
      for (final String no in <String>[
        'ch01',
        'Chapter 1',
        'Episode 2',
        '第1話',
        'extra',
        'Extra 2',
        'images',
        'Bleach 01',
        'Catch22',
      ]) {
        expect(
          parseBookVolumeFolderName(no, seriesFolderName: s),
          isNull,
          reason: no,
        );
      }
      expect(
        parseBookVolumeFolderName('Vol01', seriesFolderName: s)!.volume,
        1,
      );
      expect(
        parseBookVolumeFolderName(
          'ONE PIECE 14',
          seriesFolderName: s,
        )!.namesSeries,
        isTrue,
      );
    });
  });

  group('planMangaFoldersInDirectory (dart:io)', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('manga_folder_plan_');
    });
    tearDown(() {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    void writeFile(String path) {
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(<int>[1, 2, 3]);
    }

    test('递归枚举后与纯函数同一结果', () {
      final String vol1 = p.join(tmp.path, 'vol-1');
      final String vol2 = p.join(tmp.path, 'vol-2');
      final String mk = p.join(tmp.path, 'vol-3');
      writeFile(p.join(vol1, '001.jpg'));
      writeFile(p.join(vol2, 'ch1', '001.png'));
      writeFile(p.join(mk, 'vol-3.mokuro'));
      writeFile(p.join(mk, 'images', '001.jpg'));
      writeFile(p.join(tmp.path, 'readme.txt'));

      final MangaFolderPlan plan = planMangaFoldersInDirectory(tmp);

      expect(plan.imageFolders, <String>[vol1, vol2]);
      expect(plan.mokuroPaths, <String>[p.join(mk, 'vol-3.mokuro')]);
    });

    test('不存在的根目录 → 空归组而非异常', () {
      final Directory missing = Directory(p.join(tmp.path, 'missing'));
      expect(planMangaFoldersInDirectory(missing).isEmpty, isTrue);
    });
  });
}
