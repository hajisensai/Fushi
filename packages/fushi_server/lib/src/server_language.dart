/// 服务端面向人的输出（CLI 帮助 / 提示 / 错误、日志、admin API 错误文案）用哪种语言。
///
/// 进程级一份：CLI 入口在建参数解析器之前按 [resolveServerLanguage] 定下来（帮助文案
/// 建 parser 时就要用），WebUI 改了配置里的 `language` 时 [AdminContext.updateConfig]
/// 再设一次。文案就地写成双语 `tr('中文', 'English')`，不另建键表。
library;

import 'dart:io';

import 'package:fushi_server/src/config/server_config.dart';

/// 环境变量覆盖：`FUSHI_LANGUAGE=zh|en`，优先于配置文件（容器 / 一次性命令用）。
const String kServerLanguageEnv = 'FUSHI_LANGUAGE';

String _serverLanguage = ServerConfig.defaultLanguage;

/// 当前输出语言（`en` / `zh`）。
String get serverLanguage => _serverLanguage;

/// 设输出语言；不认识的值回落默认（英文），不抛——这里只管显示。
set serverLanguage(String value) {
  final String v = value.trim().toLowerCase();
  _serverLanguage = ServerConfig.supportedLanguages.contains(v)
      ? v
      : ServerConfig.defaultLanguage;
}

/// 按当前语言二选一。
String tr(String zh, String en) =>
    _serverLanguage == ServerConfig.languageChinese ? zh : en;

final RegExp _languageLine = RegExp(
  r'''^language:\s*["']?([A-Za-z]+)["']?\s*(?:#.*)?$''',
  multiLine: true,
);

/// 定 CLI 的输出语言：`FUSHI_LANGUAGE` > 配置文件里的 `language`（文件在但没写这一行
/// = 旧配置，按 [ServerConfig.legacyLanguage]）> 默认英文（还没有配置文件，如 `init`）。
///
/// 在参数解析之前调用，所以自己从 [args] 里找 `--config` / `-c`（缺省
/// [defaultConfigFileName]），只读 `language:` 一行：配置文件不存在、读不了或写坏了
/// 都不影响这里，后面真正加载配置时再报错（那条报错也就按这里定的语言出）。
String resolveServerLanguage(
  List<String> args, {
  required String defaultConfigFileName,
  Map<String, String>? environment,
}) {
  final Map<String, String> env = environment ?? Platform.environment;
  final String fromEnv = (env[kServerLanguageEnv] ?? '').trim().toLowerCase();
  if (ServerConfig.supportedLanguages.contains(fromEnv)) return fromEnv;
  final String path = _configPathFromArgs(args) ?? defaultConfigFileName;
  try {
    final File file = File(path);
    if (file.existsSync()) {
      final Match? m = _languageLine.firstMatch(file.readAsStringSync());
      if (m == null) return ServerConfig.legacyLanguage; // 加这个键之前的旧配置
      final String v = m.group(1)!.toLowerCase();
      if (ServerConfig.supportedLanguages.contains(v)) return v;
    }
  } on FileSystemException {
    // 读不了就用默认；真正的加载会报错。
  }
  return ServerConfig.defaultLanguage;
}

String? _configPathFromArgs(List<String> args) {
  for (int i = 0; i < args.length; i++) {
    final String a = args[i];
    if (a == '--') return null;
    if (a == '--config' || a == '-c') {
      return i + 1 < args.length ? args[i + 1] : null;
    }
    if (a.startsWith('--config=')) return a.substring('--config='.length);
    if (a.startsWith('-c') && a.length > 2 && !a.startsWith('--')) {
      return a.substring(2);
    }
  }
  return null;
}
