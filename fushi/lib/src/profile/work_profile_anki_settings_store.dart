import 'dart:convert';

import 'package:fushi_anki/fushi_anki.dart';

import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/profile/work_profile_scope.dart';

/// 反馈 kEFPY4cuKZ：制卡链用的 Anki 设置存储——打开带作品级配置的作品时，牌组 / 笔记类型 /
/// 字段映射 / 标签 / 查重范围（[ProfileKeys.ankiSettingsToMap] 那几个**配置拥有**的字段）按
/// 作品配置读写；其余字段（连接地址、后端选择、Lapis 样式……设备本地 / 不随配置走）照旧是
/// live 设置。没有会话（或作品配置的快照里没有 Anki 字段）时与 [live] 逐字节一致。
///
/// 与 `ProfileSettingsView` 的合成规则同一套（[ProfileKeys.mapToAnkiSettings] 叠在 live
/// 上），只是每次读都现合成：会话期间改了 live 的设备本地字段（换 AnkiConnect 地址）立即生效。
///
/// 只给制卡 / 制卡设置页那条链用（`ankiRepositoryProvider`）。快照 / 应用配置的
/// `ProfileRepository` 用裸的 live 存储——它处理的是**激活配置**的设置，叠会话会把作品配置的
/// 牌组快照进激活配置。
class WorkScopedAnkiSettingsStore implements AnkiSettingsStore {
  /// [live] 每次读写时求值（默认 = 本 isolate 装配的 live 存储，装配点后换也跟得上）。
  WorkScopedAnkiSettingsStore({
    AnkiSettingsStore Function()? live,
    WorkProfileScope? scope,
  }) : _live = live ?? (() => BaseAnkiRepository.defaultSettingsStore),
       _scope = scope ?? WorkProfileScope.instance;

  final AnkiSettingsStore Function() _live;
  final WorkProfileScope _scope;

  static AnkiSettings _decode(String? raw) {
    if (raw == null) return const AnkiSettings();
    try {
      return AnkiSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on Object {
      return const AnkiSettings();
    }
  }

  static bool _sameMap(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final MapEntry<String, String> e in a.entries) {
      if (b[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  Future<String?> read() async {
    final String? liveRaw = await _live().read();
    final Map<String, String>? overrides = await _scope.readAnki();
    if (overrides == null) return liveRaw;
    return jsonEncode(
      ProfileKeys.mapToAnkiSettings(overrides, _decode(liveRaw)).toJson(),
    );
  }

  @override
  Future<void> write(String json) async {
    final AnkiSettingsStore live = _live();
    if (_scope.active == null) {
      await live.write(json);
      return;
    }
    final Map<String, String>? overrides = await _scope.readAnki();
    final AnkiSettings wanted = _decode(json);
    final Map<String, String> wantedOwned = ProfileKeys.ankiSettingsToMap(
      wanted,
    );
    final String? liveRaw = await live.read();
    final AnkiSettings liveSettings = _decode(liveRaw);
    // 绑定配置还没接管 Anki 设置、这次写入也没改配置拥有的字段（只改了 AnkiConnect 地址之类
    // 的设备本地字段，或读时迁移的回写）：照旧写 live，不把此刻的全局牌组固化进作品配置——
    // 否则这份配置从此钉在这一刻的全局牌组上、不再跟随 live。
    if (overrides == null &&
        _sameMap(wantedOwned, ProfileKeys.ankiSettingsToMap(liveSettings))) {
      await live.write(json);
      return;
    }
    // 配置拥有的字段写进作品配置；其余字段（设备本地）写回 live，但 live 上配置拥有的字段
    // 保持全局原值——全局配置的牌组不因在书里改了牌组而变。
    await _scope.writeAnki(wantedOwned);
    final String merged = jsonEncode(
      ProfileKeys.mapToAnkiSettings(
        ProfileKeys.ankiSettingsToMap(liveSettings),
        wanted,
      ).toJson(),
    );
    if (merged != liveRaw) await live.write(merged);
  }
}
