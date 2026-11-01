/// 可移植偏好设置：判定 + 跨设备合并（反馈 AWp-0BtDDv）。
///
/// 用户诉求：备份与同步只带了少量设置（词典等），希望「除了平台相关、需要本机路径、
/// 依赖外部工具（如 AnkiConnect）的，其余设置都能带上」。所有者批准：备份 / 同步可选
/// 包含全部偏好设置，排除不可移植项，排除清单明确、有测试。
///
/// 现状核对（不是「备份里没有设置」）：
/// - 备份导出的 `settings` 类别本来就带整张 `preferences`（只剔凭据 / 设备本地），
///   但只有**覆盖导入 + 勾「导入设置」**才会用上；**合并导入**恒保留本机设置——
///   `BackupMergeEngine` 对 preferences 只合并几处点名的内容键（收藏句、有声书位置、
///   音频来源、书名改名），其余设置一行都不进来。
/// - 云同步 / 互联同步**没有任何设置通道**（互联只有「外部服务身份」小白名单与手动的
///   整份 Profile 搬运）。
///
/// 所以补的是两个开关，共用本文件这一个判定：
/// 1. 同步页「同步设置」：每台设备在同步根 `__settings__/` 下写一份自己的可移植设置
///    快照（`settings-<deviceId>.json`，按设备分文件，两台设备并发写互不覆盖），读取
///    时把所有对端快照按 key 取最新，再与本机按修改时刻 LWW。
/// 2. 备份页「合并导入时包含设置」：合并导入时按同一判定把备份里的可移植设置并进来，
///    同样按修改时刻取较新者。
library;

import 'dart:convert';

import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/sync/backup_service.dart'
    show backupContentRegistryPrefKeys;
import 'package:fushi_core/fushi_core.dart';
import 'package:meta/meta.dart';

/// 「一条 preferences key 能不能作为设置跨设备流动」的唯一判定。
///
/// 判定顺序（任一命中即不可移植），[exclusionReason] 给出命中的那一条：
/// 1. [ProfileKeys.isExcludedPref]——凭据 / 设备本地（`PrefRedactionPolicy` 与
///    `SyncRepository.deviceLocalPrefKeys`）、本库状态标记（版本号、首启、迁移结论、
///    激活 Profile id）、按条目的内容状态（有声书位置 / 速度、书名改名、扫描索引……）、
///    这台设备的界面布局（缩放、语言、导航栏、页签顺序）、更新通道与代理。
/// 2. [backupContentRegistryPrefKeys]——收藏句 / 本地音频库 / 音频来源 / 字体目录：
///    各有自己的资产通道，值里是本机文件路径。
/// 3. [nonPortablePrefixes]——整族设备 / 通道 / 平台状态。
/// 4. [nonPortableTokens]——key 按非字母数字切成词，含其中任一词即排除：本机路径、
///    窗口几何、平台专属、外部工具连接。
///
/// 防漏优先于防误伤：误伤一个只是那项设置不跨设备跟随（各设备照旧各自保存），漏一个
/// 则是把别的设备的路径 / 连接地址写进这台设备。
abstract final class PortableSettingsPolicy {
  /// 整族不可移植的 key 前缀。
  static const List<String> nonPortablePrefixes = <String>[
    // 同步 / 备份 / 互联 / P2P / 网络：通道配置、基线、开关本身（「同步设置」开关若
    // 跟着同步，一台设备关掉就会把所有设备一起关掉）。
    'sync_',
    'backup_',
    'interconnect_',
    'p2p_',
    'network_',
    'update_',
    // 复习同步 v2 的存储位置、密钥。
    'srs_sync2_',
    // 数据目录 / 沙盒书签 / 桌面窗口：本机文件系统与屏幕。
    'data_root',
    'sandbox_',
    'desktop_',
    'migration_',
    // galgame 文本 / 语音 hook 只在 Windows 上有，参数与具体游戏进程绑定。
    'gal_hook',
    'galgame',
    // 「上一次」系列是这台设备的使用状态，不是设置。
    'last_',
  ];

  /// key 里出现即排除的词（key 按 `[^a-z0-9]+` 切词后逐词比较，不做子串匹配，
  /// `export` 不会命中 `port`，`portrait` 也不会）。
  static const Set<String> nonPortableTokens = <String>{
    // 本机路径
    'path', 'paths', 'dir', 'dirs', 'directory', 'folder', 'folders', 'root',
    'roots', 'exe', 'executable', 'binary', 'bookmark',
    // 窗口 / 屏幕几何
    'window', 'rect', 'tray', 'autostart', 'monitor',
    // 平台专属
    'windows', 'macos', 'linux', 'android', 'ios', 'overlay', 'hotkey',
    'hwdec', 'gpu', 'device', 'devices',
    // 外部工具 / 服务连接（地址、端口、外部进程）
    'host', 'port', 'url', 'urls', 'endpoint', 'server', 'servers', 'proxy',
    'anki', 'ankiconnect', 'mpv', 'ffmpeg', 'qb', 'qbittorrent', 'jellyfin',
    'plex', 'emby', 'subsonic', 'kavita', 'opds', 'alist', 'audiobookshelf',
    'yomitan', 'obs', 'texthooker', 'websocket', 'lunahook', 'torznab',
    // 缓存 / 迁移 / 一次性提示
    'cache', 'cached', 'migrated', 'migration', 'baseline', 'dismissed',
    'notice', 'onboarding',
  };

  static final RegExp _tokenSplitter = RegExp(r'[^a-z0-9]+');

  /// [key] 能否作为设置跨设备流动。
  static bool isPortable(String key) => exclusionReason(key) == null;

  /// [key] 不可移植的原因（测试与诊断用）；可移植时 null。
  static String? exclusionReason(String key) {
    if (ProfileKeys.isExcludedPref(key)) {
      return 'device-local / credential / per-item state (ProfileKeys)';
    }
    if (backupContentRegistryPrefKeys.contains(key)) {
      return 'content registry with its own sync channel';
    }
    final String lower = key.toLowerCase();
    for (final String prefix in nonPortablePrefixes) {
      if (lower.startsWith(prefix)) return 'prefix "$prefix"';
    }
    for (final String token in lower.split(_tokenSplitter)) {
      if (nonPortableTokens.contains(token)) return 'token "$token"';
    }
    return null;
  }
}

/// 一项可移植设置：原样的持久化值 + 最后修改时刻（`preferences.updated_at`，毫秒；
/// 0 = 时刻未知，见 `Preferences.updatedAt` 的文档）。
@immutable
class PortableSettingValue {
  const PortableSettingValue(this.value, this.updatedAt);

  final String value;
  final int updatedAt;

  @override
  bool operator ==(Object other) =>
      other is PortableSettingValue &&
      other.value == value &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(value, updatedAt);
}

/// 一台设备发布的可移植设置快照（`__settings__/settings-<deviceId>.json`）。
@immutable
class SettingsSnapshot {
  const SettingsSnapshot({required this.deviceId, required this.entries});

  static const String format = 'fushi.settings';
  static const int version = 1;

  final String deviceId;
  final Map<String, PortableSettingValue> entries;

  /// 确定性编码（key 排序）：内容相同 ⇒ 字节相同，回写前据此判断要不要写。
  String canonicalJson() {
    final List<String> keys = entries.keys.toList()..sort();
    return jsonEncode(<String, Object?>{
      'format': format,
      'version': version,
      'deviceId': deviceId,
      'entries': <String, Object?>{
        for (final String k in keys)
          k: <String, Object?>{
            'v': entries[k]!.value,
            't': entries[k]!.updatedAt,
          },
      },
    });
  }

  Object? toJson() => jsonDecode(canonicalJson());

  /// 解析对端快照；格式不对抛 [FormatException]。读入时**再过一遍**
  /// [PortableSettingsPolicy]：对端可能是判定更宽的旧 / 新版本，不能因为它发了就收。
  static SettingsSnapshot fromJson(Object? json) {
    if (json is! Map || json['format'] != format) {
      throw const FormatException('not a fushi settings snapshot');
    }
    final Object? v = json['version'];
    if (v is! int || v > version) {
      throw FormatException('unsupported settings snapshot version: $v');
    }
    final Object? rawEntries = json['entries'];
    if (rawEntries is! Map) {
      throw const FormatException('settings snapshot without entries');
    }
    final Map<String, PortableSettingValue> entries =
        <String, PortableSettingValue>{};
    rawEntries.forEach((Object? k, Object? e) {
      if (k is! String || e is! Map) return;
      final Object? value = e['v'];
      final Object? t = e['t'];
      if (value is! String) return;
      if (!PortableSettingsPolicy.isPortable(k)) return;
      entries[k] = PortableSettingValue(value, t is int ? t : 0);
    });
    final Object? id = json['deviceId'];
    return SettingsSnapshot(deviceId: id is String ? id : '', entries: entries);
  }
}

/// 同步根下设置快照的命名空间与文件名。
const String kSyncSettingsNamespace = '__settings__';

/// 本设备快照的文件名。
String settingsSnapshotNameFor(String deviceId) => 'settings-$deviceId.json';

/// 是否是设置快照文件名。
bool isSettingsSnapshotName(String name) =>
    name.startsWith('settings-') && name.endsWith('.json');

/// 把多份对端快照折叠成「每个 key 最新的那份值」。时刻相同取字典序较大的值，
/// 保证与折叠顺序无关（各设备折出同一个结果）。
Map<String, PortableSettingValue> foldSettingsSnapshots(
  Iterable<SettingsSnapshot> snapshots,
) {
  final Map<String, PortableSettingValue> out =
      <String, PortableSettingValue>{};
  for (final SettingsSnapshot s in snapshots) {
    s.entries.forEach((String k, PortableSettingValue v) {
      final PortableSettingValue? cur = out[k];
      if (cur == null ||
          v.updatedAt > cur.updatedAt ||
          (v.updatedAt == cur.updatedAt && v.value.compareTo(cur.value) > 0)) {
        out[k] = v;
      }
    });
  }
  return out;
}

/// 远端设置里该落到本机的那部分。
///
/// - [firstAlignment] 为 true（本设备第一次开设置同步）：远端每一项都采纳（值不同
///   才算），时刻沿用远端的——新装的设备会以 `now` 写一批默认值，按时刻比会让这些
///   默认值盖掉别处调了很久的设置。
/// - 否则严格 LWW：本机没有这项、或远端时刻**严格更新**才采纳；平局保留本机
///   （与 `FushiDatabase.setPrefIfNewer` 同一规则）。
Map<String, PortableSettingValue> settingsToAdopt({
  required Map<String, PortableSettingValue> local,
  required Map<String, PortableSettingValue> remote,
  required bool firstAlignment,
}) {
  final Map<String, PortableSettingValue> out =
      <String, PortableSettingValue>{};
  remote.forEach((String k, PortableSettingValue r) {
    if (!PortableSettingsPolicy.isPortable(k)) return;
    final PortableSettingValue? l = local[k];
    if (l == null) {
      out[k] = r;
    } else if (firstAlignment) {
      if (l.value != r.value) out[k] = r;
    } else if (r.updatedAt > l.updatedAt && l.value != r.value) {
      out[k] = r;
    }
  });
  return out;
}

/// 读本机全部可移植设置（key → 值 + 修改时刻）。
Future<Map<String, PortableSettingValue>> loadLocalPortableSettings(
  FushiDatabase db,
) async {
  final List<PreferenceRow> rows = await db.select(db.preferences).get();
  return <String, PortableSettingValue>{
    for (final PreferenceRow r in rows)
      if (PortableSettingsPolicy.isPortable(r.key))
        r.key: PortableSettingValue(r.value, r.updatedAt),
  };
}

/// 把 [adopt] 写进本机；返回实际改动的行数。[firstAlignment] 见 [settingsToAdopt]。
Future<int> applyAdoptedSettings(
  FushiDatabase db,
  Map<String, PortableSettingValue> adopt, {
  required bool firstAlignment,
}) async {
  int changed = 0;
  for (final MapEntry<String, PortableSettingValue> e in adopt.entries) {
    final bool wrote = firstAlignment
        ? await db.adoptPrefWithStamp(
            e.key,
            e.value.value,
            updatedAt: e.value.updatedAt,
          )
        : await db.setPrefIfNewer(
            e.key,
            e.value.value,
            updatedAt: e.value.updatedAt,
          );
    if (wrote) changed++;
  }
  return changed;
}
