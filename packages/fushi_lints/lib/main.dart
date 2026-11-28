import 'package:analysis_server_plugin/plugin.dart';
import 'package:analysis_server_plugin/registry.dart';

import 'src/rules.dart';

/// analysis_server_plugin 的入口：分析服务器按 `analysis_options.yaml` 顶层
/// `plugins:` 段加载本包，读这个顶层变量。
final FushiLintsPlugin plugin = FushiLintsPlugin();

class FushiLintsPlugin extends Plugin {
  @override
  String get name => 'fushi_lints';

  @override
  void register(PluginRegistry registry) {
    // 一律注册成 warning 规则：启用插件即生效，不需要在各包 diagnostics 段里
    // 逐条打开，`flutter analyze` 见到就非零退出。
    for (final rule in fushiRules()) {
      registry.registerWarningRule(rule);
    }
  }
}
