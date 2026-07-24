import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_cover_resolver.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// 游戏库「自动获取封面」的解析器测试：文件名打分（纯函数）+ 真实目录上的级联落盘。
void main() {
  group('rankGameCoverCandidates', () {
    test('封面类文件名排在立绘/背景之前，非图片被过滤', () {
      final List<GameCoverCandidate> ranked = rankGameCoverCandidates(
        filePaths: <String>[
          p.join('game', 'bg_school.png'),
          p.join('game', 'cover.png'),
          p.join('game', 'chara_yuki.png'),
          p.join('game', 'readme.txt'),
          p.join('game', 'パッケージ.jpg'),
        ],
        gameName: 'Some Game',
      );

      expect(ranked.map((GameCoverCandidate c) => p.basename(c.path)),
          <String>['cover.png', 'パッケージ.jpg']);
    });

    test('与游戏同名的图拿到额外加分', () {
      final List<GameCoverCandidate> ranked = rankGameCoverCandidates(
        filePaths: <String>[
          p.join('g', 'sakura_moyu.png'),
          p.join('g', 'thumb.png')
        ],
        gameName: 'Sakura Moyu',
      );
      expect(p.basename(ranked.first.path), 'sakura_moyu.png');
    });

    test('.ico 可用但排在同类正分图片之后', () {
      final List<GameCoverCandidate> ranked = rankGameCoverCandidates(
        filePaths: <String>[p.join('g', 'cover.ico'), p.join('g', 'cover.png')],
        gameName: 'Game',
      );
      expect(p.basename(ranked.first.path), 'cover.png');
      expect(ranked, hasLength(2));
    });

    test('同分候选按路径稳定排序（目录枚举顺序不影响结果）', () {
      final List<String> files = <String>[
        p.join('g', 'b_cover.png'),
        p.join('g', 'a_cover.png')
      ];
      expect(
        rankGameCoverCandidates(filePaths: files, gameName: 'x')
            .map((GameCoverCandidate c) => c.path),
        rankGameCoverCandidates(
                filePaths: files.reversed.toList(), gameName: 'x')
            .map((GameCoverCandidate c) => c.path),
      );
    });
  });

  group('isUsableCoverSize', () {
    test('太小或过于细长的图不作封面', () {
      expect(isUsableCoverSize(600, 800), isTrue);
      expect(isUsableCoverSize(64, 64), isFalse); // 小图标
      expect(isUsableCoverSize(1920, 200), isFalse); // 横幅
    });
  });

  group('autoResolveGameCover', () {
    late Directory root;
    late Directory gameDir;
    late Directory coverDir;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('hibiki_game_cover_test_');
      gameDir = Directory(p.join(root.path, 'game'))..createSync();
      coverDir = Directory(p.join(root.path, 'covers'))..createSync();
    });

    tearDown(() async {
      if (root.existsSync()) {
        root.deleteSync(recursive: true);
      }
    });

    test('优先选目录里够大的封面图，落盘到封面目录', () async {
      _writePng(p.join(gameDir.path, 'bg_town.png'), 800, 600);
      _writePng(p.join(gameDir.path, 'cover.png'), 600, 800);
      final String exe = p.join(gameDir.path, 'game.exe');
      File(exe).writeAsBytesSync(Uint8List.fromList(<int>[0, 1, 2]));

      final ResolvedGameCover? resolved = await autoResolveGameCover(
        gameId: 'g1',
        gameName: 'Game',
        exePath: exe,
        workdir: gameDir.path,
        coverDirectory: coverDir,
      );

      expect(resolved, isNotNull);
      expect(resolved!.source, GameCoverSource.directoryImage);
      expect(p.basename(resolved.path), 'g1.png');
      expect(File(resolved.path).existsSync(), isTrue);
      // 落盘的是 cover.png（600×800），不是同目录更大的背景图。
      final img.Image? decoded = img.decodePng(
        File(resolved.path).readAsBytesSync(),
      );
      expect(decoded!.width, 600);
      expect(decoded.height, 800);
    });

    test('目录里只有过小的图时跳过它（不硬塞一张糊图当封面）', () async {
      _writePng(p.join(gameDir.path, 'cover.png'), 64, 64);
      final String exe = p.join(gameDir.path, 'game.exe');
      File(exe).writeAsBytesSync(Uint8List.fromList(<int>[0, 1, 2]));

      final ResolvedGameCover? resolved = await autoResolveGameCover(
        gameId: 'g2',
        gameName: 'Game',
        exePath: exe,
        workdir: gameDir.path,
        coverDirectory: coverDir,
      );

      // 目录候选被尺寸门槛挡下，exe 又不是真 PE：整体无封面可用。
      expect(resolved, isNull);
      expect(coverDir.listSync(), isEmpty);
    });

    test('目录里没有候选时回退到 exe 内嵌图标', () async {
      final String exe = p.join(gameDir.path, 'game.exe');
      File(exe).writeAsBytesSync(_peWith64pxIcon());

      final ResolvedGameCover? resolved = await autoResolveGameCover(
        gameId: 'g3',
        gameName: 'Game',
        exePath: exe,
        workdir: gameDir.path,
        coverDirectory: coverDir,
      );

      expect(resolved, isNotNull);
      expect(resolved!.source, GameCoverSource.exeIcon);
      final img.Image? decoded =
          img.decodePng(File(resolved.path).readAsBytesSync());
      expect(decoded!.width, 64);
    });

    test('换封面时清掉该游戏的旧封面文件（不同扩展名也不残留）', () async {
      final String jpg = p.join(gameDir.path, 'old.jpg');
      File(jpg)
          .writeAsBytesSync(img.encodeJpg(img.Image(width: 300, height: 400)));
      await saveGameCoverFromFile(
        gameId: 'g4',
        sourcePath: jpg,
        coverDirectory: coverDir,
      );
      expect(
          coverDir.listSync().map((FileSystemEntity e) => p.basename(e.path)),
          <String>['g4.jpg']);

      _writePng(p.join(gameDir.path, 'new.png'), 300, 400);
      final String? second = await saveGameCoverFromFile(
        gameId: 'g4',
        sourcePath: p.join(gameDir.path, 'new.png'),
        coverDirectory: coverDir,
      );

      expect(second, isNotNull);
      expect(
          coverDir.listSync().map((FileSystemEntity e) => p.basename(e.path)),
          <String>['g4.png']);
    });

    test('exe 不存在 / 目录不存在时安静返回 null', () async {
      final ResolvedGameCover? resolved = await autoResolveGameCover(
        gameId: 'g5',
        gameName: 'Ghost',
        exePath: p.join(root.path, 'missing', 'nope.exe'),
        workdir: p.join(root.path, 'missing'),
        coverDirectory: coverDir,
      );
      expect(resolved, isNull);
    });
  });
}

void _writePng(String path, int width, int height) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(10, 120, 200));
  File(path).writeAsBytesSync(img.encodePng(image));
}

/// 一个含 64×64 PNG 图标的最小 PE（结构同 `galgame_exe_icon_test.dart` 里的构造器）。
Uint8List _peWith64pxIcon() {
  final img.Image image = img.Image(width: 64, height: 64);
  img.fill(image, color: img.ColorRgb8(255, 200, 0));
  final Uint8List icon = img.encodePng(image);

  const int peOffset = 0x80;
  const int optionalHeaderSize = 0xE0;
  const int sectionTableOffset = peOffset + 4 + 20 + optionalHeaderSize;
  const int rsrcFileOffset = sectionTableOffset + 40;
  const int rsrcRva = 0x1000;
  const int l2 = 24;
  const int langBase = l2 + 24;
  const int leafBase = langBase + 24;
  const int dataBase = leafBase + 16;
  final int rsrcSize = dataBase + icon.length;

  final Uint8List out = Uint8List(rsrcFileOffset + rsrcSize);
  final ByteData view = ByteData.sublistView(out);
  out[0] = 0x4D;
  out[1] = 0x5A;
  view.setUint32(0x3C, peOffset, Endian.little);
  out[peOffset] = 0x50;
  out[peOffset + 1] = 0x45;
  view.setUint16(peOffset + 6, 1, Endian.little); // NumberOfSections
  view.setUint16(peOffset + 20, optionalHeaderSize, Endian.little);
  for (int i = 0; i < '.rsrc'.length; i++) {
    out[sectionTableOffset + i] = '.rsrc'.codeUnitAt(i);
  }
  view.setUint32(sectionTableOffset + 8, rsrcSize, Endian.little);
  view.setUint32(sectionTableOffset + 12, rsrcRva, Endian.little);
  view.setUint32(sectionTableOffset + 16, rsrcSize, Endian.little);
  view.setUint32(sectionTableOffset + 20, rsrcFileOffset, Endian.little);

  int abs(int relative) => rsrcFileOffset + relative;
  view.setUint16(abs(0) + 14, 1, Endian.little);
  view.setUint32(abs(0) + 16, 3, Endian.little); // RT_ICON
  view.setUint32(abs(0) + 20, 0x80000000 | l2, Endian.little);
  view.setUint16(abs(l2) + 14, 1, Endian.little);
  view.setUint32(abs(l2) + 16, 1, Endian.little);
  view.setUint32(abs(l2) + 20, 0x80000000 | langBase, Endian.little);
  view.setUint16(abs(langBase) + 14, 1, Endian.little);
  view.setUint32(abs(langBase) + 16, 1033, Endian.little);
  view.setUint32(abs(langBase) + 20, leafBase, Endian.little);
  view.setUint32(abs(leafBase), rsrcRva + dataBase, Endian.little);
  view.setUint32(abs(leafBase) + 4, icon.length, Endian.little);
  out.setRange(abs(dataBase), abs(dataBase) + icon.length, icon);
  return out;
}
