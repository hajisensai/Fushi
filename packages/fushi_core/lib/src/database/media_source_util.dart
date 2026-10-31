// TODO-817 / TODO-1274 网络/本地来源库纯函数工具：路径归一化、默认显示名、
// 来源连接配置编解码。
//
// 🔴 凭据红线：本文件的 config 编解码 **绝不裸存明文密码**。本地来源 config 只在
// iOS 上带一条安全作用域书签（[kSourceConfigIosBookmarkKey]，见下），其余平台恒空；
// 网络来源（SFTP/FTP）的 configJson 只存**非敏感连接参数**（host/port/username/useTls），
// 密码/私钥经 SourceLibraryCredentialStore 以 base64 单独落 Preferences（键
// `media_source_secret_<id>`），绝不进入 configJson。[encodeSourceConfig] 以允许键
// 白名单强制这条红线：即使调用方误传 password/privateKey 也会被丢弃。

import 'dart:convert';

/// 归一化来源根路径：
/// - 本地（transport=='local'）：统一正斜杠分隔符、去掉末尾斜杠（盘符根如 `C:/` 保留）。
/// - 网络（sftp/ftp/http）：保 scheme 原样，仅去末尾斜杠（不动 scheme 后的 `//`）。
///
/// 纯函数，不触磁盘、不做 I/O；空串原样返回。
String normalizeSourceRootPath(String raw, {required String transport}) {
  if (raw.isEmpty) {
    return raw;
  }
  final bool isLocal = transport == 'local';
  // 本地统一分隔符为正斜杠；网络保 scheme（含 `://`）。
  String result = isLocal ? raw.replaceAll(r'\', '/') : raw;

  // 去末尾斜杠，但保留：
  // - 盘符根 `C:/` 的尾斜杠（去掉会变成裸盘符 `C:`，语义不同）。
  // - 单个 `/`（POSIX 根）。
  while (result.length > 1 && result.endsWith('/')) {
    final String trimmed = result.substring(0, result.length - 1);
    // 盘符根：trimmed 形如 `C:` → 还原尾斜杠并停。
    if (trimmed.length == 2 && trimmed.endsWith(':')) {
      break;
    }
    result = trimmed;
  }
  return result;
}

/// 取归一化后路径的末段作为默认显示名（文件夹名）。
/// - 末段为空（如根路径）时回退整段。
/// - 纯函数，不触磁盘。
String defaultLabelFromRoot(String rootPath, {required String transport}) {
  final String normalized = normalizeSourceRootPath(
    rootPath,
    transport: transport,
  );
  if (normalized.isEmpty) {
    return normalized;
  }
  final int slash = normalized.lastIndexOf('/');
  if (slash < 0) {
    return normalized;
  }
  final String last = normalized.substring(slash + 1);
  return last.isEmpty ? normalized : last;
}

/// [encodeSourceConfig] / [decodeSourceConfig] 允许持久化到 configJson 的
/// **非敏感**连接参数键。password / privateKey 绝不在此列（凭据红线）。
const Set<String> kSourceConfigAllowedKeys = <String>{
  'host',
  'port',
  'username',
  'useTls',
  // AList / OpenList 站点根（`https://od.example.com`）；非敏感，条目地址由它派生。
  'baseUrl',
  kSourceConfigIosBookmarkKey,
};

/// iOS 本地来源的安全作用域书签（`URL.bookmarkData()` 的 base64）所在的 configJson 键。
///
/// 为什么能进 configJson（凭据红线不变）：书签不是口令——它只是「用户在系统文件
/// 选择器里亲手选过这个文件夹」这件事的凭证，只对**本 app、本设备**有效，换设备 /
/// 卸载重装即失效，用户删掉文件夹或撤销授权也失效；泄露出去别的进程用不了。所以它
/// 与 host/port 同属「来源怎么连」的非敏感参数，而**不**与密码 / 私钥混放（那两样
/// 仍只在 SourceLibraryCredentialStore）。iOS 上没有它，沙盒外文件夹 `dart:io` 一个
/// 字节都读不到（BUG-2786）；其它平台从不写这个键。
const String kSourceConfigIosBookmarkKey = 'iosBookmark';

/// 取 configJson 里的 iOS 安全作用域书签；没有 / 空串 / 非字符串 → null。
String? sourceBookmarkFromConfig(String? configJson) {
  final Object? value = decodeSourceConfig(
    configJson,
  )[kSourceConfigIosBookmarkKey];
  return value is String && value.isNotEmpty ? value : null;
}

/// 把 [bookmark] 写进（或替换）configJson 里的书签键，其余已有键原样保留；
/// 结果仍经 [encodeSourceConfig] 的白名单。
String? configWithSourceBookmark(String? configJson, String bookmark) =>
    encodeSourceConfig(<String, Object?>{
      ...decodeSourceConfig(configJson),
      kSourceConfigIosBookmarkKey: bookmark,
    });

/// 把来源连接参数编码为 configJson 字符串。
///
/// 🔴 凭据红线：只保留 [kSourceConfigAllowedKeys] 中的非敏感键；任何
/// password/privateKey/未知键都被丢弃，绝不写入 configJson。空配置（本地来源或
/// 无可持久化字段）返回 null。
String? encodeSourceConfig(Map<String, Object?> config) {
  final Map<String, Object?> safe = <String, Object?>{};
  for (final MapEntry<String, Object?> entry in config.entries) {
    if (!kSourceConfigAllowedKeys.contains(entry.key)) {
      continue; // 丢弃敏感/未知键（凭据红线）。
    }
    if (entry.value == null) {
      continue;
    }
    safe[entry.key] = entry.value;
  }
  if (safe.isEmpty) {
    return null; // 本地来源 / 空配置 → NULL。
  }
  return jsonEncode(safe);
}

/// 把 configJson 字符串解码为来源连接参数 Map。
///
/// null / 空串 / 非法 JSON / 非对象顶层都回退空 Map。
Map<String, Object?> decodeSourceConfig(String? configJson) {
  if (configJson == null || configJson.isEmpty) {
    return <String, Object?>{};
  }
  try {
    final Object? decoded = jsonDecode(configJson);
    if (decoded is Map) {
      return decoded.map<String, Object?>(
        (Object? key, Object? value) =>
            MapEntry<String, Object?>(key.toString(), value),
      );
    }
  } catch (_) {
    // 非法 JSON：回退空 Map。
  }
  return <String, Object?>{};
}
