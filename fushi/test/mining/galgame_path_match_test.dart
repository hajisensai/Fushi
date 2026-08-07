import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_path_match.dart';
import 'package:path/path.dart' as p;

/// [galgamePathComponents] / [galgamePathIsWithin] 纯函数守卫。
///
/// 「是否在游戏目录下」的用例路径一律用 [p.join] 构造，**不靠硬编码 `C:\`**——
/// Linux CI 上 `\` 不是分隔符，硬编码过的测试在本机绿、在 CI 红（见 `16b981c63`）。
///
/// 例外只有下面几条**归一化本身**的用例：被测函数的契约就是「`\` 与 `/` 一律当
/// 分隔符、盘符是独立首段」，验证它必须写出字面反斜杠与盘符。这些断言是纯字符串
/// 运算，不碰文件系统、不依赖 `p.separator`，三端结果完全相同。
void main() {
  final String gamesRoot = p.join(p.rootPrefix(p.current), 'Games');
  final String gameDir = p.join(gamesRoot, 'Game');
  final String siblingDir = p.join(gamesRoot, 'Game2');

  group('galgamePathComponents', () {
    test('反斜杠与正斜杠等价，尾斜杠/连续斜杠不产生空段', () {
      expect(
        galgamePathComponents(r'C:\Games\Game\'),
        galgamePathComponents('C:/Games//Game'),
      );
    });

    test('大小写不敏感', () {
      expect(
        galgamePathComponents(r'C:\GAMES\Game'),
        galgamePathComponents(r'c:\games\game'),
      );
    });

    test('. 段丢弃，.. 段回退上一级', () {
      expect(
        galgamePathComponents(r'C:\Games\.\Game\sub\..\bin'),
        <String>['c:', 'games', 'game', 'bin'],
      );
    });

    test('顶到头的 .. 原样保留，不静默吞掉', () {
      expect(galgamePathComponents('../x'), <String>['..', 'x']);
    });
  });

  group('galgamePathIsWithin', () {
    test('目录下的 exe 命中', () {
      expect(
        galgamePathIsWithin(p.join(gameDir, 'game.exe'), gameDir),
        isTrue,
      );
      expect(
        galgamePathIsWithin(p.join(gameDir, 'bin', 'x86', 'game.exe'), gameDir),
        isTrue,
      );
    });

    test('同前缀的兄弟目录不得误命中（Game vs Game2）', () {
      expect(
        galgamePathIsWithin(p.join(siblingDir, 'game.exe'), gameDir),
        isFalse,
        reason: '裸 startsWith 会在这里把隔壁游戏的进程算成自己的',
      );
      expect(galgamePathIsWithin(siblingDir, gameDir), isFalse);
    });

    test('分隔符混用 + 大小写差异 + 尾斜杠仍命中', () {
      final String messy =
          '${gameDir.replaceAll(p.separator, '/').toUpperCase()}/BIN\\Game.EXE';
      expect(galgamePathIsWithin(messy, '$gameDir${p.separator}'), isTrue);
    });

    test('父目录本身：includeSelf 默认命中，关掉则不命中', () {
      expect(galgamePathIsWithin(gameDir, gameDir), isTrue);
      expect(
        galgamePathIsWithin(gameDir, gameDir, includeSelf: false),
        isFalse,
      );
    });

    test('上级目录不算在下级目录内', () {
      expect(galgamePathIsWithin(p.join(gamesRoot, 'x.exe'), gameDir), isFalse);
    });

    test('空目录不匹配任何路径（否则逃逸检测退化成全匹配）', () {
      expect(galgamePathIsWithin(p.join(gameDir, 'game.exe'), ''), isFalse);
      expect(galgamePathIsWithin(p.join(gameDir, 'game.exe'), '/'), isFalse);
    });

    test('不同盘符/不同根不互相匹配', () {
      expect(galgamePathIsWithin(r'D:\Games\Game\game.exe', r'C:\Games\Game'),
          isFalse);
    });
  });
}
