import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/widgets.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_sessions.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/media_search_text.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_settings_ai_routes.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/ops/ctl_settings_credential_endpoints.dart';
import 'package:fushi/src/ops/ctl_settings_model_routes.dart';
import 'package:fushi/src/ops/ctl_settings_task_routes.dart';
import 'package:fushi/src/ops/ctl_settings_values.dart';
import 'package:fushi/src/ops/ctl_settings_wire.dart';
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/profile/language_binding.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/settings/settings_actions.dart'
    show notifyReaderSettingsChanged;
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_kit.dart'
    show SettingsResetSpec, settingsResetSpecFor;
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';
import 'package:fushi/src/shortcuts/shortcut_preferences.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/stats/study_diag_export.dart';
import 'package:fushi/src/utils/fushi_localisations.dart';
import 'package:fushi/src/utils/misc/build_version.dart';

/// settings 域控制通道路由（CLI 侧命令见 `packages/fushi_cli/lib/src/commands/settings_commands.dart`）。
///
/// - `/api/admin/settings`：设置项读写。键 = 设置 schema 的条目 id，值的读写
///   **直接调该条目在设置页里的 value / onChanged 闭包**，与在设置页拨开关、拖
///   滑条等价（同一个 AppModel setter + 同一套联动通知）；`reset` 走详情页「恢复
///   默认」同一个 `settingsResetSpecFor`，`run` 调动作行 / 状态行按钮的同一个
///   onTap / onAction；
/// - `/api/admin/modules`：功能模块开关与底栏顺序（`AppModel.setModuleEnabled` /
///   `setModuleOrder`）；
/// - `/api/admin/profiles`：Profile 管理与媒体类型 / 语言绑定（`ProfileViewModel`，
///   与配置管理页同一组方法）；
/// - `/api/admin/stats`：学习统计（只经 `loadStatFacts` + `StatWindow`）；
/// - `/api/admin/shortcuts`：快捷键绑定读写（`AppModel.shortcutRegistry` +
///   `saveShortcutRegistry`，与快捷键设置页同一条写穿路径）；
/// - `/api/admin/ai/*`、`/api/admin/models/*`、`/api/admin/voices/*`：见
///   `ctl_settings_ai_routes.dart` / `ctl_settings_model_routes.dart`。
List<CtlRoute> buildSettingsCtlRoutes(OpContext context) => <CtlRoute>[
  CtlRoute.get(
    '/api/admin/settings',
    (CtlCall call) => _listSettings(context, call),
  ),
  CtlRoute.get(
    '/api/admin/settings/:key',
    (CtlCall call) => _getSetting(context, call),
  ),
  CtlRoute.put(
    '/api/admin/settings/:key',
    (CtlCall call) => _setSetting(context, call),
  ),
  CtlRoute.get('/api/admin/modules', (CtlCall call) => _listModules(context)),
  CtlRoute.put(
    '/api/admin/modules/:id',
    (CtlCall call) => _setModule(context, call),
  ),
  CtlRoute.get('/api/admin/profiles', (CtlCall call) => _listProfiles(context)),
  CtlRoute.post(
    '/api/admin/profiles',
    (CtlCall call) => _createProfile(context, call),
  ),
  CtlRoute.post(
    '/api/admin/profiles/import',
    (CtlCall call) => _importProfile(context, call),
  ),
  CtlRoute.post(
    '/api/admin/profiles/:id/activate',
    (CtlCall call) => _activateProfile(context, call),
  ),
  CtlRoute.put(
    '/api/admin/profiles/:id',
    (CtlCall call) => _renameProfile(context, call),
  ),
  CtlRoute.post(
    '/api/admin/profiles/:id/copy',
    (CtlCall call) => _copyProfile(context, call),
  ),
  CtlRoute.delete(
    '/api/admin/profiles/:id',
    (CtlCall call) => _deleteProfile(context, call),
  ),
  CtlRoute.post(
    '/api/admin/profiles/:id/export',
    (CtlCall call) => _exportProfile(context, call),
  ),
  CtlRoute.get(
    '/api/admin/stats',
    (CtlCall call) => _statsSummary(context, call),
  ),
  CtlRoute.get(
    '/api/admin/stats/sessions',
    (CtlCall call) => _statsSessions(context, call),
  ),
  CtlRoute.post(
    '/api/admin/stats/export',
    (CtlCall call) => _statsExport(context, call),
  ),
  CtlRoute.get(
    '/api/admin/shortcuts',
    (CtlCall call) => _listShortcuts(context, call),
  ),
  CtlRoute.put(
    '/api/admin/shortcuts/:action',
    (CtlCall call) => _setShortcut(context, call),
  ),
  CtlRoute.post(
    '/api/admin/shortcuts/:action/unbind',
    (CtlCall call) => _unbindShortcut(context, call),
  ),
  CtlRoute.post(
    '/api/admin/shortcuts/reset',
    (CtlCall call) => _resetShortcuts(context, call),
  ),
  CtlRoute.post(
    '/api/admin/settings/:key/reset',
    (CtlCall call) => _resetSetting(context, call),
  ),
  CtlRoute.post(
    '/api/admin/settings/:key/run',
    (CtlCall call) => _runSetting(context, call),
  ),
  CtlRoute.get(
    '/api/admin/settings/:key/items',
    (CtlCall call) => _listSettingItems(context, call),
  ),
  CtlRoute.post(
    '/api/admin/settings/:key/items',
    (CtlCall call) => _addSettingItem(context, call),
  ),
  CtlRoute.put(
    '/api/admin/settings/:key/items/:id',
    (CtlCall call) => _updateSettingItem(context, call),
  ),
  CtlRoute.delete(
    '/api/admin/settings/:key/items/:id',
    (CtlCall call) => _removeSettingItem(context, call),
  ),
  CtlRoute.post(
    '/api/admin/modules/order',
    (CtlCall call) => _setModuleOrder(context, call),
  ),
  CtlRoute.get(
    '/api/admin/profiles/bindings',
    (CtlCall call) => _listProfileBindings(context),
  ),
  CtlRoute.put(
    '/api/admin/profiles/bindings/:scope/:key',
    (CtlCall call) => _setProfileBinding(context, call),
  ),
  ...buildSettingsAiCtlRoutes(context),
  ...buildSettingsModelCtlRoutes(context),
  ...buildSettingsTaskCtlRoutes(),
];

// ── 设置项 ──────────────────────────────────────────────────────────────────

/// 设置宿主上下文：与设置页同形（readerSource 单例），refresh 为空——CLI 没有
/// 要重建的设置页；设置项自己的联动（notifyListeners / 阅读器重注入）照常发生。
SettingsContext _settingsContext(OpContext context) {
  final BuildContext? buildContext =
      context.appModel.navigatorKey.currentContext;
  if (buildContext == null) {
    throw const CtlFailure.conflict('主窗口尚未就绪，稍后再试');
  }
  return SettingsContext(
    context: buildContext,
    appModel: context.appModel,
    ref: context.ref,
    readerSource: ReaderFushiSource.instance,
    refresh: () {},
  );
}

/// 自绘行（主题 / 明暗 / 界面语言）没有 schema 值闭包；这里按自绘行里的同一组
/// AppModel 读写方法补上，键沿用该行的 schema id。
class _VirtualSetting {
  const _VirtualSetting({
    required this.read,
    required this.options,
    required this.write,
  });

  final String Function(AppModel appModel) read;
  final List<(String, String)> Function(AppModel appModel) options;
  final Future<void> Function(SettingsContext context, String value) write;
}

final Map<String, _VirtualSetting> _virtualSettings = <String, _VirtualSetting>{
  // buildDesignSystemSelector（settings_actions.dart）：只开放设置页列出的三档，
  // Apple 等隐藏值由 ThemeNotifier 在写入边界归一化。
  'appearance.design_system': _VirtualSetting(
    read: (AppModel appModel) => appModel.themeNotifier.designSystem,
    options: (AppModel _) => const <(String, String)>[
      ('auto', 'auto'),
      ('material', 'Material'),
      ('glass', 'glass'),
    ],
    write: (SettingsContext context, String value) =>
        context.appModel.themeNotifier.setDesignSystem(value),
  ),
  // buildBrightnessSelector（settings_actions.dart）。
  'appearance.brightness': _VirtualSetting(
    read: (AppModel appModel) => appModel.brightnessMode,
    options: (AppModel _) => const <(String, String)>[
      ('light', 'light'),
      ('system', 'system'),
      ('dark', 'dark'),
    ],
    write: (SettingsContext context, String value) async {
      await context.appModel.setBrightnessMode(value);
      notifyReaderSettingsChanged(context);
    },
  ),
  // buildThemeSelector：系统色 / 预设 / 自定义主题 swatch。
  'appearance.theme': _VirtualSetting(
    read: (AppModel appModel) => appModel.appThemeKey,
    options: (AppModel appModel) => <(String, String)>[
      ('system-theme', 'system-theme'),
      for (final String key in AppModel.themePresets.keys) (key, key),
      for (final CustomThemeEntry entry in appModel.customThemes)
        ('custom-theme:${entry.id}', entry.name),
    ],
    write: (SettingsContext context, String value) async {
      await context.appModel.setAppThemeKey(value);
      notifyReaderSettingsChanged(context);
    },
  ),
  // buildLanguageSelector：界面语言。
  'appearance.language': _VirtualSetting(
    read: (AppModel appModel) => appModel.appLocale.toLanguageTag(),
    options: (AppModel _) => <(String, String)>[
      for (final MapEntry<String, String> e
          in FushiLocalisations.localeNames.entries)
        (e.key, e.value),
    ],
    write: (SettingsContext context, String value) =>
        context.appModel.setAppLocale(value),
  ),
};

/// 索引里的一条设置项。
class _SettingEntry {
  _SettingEntry({
    required this.key,
    required this.title,
    required this.breadcrumb,
    required this.visible,
    this.item,
    this.virtual,
  });

  final String key;
  final String title;
  final String breadcrumb;
  final bool visible;
  final SettingsItem? item;
  final _VirtualSetting? virtual;

  bool get isSecret {
    final SettingsItem? row = item;
    return row is SettingsTextItem &&
        isCtlSecretSetting(key, declaredSecret: row.secret);
  }

  String get type {
    if (virtual != null) return CtlSettingType.choice;
    return switch (item) {
      SettingsSwitchItem() => CtlSettingType.boolean,
      SettingsSegmentedItem<Object>() => CtlSettingType.choice,
      SettingsSliderItem() ||
      SettingsStepperItem() ||
      SettingsNumberItem() => CtlSettingType.number,
      SettingsTextItem() =>
        isSecret ? CtlSettingType.secret : CtlSettingType.text,
      SettingsActionItem() => CtlSettingKind.action,
      SettingsStatusItem() => CtlSettingKind.status,
      SettingsCustomItem(cliValue: final SettingsCliValue _) =>
        CtlSettingType.text,
      SettingsCustomItem(cliList: final SettingsCliList _) =>
        CtlSettingKind.list,
      SettingsCustomItem() => CtlSettingKind.custom,
      _ => 'unknown',
    };
  }

  /// 条目大类（`config ls --kind` 的筛选口径）。
  String get kind => switch (item) {
    SettingsActionItem() => CtlSettingKind.action,
    SettingsStatusItem() => CtlSettingKind.status,
    SettingsCustomItem(cliValue: final SettingsCliValue _) =>
      CtlSettingKind.value,
    SettingsCustomItem(cliList: final SettingsCliList _) => CtlSettingKind.list,
    SettingsCustomItem() => CtlSettingKind.custom,
    _ => CtlSettingKind.value,
  };

  /// 自绘行声明的单值读写（[SettingsCustomItem.cliValue]）。
  SettingsCliValue? get cliValue => switch (item) {
    SettingsCustomItem(:final SettingsCliValue? cliValue) => cliValue,
    _ => null,
  };

  /// 自绘行声明的记录列表操作（[SettingsCustomItem.cliList]）。
  SettingsCliList? get cliList => switch (item) {
    SettingsCustomItem(:final SettingsCliList? cliList) => cliList,
    _ => null,
  };

  /// 行只在某个页面（播放页快捷面板…）可见，但声明了离开页面也能写 / 执行：
  /// 值是全局偏好，CLI 不按行可见性拒绝。
  bool get offPage =>
      cliValue?.offPageWritable == true ||
      cliList?.offPageWritable == true ||
      switch (item) {
        SettingsActionItem(:final SettingsCliAction? cli) =>
          cli?.offPageRunnable == true,
        _ => false,
      };
}

/// 设置项大类：可读写的值 / 可执行的动作 / 只读状态 / 记录列表 / 自绘行。
abstract final class CtlSettingKind {
  static const String value = 'value';
  static const String action = 'action';
  static const String status = 'status';
  static const String list = 'list';
  static const String custom = 'custom';
  static const List<String> all = <String>[value, action, status, list, custom];
}

const int _kSubPageMaxDepth = 3;

/// 把整棵 schema（含不可见项与子页）展平成「键 → 条目」：有值闭包的条目可读写；
/// 动作行（[SettingsActionItem]）与带按钮的状态行可经 `run` 执行；状态行可读
/// 副标题；自绘行声明了 [SettingsCustomReset] 的可读当前值并恢复默认（主题 /
/// 明暗 / 语言 / 设计系统这几条自绘行另见 [_virtualSettings]，可直接写值）。
Map<String, _SettingEntry> _buildSettingIndex(SettingsContext context) {
  final Map<String, _SettingEntry> index = <String, _SettingEntry>{};

  bool safeVisible(bool Function() predicate) {
    try {
      return predicate();
    } catch (_) {
      return false;
    }
  }

  void add(
    SettingsItem item, {
    required String breadcrumb,
    required bool visible,
  }) {
    if (index.containsKey(item.id)) return;
    final _VirtualSetting? virtual = _virtualSettings[item.id];
    final bool indexed =
        virtual != null ||
        item is SettingsSwitchItem ||
        item is SettingsSegmentedItem ||
        item is SettingsSliderItem ||
        item is SettingsStepperItem ||
        item is SettingsNumberItem ||
        item is SettingsTextItem ||
        item is SettingsActionItem ||
        item is SettingsStatusItem ||
        item is SettingsCustomItem;
    if (!indexed) return;
    index[item.id] = _SettingEntry(
      key: item.id,
      title: item is SettingsCustomItem
          ? (item.searchTitle ?? item.id)
          : item.title,
      breadcrumb: breadcrumb,
      visible: visible,
      item: virtual == null ? item : null,
      virtual: virtual,
    );
  }

  void walk(
    SettingsDestination page, {
    required String breadcrumb,
    required bool parentVisible,
    required int depth,
  }) {
    final bool pageVisible =
        parentVisible && safeVisible(() => page.isVisible(context));
    for (final SettingsSection section in page.sections) {
      final bool sectionVisible =
          pageVisible && safeVisible(() => section.isVisible(context));
      final String sectionCrumb =
          section.title == null || section.title!.isEmpty
          ? breadcrumb
          : '$breadcrumb › ${section.title}';
      for (final SettingsItem item in section.items) {
        final bool visible =
            sectionVisible && safeVisible(() => item.isVisible(context));
        add(item, breadcrumb: sectionCrumb, visible: visible);
        if (item is SettingsNavigationItem &&
            item.child != null &&
            depth < _kSubPageMaxDepth) {
          final SettingsDestination child = item.child!();
          walk(
            child,
            breadcrumb: '$sectionCrumb › ${child.title}',
            parentVisible: visible,
            depth: depth + 1,
          );
        }
      }
    }
  }

  for (final SettingsDestination destination in buildSettingsSchema(context)) {
    walk(
      destination,
      breadcrumb: destination.title,
      parentVisible: true,
      depth: 0,
    );
  }
  // 逃生口页面（Anki 设置页、媒体服务器配置页…）的条目：schema 树里没有，
  // 用同一套 item 类型在 ctl_settings_body_*.dart 里声明。
  for (final CtlBodyPage page in buildCtlBodyPages()) {
    final bool pageVisible =
        page.visible == null || safeVisible(() => page.visible!(context));
    for (final SettingsItem item in page.items) {
      add(
        item,
        breadcrumb: page.breadcrumb,
        visible: pageVisible && safeVisible(() => item.isVisible(context)),
      );
    }
  }
  return index;
}

/// 读当前值（原始值 + 人读展示）。机密项只给打码后的展示，不给原始值。
Map<String, Object?> _settingJson(
  _SettingEntry entry,
  SettingsContext context,
) {
  Object? value;
  String display;
  List<String>? options;
  num? min;
  num? max;
  String? error;
  try {
    final _VirtualSetting? virtual = entry.virtual;
    final SettingsItem? item = entry.item;
    if (virtual != null) {
      value = virtual.read(context.appModel);
      display = '$value';
      options = <String>[
        for (final (String token, String _) in virtual.options(
          context.appModel,
        ))
          token,
      ];
    } else {
      switch (item) {
        case SettingsSwitchItem():
          value = item.value(context);
          display = '$value';
        case SettingsSegmentedItem<Object>():
          value = ctlSettingOptionToken(item.selected(context));
          display = '$value';
          options = <String>[
            for (final SettingsSegmentOption<Object> option in item.optionsFor(
              context,
            ))
              ctlSettingOptionToken(option.value),
          ];
        case SettingsSliderItem():
          final double v = item.value(context);
          value = v;
          display = item.label?.call(v) ?? '$v';
          min = item.min;
          max = item.max;
        case SettingsStepperItem():
          final double v = item.value(context);
          value = v;
          display = item.format(v);
          min = item.min;
          max = item.max;
        case SettingsNumberItem():
          value = item.value(context);
          display = '$value${item.suffixText ?? ''}';
          min = item.min;
          max = item.max;
        case SettingsTextItem():
          final String v = item.value(context);
          if (entry.isSecret) {
            value = null;
            display = redactCtlSecret(v);
          } else {
            value = v;
            display = v;
          }
        case SettingsActionItem():
          value = null;
          display = item.subtitleBuilder?.call(context) ?? item.subtitle ?? '';
        case SettingsStatusItem():
          // 状态行的「值」就是它的副标题（运行期状态只走 subtitleBuilder）。
          final String status =
              item.subtitleBuilder?.call(context) ?? item.subtitle ?? '';
          value = status;
          display = status;
        case SettingsCustomItem(cliValue: final SettingsCliValue cli):
          final String v = cli.read(context);
          value = v;
          display = v;
          options = cli.options?.call(context);
        default:
          value = null;
          display = '';
      }
    }
  } catch (e) {
    value = null;
    display = '<读取失败>';
    error = '$e';
  }
  final SettingsItem? item = entry.item;
  SettingsResetSpec? reset;
  if (item != null && error == null) {
    try {
      reset = settingsResetSpecFor(item, context);
    } catch (_) {
      reset = null;
    }
  }
  // 自绘行没有值闭包；声明了「恢复默认」且没有 cliValue 的，以它的当前值标签作展示。
  if (item is SettingsCustomItem && item.cliValue == null && reset != null) {
    display = reset.currentLabel;
  }
  final SettingsCliAction? cli = item is SettingsActionItem ? item.cli : null;
  final SettingsCliList? list = entry.cliList;
  return <String, Object?>{
    'key': entry.key,
    'type': entry.type,
    'kind': entry.kind,
    'title': entry.title,
    'section': entry.breadcrumb,
    'visible': entry.visible,
    'value': value,
    'display': display,
    if (entry.isSecret) 'redacted': true,
    // 告诉 AI 这一项它改不了（只能指引用户去改），免得白调一次 settings.set。
    if (entry.item != null && !isModelWritableSetting(entry.key, entry.item))
      'userOnly': true,
    if (options != null) 'options': options,
    if (min != null) 'min': min,
    if (max != null) 'max': max,
    if (reset != null) 'default': reset.defaultLabel,
    if (reset != null) 'modified': reset.modified,
    if (_runnable(entry)) 'runnable': true,
    if (item is SettingsActionItem &&
        (item.destructive || cli?.confirm == true))
      'destructive': true,
    if (entry.cliValue?.help != null) 'help': entry.cliValue!.help,
    if (cli?.unsupportedHint != null) 'hint': cli!.unsupportedHint,
    if (cli != null && cli.params.isNotEmpty)
      'params': <Map<String, Object?>>[
        for (final SettingsCliParam param in cli.params) _cliParamJson(param),
      ],
    if (list != null)
      'listOps': <String>[
        'ls',
        if (list.add != null) 'add',
        if (list.update != null) 'set',
        if (list.remove != null) 'rm',
      ],
    if (list != null && list.fields.isNotEmpty)
      'fields': <Map<String, Object?>>[
        for (final SettingsCliParam param in list.fields) _cliParamJson(param),
      ],
    if (error != null) 'error': error,
  };
}

Map<String, Object?> _cliParamJson(SettingsCliParam param) => <String, Object?>{
  'name': param.name,
  'help': param.help,
  'required': param.required,
  if (param.path) 'path': true,
  if (param.secret) 'secret': true,
};

/// 能经 `config run` 执行：动作行，或带按钮的状态行。
bool _runnable(_SettingEntry entry) {
  final SettingsItem? item = entry.item;
  return (item is SettingsActionItem &&
          item.cli != null &&
          item.cli!.unsupportedHint == null) ||
      (item is SettingsStatusItem && item.onAction != null);
}

_SettingEntry _requireSettingEntry(
  Map<String, _SettingEntry> index,
  String key,
) {
  final _SettingEntry? entry = index[key];
  if (entry == null) {
    throw CtlFailure.badRequest('未知设置项「$key」（用 config ls --search 查键名）');
  }
  return entry;
}

Future<Object?> _listSettings(OpContext context, CtlCall call) async {
  final SettingsContext settings = _settingsContext(context);
  final String query = call.optString('search') ?? '';
  final bool all = call.optBool('all') ?? false;
  final String kind = call.optString('kind') ?? CtlSettingKind.value;
  if (kind != 'all' && !CtlSettingKind.all.contains(kind)) {
    throw CtlFailure.badRequest(
      'kind 只能是 ${CtlSettingKind.all.join(' / ')} / all，收到「$kind」',
    );
  }
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[
    for (final _SettingEntry entry in _buildSettingIndex(settings).values)
      if ((all || entry.visible) &&
          (kind == 'all' || entry.kind == kind) &&
          matchesMediaSearch(
            query: query,
            titles: <String>[entry.key, entry.title, entry.breadcrumb],
          ))
        _settingJson(entry, settings),
  ];
  return <String, Object?>{'settings': rows, 'count': rows.length};
}

Future<Object?> _getSetting(OpContext context, CtlCall call) async {
  final SettingsContext settings = _settingsContext(context);
  final _SettingEntry entry = _requireSettingEntry(
    _buildSettingIndex(settings),
    call.params['key']!,
  );
  return _settingJson(entry, settings);
}

/// 模型（AI 助手的 `settings.set`）能不能写这一行：
/// - [SettingsSwitchItem.userOnly] 的授权开关只能由用户拨；
/// - 带凭据服务的地址（[ctlCredentialEndpoints]）：改了就把已存凭据发去新地址；
/// - 机密项本身（spec §10：AI 不读写凭据）。
/// 用户自己（设置页、`fushi_cli`、撤销）不受影响。
bool isModelWritableSetting(
  String key,
  SettingsItem? item, {
  CtlCredentialEndpoints? endpoints,
}) {
  if (item is SettingsSwitchItem && item.userOnly) return false;
  if (item is SettingsTextItem &&
      isCtlSecretSetting(key, declaredSecret: item.secret)) {
    return false;
  }
  return !(endpoints ?? ctlCredentialEndpoints()).valueKeys.contains(key);
}

/// 模型写带凭据服务的地址：在路由入口、建设置索引之前就拒（只看 key 与 body，
/// 与可见性无关——不可见的项模型同样不该改）。用户调用直接放过。
///
/// - 值设置项（`settings.set`）：key 在 [CtlCredentialEndpoints.valueKeys]；
/// - 记录列表修改 / 动作：给了 [CtlCredentialEndpoints.listFields] /
///   [CtlCredentialEndpoints.actionParams] 里的字段（`args` 对象里或铺在 body 顶层）。
void refuseModelCredentialEndpointWrite(
  CtlCall call, {
  required CtlCredentialEndpointWrite kind,
}) {
  if (!call.fromModel) return;
  final String key = call.params['key'] ?? '';
  final CtlCredentialEndpoints endpoints = ctlCredentialEndpoints();
  final Set<String>? locked = switch (kind) {
    CtlCredentialEndpointWrite.value =>
      endpoints.valueKeys.contains(key) ? const <String>{'value'} : null,
    CtlCredentialEndpointWrite.listItem => endpoints.listFields[key],
    CtlCredentialEndpointWrite.action => endpoints.actionParams[key],
  };
  if (locked == null) return;
  final Object? args = call.body['args'];
  final Set<String> given = <String>{
    ...call.body.keys,
    if (args is Map) ...args.keys.map((Object? k) => '$k'),
  };
  final List<String> hit = kind == CtlCredentialEndpointWrite.value
      ? const <String>['value']
      : given.where(locked.contains).toList();
  if (hit.isEmpty) return;
  throw CtlFailure.rejected(
    '「$key」${kind == CtlCredentialEndpointWrite.value ? '' : '的 ${hit.join(' / ')}'}'
    '是带凭据服务的地址：改了会把已存的凭据发去新地址，AI 不能改，请用户在设置页或 '
    'fushi_cli 里改',
  );
}

/// [refuseModelCredentialEndpointWrite] 守的是哪种写入。
enum CtlCredentialEndpointWrite { value, listItem, action }

Future<Object?> _setSetting(OpContext context, CtlCall call) async {
  refuseModelCredentialEndpointWrite(
    call,
    kind: CtlCredentialEndpointWrite.value,
  );
  final SettingsContext settings = _settingsContext(context);
  final _SettingEntry entry = _requireSettingEntry(
    _buildSettingIndex(settings),
    call.params['key']!,
  );
  final Object? rawValue = call.body['value'] ?? call.query['value'];
  if (rawValue == null) throw const CtlFailure.badRequest('value 缺失');
  final String raw = '$rawValue';
  if (!entry.visible && !entry.offPage) {
    throw CtlFailure.rejected('设置项「${entry.key}」在当前平台 / 模块 / 状态下不可见，设置页里也改不了');
  }
  if (call.fromModel && !isModelWritableSetting(entry.key, entry.item)) {
    throw CtlFailure.rejected(
      '「${entry.title}」只能由用户自己改（授权开关 / 凭据 / 带凭据服务的地址：'
      '改地址会把已存的凭据发去新地址）；请用户在设置页或 fushi_cli 里改',
    );
  }
  if (entry.isSecret && (call.optString('source') ?? 'argv') == 'argv') {
    throw CtlFailure.badRequest(
      '「${entry.key}」是机密项，值只能经 --stdin 或 --from-env 传入，不能写在命令行里',
    );
  }
  await _applySetting(entry, settings, raw);
  // 写后重读：一些 setter 会规整 / 夹取值，回显以真实存储为准。
  return _settingJson(entry, settings);
}

Future<void> _applySetting(
  _SettingEntry entry,
  SettingsContext context,
  String raw,
) async {
  final _VirtualSetting? virtual = entry.virtual;
  if (virtual != null) {
    final List<(String, String)> options = virtual.options(context.appModel);
    final int index = indexOfCtlSettingOption(
      raw,
      tokens: <String>[for (final (String token, String _) in options) token],
      labels: <String>[for (final (String _, String label) in options) label],
    );
    await virtual.write(context, options[index].$1);
    return;
  }
  final SettingsItem? item = entry.item;
  switch (item) {
    case SettingsSwitchItem():
      await item.onChanged(context, parseCtlSettingBool(raw));
    case SettingsSegmentedItem<Object>():
      final List<SettingsSegmentOption<Object>> choices = item.optionsFor(
        context,
      );
      final int index = indexOfCtlSettingOption(
        raw,
        tokens: <String>[
          for (final SettingsSegmentOption<Object> option in choices)
            ctlSettingOptionToken(option.value),
        ],
        labels: <String>[
          for (final SettingsSegmentOption<Object> option in choices)
            option.label,
        ],
      );
      await item.dispatchChange(context, choices[index].value);
    case SettingsSliderItem():
      final double value = parseCtlSettingNumber(
        raw,
        integer: false,
        min: item.min,
        max: item.max,
      ).toDouble();
      // 等价于一次「拖到该值并松手」：onChanged 提交，声明了 onChangeEnd 的再补一次松手回调。
      await item.onChanged(context, value);
      await item.onChangeEnd?.call(context, value);
    case SettingsStepperItem():
      await item.onChanged(
        context,
        parseCtlSettingNumber(
          raw,
          integer: false,
          min: item.min,
          max: item.max,
        ).toDouble(),
      );
    case SettingsNumberItem():
      await item.onChanged(
        context,
        parseCtlSettingNumber(
          raw,
          integer: item.integer,
          min: item.min,
          max: item.max,
        ),
      );
    case SettingsTextItem():
      await _guardCliInput<void>(() async {
        await item.onChanged(context, raw);
      });
    case SettingsCustomItem(cliValue: final SettingsCliValue cli):
      await _guardCliInput(() => cli.write(context, raw));
    default:
      final bool resettable =
          item != null && settingsResetSpecFor(item, context) != null;
      throw CtlFailure.badRequest(
        '设置项「${entry.key}」（${entry.type}）不能直接写值'
        '${_runnable(entry) ? '；执行它用 config run' : ''}'
        '${entry.kind == CtlSettingKind.list ? '；记录列表用 config items' : ''}'
        '${resettable ? '；可用 config reset 恢复默认' : ''}',
      );
  }
}

/// 设置项自己的写入 / 执行体对非法参数抛 [ArgumentError] / [FormatException]：
/// 映射成 400，让 CLI 拿到可读原因而不是 500。
Future<T> _guardCliInput<T>(Future<T> Function() body) async {
  try {
    return await body();
  } on ArgumentError catch (e) {
    throw CtlFailure.badRequest('${e.message ?? e}');
  } on FormatException catch (e) {
    throw CtlFailure.badRequest(e.message);
  } on StateError catch (e) {
    // 状态冲突（已有同类任务在跑、服务不在…）：稍后再试。
    throw CtlFailure.conflict(e.message);
  }
}

/// 控制通道动作 / 列表操作的参数：明文走 body `args`，凭据走 body `secrets`
/// （CLI 只经 stdin / 环境变量填它，`secretSource` 标出来源）。按 [params] 校验：
/// 未声明的参数、缺必填、相对路径、明文传凭据一律 400。[partial] = 更新操作，
/// 不要求必填。
Map<String, String> _cliArgs(
  CtlCall call,
  List<SettingsCliParam> params, {
  bool partial = false,
}) {
  final Map<String, SettingsCliParam> declared = <String, SettingsCliParam>{
    for (final SettingsCliParam param in params) param.name: param,
  };
  final Map<String, String> args = <String, String>{};
  void collect(Object? raw, {required bool secret}) {
    if (raw == null) return;
    if (raw is! Map) {
      throw CtlFailure.badRequest('${secret ? 'secrets' : 'args'} 必须是对象');
    }
    raw.forEach((Object? k, Object? v) {
      final String name = '$k';
      final SettingsCliParam? param = declared[name];
      if (param == null) {
        throw CtlFailure.badRequest(
          '没有参数「$name」；可用：'
          '${declared.isEmpty ? '（无）' : declared.keys.join(' | ')}',
        );
      }
      if (param.secret && !secret) {
        throw CtlFailure.badRequest(
          '「$name」是凭据，只能经 --secret-stdin 或 --secret-from-env 传入',
        );
      }
      args[name] = v == null ? '' : '$v';
    });
  }

  collect(call.body['args'], secret: false);
  final Object? secrets = call.body['secrets'];
  if (secrets is Map && secrets.isNotEmpty && call.fromModel) {
    // spec §10：AI 不写凭据。操作目录本来就不给模型 secrets 参数，这里再兜一层。
    throw const CtlFailure.rejected('凭据只能由用户自己填，AI 不能写');
  }
  if (secrets is Map && secrets.isNotEmpty) {
    final String source = call.optString('secretSource') ?? 'argv';
    if (source != 'stdin' && source != 'env') {
      throw const CtlFailure.badRequest('凭据只能经 stdin 或环境变量传入');
    }
  }
  collect(secrets, secret: true);
  for (final SettingsCliParam param in params) {
    final String? value = args[param.name];
    if (!partial && param.required && (value == null || value.isEmpty)) {
      throw CtlFailure.badRequest('缺少参数「${param.name}」：${param.help}');
    }
    if (param.path &&
        value != null &&
        value.isNotEmpty &&
        !p.isAbsolute(value)) {
      throw CtlFailure.badRequest('「${param.name}」必须是绝对路径：$value');
    }
  }
  return args;
}

/// `config items <key> ...`：取声明了 [SettingsCustomItem.cliList] 的条目。
({SettingsContext settings, _SettingEntry entry, SettingsCliList list})
_requireListEntry(OpContext context, CtlCall call) {
  final SettingsContext settings = _settingsContext(context);
  final _SettingEntry entry = _requireSettingEntry(
    _buildSettingIndex(settings),
    call.params['key']!,
  );
  final SettingsCliList? list = entry.cliList;
  if (list == null) {
    throw CtlFailure.badRequest(
      '设置项「${entry.key}」（${entry.type}）不是记录列表'
      '（config ls --kind list 列出可用的列表）',
    );
  }
  if (!entry.visible && !entry.offPage) {
    throw CtlFailure.rejected('设置项「${entry.key}」在当前平台 / 模块 / 状态下不可见，设置页里也改不了');
  }
  return (settings: settings, entry: entry, list: list);
}

Future<Object?> _listSettingItems(OpContext context, CtlCall call) async {
  final ({SettingsContext settings, _SettingEntry entry, SettingsCliList list})
  target = _requireListEntry(context, call);
  final List<Map<String, Object?>> items = await target.list.list(
    target.settings,
  );
  return <String, Object?>{
    'key': target.entry.key,
    'title': target.entry.title,
    'items': items,
    'count': items.length,
  };
}

Future<Object?> _addSettingItem(OpContext context, CtlCall call) async {
  final ({SettingsContext settings, _SettingEntry entry, SettingsCliList list})
  target = _requireListEntry(context, call);
  final Future<Object?> Function(SettingsContext, Map<String, String>)? add =
      target.list.add;
  if (add == null) {
    throw CtlFailure.badRequest('「${target.entry.key}」不支持新增');
  }
  final Map<String, String> args = _cliArgs(call, target.list.fields);
  final Object? created = await _guardCliInput(
    () => add(target.settings, args),
  );
  return <String, Object?>{
    'key': target.entry.key,
    'action': '已添加',
    'item': created,
  };
}

Future<Object?> _updateSettingItem(OpContext context, CtlCall call) async {
  refuseModelCredentialEndpointWrite(
    call,
    kind: CtlCredentialEndpointWrite.listItem,
  );
  final ({SettingsContext settings, _SettingEntry entry, SettingsCliList list})
  target = _requireListEntry(context, call);
  final Future<Object?> Function(SettingsContext, String, Map<String, String>)?
  update = target.list.update;
  if (update == null) {
    throw CtlFailure.badRequest('「${target.entry.key}」不支持修改');
  }
  final Map<String, String> args = _cliArgs(
    call,
    target.list.fields,
    partial: true,
  );
  if (args.isEmpty) throw const CtlFailure.badRequest('没有要改的字段');
  final String id = call.params['id']!;
  await _requireListItem(target.settings, target.list, id);
  final Object? updated = await _guardCliInput(
    () => update(target.settings, id, args),
  );
  return <String, Object?>{
    'key': target.entry.key,
    'action': '已更新',
    'item': updated,
  };
}

Future<Object?> _removeSettingItem(OpContext context, CtlCall call) async {
  if (call.optBool('confirm') != true) {
    throw const CtlFailure.badRequest('删除记录需要 confirm=true');
  }
  final ({SettingsContext settings, _SettingEntry entry, SettingsCliList list})
  target = _requireListEntry(context, call);
  final Future<void> Function(SettingsContext, String)? remove =
      target.list.remove;
  if (remove == null) {
    throw CtlFailure.badRequest('「${target.entry.key}」不支持删除');
  }
  final String id = call.params['id']!;
  final Map<String, Object?> removed = await _requireListItem(
    target.settings,
    target.list,
    id,
  );
  await _guardCliInput(() => remove(target.settings, id));
  return <String, Object?>{
    'key': target.entry.key,
    'action': '已删除',
    'item': removed,
  };
}

/// 列表里的一条（按 `id`）；不存在给 404，避免「以为删掉了」。
Future<Map<String, Object?>> _requireListItem(
  SettingsContext settings,
  SettingsCliList list,
  String id,
) async {
  for (final Map<String, Object?> item in await list.list(settings)) {
    if ('${item['id']}' == id) return item;
  }
  throw CtlFailure.notFound('没有记录「$id」（config items ls 查看）');
}

/// 恢复默认：与设置详情页「恢复本页默认」逐项同一个 [settingsResetSpecFor]
/// （开关 / 滑条 / 步进 / 分段 / 声明了 [SettingsCustomReset] 的自绘行）。
Future<Object?> _resetSetting(OpContext context, CtlCall call) async {
  final SettingsContext settings = _settingsContext(context);
  final _SettingEntry entry = _requireSettingEntry(
    _buildSettingIndex(settings),
    call.params['key']!,
  );
  if (!entry.visible) {
    throw CtlFailure.rejected('设置项「${entry.key}」在当前平台 / 模块 / 状态下不可见，设置页里也改不了');
  }
  final SettingsItem? item = entry.item;
  final SettingsResetSpec? spec = item == null
      ? null
      : settingsResetSpecFor(item, settings);
  if (spec == null) {
    throw CtlFailure.badRequest('设置项「${entry.key}」没有声明默认值，不能恢复默认');
  }
  final bool wasModified = spec.modified;
  if (wasModified) await spec.reset();
  return <String, Object?>{
    ..._settingJson(entry, settings),
    'wasModified': wasModified,
  };
}

/// 执行动作行：只走它声明的控制通道入口（[SettingsActionItem.cli]）——
/// 无交互的直接调 onTap；带对话框 / 选择器的走参数化入口，值由 CLI 参数给出、
/// 确认由 confirm=true 给出，**不在主窗口上弹任何对话框**；只是打开界面的
/// 动作返回 422 并指向对应命令。
Future<Object?> _runSetting(OpContext context, CtlCall call) async {
  refuseModelCredentialEndpointWrite(
    call,
    kind: CtlCredentialEndpointWrite.action,
  );
  final SettingsContext settings = _settingsContext(context);
  final _SettingEntry entry = _requireSettingEntry(
    _buildSettingIndex(settings),
    call.params['key']!,
  );
  final SettingsItem? item = entry.item;
  if (item is SettingsActionItem) {
    final SettingsCliAction? cli = item.cli;
    if (cli == null) {
      throw CtlFailure.rejected('「${entry.title}」没有声明控制通道入口（只能在设置页里点）');
    }
    final String? hint = cli.unsupportedHint;
    if (hint != null) {
      throw CtlFailure.rejected('「${entry.title}」只是打开界面：$hint');
    }
  }
  if (!_runnable(entry)) {
    throw CtlFailure.badRequest(
      '设置项「${entry.key}」（${entry.type}）不是可执行的动作'
      '（config ls --kind action 列出可执行项）',
    );
  }
  if (!entry.visible && !entry.offPage) {
    throw CtlFailure.rejected('设置项「${entry.key}」在当前平台 / 模块 / 状态下不可见，设置页里也点不到');
  }
  Object? result;
  switch (item) {
    case SettingsActionItem(cli: final SettingsCliAction cli):
      if ((item.destructive || cli.confirm) &&
          call.optBool('confirm') != true) {
        throw CtlFailure.badRequest('「${entry.title}」是破坏性动作，需要 confirm=true');
      }
      final Map<String, String> args = _cliArgs(call, cli.params);
      final SettingsCliRun? run = cli.run;
      if (run != null) {
        result = await _guardCliInput(() => run(settings, args));
      } else {
        await item.onTap(settings);
      }
    case SettingsStatusItem():
      await item.onAction!(settings);
    default:
      break;
  }
  return <String, Object?>{
    ..._settingJson(entry, settings),
    'ran': true,
    if (result != null) 'result': result,
  };
}

// ── 功能模块 ────────────────────────────────────────────────────────────────

bool _moduleAvailable(AppModel appModel, ModuleId module) => module.availableOn(
  isWindows: appModel.platformServices.isWindows,
  isDesktop: appModel.platformServices.isDesktop,
  isIOS: appModel.platformServices.isIOS,
  isAndroid: appModel.platformServices.isAndroid,
);

Map<String, Object?> _moduleJson(AppModel appModel, ModuleId module) =>
    <String, Object?>{
      'id': module.name,
      'prefKey': module.prefKey,
      'available': _moduleAvailable(appModel, module),
      'enabled': appModel.moduleEnabled(module),
      'visible': appModel.moduleVisibility.isEnabled(module),
    };

Future<Object?> _listModules(OpContext context) async {
  final AppModel appModel = context.appModel;
  return <String, Object?>{
    'modules': <Map<String, Object?>>[
      for (final ModuleId module in ModuleId.values)
        _moduleJson(appModel, module),
    ],
    // 用户排的底栏 / 侧栏顺序（全量，含本平台不可用的模块）。
    'order': <String>[
      for (final ModuleId module in appModel.moduleVisibility.ordered)
        module.name,
    ],
  };
}

Future<Object?> _setModule(OpContext context, CtlCall call) async {
  final String raw = call.params['id']!;
  final ModuleId? module = parseCtlModuleId(raw);
  if (module == null) {
    throw CtlFailure.notFound(
      '没有模块「$raw」；可选：${ModuleId.values.map((ModuleId m) => m.name).join(' | ')}',
    );
  }
  final bool? enabled = call.optBool('enabled');
  if (enabled == null) throw const CtlFailure.badRequest('enabled 缺失');
  final AppModel appModel = context.appModel;
  // 平台判据与合规门都在 availableOn 里（browse 委托 StoreRestrictedCapability）；
  // 设置页对不可用的模块不出开关，这里同样拒绝。
  if (!_moduleAvailable(appModel, module)) {
    throw CtlFailure.rejected('模块 ${module.name} 在本平台不可用');
  }
  await appModel.setModuleEnabled(module, enabled);
  return _moduleJson(appModel, module);
}

/// 底栏 / 侧栏模块顺序：给出的模块按给出顺序排到最前，没提到的保持原相对顺序
/// （与设置页拖拽排序同一个 `AppModel.setModuleOrder`，存全量顺序）。
Future<Object?> _setModuleOrder(OpContext context, CtlCall call) async {
  final List<String> raw = call.stringList('order');
  if (raw.isEmpty) throw const CtlFailure.badRequest('order 缺失（模块 id 列表）');
  final List<ModuleId> head = <ModuleId>[];
  for (final String id in raw) {
    final ModuleId? module = parseCtlModuleId(id);
    if (module == null) {
      throw CtlFailure.notFound(
        '没有模块「$id」；可选：${ModuleId.values.map((ModuleId m) => m.name).join(' | ')}',
      );
    }
    if (head.contains(module)) {
      throw CtlFailure.badRequest('模块 ${module.name} 重复');
    }
    head.add(module);
  }
  final AppModel appModel = context.appModel;
  await appModel.setModuleOrder(<ModuleId>[
    ...head,
    for (final ModuleId module in appModel.moduleVisibility.ordered)
      if (!head.contains(module)) module,
  ], settingsSlot: appModel.moduleSettingsSlot);
  return _listModules(context);
}

// ── Profile ─────────────────────────────────────────────────────────────────

/// 取 Profile 视图模型并把状态刷到仓库真值（视图模型首次被读时的异步加载
/// 可能还没完成，`activeProfileId` 仍是 -1）。
Future<ProfileViewModel> _profileViewModel(OpContext context) async {
  final ProfileViewModel viewModel = context.ref.read(
    profileViewModelProvider.notifier,
  );
  await viewModel.reload();
  return viewModel;
}

ProfileUiState _profileState(OpContext context) =>
    context.ref.read(profileViewModelProvider);

Map<String, Object?> _profileJson(ProfileRow profile, ProfileUiState state) =>
    <String, Object?>{
      'id': profile.id,
      'name': profile.name,
      'active': profile.id == state.activeProfileId,
    };

/// `<id|名字>`：整数优先按 id，其次按名字精确匹配。
ProfileRow _resolveProfile(ProfileUiState state, String ref) {
  final int? id = int.tryParse(ref.trim());
  for (final ProfileRow profile in state.profiles) {
    if (id != null && profile.id == id) return profile;
  }
  final List<ProfileRow> byName = <ProfileRow>[
    for (final ProfileRow profile in state.profiles)
      if (profile.name == ref.trim()) profile,
  ];
  if (byName.length == 1) return byName.single;
  if (byName.length > 1) {
    throw CtlFailure.conflict('有 ${byName.length} 个名为「$ref」的 Profile，请用 id');
  }
  throw CtlFailure.notFound('没有 Profile「$ref」');
}

Map<String, Object?> _profileResult(OpContext context, String action, int id) {
  final ProfileUiState state = _profileState(context);
  return <String, Object?>{
    'action': action,
    'profile': _profileJson(_resolveProfile(state, '$id'), state),
  };
}

Future<Object?> _listProfiles(OpContext context) async {
  await _profileViewModel(context);
  final ProfileUiState state = _profileState(context);
  return <String, Object?>{
    'activeProfileId': state.activeProfileId,
    'profiles': <Map<String, Object?>>[
      for (final ProfileRow profile in state.profiles)
        _profileJson(profile, state),
    ],
    'mediaTypeBindings': state.mediaTypeBindings,
    'languageBindings': state.languageBindings,
  };
}

Future<Object?> _activateProfile(OpContext context, CtlCall call) async {
  final ProfileViewModel viewModel = await _profileViewModel(context);
  final ProfileRow target = _resolveProfile(
    _profileState(context),
    call.params['id']!,
  );
  if (target.id != _profileState(context).activeProfileId) {
    await viewModel.switchProfile(target.id);
  }
  return _profileResult(context, '已切换到', target.id);
}

Future<Object?> _createProfile(OpContext context, CtlCall call) async {
  final String name = call.requireString('name');
  final ProfileViewModel viewModel = await _profileViewModel(context);
  await viewModel.createProfile(name);
  return _profileResult(
    context,
    '已新建并切换到',
    _profileState(context).activeProfileId,
  );
}

Future<Object?> _renameProfile(OpContext context, CtlCall call) async {
  final String name = call.requireString('name');
  final ProfileViewModel viewModel = await _profileViewModel(context);
  final ProfileRow target = _resolveProfile(
    _profileState(context),
    call.params['id']!,
  );
  await viewModel.renameProfile(target.id, name);
  return _profileResult(context, '已重命名', target.id);
}

Future<Object?> _copyProfile(OpContext context, CtlCall call) async {
  final String name = call.requireString('name');
  final ProfileViewModel viewModel = await _profileViewModel(context);
  final ProfileRow source = _resolveProfile(
    _profileState(context),
    call.params['id']!,
  );
  final Set<int> before = <int>{
    for (final ProfileRow profile in _profileState(context).profiles)
      profile.id,
  };
  await viewModel.copyProfile(source.id, name);
  final ProfileUiState after = _profileState(context);
  final ProfileRow? created = after.profiles
      .where((ProfileRow profile) => !before.contains(profile.id))
      .firstOrNull;
  // 找不到新建的那份就如实报错：回退成源 Profile 会让调用方（撤销「删掉复制出的
  // 那份」）把源 Profile 当成复制结果删掉。
  if (created == null) {
    throw CtlFailure.conflict('复制「${source.name}」后没找到新建的 Profile');
  }
  return _profileResult(context, '已复制为', created.id);
}

Future<Object?> _deleteProfile(OpContext context, CtlCall call) async {
  if (call.optBool('confirm') != true) {
    throw const CtlFailure.badRequest('删除 Profile 需要 confirm=true');
  }
  final ProfileViewModel viewModel = await _profileViewModel(context);
  final ProfileUiState state = _profileState(context);
  final ProfileRow target = _resolveProfile(state, call.params['id']!);
  // ProfileRepository.deleteProfile 在只剩一个时静默不删；这里把它说出来。
  if (state.profiles.length <= 1) {
    throw const CtlFailure.rejected('至少要保留一个 Profile');
  }
  await viewModel.deleteProfile(target.id);
  final ProfileUiState after = _profileState(context);
  return <String, Object?>{
    'deleted': <String, Object?>{'id': target.id, 'name': target.name},
    'activeProfileId': after.activeProfileId,
  };
}

/// 本机文件参数：CLI 已转绝对路径；这里再挡一次相对路径。
String _requireAbsolutePath(CtlCall call) {
  final String path = call.requireString('path');
  if (!p.isAbsolute(path)) throw CtlFailure.badRequest('path 必须是绝对路径：$path');
  return path;
}

/// 写出文件；目标已存在且没确认覆盖给 409。
Future<Map<String, Object?>> _writeExport(
  CtlCall call,
  String path,
  String content,
) async {
  final File file = File(path);
  if (file.existsSync() && call.optBool('confirm') != true) {
    throw CtlFailure.conflict('$path 已存在；覆盖请加 --yes');
  }
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
  return <String, Object?>{'path': path, 'bytes': await file.length()};
}

Future<Object?> _exportProfile(OpContext context, CtlCall call) async {
  final String path = _requireAbsolutePath(call);
  final ProfileViewModel viewModel = await _profileViewModel(context);
  final ProfileRow target = _resolveProfile(
    _profileState(context),
    call.params['id']!,
  );
  // 与配置管理页的导出同参：字体根用于把本机字体绝对路径剥成相对。
  final String content = await viewModel.exportProfile(
    target.id,
    fontsRootDirectory: p.join(
      context.appModel.appDirectory.path,
      'custom_fonts',
    ),
  );
  return <String, Object?>{
    ...await _writeExport(call, path, content),
    'profile': <String, Object?>{'id': target.id, 'name': target.name},
  };
}

Future<Object?> _importProfile(OpContext context, CtlCall call) async {
  final String path = _requireAbsolutePath(call);
  final File file = File(path);
  if (!file.existsSync()) throw CtlFailure.notFound('文件不存在：$path');
  final String json = await file.readAsString();
  final ProfileViewModel viewModel = await _profileViewModel(context);
  final String? into = call.optString('into');
  int? targetId;
  if (into != null) {
    if (call.optBool('confirm') != true) {
      throw const CtlFailure.badRequest('覆盖已有 Profile 需要 confirm=true');
    }
    targetId = _resolveProfile(_profileState(context), into).id;
  }
  final int writtenId;
  try {
    writtenId = await viewModel.importProfile(
      json,
      mode: targetId == null
          ? ProfileImportMode.createNew
          : ProfileImportMode.overwrite,
      targetProfileId: targetId,
    );
  } on ProfileImportException catch (e) {
    throw CtlFailure.badRequest('Profile 文件无效：${e.message}');
  }
  return _profileResult(context, targetId == null ? '已导入为' : '已覆盖', writtenId);
}

/// 媒体类型 / 内容语言 → Profile 的自动切换绑定（配置管理页同一份）。
Future<Object?> _listProfileBindings(OpContext context) async {
  await _profileViewModel(context);
  final ProfileUiState state = _profileState(context);
  String? nameOf(int? id) {
    if (id == null) return null;
    for (final ProfileRow profile in state.profiles) {
      if (profile.id == id) return profile.name;
    }
    return null;
  }

  final List<String> languageTags = state.languageBindings.keys.toList()
    ..sort();
  return <String, Object?>{
    'media': <Map<String, Object?>>[
      for (final ProfileMediaKind kind in ProfileMediaKind.values)
        <String, Object?>{
          'scope': 'media',
          'key': kind.dbValue,
          'profileId': state.mediaTypeBindings[kind.dbValue],
          'profile': nameOf(state.mediaTypeBindings[kind.dbValue]),
        },
    ],
    'language': <Map<String, Object?>>[
      for (final String tag in languageTags)
        <String, Object?>{
          'scope': 'language',
          'key': tag,
          'profileId': state.languageBindings[tag],
          'profile': nameOf(state.languageBindings[tag]),
        },
    ],
  };
}

/// `scope` = media（键 = `ProfileMediaKind`）/ language（键 = BCP-47，按
/// [normalizeLanguageBinding] 归一）；body `profile` = id / 名字 / none（解绑）。
Future<Object?> _setProfileBinding(OpContext context, CtlCall call) async {
  final String scope = call.params['scope']!.trim().toLowerCase();
  final String key = call.params['key']!;
  final String target = call.requireString('profile');
  final ProfileViewModel viewModel = await _profileViewModel(context);
  final int? profileId = isCtlNoneToken(target)
      ? null
      : _resolveProfile(_profileState(context), target).id;
  switch (scope) {
    case 'media':
      final ProfileMediaKind? kind = parseCtlProfileMediaKind(key);
      if (kind == null) {
        throw CtlFailure.notFound(
          '没有媒体类型「$key」；可选：'
          '${ProfileMediaKind.values.map((ProfileMediaKind k) => k.dbValue).join(' | ')}',
        );
      }
      await viewModel.setMediaTypeBinding(kind, profileId);
    case 'language' || 'lang':
      // repository 层同样归一；这里先判一次，空串 = 认不出的标签，不能拿去写。
      if (normalizeLanguageBinding(key).isEmpty) {
        throw CtlFailure.badRequest('「$key」不是可用的语言标签（如 ja / en / zh-Hant）');
      }
      await viewModel.setLanguageBinding(key, profileId);
    default:
      throw CtlFailure.notFound('绑定范围只能是 media / language，收到「$scope」');
  }
  return _listProfileBindings(context);
}

// ── 学习统计 ────────────────────────────────────────────────────────────────

/// `--window` → dateKey 谓词与起止。窗口只用 [StatWindow]，不自己算 `now - Nd`。
({String name, String? fromKey, String toKey, bool Function(String) contains})
_statWindowOf(String? raw) {
  final StatWindow window = StatWindow(DateTime.now());
  switch (raw?.trim().toLowerCase() ?? '7d') {
    case 'today':
      return (
        name: 'today',
        fromKey: window.todayKey,
        toKey: window.todayKey,
        contains: window.isToday,
      );
    case '7d' || 'week':
      // 滚动近 7 天（含今日）；[StatWindow.inWeek] 是自然周，口径不同。
      final String from = window.lastDayKeys(7).first;
      return (
        name: '7d',
        fromKey: from,
        toKey: window.todayKey,
        contains: (String key) =>
            key.compareTo(from) >= 0 && key.compareTo(window.todayKey) <= 0,
      );
    case '30d' || 'month':
      return (
        name: '30d',
        fromKey: window.monthFromKey,
        toKey: window.todayKey,
        contains: window.inMonth,
      );
    case 'all':
      return (
        name: 'all',
        fromKey: null,
        toKey: window.todayKey,
        contains: (String _) => true,
      );
  }
  throw CtlFailure.badRequest('--window 只能是 today / 7d / 30d / all，收到「$raw」');
}

Future<Object?> _statsSummary(OpContext context, CtlCall call) async {
  final String? mediaKind = ctlStatMediaKindOf(call.optString('kind'));
  final ({
    String name,
    String? fromKey,
    String toKey,
    bool Function(String) contains,
  })
  window = _statWindowOf(call.optString('window'));
  // 当前 Profile 的统一事实面；只用日面（daily），与统计页同一口径。
  final StatFacts facts = await loadStatFacts(
    context.appModel.database,
    activityLimit: 0,
  );
  return <String, Object?>{
    'window': window.name,
    'fromKey': window.fromKey,
    'toKey': window.toKey,
    'kind': mediaKind == null ? null : ctlStatKindName(mediaKind),
    ...summarizeCtlStatFacts(
      facts.daily,
      inWindow: window.contains,
      mediaKind: mediaKind,
    ),
  };
}

Future<Object?> _statsSessions(OpContext context, CtlCall call) async {
  final String? mediaKind = ctlStatMediaKindOf(call.optString('kind'));
  final ({
    String name,
    String? fromKey,
    String toKey,
    bool Function(String) contains,
  })
  window = _statWindowOf(call.optString('window'));
  final int limit = call.optInt('limit') ?? 20;
  if (limit <= 0) throw const CtlFailure.badRequest('limit 必须是正整数');
  final StatFacts facts = await loadStatFacts(
    context.appModel.database,
    activityLimit: 0,
  );
  final List<StudySession> sessions = <StudySession>[
    for (final StudySession session in facts.sessions)
      if ((mediaKind == null || session.mediaKind == mediaKind) &&
          window.contains(
            FushiDatabase.statDateKeyOf(
              DateTime.fromMillisecondsSinceEpoch(session.startAt),
            ),
          ))
        session,
  ];
  return <String, Object?>{
    'window': window.name,
    'total': sessions.length,
    'sessions': <Map<String, Object?>>[
      for (final StudySession session in sessions.take(limit))
        ctlStudySessionJson(session),
    ],
  };
}

Future<Object?> _statsExport(OpContext context, CtlCall call) async {
  final String path = _requireAbsolutePath(call);
  final AppModel appModel = context.appModel;
  // 与 设置 › 诊断 › 导出统计诊断日志 同一份正文、同一组参数。
  final String content = await buildStudyDiagExport(
    appModel.database,
    appVersion: resolveCurrentAppVersion(appModel.packageInfo.version),
    readingIdleTimeoutMinutes: appModel.readingIdleTimeoutMinutes,
    statDayResetHour: appModel.statDayResetHour,
  );
  return _writeExport(call, path, content);
}

// ── 快捷键 ──────────────────────────────────────────────────────────────────

Future<Object?> _listShortcuts(OpContext context, CtlCall call) async {
  final String? scopeFilter = call.optString('scope');
  if (scopeFilter != null &&
      !ShortcutScope.values.any((ShortcutScope s) => s.name == scopeFilter)) {
    throw CtlFailure.badRequest(
      '没有作用域「$scopeFilter」；可选：'
      '${ShortcutScope.values.map((ShortcutScope s) => s.name).join(' | ')}',
    );
  }
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
  for (final ShortcutAction action in ShortcutAction.values) {
    if (scopeFilter != null && action.scope.name != scopeFilter) continue;
    final ShortcutBindingSet bindings = context.appModel.shortcutRegistry
        .bindingsFor(action);
    rows.add(_shortcutRow(action, bindings));
  }
  return <String, Object?>{'shortcuts': rows, 'count': rows.length};
}

Map<String, Object?> _shortcutRow(
  ShortcutAction action,
  ShortcutBindingSet bindings,
) => <String, Object?>{
  'scope': action.scope.name,
  'action': action.key,
  'label': action.label,
  ...ctlShortcutBindingColumns(bindings),
  // 可原样抄回 `keys set` / `keys unbind` 的持久化写法（显示列按平台换了符号）。
  'tokens': ctlShortcutTokens(bindings),
};

ShortcutAction _requireShortcutAction(String raw) {
  final ShortcutAction? action = parseCtlShortcutAction(raw);
  if (action == null) {
    throw CtlFailure.notFound('没有快捷键动作「$raw」（keys ls 查看 action 列）');
  }
  return action;
}

/// 与快捷键设置页同一条写穿路径：registry 改完立即 `saveShortcutRegistry`。
Future<void> _saveShortcuts(OpContext context) => saveShortcutRegistry(
  context.appModel.shortcutRegistry,
  ReaderFushiSource.instance,
);

/// 新绑定在同时生效的作用域里撞上的别的动作（检测与设置页编辑对话框同一组
/// `has*Conflict`，含 app 外热键对页面键的单向抢占）。
List<({Object binding, ShortcutAction owner})> _shortcutConflicts(
  FushiShortcutRegistry registry,
  ShortcutAction action,
  List<Object> bindings,
) => <({Object binding, ShortcutAction owner})>[
  for (final Object binding in bindings)
    if (switch (binding) {
          InputBinding() => registry.hasKeyboardConflict(
            action.scope,
            binding,
            exclude: action,
          ),
          GamepadBinding() => registry.hasGamepadConflict(
            action.scope,
            binding,
            exclude: action,
          ),
          MouseBinding() => registry.hasMouseConflict(
            action.scope,
            binding,
            exclude: action,
          ),
          WheelBinding() => registry.hasWheelConflict(
            action.scope,
            binding,
            exclude: action,
          ),
          _ => null,
        }
        case final ShortcutAction owner)
      (binding: binding, owner: owner),
];

/// `keys set`：body `bindings`（token 列表）、`mode`（replace / add）、
/// `conflict`（fail / steal / keep）。
///
/// - replace：被提到的通道整体换成新绑定（键盘只给了键盘键就只换键盘那条）；
/// - steal：把撞车的绑定从原动作上摘掉（设置页编辑对话框的「重新分配」）；
/// - keep：两个动作都保留（同设置页「都保留」，后注册的那个不会触发）。
Future<Object?> _setShortcut(OpContext context, CtlCall call) async {
  final ShortcutAction action = _requireShortcutAction(call.params['action']!);
  final List<String> tokens = call.stringList('bindings');
  if (tokens.isEmpty) throw const CtlFailure.badRequest('bindings 缺失');
  final List<Object> added = <Object>[
    for (final String token in tokens) parseCtlShortcutBinding(token),
  ];
  final String mode = call.optString('mode') ?? 'replace';
  if (mode != 'replace' && mode != 'add') {
    throw CtlFailure.badRequest('mode 只能是 replace / add，收到「$mode」');
  }
  final String conflictMode = call.optString('conflict') ?? 'fail';
  if (!<String>['fail', 'steal', 'keep'].contains(conflictMode)) {
    throw CtlFailure.badRequest(
      'conflict 只能是 fail / steal / keep，收到「$conflictMode」',
    );
  }
  final FushiShortcutRegistry registry = context.appModel.shortcutRegistry;
  final List<({Object binding, ShortcutAction owner})> conflicts =
      _shortcutConflicts(registry, action, added);
  if (conflicts.isNotEmpty && conflictMode == 'fail') {
    throw CtlFailure.conflict(
      '绑定已被占用：'
      '${conflicts.map((({Object binding, ShortcutAction owner}) c) => '${ctlShortcutBindingToken(c.binding)} → ${c.owner.key}').join('，')}'
      '；抢过来加 --steal，两边都留加 --keep-both',
    );
  }
  final ShortcutBindingSet next = ctlShortcutMergedBindings(
    registry.bindingsFor(action),
    added,
    replace: mode == 'replace',
  );
  if (conflictMode == 'steal') {
    final List<Object> taken = <Object>[
      for (final ({Object binding, ShortcutAction owner}) c in conflicts)
        c.binding,
    ];
    registry.updateBindingWithReassignments(
      action,
      next,
      removeKeyboardConflicts: taken.whereType<InputBinding>(),
      removeGamepadConflicts: taken.whereType<GamepadBinding>(),
      removeMouseConflicts: taken.whereType<MouseBinding>(),
      removeWheelConflicts: taken.whereType<WheelBinding>(),
    );
  } else {
    registry.updateBinding(action, next);
  }
  await _saveShortcuts(context);
  return <String, Object?>{
    'shortcut': _shortcutRow(action, registry.bindingsFor(action)),
    if (conflicts.isNotEmpty)
      'conflicts': <Map<String, Object?>>[
        for (final ({Object binding, ShortcutAction owner}) c in conflicts)
          <String, Object?>{
            'binding': ctlShortcutBindingToken(c.binding),
            'action': c.owner.key,
            'resolution': conflictMode == 'steal' ? 'removed' : 'kept',
          },
      ],
  };
}

/// `keys unbind`：body `bindings` 给出要摘掉的绑定；不给且 `all=true` + confirm
/// 时清空该动作的全部绑定。
Future<Object?> _unbindShortcut(OpContext context, CtlCall call) async {
  final ShortcutAction action = _requireShortcutAction(call.params['action']!);
  final FushiShortcutRegistry registry = context.appModel.shortcutRegistry;
  final List<String> tokens = call.stringList('bindings');
  final ShortcutBindingSet next;
  if (tokens.isEmpty) {
    if (call.optBool('all') != true || call.optBool('confirm') != true) {
      throw const CtlFailure.badRequest(
        '给出要解绑的绑定；清空全部绑定需要 all=true 与 confirm=true',
      );
    }
    next = const ShortcutBindingSet();
  } else {
    next = ctlShortcutWithout(registry.bindingsFor(action), <Object>[
      for (final String token in tokens) parseCtlShortcutBinding(token),
    ]);
  }
  registry.updateBinding(action, next);
  await _saveShortcuts(context);
  return <String, Object?>{
    'shortcut': _shortcutRow(action, registry.bindingsFor(action)),
  };
}

/// `keys reset`：body `action`（单个动作，设置页行内「恢复默认」）/ `scope`
/// （一组，`resetScopeToDefaults`）/ `all`（整张表，`resetToDefaults`）三选一；
/// 分组与整张表需要 confirm（与设置页同样先确认）。
Future<Object?> _resetShortcuts(OpContext context, CtlCall call) async {
  final String? actionRaw = call.optString('action');
  final String? scopeRaw = call.optString('scope');
  final bool all = call.optBool('all') ?? false;
  final int targets =
      (actionRaw != null ? 1 : 0) + (scopeRaw != null ? 1 : 0) + (all ? 1 : 0);
  if (targets != 1) {
    throw const CtlFailure.badRequest('action / scope / all 必须且只能给一个');
  }
  final FushiShortcutRegistry registry = context.appModel.shortcutRegistry;
  final List<ShortcutAction> affected;
  if (actionRaw != null) {
    final ShortcutAction action = _requireShortcutAction(actionRaw);
    registry.updateBinding(
      action,
      ShortcutDefaults.forPlatform(defaultTargetPlatform)[action] ??
          const ShortcutBindingSet(),
    );
    affected = <ShortcutAction>[action];
  } else {
    if (call.optBool('confirm') != true) {
      throw const CtlFailure.badRequest('整组 / 全部恢复默认需要 confirm=true');
    }
    if (scopeRaw != null) {
      final ShortcutScope? scope = parseCtlShortcutScope(scopeRaw);
      if (scope == null) {
        throw CtlFailure.badRequest(
          '没有作用域「$scopeRaw」；可选：'
          '${ShortcutScope.values.map((ShortcutScope s) => s.name).join(' | ')}',
        );
      }
      registry.resetScopeToDefaults(scope, defaultTargetPlatform);
      affected = ShortcutAction.actionsForScope(scope);
    } else {
      registry.resetToDefaults(defaultTargetPlatform);
      affected = ShortcutAction.values;
    }
  }
  await _saveShortcuts(context);
  return <String, Object?>{
    'reset': affected.length,
    'shortcuts': <Map<String, Object?>>[
      for (final ShortcutAction action in affected)
        _shortcutRow(action, registry.bindingsFor(action)),
    ],
  };
}

/// `/api/admin/shortcuts` 每行的三列绑定。
///
/// 这是给人看的列表（`fushi_cli keys ls` 直接渲染成表），按当前平台的显示约定出：
/// 键盘与滚轮绑定都走 `displayLabel`，macOS 上就是 `⌘F` / `⌥WheelDown` 这类符号
/// 写法，与 app 内快捷键设置页同形（用户 2026-10-10 拍板「根据 mac 的来」）。
/// 手柄 / 鼠标键没有修饰键、也没有平台差异，沿用 `serialize()` token。
Map<String, List<String>> ctlShortcutBindingColumns(
  ShortcutBindingSet bindings,
) => <String, List<String>>{
  'keyboard': <String>[
    for (final InputBinding b in bindings.keyboardBindings) b.displayLabel,
  ],
  'gamepad': <String>[
    for (final GamepadBinding b in bindings.gamepadBindings) b.serialize(),
  ],
  'mouse': <String>[
    for (final MouseBinding b in bindings.mouseBindings) b.serialize(),
    for (final WheelBinding b in bindings.wheelBindings) b.displayLabel,
  ],
};
