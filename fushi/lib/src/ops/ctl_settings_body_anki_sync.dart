import 'package:fushi_engine/anki_sync/anki_sync_session.dart';

import 'package:fushi/src/anki/sync_client/anki_sync_client_actions.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

/// Anki 设置页「Anki 同步（无需安装 Anki）」节在控制通道上的条目：切后端、
/// 登录（密码只经 stdin / 环境变量，不回显）、退出、立即同步、状态。动作与设置节
/// 共用 `anki_sync_client_actions.dart`。本机没有 `fushi-anki-sync` 时整页不可见。
///
/// CLI 侧：`fushi_cli anki sync-status | sync-login | sync-logout`，立即同步沿用
/// `fushi_cli anki sync`。
List<CtlBodyPage> buildCtlAnkiSyncBodyPages() => <CtlBodyPage>[
  CtlBodyPage(
    breadcrumb: t.anki_sync_client_section_title,
    visible: (SettingsContext c) => ankiSyncClientSessionOf(c.ref) != null,
    items: <SettingsItem>[
      SettingsSwitchItem(
        id: 'card_creation.anki.sync_client.enabled',
        title: t.anki_sync_client_use_title,
        subtitle: t.anki_sync_client_use_hint,
        value: (SettingsContext c) =>
            c.appModel.platformServices.useAnkiSyncClient,
        onChanged: (SettingsContext c, bool value) =>
            setAnkiSyncClientEnabled(c.ref, value),
        defaultValue: false,
      ),
      _action(
        id: 'card_creation.anki.sync_client.status',
        title: t.anki_sync_client_section_title,
        cli: SettingsCliAction(
          run: (SettingsContext c, Map<String, String> _) async {
            final AnkiSyncSession session = _session(c);
            return ankiSyncClientStatusJson(
              await session.refresh(),
              await session.account(),
              enabled: c.appModel.platformServices.useAnkiSyncClient,
            );
          },
        ),
      ),
      _action(
        id: 'card_creation.anki.sync_client.sign_in',
        title: t.anki_sync_client_sign_in,
        cli: SettingsCliAction(
          params: const <SettingsCliParam>[
            SettingsCliParam(
              'server',
              help: '自建同步服务器根地址；省略 = AnkiWeb（需 accept_ankiweb=true）',
              required: false,
            ),
            SettingsCliParam('username', help: '用户名'),
            SettingsCliParam(
              'password',
              help: '密码（只经 --secret-stdin / --secret-from-env；登录换回密钥后即丢弃）',
              secret: true,
            ),
            SettingsCliParam(
              'accept_ankiweb',
              help:
                  'true = 已知晓 AnkiWeb 条款只允许官方客户端同步（同设置页的确认框）；'
                  '登录 AnkiWeb 时必填',
              required: false,
            ),
          ],
          run: (SettingsContext c, Map<String, String> args) async {
            final AnkiSyncSession session = _session(c);
            final String server = (args['server'] ?? '').trim();
            final String? endpoint = server.isEmpty ? null : server;
            if (endpoint == null && args['accept_ankiweb'] != 'true') {
              throw ArgumentError(
                '${t.anki_sync_client_ankiweb_body}\n'
                '确认要登录 AnkiWeb 请加 --arg accept_ankiweb=true',
              );
            }
            final String username = (args['username'] ?? '').trim();
            final String password = args['password'] ?? '';
            if (username.isEmpty || password.isEmpty) {
              throw ArgumentError('用户名与密码不能为空');
            }
            try {
              await signInAnkiSyncClient(
                c.ref,
                session,
                endpoint: endpoint,
                username: username,
                password: password,
              );
            } on AnkiSyncHasUnsyncedNotes catch (e) {
              throw StateError(t.anki_sync_client_has_unsynced(count: e.count));
            }
            return ankiSyncClientStatusJson(
              session.state,
              await session.account(),
              enabled: c.appModel.platformServices.useAnkiSyncClient,
            );
          },
        ),
      ),
      _action(
        id: 'card_creation.anki.sync_client.sign_out',
        title: t.anki_sync_client_sign_out,
        cli: SettingsCliAction(
          run: (SettingsContext c, Map<String, String> _) async {
            final AnkiSyncSession session = _session(c);
            try {
              await session.signOut();
            } on AnkiSyncHasUnsyncedNotes catch (e) {
              // 同设置节：退出会丢掉这些卡，必须显式确认放弃。
              throw StateError(
                '${t.anki_sync_client_discard_confirm(count: e.count)}'
                '（确认放弃用 card_creation.anki.sync_client.sign_out_discard --yes）',
              );
            }
            return ankiSyncClientStatusJson(
              session.state,
              await session.account(),
              enabled: c.appModel.platformServices.useAnkiSyncClient,
            );
          },
        ),
      ),
      _action(
        id: 'card_creation.anki.sync_client.sign_out_discard',
        title: t.anki_sync_client_discard_action,
        destructive: true,
        cli: SettingsCliAction(
          confirm: true,
          run: (SettingsContext c, Map<String, String> _) async {
            final AnkiSyncSession session = _session(c);
            await session.signOut(discardUnsynced: true);
            return ankiSyncClientStatusJson(
              session.state,
              await session.account(),
              enabled: c.appModel.platformServices.useAnkiSyncClient,
            );
          },
        ),
      ),
      _action(
        id: 'card_creation.anki.sync_client.sync_now',
        title: t.anki_sync_client_sync_now,
        cli: SettingsCliAction(
          run: (SettingsContext c, Map<String, String> _) async {
            final AnkiSyncSession session = _session(c);
            try {
              return ankiSyncClientStatusJson(
                await session.syncNow(),
                await session.account(),
                enabled: c.appModel.platformServices.useAnkiSyncClient,
              );
            } on AnkiSyncNotSignedIn {
              throw StateError('Anki 同步客户端未登录（先 sign_in）');
            }
          },
        ),
      ),
    ],
  ),
];

AnkiSyncSession _session(SettingsContext c) {
  final AnkiSyncSession? session = ankiSyncClientSessionOf(c.ref);
  if (session == null) {
    throw StateError('本机没有内置 Anki 同步客户端（fushi-anki-sync）');
  }
  return session;
}

/// 状态 + 账号（只有服务器与用户名；密钥 hkey 永不出现在应答里）。
Map<String, Object?> ankiSyncClientStatusJson(
  AnkiSyncState state,
  AnkiSyncAccount? account, {
  required bool enabled,
}) => <String, Object?>{
  'enabled': enabled,
  'signedIn': account != null,
  if (account != null) 'username': account.username,
  if (account != null) 'server': account.server ?? 'AnkiWeb',
  'phase': state.phase.name,
  'unsynced': state.unsynced,
  'failing': state.failing,
  if (state.lastSyncAt != null) 'lastSyncAt': state.lastSyncAt,
  if (state.lastError != null) 'lastError': state.lastError,
  if (state.message != null) 'message': state.message,
};

SettingsActionItem _action({
  required String id,
  required String title,
  required SettingsCliAction cli,
  bool destructive = false,
}) => SettingsActionItem(
  id: id,
  title: title,
  destructive: destructive,
  cli: cli,
  onTap: (SettingsContext _) async {},
);
