/// `fushi_server tracking sync|status`：Bangumi 追番同步（引擎 `MediaTrackingService`）。
///
/// **当前恒不可用**：所有者 2026-08-19 把 Bangumi 同步整体下线（引擎总开关
/// `kMediaTrackingEnabled = false`，「匹配 / 同步效果太差，先撤下」），app 的四个生产
/// 触发点都不进服务。CLI 是又一个生产触发点，同样尊重这道闸：闸关时在发任何请求
/// 之前判 69 并说明原因。装配本身是完整的（`MediaTrackingRepository(db)` +
/// 服务端偏好 + 引擎缺省 `BangumiApiClient` 经 `createAppHttpIoClient()` 出站），闸一
/// 打开即可用，不用再改这里。
///
/// 令牌：读偏好 `media_tracking_bangumi_access_token`（与 app 同键）；环境变量
/// `FUSHI_BANGUMI_TOKEN` 给了且与已存的不同时先 `connect`（校验后落盘、换号清水位）。
/// 注意：这台服务端作为互联 host 时，服务配置端点会把这枚令牌下发给已配对设备
/// （`InterconnectServiceConfigSnapshot`，引擎既有契约）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_engine/media/tracking/bangumi_api_client.dart';
import 'package:fushi_engine/media/tracking/media_tracking_repository.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/server_runtime.dart';

const int _exitOk = 0;
const int _exitFailure = 1;
const int _exitUsage = 64;
const int _exitUnavailable = 69;

/// 直接给 Bangumi 令牌的环境变量。
const String kBangumiTokenEnv = 'FUSHI_BANGUMI_TOKEN';

/// 服务端发给 Bangumi 的 User-Agent（Bangumi API 要求可识别的 UA；与 app 同形）。
const String kServerBangumiUserAgent = 'hajisensai/Fushi-Server (https://github.com/hajisensai/fushi)';

/// 一轮同步结果 → 退出码：未授权 69，有失败 1，否则 0。
int trackingSyncExitCode(MediaTrackingSyncResult r) {
  if (r.unauthorized) return _exitUnavailable;
  return r.failed > 0 ? _exitFailure : _exitOk;
}

class TrackingModule extends CliModule {
  const TrackingModule({this.out, this.err, this.env, this.enabled = kMediaTrackingEnabled, this.apiFactory});

  final StringSink? out;
  final StringSink? err;

  /// 测试注入点：环境变量 / 下线闸 / Bangumi 客户端。
  final Map<String, String>? env;
  final bool enabled;
  final BangumiApiFactory? apiFactory;

  @override
  List<String> get commands => const <String>['tracking'];

  @override
  void register(ArgParser parser) {
    final ArgParser tracking = parser.addCommand('tracking');
    tracking.addCommand('sync')
      ..addFlag('force', negatable: false, help: '忽略退避窗口，所有待发条目立刻重试')
      ..addFlag('json', negatable: false, help: '输出 JSON');
    tracking.addCommand('status').addFlag('json', negatable: false, help: '输出 JSON');
  }

  @override
  String get usage =>
      '''
tracking sync [--force] [--json] | tracking status [--json]
    Bangumi 追番同步（令牌取偏好或环境变量 $kBangumiTokenEnv）。目前该功能被所有者
    整体下线（kMediaTrackingEnabled = false），命令恒返回 69。''';

  @override
  Future<int> run(String name, ArgResults command, CliContext ctx) async {
    final StringSink o = out ?? stdout;
    final StringSink e = err ?? stderr;
    final ArgResults? sub = command.command;
    if (sub == null || (sub.name != 'sync' && sub.name != 'status')) {
      e.writeln('用法: tracking sync [--force] | tracking status');
      return _exitUsage;
    }
    if (!enabled) {
      e.writeln(
        'Bangumi 追番同步已被下线（kMediaTrackingEnabled = false，2026-08-19 所有者决定：'
        '匹配 / 同步效果太差，改好后再开放）',
      );
      return _exitUnavailable;
    }
    return ctx.withRuntime((ServerRuntime rt) async {
      final MediaTrackingService service = MediaTrackingService(
        repository: MediaTrackingRepository(rt.db),
        preferences: rt.prefs,
        userAgent: kServerBangumiUserAgent,
        apiFactory: apiFactory,
      );
      try {
        final String envToken = ((env ?? Platform.environment)[kBangumiTokenEnv] ?? '').trim();
        if (envToken.isNotEmpty && envToken != service.accessToken) {
          try {
            final BangumiUser user = await service.connect(envToken);
            e.writeln('已连接 Bangumi 账号 ${user.nickname.isEmpty ? user.username : user.nickname}');
          } on BangumiApiException catch (x) {
            e.writeln(x.isUnauthorized ? '$kBangumiTokenEnv 被 Bangumi 拒绝（令牌无效或过期）' : 'Bangumi 校验令牌失败: $x');
            return _exitUnavailable;
          }
        }
        if (sub.name == 'status') {
          final MediaTrackingStatus s = await service.loadStatus();
          final Map<String, Object?> status = <String, Object?>{
            'configured': s.configured,
            'account': s.accountName,
            'lastSyncAt': s.lastSyncAt,
            'lastSucceeded': s.lastSucceeded,
            'lastFailed': s.lastFailed,
            'unauthorized': s.unauthorized,
            'pending': s.pending,
            'mappings': s.mappings.length,
            'unlinked': s.unlinked.length,
            'failures': <Object?>[
              for (final MediaTrackingFailure f in s.failures)
                <String, Object?>{'title': f.mediaTitle, 'subjectId': f.subjectId, 'error': f.error},
            ],
          };
          if (sub['json'] as bool) {
            o.writeln(const JsonEncoder.withIndent('  ').convert(status));
          } else {
            o.writeln(s.configured ? '账号: ${s.accountName.isEmpty ? '（已配置）' : s.accountName}' : '未配置 Bangumi 令牌');
            o.writeln('待发送: ${s.pending}  已关联: ${s.mappings.length}  未关联: ${s.unlinked.length}');
          }
          return _exitOk;
        }
        if (!service.isConfigured) {
          e.writeln('没有 Bangumi 令牌：设置环境变量 $kBangumiTokenEnv（在 ${BangumiApiClient.accessTokenUrl} 生成）');
          return _exitUnavailable;
        }
        e.writeln('同步 Bangumi …');
        final MediaTrackingSyncResult r = await service.syncNow(force: sub['force'] as bool);
        final Map<String, Object?> report = <String, Object?>{
          'succeeded': r.succeeded,
          'failed': r.failed,
          'pending': r.pending,
          'unauthorized': r.unauthorized,
        };
        if (sub['json'] as bool) {
          o.writeln(jsonEncode(report));
        } else {
          o.writeln('成功 ${r.succeeded}  失败 ${r.failed}  仍待发 ${r.pending}${r.unauthorized ? '  （令牌被拒）' : ''}');
        }
        return trackingSyncExitCode(r);
      } finally {
        // 服务会在每轮收尾挂退避重试定时器；CLI 进程不常驻，必须取消，否则进程挂着不退。
        service.dispose();
      }
    });
  }
}
