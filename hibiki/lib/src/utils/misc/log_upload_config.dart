/// 日志上传端点配置。真实值在构建时通过 --dart-define 注入，不入库：
///   flutter build apk \
///     --dart-define=HIBIKI_LOG_ENDPOINT=https://logs.example.com/api/logs \
///     --dart-define=HIBIKI_LOG_TOKEN=<上传token>
/// 未注入时两常量为空串 → 上传按钮自动隐藏，fresh clone 即可编译。
const String kLogUploadEndpoint = String.fromEnvironment('HIBIKI_LOG_ENDPOINT');
const String kLogUploadToken = String.fromEnvironment('HIBIKI_LOG_TOKEN');

/// 上传单条日志的请求体字节硬上限（与源站/EO 各自上限呼应）。
const int kMaxLogUploadBytes = 512 * 1024;

/// 端点是否已配置成可上传的 http(s) 地址（纯函数，便于测试门控）。
bool isLogUploadConfigured(String endpoint) {
  final String e = endpoint.trim();
  return e.startsWith('https://') || e.startsWith('http://');
}

/// 当前构建是否展示「上传」按钮。
bool get showUploadLogAction => isLogUploadConfigured(kLogUploadEndpoint);
