/// `fushi_server tracking sync|status`：Bangumi 追番同步（引擎 `MediaTrackingService`）。
///
/// The build flag `kMediaTrackingEnabled` that kept this command offline is
/// gone (2026-11-10): in the app media tracking is now a user option (the
/// Media tracking module). The server has no modules; running this command is
/// the operator's explicit request, so it always runs. Assembly:
/// `MediaTrackingRepository(db)` + server preferences + the engine's default
/// `BangumiApiClient` going out through `createAppHttpIoClient()`.
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
import 'package:fushi_server/src/server_language.dart';
import 'package:fushi_server/src/server_runtime.dart';

const int _exitOk = 0;
const int _exitFailure = 1;
const int _exitUsage = 64;
const int _exitUnavailable = 69;

/// 直接给 Bangumi 令牌的环境变量。
const String kBangumiTokenEnv = 'FUSHI_BANGUMI_TOKEN';

/// 服务端发给 Bangumi 的 User-Agent（Bangumi API 要求可识别的 UA；与 app 同形）。
const String kServerBangumiUserAgent =
    'hajisensai/Fushi-Server (https://github.com/hajisensai/fushi)';

/// 一轮同步结果 → 退出码：未授权 69，有失败 1，否则 0。
int trackingSyncExitCode(MediaTrackingSyncResult r) {
  if (r.unauthorized) return _exitUnavailable;
  return r.failed > 0 ? _exitFailure : _exitOk;
}

class TrackingModule extends CliModule {
  const TrackingModule({
    this.out,
    this.err,
    this.env,
    this.apiFactory,
  });

  final StringSink? out;
  final StringSink? err;

  /// 测试注入点：环境变量 / Bangumi 客户端。
  final Map<String, String>? env;
  final BangumiApiFactory? apiFactory;

  @override
  List<String> get commands => const <String>['tracking'];

  @override
  void register(ArgParser parser) {
    final ArgParser tracking = parser.addCommand('tracking');
    tracking.addCommand('sync')
      ..addFlag(
        'force',
        negatable: false,
        help: tr(
          '忽略退避窗口，所有待发条目立刻重试',
          'Ignore the back-off window and retry all pending entries immediately',
        ),
      )
      ..addFlag('json', negatable: false, help: tr('输出 JSON', 'Output JSON'));
    tracking
        .addCommand('status')
        .addFlag('json', negatable: false, help: tr('输出 JSON', 'Output JSON'));
  }

  @override
  String get usage => tr(
    '''
tracking sync [--force] [--json] | tracking status [--json]
    Bangumi 追番同步（令牌取偏好或环境变量 $kBangumiTokenEnv）。''',
    '''
tracking sync [--force] [--json] | tracking status [--json]
    Bangumi tracking sync (the token comes from the preference or the environment variable $kBangumiTokenEnv).''',
  );

  @override
  Future<int> run(String name, ArgResults command, CliContext ctx) async {
    final StringSink o = out ?? stdout;
    final StringSink e = err ?? stderr;
    final ArgResults? sub = command.command;
    if (sub == null || (sub.name != 'sync' && sub.name != 'status')) {
      e.writeln(
        tr(
          '用法: tracking sync [--force] | tracking status',
          'Usage: tracking sync [--force] | tracking status',
        ),
      );
      return _exitUsage;
    }
    return ctx.withRuntime((ServerRuntime rt) async {
      final MediaTrackingService service = MediaTrackingService(
        repository: MediaTrackingRepository(rt.db),
        preferences: rt.prefs,
        userAgent: kServerBangumiUserAgent,
        apiFactory: apiFactory,
      );
      try {
        final String envToken =
            ((env ?? Platform.environment)[kBangumiTokenEnv] ?? '').trim();
        if (envToken.isNotEmpty && envToken != service.accessToken) {
          try {
            final BangumiUser user = await service.connect(envToken);
            e.writeln(
              tr(
                '已连接 Bangumi 账号 ${user.nickname.isEmpty ? user.username : user.nickname}',
                'Connected Bangumi account ${user.nickname.isEmpty ? user.username : user.nickname}',
              ),
            );
          } on BangumiApiException catch (x) {
            e.writeln(
              x.isUnauthorized
                  ? tr(
                      '$kBangumiTokenEnv 被 Bangumi 拒绝（令牌无效或过期）',
                      '$kBangumiTokenEnv was rejected by Bangumi (invalid or expired token)',
                    )
                  : tr(
                      'Bangumi 校验令牌失败: $x',
                      'Bangumi token validation failed: $x',
                    ),
            );
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
                <String, Object?>{
                  'title': f.mediaTitle,
                  'subjectId': f.subjectId,
                  'error': f.error,
                },
            ],
          };
          if (sub['json'] as bool) {
            o.writeln(const JsonEncoder.withIndent('  ').convert(status));
          } else {
            o.writeln(
              s.configured
                  ? tr(
                      '账号: ${s.accountName.isEmpty ? '（已配置）' : s.accountName}',
                      'Account: ${s.accountName.isEmpty ? '(configured)' : s.accountName}',
                    )
                  : tr('未配置 Bangumi 令牌', 'No Bangumi token configured'),
            );
            o.writeln(
              tr(
                '待发送: ${s.pending}  已关联: ${s.mappings.length}  未关联: ${s.unlinked.length}',
                'Pending: ${s.pending}  linked: ${s.mappings.length}  unlinked: ${s.unlinked.length}',
              ),
            );
          }
          return _exitOk;
        }
        if (!service.isConfigured) {
          e.writeln(
            tr(
              '没有 Bangumi 令牌：设置环境变量 $kBangumiTokenEnv（在 ${BangumiApiClient.accessTokenUrl} 生成）',
              'No Bangumi token: set the environment variable $kBangumiTokenEnv (generate one at ${BangumiApiClient.accessTokenUrl})',
            ),
          );
          return _exitUnavailable;
        }
        e.writeln(tr('同步 Bangumi …', 'Syncing Bangumi …'));
        final MediaTrackingSyncResult r = await service.syncNow(
          force: sub['force'] as bool,
        );
        final Map<String, Object?> report = <String, Object?>{
          'succeeded': r.succeeded,
          'failed': r.failed,
          'pending': r.pending,
          'unauthorized': r.unauthorized,
        };
        if (sub['json'] as bool) {
          o.writeln(jsonEncode(report));
        } else {
          o.writeln(
            tr(
              '成功 ${r.succeeded}  失败 ${r.failed}  仍待发 ${r.pending}${r.unauthorized ? '  （令牌被拒）' : ''}',
              'Succeeded ${r.succeeded}  failed ${r.failed}  still pending ${r.pending}${r.unauthorized ? '  (token rejected)' : ''}',
            ),
          );
        }
        return trackingSyncExitCode(r);
      } finally {
        // 服务会在每轮收尾挂退避重试定时器；CLI 进程不常驻，必须取消，否则进程挂着不退。
        service.dispose();
      }
    });
  }
}
