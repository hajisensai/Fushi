import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/ops/ctl_settings_credential_endpoints.dart';
import 'package:fushi/src/ops/ctl_settings_values.dart';
import 'package:fushi/src/settings/settings_actions.dart'
    show notifyReaderSettingsChanged;
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_kit.dart'
    show SettingsResetSpec, settingsResetSpecFor;
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/utils/fushi_localisations.dart';

/// 设置索引：把整棵设置 schema（含子页与控制通道逃生口页面）展平成「键 → 条目」，
/// 并提供读值（[settingsIndexEntryJson]）与写值（[applySettingsIndexValue]）。
///
/// 唯一实现，两个消费方：`fushi_cli config`（`ctl_settings_routes.dart`）与第二屏
/// 伴屏的设置页（`second_screen/companion/companion_settings_service.dart`）。
/// 值的读写都直接调该条目在设置页里的 value / onChanged 闭包，与在设置页里操作
/// 等价（同一个 AppModel setter + 同一套联动通知）。失败一律抛 [CtlFailure]
/// （控制通道直接映射成 HTTP 状态，伴屏转成错误应答）。

/// 全局设置上下文（不在任何播放页里）：BuildContext 取主导航器的。主窗口还没
/// 起来时抛 409。
SettingsContext settingsIndexContext(AppModel appModel, WidgetRef ref) {
  final BuildContext? buildContext = appModel.navigatorKey.currentContext;
  if (buildContext == null) {
    throw const CtlFailure.conflict('主窗口尚未就绪，稍后再试');
  }
  return SettingsContext(
    context: buildContext,
    appModel: appModel,
    ref: ref,
    readerSource: ReaderFushiSource.instance,
    refresh: () {},
  );
}

/// 自绘行（主题 / 明暗 / 界面语言）没有 schema 值闭包；这里按自绘行里的同一组
/// AppModel 读写方法补上，键沿用该行的 schema id。
class SettingsIndexVirtual {
  const SettingsIndexVirtual({
    required this.read,
    required this.options,
    required this.write,
  });

  final String Function(AppModel appModel) read;
  final List<(String, String)> Function(AppModel appModel) options;
  final Future<void> Function(SettingsContext context, String value) write;
}

final Map<String, SettingsIndexVirtual> settingsIndexVirtuals =
    <String, SettingsIndexVirtual>{
      // buildDesignSystemSelector（settings_actions.dart）：只开放设置页列出的三档，
      // Apple 等隐藏值由 ThemeNotifier 在写入边界归一化。
      'appearance.design_system': SettingsIndexVirtual(
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
      'appearance.brightness': SettingsIndexVirtual(
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
      'appearance.theme': SettingsIndexVirtual(
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
      'appearance.language': SettingsIndexVirtual(
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
class SettingsIndexEntry {
  SettingsIndexEntry({
    required this.key,
    required this.title,
    required this.breadcrumb,
    required this.visible,
    this.item,
    this.virtual,
    this.destinationId,
    this.pagePath,
  });

  final String key;
  final String title;
  final String breadcrumb;
  final bool visible;

  /// 所属一级分类；逃生口页面（[CtlBodyPage]）的条目为 null。
  final SettingsDestinationId? destinationId;

  /// 分类内的位置（「分区」或「子页 › 分区」）；直接在分类首页、没有分区标题的
  /// 条目为 null。
  final String? pagePath;
  final SettingsItem? item;
  final SettingsIndexVirtual? virtual;

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
/// 明暗 / 语言 / 设计系统这几条自绘行另见 [settingsIndexVirtuals]，可直接写值）。
///
/// [destinations] / [bodyPages] 默认是完整 schema 与全部逃生口页面（测试可注入
/// 片段）。
Map<String, SettingsIndexEntry> buildSettingsIndex(
  SettingsContext context, {
  List<SettingsDestination>? destinations,
  List<CtlBodyPage>? bodyPages,
}) {
  final Map<String, SettingsIndexEntry> index = <String, SettingsIndexEntry>{};

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
    SettingsDestinationId? destinationId,
    String? pagePath,
  }) {
    if (index.containsKey(item.id)) return;
    final SettingsIndexVirtual? virtual = settingsIndexVirtuals[item.id];
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
    index[item.id] = SettingsIndexEntry(
      key: item.id,
      title: item is SettingsCustomItem
          ? (item.searchTitle ?? item.id)
          : item.title,
      breadcrumb: breadcrumb,
      visible: visible,
      item: virtual == null ? item : null,
      virtual: virtual,
      destinationId: destinationId,
      pagePath: pagePath,
    );
  }

  void walk(
    SettingsDestination page, {
    required SettingsDestinationId destinationId,
    required String breadcrumb,
    required String? pagePath,
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
      final String? sectionPath =
          section.title == null || section.title!.isEmpty
          ? pagePath
          : pagePath == null
          ? section.title
          : '$pagePath › ${section.title}';
      for (final SettingsItem item in section.items) {
        final bool visible =
            sectionVisible && safeVisible(() => item.isVisible(context));
        add(
          item,
          breadcrumb: sectionCrumb,
          visible: visible,
          destinationId: destinationId,
          pagePath: sectionPath,
        );
        if (item is SettingsNavigationItem &&
            item.child != null &&
            depth < _kSubPageMaxDepth) {
          final SettingsDestination child = item.child!();
          walk(
            child,
            destinationId: destinationId,
            breadcrumb: '$sectionCrumb › ${child.title}',
            pagePath: sectionPath == null
                ? child.title
                : '$sectionPath › ${child.title}',
            parentVisible: visible,
            depth: depth + 1,
          );
        }
      }
    }
  }

  for (final SettingsDestination destination
      in destinations ?? buildSettingsSchema(context)) {
    walk(
      destination,
      destinationId: destination.id,
      breadcrumb: destination.title,
      pagePath: null,
      parentVisible: true,
      depth: 0,
    );
  }
  // 逃生口页面（Anki 设置页、媒体服务器配置页…）的条目：schema 树里没有，
  // 用同一套 item 类型在 ctl_settings_body_*.dart 里声明。
  for (final CtlBodyPage page in bodyPages ?? buildCtlBodyPages()) {
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
Map<String, Object?> settingsIndexEntryJson(
  SettingsIndexEntry entry,
  SettingsContext context,
) {
  Object? value;
  String display;
  List<String>? options;
  num? min;
  num? max;
  String? error;
  try {
    final SettingsIndexVirtual? virtual = entry.virtual;
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
    if (settingsIndexRunnable(entry)) 'runnable': true,
    if (item is SettingsActionItem &&
        (item.destructive || cli?.confirm == true))
      'destructive': true,
    if (entry.cliValue?.help != null) 'help': entry.cliValue!.help,
    if (cli?.unsupportedHint != null) 'hint': cli!.unsupportedHint,
    if (cli != null && cli.params.isNotEmpty)
      'params': <Map<String, Object?>>[
        for (final SettingsCliParam param in cli.params)
          settingsCliParamJson(param),
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
        for (final SettingsCliParam param in list.fields)
          settingsCliParamJson(param),
      ],
    if (error != null) 'error': error,
  };
}

Map<String, Object?> settingsCliParamJson(SettingsCliParam param) =>
    <String, Object?>{
      'name': param.name,
      'help': param.help,
      'required': param.required,
      if (param.path) 'path': true,
      if (param.secret) 'secret': true,
    };

/// 能经 `config run` 执行：动作行，或带按钮的状态行。
bool settingsIndexRunnable(SettingsIndexEntry entry) {
  final SettingsItem? item = entry.item;
  return (item is SettingsActionItem &&
          item.cli != null &&
          item.cli!.unsupportedHint == null) ||
      (item is SettingsStatusItem && item.onAction != null);
}

SettingsIndexEntry requireSettingsIndexEntry(
  Map<String, SettingsIndexEntry> index,
  String key,
) {
  final SettingsIndexEntry? entry = index[key];
  if (entry == null) {
    throw CtlFailure.badRequest('未知设置项「$key」（用 config ls --search 查键名）');
  }
  return entry;
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

Future<void> applySettingsIndexValue(
  SettingsIndexEntry entry,
  SettingsContext context,
  String raw,
) async {
  final SettingsIndexVirtual? virtual = entry.virtual;
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
      // 开关也可能拒绝某个值（例如要求改走带确认的动作）：ArgumentError → 400。
      await guardSettingsCliInput<void>(() async {
        await item.onChanged(context, parseCtlSettingBool(raw));
      });
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
      await guardSettingsCliInput<void>(() async {
        await item.onChanged(context, raw);
      });
    case SettingsCustomItem(cliValue: final SettingsCliValue cli):
      await guardSettingsCliInput(() => cli.write(context, raw));
    default:
      final bool resettable =
          item != null && settingsResetSpecFor(item, context) != null;
      throw CtlFailure.badRequest(
        '设置项「${entry.key}」（${entry.type}）不能直接写值'
        '${settingsIndexRunnable(entry) ? '；执行它用 config run' : ''}'
        '${entry.kind == CtlSettingKind.list ? '；记录列表用 config items' : ''}'
        '${resettable ? '；可用 config reset 恢复默认' : ''}',
      );
  }
}

/// 设置项自己的写入 / 执行体对非法参数抛 [ArgumentError] / [FormatException]：
/// 映射成 400，让 CLI 拿到可读原因而不是 500。
Future<T> guardSettingsCliInput<T>(Future<T> Function() body) async {
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
