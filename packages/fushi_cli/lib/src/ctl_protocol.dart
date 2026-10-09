/// 本机控制通道的线协议。
///
/// 路径沿用 `fushi_server` 管理 API 的 `/api/admin/*` 形态，鉴权同为
/// `Authorization: Bearer <token>`：两边都有的能力用同一套路由，以后同一个 CLI
/// 加 `--server <url>` 就能管服务端。桌面独有（要界面）的动作放在 `/api/admin/app/*`。
library;

const String kCtlStatusPath = '/api/admin/status';
const String kCtlOpenPath = '/api/admin/app/open';
const String kCtlLookupPath = '/api/admin/app/lookup';
const String kCtlQuitPath = '/api/admin/app/quit';

/// 409：app 进程已起、控制通道已开，但还没初始化完（LoadingPage）。CLI 应继续等。
const String kCtlErrorNotReady = 'not_ready';
const String kCtlErrorUnauthorized = 'unauthorized';
const String kCtlErrorBadRequest = 'bad_request';

/// 422：目标被 app 拒绝（不支持的类型 / 文件不存在 / 模块关闭）。
const String kCtlErrorRejected = 'rejected';

/// `status` 的应答。
class CtlAppStatus {
  const CtlAppStatus({
    required this.pid,
    required this.platform,
    required this.initialised,
    this.version,
  });

  final int pid;
  final String platform;

  /// AppModel 初始化完成且主导航已就绪；为 false 时 open / lookup 回 409。
  final bool initialised;
  final String? version;

  Map<String, Object?> toJson() => <String, Object?>{
    'app': 'fushi',
    'kind': 'desktop',
    'pid': pid,
    'platform': platform,
    'initialised': initialised,
    if (version != null) 'version': version,
  };

  static CtlAppStatus fromJson(Map<String, Object?> json) => CtlAppStatus(
    pid: (json['pid'] as num?)?.toInt() ?? 0,
    platform: json['platform'] as String? ?? '',
    initialised: json['initialised'] == true,
    version: json['version'] as String?,
  );
}

/// `open` 接受的目标种类——与 argv / 单实例转交认的候选一一对应。
enum CtlOpenKind {
  video,
  lookup,
  pairLink,
  sourceUrl;

  String get wireName => switch (this) {
    CtlOpenKind.video => 'video',
    CtlOpenKind.lookup => 'lookup',
    CtlOpenKind.pairLink => 'pair_link',
    CtlOpenKind.sourceUrl => 'source_url',
  };

  static CtlOpenKind? fromWire(String? value) {
    for (final CtlOpenKind kind in CtlOpenKind.values) {
      if (kind.wireName == value) return kind;
    }
    return null;
  }
}

/// app 对 `open` 的裁决：接受（带种类）或拒绝（带原因）。
class CtlOpenResult {
  const CtlOpenResult.accepted(CtlOpenKind this.kind) : reason = null;
  const CtlOpenResult.rejected(String this.reason) : kind = null;

  final CtlOpenKind? kind;
  final String? reason;

  bool get accepted => kind != null;
}
