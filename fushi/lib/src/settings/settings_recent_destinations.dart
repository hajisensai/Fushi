import 'dart:convert';

import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:material_ui/material_ui.dart';

/// 最多记几个最近打开的设置一级分类。
const int kSettingsRecentDestinationLimit = 5;

/// 解出偏好 `settings_recent_destinations` 的值（JSON 字符串数组，最近的在前）。
/// 空串 / 坏 JSON 当没有记录；不认识的名字（分类改名 / 删掉）跳过。
List<SettingsDestinationId> decodeSettingsRecentDestinations(String raw) {
  if (raw.isEmpty) return const <SettingsDestinationId>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return const <SettingsDestinationId>[];
  }
  if (decoded is! List) return const <SettingsDestinationId>[];
  final Map<String, SettingsDestinationId> byName =
      <String, SettingsDestinationId>{
        for (final SettingsDestinationId id in SettingsDestinationId.values)
          id.name: id,
      };
  return <SettingsDestinationId>[
    for (final Object? name in decoded)
      if (byName[name] case final SettingsDestinationId id) id,
  ];
}

/// [id] 挪到最前、去重、截到 [kSettingsRecentDestinationLimit]。
List<SettingsDestinationId> pushSettingsRecentDestination(
  List<SettingsDestinationId> current,
  SettingsDestinationId id,
) => <SettingsDestinationId>[
  id,
  ...current.where((SettingsDestinationId e) => e != id),
].take(kSettingsRecentDestinationLimit).toList();

/// 最近打开的设置一级分类（最近的在前），首页侧栏「设置」速览卡读它（设备本地）。
List<SettingsDestinationId> readSettingsRecentDestinations(
  PreferencesRepository prefs,
) => decodeSettingsRecentDestinations(prefs.settingsRecentDestinationsJson);

/// 把 [id] 记成最近打开的分类。已经在最前就不写库。
Future<void> recordSettingsDestinationVisit(
  PreferencesRepository prefs,
  SettingsDestinationId id,
) async {
  final List<SettingsDestinationId> current = readSettingsRecentDestinations(
    prefs,
  );
  if (current.isNotEmpty && current.first == id) return;
  await prefs.setSettingsRecentDestinationsJson(
    jsonEncode(<String>[
      for (final SettingsDestinationId e in pushSettingsRecentDestination(
        current,
        id,
      ))
        e.name,
    ]),
  );
}

/// 从设置页外面（首页侧栏速览卡）请求「打开这个设置分类」：写入后由设置主页
/// 消费并清回 null——宽屏主从切选中分类，窄屏推详情页。设置 tab 还没挂载时
/// 请求挂着，主页挂载时取走。
final ValueNotifier<SettingsDestinationId?> settingsDestinationRequest =
    ValueNotifier<SettingsDestinationId?>(null);
