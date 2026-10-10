import 'dart:async';
import 'dart:io';

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
import 'package:fushi/src/platform/desktop/ctl/ctl_settings_values.dart';
import 'package:fushi/src/platform/desktop/ctl/desktop_ctl_context.dart';
import 'package:fushi/src/profile/profile_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/settings/settings_actions.dart'
    show notifyReaderSettingsChanged;
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';
import 'package:fushi/src/stats/stat_window.dart';
import 'package:fushi/src/stats/study_diag_export.dart';
import 'package:fushi/src/utils/fushi_localisations.dart';
import 'package:fushi/src/utils/misc/build_version.dart';

/// settings 域控制通道路由（CLI 侧命令见 `packages/fushi_cli/lib/src/commands/settings_commands.dart`）。
///
/// - `/api/admin/settings`：设置项读写。键 = 设置 schema 的条目 id，值的读写
///   **直接调该条目在设置页里的 value / onChanged 闭包**，与在设置页拨开关、拖
///   滑条等价（同一个 AppModel setter + 同一套联动通知）；
/// - `/api/admin/modules`：功能模块开关（`AppModel.setModuleEnabled`）；
/// - `/api/admin/profiles`：Profile 管理（`ProfileViewModel`，与配置管理页同一组方法）；
/// - `/api/admin/stats`：学习统计（只经 `loadStatFacts` + `StatWindow`）；
/// - `/api/admin/shortcuts`：快捷键绑定（只读，`AppModel.shortcutRegistry`）。
List<CtlRoute> buildSettingsCtlRoutes(DesktopCtlContext context) => <CtlRoute>[
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
];

// ── 设置项 ──────────────────────────────────────────────────────────────────

/// 设置宿主上下文：与设置页同形（readerSource 单例），refresh 为空——CLI 没有
/// 要重建的设置页；设置项自己的联动（notifyListeners / 阅读器重注入）照常发生。
SettingsContext _settingsContext(DesktopCtlContext context) {
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
      _ => 'unknown',
    };
  }
}

const int _kSubPageMaxDepth = 3;

/// 把整棵 schema（含不可见项与子页）展平成「键 → 可读写条目」。只收有值闭包的
/// 条目类型；导航 / 动作 / 状态 / 自绘行没有可读写的值（自绘行另见 [_virtualSettings]）。
Map<String, _SettingEntry> _buildSettingIndex(SettingsContext context) {
  final Map<String, _SettingEntry> index = <String, _SettingEntry>{};

  bool safeVisible(bool Function() predicate) {
    try {
      return predicate();
    } catch (_) {
      return false;
    }
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
        final _VirtualSetting? virtual = _virtualSettings[item.id];
        final bool valued =
            virtual != null ||
            item is SettingsSwitchItem ||
            item is SettingsSegmentedItem ||
            item is SettingsSliderItem ||
            item is SettingsStepperItem ||
            item is SettingsNumberItem ||
            item is SettingsTextItem;
        if (valued && !index.containsKey(item.id)) {
          final String title = item is SettingsCustomItem
              ? (item.searchTitle ?? item.id)
              : item.title;
          index[item.id] = _SettingEntry(
            key: item.id,
            title: title,
            breadcrumb: sectionCrumb,
            visible: visible,
            item: virtual == null ? item : null,
            virtual: virtual,
          );
        }
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
            for (final SettingsSegmentOption<Object> option in item.options)
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
  return <String, Object?>{
    'key': entry.key,
    'type': entry.type,
    'title': entry.title,
    'section': entry.breadcrumb,
    'visible': entry.visible,
    'value': value,
    'display': display,
    if (entry.isSecret) 'redacted': true,
    if (options != null) 'options': options,
    if (min != null) 'min': min,
    if (max != null) 'max': max,
    if (error != null) 'error': error,
  };
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

Future<Object?> _listSettings(DesktopCtlContext context, CtlCall call) async {
  final SettingsContext settings = _settingsContext(context);
  final String query = call.optString('search') ?? '';
  final bool all = call.optBool('all') ?? false;
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[
    for (final _SettingEntry entry in _buildSettingIndex(settings).values)
      if ((all || entry.visible) &&
          matchesMediaSearch(
            query: query,
            titles: <String>[entry.key, entry.title, entry.breadcrumb],
          ))
        _settingJson(entry, settings),
  ];
  return <String, Object?>{'settings': rows, 'count': rows.length};
}

Future<Object?> _getSetting(DesktopCtlContext context, CtlCall call) async {
  final SettingsContext settings = _settingsContext(context);
  final _SettingEntry entry = _requireSettingEntry(
    _buildSettingIndex(settings),
    call.params['key']!,
  );
  return _settingJson(entry, settings);
}

Future<Object?> _setSetting(DesktopCtlContext context, CtlCall call) async {
  final SettingsContext settings = _settingsContext(context);
  final _SettingEntry entry = _requireSettingEntry(
    _buildSettingIndex(settings),
    call.params['key']!,
  );
  final Object? rawValue = call.body['value'] ?? call.query['value'];
  if (rawValue == null) throw const CtlFailure.badRequest('value 缺失');
  final String raw = '$rawValue';
  if (!entry.visible) {
    throw CtlFailure.rejected('设置项「${entry.key}」在当前平台 / 模块 / 状态下不可见，设置页里也改不了');
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
      final int index = indexOfCtlSettingOption(
        raw,
        tokens: <String>[
          for (final SettingsSegmentOption<Object> option in item.options)
            ctlSettingOptionToken(option.value),
        ],
        labels: <String>[
          for (final SettingsSegmentOption<Object> option in item.options)
            option.label,
        ],
      );
      await item.dispatchChange(context, item.options[index].value);
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
      await item.onChanged(context, raw);
    default:
      throw CtlFailure.badRequest('设置项「${entry.key}」不能直接写值');
  }
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

Future<Object?> _listModules(DesktopCtlContext context) async {
  final AppModel appModel = context.appModel;
  return <String, Object?>{
    'modules': <Map<String, Object?>>[
      for (final ModuleId module in ModuleId.values)
        _moduleJson(appModel, module),
    ],
  };
}

Future<Object?> _setModule(DesktopCtlContext context, CtlCall call) async {
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

// ── Profile ─────────────────────────────────────────────────────────────────

/// 取 Profile 视图模型并把状态刷到仓库真值（视图模型首次被读时的异步加载
/// 可能还没完成，`activeProfileId` 仍是 -1）。
Future<ProfileViewModel> _profileViewModel(DesktopCtlContext context) async {
  final ProfileViewModel viewModel = context.ref.read(
    profileViewModelProvider.notifier,
  );
  await viewModel.reload();
  return viewModel;
}

ProfileUiState _profileState(DesktopCtlContext context) =>
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

Map<String, Object?> _profileResult(
  DesktopCtlContext context,
  String action,
  int id,
) {
  final ProfileUiState state = _profileState(context);
  return <String, Object?>{
    'action': action,
    'profile': _profileJson(_resolveProfile(state, '$id'), state),
  };
}

Future<Object?> _listProfiles(DesktopCtlContext context) async {
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

Future<Object?> _activateProfile(
  DesktopCtlContext context,
  CtlCall call,
) async {
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

Future<Object?> _createProfile(DesktopCtlContext context, CtlCall call) async {
  final String name = call.requireString('name');
  final ProfileViewModel viewModel = await _profileViewModel(context);
  await viewModel.createProfile(name);
  return _profileResult(
    context,
    '已新建并切换到',
    _profileState(context).activeProfileId,
  );
}

Future<Object?> _renameProfile(DesktopCtlContext context, CtlCall call) async {
  final String name = call.requireString('name');
  final ProfileViewModel viewModel = await _profileViewModel(context);
  final ProfileRow target = _resolveProfile(
    _profileState(context),
    call.params['id']!,
  );
  await viewModel.renameProfile(target.id, name);
  return _profileResult(context, '已重命名', target.id);
}

Future<Object?> _copyProfile(DesktopCtlContext context, CtlCall call) async {
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
  final ProfileRow created = after.profiles.firstWhere(
    (ProfileRow profile) => !before.contains(profile.id),
    orElse: () => source,
  );
  return _profileResult(context, '已复制为', created.id);
}

Future<Object?> _deleteProfile(DesktopCtlContext context, CtlCall call) async {
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

Future<Object?> _exportProfile(DesktopCtlContext context, CtlCall call) async {
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

Future<Object?> _importProfile(DesktopCtlContext context, CtlCall call) async {
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

Future<Object?> _statsSummary(DesktopCtlContext context, CtlCall call) async {
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

Future<Object?> _statsSessions(DesktopCtlContext context, CtlCall call) async {
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

Future<Object?> _statsExport(DesktopCtlContext context, CtlCall call) async {
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

Future<Object?> _listShortcuts(DesktopCtlContext context, CtlCall call) async {
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
    rows.add(<String, Object?>{
      'scope': action.scope.name,
      'action': action.key,
      'label': action.label,
      ...ctlShortcutBindingColumns(bindings),
    });
  }
  return <String, Object?>{'shortcuts': rows, 'count': rows.length};
}

/// `/api/admin/shortcuts` 每行的三列绑定。
///
/// 手柄 / 鼠标列是持久化序列化格式（`serialize()`，与 `shortcut_bindings` 偏好
/// 同一套 token，跨平台恒定、可回读）；滚轮绑定同列，也必须走 `serialize()`——
/// 它的 `displayLabel` 自 BUG-3203 起随平台变成 `⌥WheelDown` 这类显示格式，
/// 混进来会让同一列在 macOS 上一半 token、一半符号（2026-10-10 审查）。
/// 键盘列历来是显示标签（`Ctrl+F` 而非持久化的 `Ctrl+KeyF`，BUG-3040），不变。
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
    for (final WheelBinding b in bindings.wheelBindings) b.serialize(),
  ],
};
