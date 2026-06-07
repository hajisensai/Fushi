// 日志上传配置。端点/token 的默认空值入库在 `log_upload_secret.dart`（保证可编译）；
// 真值只在本机填该文件并 `git update-index --skip-worktree` 隐藏，不入库。
// 端点留空则「上传」按钮自动隐藏。
import 'package:hibiki/src/utils/misc/log_upload_secret.dart';

export 'package:hibiki/src/utils/misc/log_upload_secret.dart'
    show kLogUploadEndpoint, kLogUploadToken;

/// 上传单条日志的请求体字节硬上限（与接收端/边缘各自上限呼应）。
const int kMaxLogUploadBytes = 512 * 1024;

/// 端点是否已配置成可上传的 http(s) 地址（纯函数，便于测试门控）。
bool isLogUploadConfigured(String endpoint) {
  final String e = endpoint.trim();
  return e.startsWith('https://') || e.startsWith('http://');
}

/// 当前构建是否展示「上传」按钮（端点已配置才显示）。
bool get showUploadLogAction => isLogUploadConfigured(kLogUploadEndpoint);
