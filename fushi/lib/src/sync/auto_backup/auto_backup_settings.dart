/// 自动备份（定时还原点）的设置：间隔、偏好时刻、内容、落点
/// （docs/specs/2026-11-25-auto-backup-restore-points.md 第二层，D1 / D2 / D7）。
///
/// 全部存在设备本地偏好里（`preference_keys.dart` 的 `kAutoBackup*PrefKey`，登记在
/// `SyncRepository.deviceLocalPrefKeys`）。读写只经 [readAutoBackupSettings] /
/// [writeAutoBackupSettings]，设置页与控制通道共用。
library;

import 'dart:convert';

import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/sync/auto_backup/backup_folder_mirror.dart'
    show AutoBackupMirrorFolder;
import 'package:fushi/src/sync/backup_service.dart'
    show BackupCategory, kBackupFileCategories;

/// 自动备份间隔。
enum AutoBackupInterval {
  off(0),
  daily(1),
  every3Days(3),
  weekly(7);

  const AutoBackupInterval(this.days);

  /// 间隔天数；[off] 为 0。
  final int days;

  static AutoBackupInterval fromName(Object? raw) {
    for (final AutoBackupInterval v in values) {
      if (v.name == raw) return v;
    }
    return kAutoBackupDefaultInterval;
  }
}

/// 缺省间隔（D1：默认开、每日）。
const AutoBackupInterval kAutoBackupDefaultInterval = AutoBackupInterval.daily;

/// 缺省带的文件（D1「小集合」，用户 2026-11-25 改成「整库 + 挑文件」）：只带字体。每个定时
/// 还原点都是整库（书库各类条目、进度、统计、设置、配置档案、音乐、复习笔记与记录），这里只挑
/// 大块文件树（[kBackupFileCategories]）；书 / 有声书 / 视频 / 本地音频 / 词典 / 游戏封面默认
/// 不带，复习媒体另有开关（D2，默认不带）。
const Set<BackupCategory> kAutoBackupDefaultCategories = <BackupCategory>{
  BackupCategory.fonts,
};

/// 自动备份的一份设置快照（不可变）。
class AutoBackupSettings {
  const AutoBackupSettings({
    this.interval = kAutoBackupDefaultInterval,
    this.preferredMinuteOfDay,
    this.categories = kAutoBackupDefaultCategories,
    this.includeSrsMedia = false,
    this.customFolder,
    this.mirrorFolder,
  });

  final AutoBackupInterval interval;

  /// 偏好时刻（当天第几分钟，本地时间）；null = 不指定。
  final int? preferredMinuteOfDay;

  /// 带哪些文件树（只含 [kBackupFileCategories] 里的类别；数据类别恒在整库里，不在这里）。
  final Set<BackupCategory> categories;

  /// 带不带复习媒体（卡片图片 / 音频，D2，缺省不带）。复习笔记与记录恒在。
  final bool includeSrsMedia;

  /// 桌面端自定义文件夹（绝对路径）；null = 默认还原点目录。只有桌面端用（见 [effectiveFolder]）。
  final String? customFolder;

  /// 移动端的用户文件夹（第三期，Android SAF 树 / iOS 书签）：定时还原点照旧写进本机存储，写好后
  /// 复制一份进这里。null = 不复制。只有支持的平台用（见 [effectiveMirrorFolder]）。
  final AutoBackupMirrorFolder? mirrorFolder;

  bool get enabled => interval != AutoBackupInterval.off;

  /// 实际生效的自定义文件夹：只有支持自定义文件夹的平台（[supportsCustomFolder]）才用。
  String? effectiveFolder({required bool supportsCustomFolder}) =>
      supportsCustomFolder ? customFolder : null;

  /// 实际生效的用户文件夹：只有支持的平台（[supportsMirrorFolder]）才用。
  AutoBackupMirrorFolder? effectiveMirrorFolder({
    required bool supportsMirrorFolder,
  }) => supportsMirrorFolder ? mirrorFolder : null;

  /// 内容签名：内容设置变了，指纹就不同，不会因「数据没变」跳过。`full` 标记整库格式：
  /// 从按类别剥行的老格式升上来后第一次照常备份。
  String get contentSignature {
    final List<String> names = <String>[
      for (final BackupCategory c in categories) c.name,
    ]..sort();
    return 'full|${names.join(',')}|media=$includeSrsMedia';
  }

  AutoBackupSettings copyWith({
    AutoBackupInterval? interval,
    int? Function()? preferredMinuteOfDay,
    Set<BackupCategory>? categories,
    bool? includeSrsMedia,
    String? Function()? customFolder,
    AutoBackupMirrorFolder? Function()? mirrorFolder,
  }) => AutoBackupSettings(
    interval: interval ?? this.interval,
    preferredMinuteOfDay: preferredMinuteOfDay != null
        ? preferredMinuteOfDay()
        : this.preferredMinuteOfDay,
    categories: categories ?? this.categories,
    includeSrsMedia: includeSrsMedia ?? this.includeSrsMedia,
    customFolder: customFolder != null ? customFolder() : this.customFolder,
    mirrorFolder: mirrorFolder != null ? mirrorFolder() : this.mirrorFolder,
  );

  @override
  bool operator ==(Object other) =>
      other is AutoBackupSettings &&
      other.interval == interval &&
      other.preferredMinuteOfDay == preferredMinuteOfDay &&
      other.contentSignature == contentSignature &&
      other.customFolder == customFolder &&
      other.mirrorFolder == mirrorFolder;

  @override
  int get hashCode => Object.hash(
    interval,
    preferredMinuteOfDay,
    contentSignature,
    customFolder,
    mirrorFolder,
  );
}

/// 从偏好读设置；缺键 / 坏值一律回到缺省。[readPref] 是 `PreferencesRepository.getPref`。
AutoBackupSettings readAutoBackupSettings(
  Object? Function(String key) readPref,
) {
  final Object? time = readPref(kAutoBackupTimePrefKey);
  final Object? folder = readPref(kAutoBackupFolderPrefKey);
  final Object? mirror = readPref(kAutoBackupMirrorFolderPrefKey);
  final Object? mirrorLabel = readPref(kAutoBackupMirrorLabelPrefKey);
  return AutoBackupSettings(
    interval: AutoBackupInterval.fromName(readPref(kAutoBackupIntervalPrefKey)),
    preferredMinuteOfDay: time is int && time >= 0 && time < 24 * 60
        ? time
        : null,
    categories: decodeAutoBackupCategories(
      readPref(kAutoBackupCategoriesPrefKey),
    ),
    includeSrsMedia: readPref(kAutoBackupSrsMediaPrefKey) == true,
    customFolder: folder is String && folder.trim().isNotEmpty ? folder : null,
    mirrorFolder: mirror is String && mirror.isNotEmpty
        ? AutoBackupMirrorFolder(
            handle: mirror,
            label: mirrorLabel is String && mirrorLabel.isNotEmpty
                ? mirrorLabel
                : mirror,
          )
        : null,
  );
}

/// 写回设置（一个逻辑设置多个键，一次 [writePrefs] 落盘）。[writePrefs] 是
/// `PreferencesRepository.setPrefs`。
Future<void> writeAutoBackupSettings(
  Future<void> Function(Map<String, dynamic> values) writePrefs,
  AutoBackupSettings settings,
) => writePrefs(<String, dynamic>{
  kAutoBackupIntervalPrefKey: settings.interval.name,
  kAutoBackupTimePrefKey: settings.preferredMinuteOfDay ?? -1,
  kAutoBackupCategoriesPrefKey: jsonEncode(<String>[
    for (final BackupCategory c in settings.categories)
      if (kBackupFileCategories.contains(c)) c.name,
  ]),
  kAutoBackupSrsMediaPrefKey: settings.includeSrsMedia,
  kAutoBackupFolderPrefKey: settings.customFolder ?? '',
  kAutoBackupMirrorFolderPrefKey: settings.mirrorFolder?.handle ?? '',
  kAutoBackupMirrorLabelPrefKey: settings.mirrorFolder?.label ?? '',
});

/// 偏好里存的类别清单 → 文件树集合。只认 [kBackupFileCategories]：老版本存下的数据类别
/// （settings / progress / srs …，那时还按类别剥行）安全丢掉——它们现在恒在整库里。缺键 /
/// 坏值回到缺省；清单合法但一个文件类别都没有 = 不带任何文件。
Set<BackupCategory> decodeAutoBackupCategories(Object? raw) {
  if (raw is! String || raw.isEmpty) return kAutoBackupDefaultCategories;
  try {
    final Object? list = jsonDecode(raw);
    if (list is! List<Object?>) return kAutoBackupDefaultCategories;
    return <BackupCategory>{
      for (final Object? name in list)
        for (final BackupCategory c in kBackupFileCategories)
          if (c.name == name) c,
    };
  } on FormatException {
    return kAutoBackupDefaultCategories;
  }
}
