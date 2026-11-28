/// 「设置能不能跨设备同步」的名字形状兜底（反馈 AWp-0BtDDv 的排除清单）。
///
/// 它是偏好键登记表的一条 [PrefShapeRule]：命中的键把「不同步」并进生效策略
/// （[PrefPolicy.unsyncableOnly]，其它通道一概不动）。所以设置同步通道只读
/// `policyOf(key).syncable` 一个字段——登记的声明与这份形状兜底在登记表里合并成同一个
/// 结论，通道自己不再叠第二套判定。
///
/// 为什么需要兜底：只登记了名字的存量键（`kKnownPreferenceKeys`）和外部写进来的未登记键
/// 都按「普通设置」起算，其中带着本机路径、窗口几何、外部工具地址的不能流到别的设备。
/// 防漏优先于防误伤：误伤一个只是那项设置不跨设备跟随（各设备照旧各自保存），漏一个则是
/// 把别的设备的路径 / 连接地址写进这台设备。
///
/// 登记表构造期会校验：声明成可同步的固定键，名字不得命中这份形状（声明不得比生效策略
/// 宽）——想让一个名字带 `path` 的键同步，得先在这里把规则改准，而不是在别处开特例。
library;

import 'package:fushi_core/fushi_core.dart';

/// 名字带设备 / 通道 / 平台 / 外部工具形状的键不作为设置跨设备同步。
final class NonPortableSettingShapeRule extends PrefShapeRule {
  /// 形状规则。
  const NonPortableSettingShapeRule()
    : super(name: 'non-portable setting', policy: PrefPolicy.unsyncableOnly);

  /// 整族不可移植的 key 前缀（小写比较）。
  static const List<String> prefixes = <String>[
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
  static const Set<String> tokens = <String>{
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

  @override
  String? reasonFor(String key) {
    final String lower = key.toLowerCase();
    for (final String prefix in prefixes) {
      if (lower.startsWith(prefix)) return 'prefix "$prefix"';
    }
    for (final String token in lower.split(_tokenSplitter)) {
      if (tokens.contains(token)) return 'token "$token"';
    }
    return null;
  }
}

/// 登记表用的那一条实例。
const NonPortableSettingShapeRule kNonPortableSettingShapeRule =
    NonPortableSettingShapeRule();
