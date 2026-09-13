import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/manga/manga_folder_plan.dart';
import 'package:path/path.dart' as p;

/// 引擎 `planMangaFolders`：app 源库扫描与无头服务端库扫描共用的卷归组规则。
/// 三条规则各钉一例，外加排序与 `dart:io` 入口。
void main() {
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
