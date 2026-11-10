/// CLI 顶层退出码契约。
///
/// `release-server.yml` 的构建冒烟在 `set -euo pipefail` 下直接跑
/// `build/fushi_server_linux/bundle/bin/fushi_server --help`——它既验证产物能跑，
/// 也验证 `--help` 是**成功路径**。这条曾把整个 linux job 钉红：旧实现写的是
/// `return command == null ? 64 : 0;`，于是裸 `--help`（本来就没有子命令）
/// 落进 64，帮助照常打印、job 照常失败，看日志只见 usage 不见错误原因。
///
/// 三条一起钉，缺一条都会让「显式求助」和「用错了」重新混成一个码：
///   `--help` → 0（EX_OK）；什么都不给 → 64；参数非法 → 64（EX_USAGE）。
library;

import 'package:fushi_server/src/cli.dart';
import 'package:fushi_server/src/commands/command_io.dart' as io;
import 'package:fushi_server/src/commands/leaderboard_commands.dart' as lb;
import 'package:fushi_server/src/commands/video_cli_support.dart' as video;
import 'package:fushi_server/src/self_update/server_self_updater.dart';
import 'package:test/test.dart';

void main() {
  group('runFushiServerCli 退出码', () {
    test('显式 --help 是成功路径（CI 冒烟在 set -e 下依赖它）', () async {
      expect(await runFushiServerCli(<String>['--help']), 0);
      expect(await runFushiServerCli(<String>['-h']), 0);
    });

    test('不给任何子命令 = 用法错误 64', () async {
      expect(await runFushiServerCli(<String>[]), 64);
    });

    test('无法解析的参数 = 用法错误 64', () async {
      expect(await runFushiServerCli(<String>['--no-such-flag']), 64);
    });

    test('--help 与子命令同时给出时仍只打帮助并成功返回', () async {
      // help 优先于子命令：不得因为「有 command」就去执行 serve。
      expect(await runFushiServerCli(<String>['--help', 'serve']), 0);
    });
  });

  group('远程更新的重启码', () {
    // 服务单元按退出码区分「冲突 → 停」与「装好新版 → 重启」（README：systemd
    // RestartPreventExitStatus=75、NSSM AppExit 75 Exit）。重启码一旦与别的码重合，
    // 数据目录被占的服务端就会被服务管理器无限重启。
    test('与 CLI 其它任何退出码都不同', () {
      final List<int> others = <int>[
        io.kExitOk,
        io.kExitFailure,
        io.kExitUsage,
        io.kExitDataError,
        io.kExitNoInput,
        io.kExitUnavailable,
        io.kExitConflict,
        lb.kExitDataError,
        lb.kExitTempFail,
        lb.kExitNoPerm,
        video.kExitOk,
        video.kExitFailure,
        video.kExitUsage,
        video.kExitNoInput,
        video.kExitUnavailable,
        // ctl 的 HTTP 状态映射（ctl_commands.dart `_exitCodeFor`）。
        64, 69, 75, 77,
      ];
      expect(others, isNot(contains(kExitSelfUpdated)));
      expect(io.kExitConflict, 75);
    });

    test('非零，且不落在有既定含义的区间', () {
      // 非零：systemd Restart=on-failure / NSSM 默认 / WinSW onfailure 才会拉起。
      expect(kExitSelfUpdated, isNot(0));
      // LSB 1–7、sysexits 64–78、shell 126+、systemd 自用 200+。
      expect(kExitSelfUpdated, greaterThan(7));
      expect(kExitSelfUpdated, isNot(inInclusiveRange(64, 78)));
      expect(kExitSelfUpdated, lessThan(126));
    });
  });
}
