import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_library.dart';

/// 启动参数：用户输入的一整行 → argv token。规则必须与 Windows `CommandLineToArgvW`
/// 一致，因为 injector 侧会按同一套规则重新转义写进 `CreateProcessW` 的
/// `lpCommandLine`；两边不同源就会出现「配了参数但游戏收到的是别的东西」。
void main() {
  group('parseGameLaunchArguments', () {
    test('空输入 / 纯空白 → 空列表（= 不发任何 --arg，旧行为）', () {
      expect(parseGameLaunchArguments(''), <String>[]);
      expect(parseGameLaunchArguments('   '), <String>[]);
      expect(parseGameLaunchArguments('\t \n'), <String>[]);
    });

    test('空白分隔的普通参数', () {
      expect(
        parseGameLaunchArguments('-windowed -nosound'),
        <String>['-windowed', '-nosound'],
      );
      // 连续空白不产生空 token。
      expect(
        parseGameLaunchArguments('  -a    -b  '),
        <String>['-a', '-b'],
      );
    });

    test('引号保住含空格的路径（本功能最常见的真实输入）', () {
      expect(
        parseGameLaunchArguments(r'--save="D:\My Saves\slot 1" -b'),
        <String>[r'--save=D:\My Saves\slot 1', '-b'],
      );
      expect(
        parseGameLaunchArguments(r'"C:\Program Files\x"'),
        <String>[r'C:\Program Files\x'],
      );
    });

    test('反斜杠只有在引号前才是转义符，Windows 路径不会被吃掉', () {
      // 不接引号的反斜杠全是字面量。
      expect(parseGameLaunchArguments(r'a\b'), <String>[r'a\b']);
      expect(parseGameLaunchArguments(r'D:\Saves\'), <String>[r'D:\Saves\']);
      // 2n 个反斜杠 + " → n 个反斜杠，并切换引号态。
      expect(
        parseGameLaunchArguments(r'"a\\" b'),
        <String>[r'a\', 'b'],
      );
      // 2n+1 个反斜杠 + " → n 个反斜杠 + 一个字面引号。
      expect(parseGameLaunchArguments(r'a\"b'), <String>['a"b']);
      expect(parseGameLaunchArguments(r'a\\\"b'), <String>[r'a\"b']);
    });

    test('引号内的 "" 是一个字面引号且仍在引号内', () {
      expect(
        parseGameLaunchArguments(r'"say ""hi"" now"'),
        <String>['say "hi" now'],
      );
    });

    test('未闭合的引号不吞掉参数，按到行尾处理（原样交给游戏报错）', () {
      expect(
        parseGameLaunchArguments(r'-a "unclosed value'),
        <String>['-a', 'unclosed value'],
      );
    });

    test('日文/中文参数原样保留', () {
      expect(
        parseGameLaunchArguments(r'--path="D:\ゲーム\セーブ 1"'),
        <String>[r'--path=D:\ゲーム\セーブ 1'],
      );
    });
  });

  group('GalgameEntry.launchArgumentTokens', () {
    GalgameEntry entryWith(String raw) => GalgameEntry(
          id: 'g1',
          name: 'game',
          exePath: r'D:\Games\vn.exe',
          workdir: r'D:\Games',
          launchArgs: raw,
          addedAt: DateTime(2026),
        );

    test('默认空串 → 空 token（新列不改变既有游戏的启动命令行）', () {
      expect(entryWith('').launchArgumentTokens, <String>[]);
    });

    test('配置后按 Windows 规则拆分', () {
      expect(
        entryWith(r'-windowed --save="D:\My Saves"').launchArgumentTokens,
        <String>['-windowed', r'--save=D:\My Saves'],
      );
    });

    test('copyWith 保住 launchArgs，且能被显式覆盖', () {
      final GalgameEntry base = entryWith('-a');
      expect(base.copyWith(name: 'x').launchArgs, '-a');
      expect(base.copyWith(launchArgs: '-b').launchArgs, '-b');
    });
  });

  group('findGalgameByExePath', () {
    GalgameEntry entry(
      String id,
      String exe,
      String args, {
      String? name,
    }) =>
        GalgameEntry(
          id: id,
          name: name ?? id,
          exePath: exe,
          workdir: '',
          launchArgs: args,
          addedAt: DateTime(2026),
        );

    final List<GalgameEntry> games = <GalgameEntry>[
      entry('a', r'D:\Games\A\a.exe', '-a'),
      entry('b', r'D:\Games\B\b.exe', '-b'),
    ];

    // 捕获工作台只拿到裸 exe 路径。同一个 exe = 同一个游戏，必须命中同一份配置，
    // 否则「从库里启动能跑、从工作台启动就崩」。
    test('大小写与分隔符归一后命中（Windows 路径语义）', () {
      expect(findGalgameByExePath(games, r'd:/games/a/A.EXE')?.id, 'a');
      expect(
          findGalgameByExePath(games, r'D:\Games\B\b.exe')?.launchArgs, '-b');
    });

    test('库里没有该 exe / 空路径 → null（回落成不带参数的旧行为）', () {
      expect(findGalgameByExePath(games, r'D:\Other\x.exe'), isNull);
      expect(findGalgameByExePath(games, ''), isNull);
      expect(findGalgameByExePath(<GalgameEntry>[], r'D:\a.exe'), isNull);
    });

    test('活动身份统一兼容新 id、旧 exePath 与无 key 唯一标题快照', () {
      expect(
        findGalgameForActivity(games, mediaKey: 'a', title: '旧标题')?.id,
        'a',
      );
      expect(
        findGalgameForActivity(
          games,
          mediaKey: r'd:/games/b/B.EXE',
          title: '旧标题',
        )?.id,
        'b',
      );
      expect(
        findGalgameForActivity(games, title: 'a')?.id,
        'a',
      );
      expect(
        findGalgameForActivity(games, mediaKey: 'missing', title: 'missing'),
        isNull,
      );
    });

    test('exact stable id 在重复标题中仍精确命中，不能退化成标题首项', () {
      final List<GalgameEntry> sameTitle = <GalgameEntry>[
        entry(
          'stable-a',
          r'D:\Games\A\a.exe',
          '-a',
          name: '共同标题',
        ),
        entry(
          'stable-b',
          r'D:\Games\B\b.exe',
          '-b',
          name: '共同标题',
        ),
      ];

      expect(
        findGalgameForActivity(
          sameTitle,
          mediaKey: 'stable-b',
          title: '共同标题',
        )?.id,
        'stable-b',
      );
    });

    test('旧 exePath 精确命中优先于重复标题，路径迁移只接受唯一标题', () {
      final List<GalgameEntry> sameTitle = <GalgameEntry>[
        entry(
          'path-a',
          r'D:\Games\A\a.exe',
          '-a',
          name: '共同标题',
        ),
        entry(
          'path-b',
          r'D:\Games\B\b.exe',
          '-b',
          name: '共同标题',
        ),
      ];
      expect(
        findGalgameForActivity(
          sameTitle,
          mediaKey: r'd:/games/b/B.EXE',
          title: '共同标题',
        )?.id,
        'path-b',
      );
      expect(
        findGalgameForActivity(
          sameTitle,
          mediaKey: r'D:\Games\Moved\old.exe',
          title: '共同标题',
        ),
        isNull,
      );

      final List<GalgameEntry> uniqueTitle = <GalgameEntry>[
        entry(
          'moved',
          r'D:\Games\New\game.exe',
          '',
          name: '唯一旧标题',
        ),
        entry(
          'other',
          r'D:\Games\Other\other.exe',
          '',
          name: '其他游戏',
        ),
      ];
      expect(
        findGalgameForActivity(
          uniqueTitle,
          mediaKey: r'D:\Games\Old\game.exe',
          title: '唯一旧标题',
        )?.id,
        'moved',
      );
    });

    test('无 key 的 legacy 标题只有唯一候选时命中，重复标题安全返回 null', () {
      final List<GalgameEntry> uniqueTitle = <GalgameEntry>[
        entry(
          'unique',
          r'D:\Games\Unique\game.exe',
          '',
          name: '唯一标题',
        ),
        entry(
          'other',
          r'D:\Games\Other\other.exe',
          '',
          name: '其他标题',
        ),
      ];
      expect(
        findGalgameForActivity(uniqueTitle, title: '唯一标题')?.id,
        'unique',
      );

      final List<GalgameEntry> sameTitle = <GalgameEntry>[
        entry(
          'duplicate-a',
          r'D:\Games\A\a.exe',
          '',
          name: '重复标题',
        ),
        entry(
          'duplicate-b',
          r'D:\Games\B\b.exe',
          '',
          name: '重复标题',
        ),
      ];
      expect(
        findGalgameForActivity(sameTitle, title: '重复标题'),
        isNull,
      );
    });

    test('deleted stable id 与脏非路径 key 不得回落到另一个同标题游戏', () {
      final List<GalgameEntry> currentGames = <GalgameEntry>[
        entry(
          'replacement',
          r'D:\Games\Replacement\game.exe',
          '',
          name: '已删除游戏的标题',
        ),
      ];

      expect(
        findGalgameForActivity(
          currentGames,
          mediaKey: 'deleted-stable-id',
          title: '已删除游戏的标题',
        ),
        isNull,
      );
      expect(
        findGalgameForActivity(
          currentGames,
          mediaKey: 'dirty-key',
          title: '已删除游戏的标题',
        ),
        isNull,
      );
    });
  });
}
