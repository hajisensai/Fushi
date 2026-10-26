import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_cli_tasks.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/sync/plex_settings_widget.dart';
import 'package:fushi/utils.dart';

/// Plex 配置页「用 Plex 账号登录」（plex.tv PIN 授权）在控制通道上的条目。服务器
/// 列表本身是 schema 行 `services.media_server.plex` 的 cliList；这里只补 PIN 流程。
/// CLI 侧：`fushi_cli mediaserver plex-login` → 打印授权链接与 PIN →
/// `fushi_cli task get <id> --wait 60` 等结果。
List<CtlBodyPage> buildCtlPlexBodyPages() => <CtlBodyPage>[
  CtlBodyPage(
    breadcrumb: 'Plex',
    items: <SettingsItem>[
      SettingsActionItem(
        id: 'services.media_server.plex.sign_in',
        title: t.plex_account_sign_in,
        subtitle: t.plex_pin_waiting,
        onTap: (SettingsContext _) async {},
        cli: SettingsCliAction(
          params: const <SettingsCliParam>[
            SettingsCliParam(
              'open',
              help: 'true = 在本机默认浏览器里打开授权页（同设置页）；缺省只返回链接',
              required: false,
            ),
            SettingsCliParam(
              'timeout',
              help: '最多等多少秒（60…1800，缺省 600，同设置页）',
              required: false,
            ),
          ],
          run: (SettingsContext c, Map<String, String> args) async {
            final SettingsCliTask task = await startPlexAccountSignInForCli(
              c,
              openBrowser: _parseBool(args['open']),
              timeout: Duration(seconds: _parseTimeout(args['timeout'])),
            );
            return task.toJson();
          },
        ),
      ),
    ],
  ),
];

bool _parseBool(String? raw) => switch (raw?.trim().toLowerCase()) {
  null || '' || 'false' || '0' || 'no' || 'off' => false,
  'true' || '1' || 'yes' || 'on' => true,
  _ => throw ArgumentError('open 取 true / false'),
};

int _parseTimeout(String? raw) {
  if (raw == null || raw.trim().isEmpty) return 600;
  final int? seconds = int.tryParse(raw.trim());
  if (seconds == null || seconds < 60 || seconds > 1800) {
    throw ArgumentError('timeout 取 60…1800 秒');
  }
  return seconds;
}
