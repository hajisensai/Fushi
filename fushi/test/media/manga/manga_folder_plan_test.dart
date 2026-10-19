import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
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
