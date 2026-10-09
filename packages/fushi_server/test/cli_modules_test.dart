/// 命令模块登记守卫：模块的命令名不能与内建命令或彼此重名，否则 ArgParser
/// 登记时直接抛错（整个 CLI 起不来），或分发落到错误的模块。
library;

import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/cli_modules.dart';
import 'package:fushi_server/src/cli.dart';
import 'package:test/test.dart';

const Set<String> _builtins = <String>{
  'init', 'serve', 'scan', 'status', 'pair', 'admin', 'models', 'transcribe', 'ctl', //
};

void main() {
  test('模块命令名唯一且不撞内建命令', () {
    final Set<String> seen = <String>{..._builtins};
    for (final CliModule module in kCliModules) {
      for (final String name in module.commands) {
        expect(seen.add(name), isTrue, reason: '命令名 "$name" 重复（${module.runtimeType}）');
      }
    }
  });

  test('所有模块登记后 --help 仍是成功路径', () async {
    expect(await runFushiServerCli(<String>['--help']), 0);
  });
}
