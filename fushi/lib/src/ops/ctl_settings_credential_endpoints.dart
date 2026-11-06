import 'package:flutter/services.dart' show TextInputType;

import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/ops/ctl_settings_values.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';

/// 「带凭据服务的地址」：模型（AI 助手）不可写的设置（spec §10「AI 读写凭据类设置」
/// 的延伸，2026-10-27 审查）。
///
/// 问题：qBittorrent / OPDS / 媒体服务器 / WebDAV 这类服务把密码、token 存在 app 里，
/// 地址却是普通文本项。模型（受网页 / 字幕 / 扩展描述里的提示注入）改了地址，下一次
/// 连接就把**已存的凭据**发去新地址——撤销收不回已外泄的凭据。与 AI 提供商改 baseUrl
/// 是同一类（`settings.ai.provider.update` 刻意不收 baseUrl）。
///
/// 判据只看结构，不手列：
/// - **同一配置** = 同一个面包屑（schema 的 section / 子页，或控制通道逃生口页面
///   [CtlBodyPage]）。配置里只要有一项凭据（机密文本项、带机密参数的动作），该配置里
///   名字像地址的文本项（`…url` / `…host` / `…server` / `…endpoint` / `…address` /
///   `…proxy`）就是凭据地址；
/// - **记录列表**（[SettingsCliList]）：字段里有机密字段、或所在配置有凭据（如
///   Audiobookshelf 列表本身不带密码、登录动作带）时，地址字段在修改时模型不可写
///   （新增的记录没有已存凭据，模型也填不了机密字段）；
/// - **动作**：配置里有凭据时，动作的地址参数（如「测试连接（给了地址先写入）」）同理。
///
/// 用户自己（设置页、`fushi_cli`、撤销）照常可改：路由按 [CtlCall.fromModel] 判。
/// 守卫 `test/ops/ctl_settings_credential_endpoint_guard_test.dart` 用同一份枚举。
class CtlCredentialEndpoints {
  const CtlCredentialEndpoints({
    required this.valueKeys,
    required this.listFields,
    required this.actionParams,
  });

  /// 模型不可写的值设置项 id。
  final Set<String> valueKeys;

  /// 记录列表 id → 修改时模型不可写的字段名。
  final Map<String, Set<String>> listFields;

  /// 动作 id → 模型不可给的参数名。
  final Map<String, Set<String>> actionParams;

  bool get isEmpty =>
      valueKeys.isEmpty && listFields.isEmpty && actionParams.isEmpty;
}

/// 名字像网络地址的 id 尾段 / 字段名（snake / camel / 整词）。
final RegExp _addressName = RegExp(
  r'(^|[_\-])(url|uri|host|hostname|server|endpoint|address|baseurl|proxy)s?$'
  r'|[a-z0-9](Url|Uri|Host|Server|Endpoint|Address|Proxy)s?$',
);

/// [name]（设置 id、字段名或参数名）像不像网络地址。设置 id 只看最后一段。
bool isCtlAddressName(String name) {
  final int dot = name.lastIndexOf('.');
  final String tail = dot < 0 ? name : name.substring(dot + 1);
  return _addressName.hasMatch(tail) ||
      _addressName.hasMatch(tail.toLowerCase());
}

/// 一行设置（结构视图，不求值可见性）。
typedef CtlSettingRow = ({String breadcrumb, SettingsItem item});

const int _kMaxDepth = 3;

/// 全部设置行：schema 树（含子页，深度与控制通道索引一致）+ 逃生口页面。面包屑
/// 的拼法与控制通道索引相同（只用于分组，不展示）。
List<CtlSettingRow> ctlSettingRows() {
  final List<CtlSettingRow> rows = <CtlSettingRow>[];
  void walk(SettingsDestination page, String breadcrumb, int depth) {
    for (final SettingsSection section in page.sections) {
      final String crumb = section.title == null || section.title!.isEmpty
          ? breadcrumb
          : '$breadcrumb › ${section.title}';
      for (final SettingsItem item in section.items) {
        rows.add((breadcrumb: crumb, item: item));
        if (item is SettingsNavigationItem &&
            item.child != null &&
            depth < _kMaxDepth) {
          final SettingsDestination child = item.child!();
          walk(child, '$crumb › ${child.title}', depth + 1);
        }
      }
    }
  }

  for (final SettingsDestination destination in settingsSchemaDestinations()) {
    walk(destination, destination.title, 0);
  }
  for (final CtlBodyPage page in buildCtlBodyPages()) {
    for (final SettingsItem item in page.items) {
      rows.add((breadcrumb: page.breadcrumb, item: item));
    }
  }
  return rows;
}

/// 名字不像地址、但输入框声明成 URL 键盘的文本项同样算地址。
bool _isUrlInput(SettingsItem item) =>
    item is SettingsTextItem && item.keyboardType == TextInputType.url;

bool _isCredentialRow(SettingsItem item) => switch (item) {
  SettingsTextItem() => isCtlSecretSetting(
    item.id,
    declaredSecret: item.secret,
  ),
  SettingsActionItem(cli: final SettingsCliAction? cli) =>
    cli?.params.any((SettingsCliParam p) => p.secret) ?? false,
  SettingsCustomItem(cliList: final SettingsCliList? list) =>
    list?.fields.any((SettingsCliParam p) => p.secret) ?? false,
  _ => false,
};

/// 按结构判定（见类文档）。纯函数：输入换成别的行集合（测试）同样成立。
CtlCredentialEndpoints classifyCtlCredentialEndpoints(
  Iterable<CtlSettingRow> rows,
) {
  final Map<String, List<SettingsItem>> groups = <String, List<SettingsItem>>{};
  for (final CtlSettingRow row in rows) {
    (groups[row.breadcrumb] ??= <SettingsItem>[]).add(row.item);
  }
  final Set<String> valueKeys = <String>{};
  final Map<String, Set<String>> listFields = <String, Set<String>>{};
  final Map<String, Set<String>> actionParams = <String, Set<String>>{};
  for (final List<SettingsItem> items in groups.values) {
    final bool hasCredential = items.any(_isCredentialRow);
    for (final SettingsItem item in items) {
      switch (item) {
        case SettingsCustomItem(cliList: final SettingsCliList list):
          if (hasCredential ||
              list.fields.any((SettingsCliParam p) => p.secret)) {
            final Set<String> fields = <String>{
              for (final SettingsCliParam p in list.fields)
                if (!p.secret && isCtlAddressName(p.name)) p.name,
            };
            if (fields.isNotEmpty) listFields[item.id] = fields;
          }
        case SettingsActionItem(cli: final SettingsCliAction cli)
            when hasCredential:
          final Set<String> params = <String>{
            for (final SettingsCliParam p in cli.params)
              if (!p.secret && isCtlAddressName(p.name)) p.name,
          };
          if (params.isNotEmpty) actionParams[item.id] = params;
        case SettingsTextItem() || SettingsCustomItem()
            when hasCredential &&
                !_isCredentialRow(item) &&
                (isCtlAddressName(item.id) || _isUrlInput(item)):
          if (item is SettingsTextItem ||
              (item is SettingsCustomItem && item.cliValue != null)) {
            valueKeys.add(item.id);
          }
        default:
          break;
      }
    }
  }
  return CtlCredentialEndpoints(
    valueKeys: valueKeys,
    listFields: listFields,
    actionParams: actionParams,
  );
}

CtlCredentialEndpoints? _cached;

/// 当前 app 的凭据地址集合（结构不随运行期变，算一次）。
CtlCredentialEndpoints ctlCredentialEndpoints() =>
    _cached ??= classifyCtlCredentialEndpoints(ctlSettingRows());
