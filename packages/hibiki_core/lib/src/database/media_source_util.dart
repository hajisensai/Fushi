// TODO-817 网络/本地来源库纯函数工具：路径归一化、默认显示名、来源配置编解码。
//
// 🔴 凭据红线：本文件的 config 编解码 **绝不裸存明文密码**。M0 本地来源 config 恒空，
// 网络来源（M3 才接入）只存凭据「引用（键）」而非密码本体；密码存储方案（复用 base64
// vs 真 secure storage）是 M3 用户决策点，不在 M0 预判，故此处只建签名 + 空实现 + 占位
// 测试，不写任何持久化逻辑。

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
  final String normalized =
      normalizeSourceRootPath(rootPath, transport: transport);
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

/// 来源配置（凭据引用 / 网络参数）编码为 configJson 字符串。
///
/// 🔴 M0 占位：本地来源恒返回 null（不存任何配置）。网络配置 + 凭据引用的真实编码
/// 在 M3 实现，且 **绝不裸存明文密码**——只存引用键。M0 不预判存储方案（A/B 留 M3）。
String? encodeSourceConfig(Map<String, Object?> config) {
  // M0：空实现。不持久化任何明文凭据。
  return null;
}

/// 把 configJson 字符串解码为来源配置 Map。
///
/// 🔴 M0 占位：恒返回空 Map（本地来源无配置）。真实解码 M3 实现。
Map<String, Object?> decodeSourceConfig(String? configJson) {
  // M0：空实现。
  return <String, Object?>{};
}
