import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema_appearance.dart';
import 'package:hibiki/src/settings/settings_schema_card_creation.dart';
import 'package:hibiki/src/settings/settings_schema_downloads.dart';
import 'package:hibiki/src/settings/settings_schema_game.dart';
import 'package:hibiki/src/settings/settings_schema_listening.dart';
import 'package:hibiki/src/settings/settings_schema_lookup.dart';
import 'package:hibiki/src/settings/settings_schema_tracking.dart';
import 'package:hibiki/src/settings/settings_schema_profiles.dart';
import 'package:hibiki/src/settings/settings_schema_reading.dart';
import 'package:hibiki/src/settings/settings_schema_system.dart';
import 'package:hibiki/src/settings/settings_schema_video.dart';
import 'package:hibiki/src/sync/sync_settings_schema.dart';
import 'package:hibiki/utils.dart';

/// 记忆化的 schema 快照：整棵声明树 + 两张按 [ReaderPlacement] / [VideoPlacement]
/// 投影出来的分组表（后两者惰性算，用到才付钱）。
///
/// **为什么可以缓存**：`buildSettingsSchema` 名义上收 [SettingsContext]，但它的形参
/// 在收集路径上根本没被解引用——13 个 `build*Destination()` 全是零参函数，返回的是
/// 纯字面量表达式树：所有对 appModel / 平台 / 同步状态的读取都写在 item 的闭包里
/// （`(SettingsContext ctx) => ...`），求值发生在**渲染时**而非构造时，树里也没有依赖
/// 可变状态的 collection-if。故构造期唯一的动态输入是 i18n——`t.xxx` 在构造那一刻
/// 求值成 title/subtitle 字符串。于是 locale 就是完整的缓存键。
///
/// **为什么必须缓存**：`refresh()` 恒为宿主 `setState`，任何一次开关翻转、滑条 tick、
/// 搜索框击键都会重跑宿主 `build`，而四个消费点（设置主页 / 详情页 / 阅读器快捷面板 /
/// 视频快捷面板）每次都各自把 13 个分类、46 个 section、230 个 item 连同上千个闭包
/// 重新分配一遍。实测（桌面 JIT）单次全量构造 ~1.27ms，reader / video 两张投影因为
/// 内部各自再调一次 `buildSettingsSchema` 又各 ~1.2ms——视频面板每个 group 一次。
/// 拖滑条时这是逐帧的纯浪费，移动端更贵。缓存后这些路径退化成一次 map 查找。
class _SettingsSchemaCache {
  _SettingsSchemaCache(this.locale, this.destinations);

  final AppLocale locale;
  final List<SettingsDestination> destinations;

  Map<ReaderGroup, List<SettingsItem>>? readerItems;
  Map<VideoGroup, List<SettingsItem>>? videoItems;
}

_SettingsSchemaCache? _schemaCache;

/// 取当前 locale 下的 schema 快照；locale 变了（用户切界面语言）自动重建。
_SettingsSchemaCache _schemaSnapshot() {
  final AppLocale locale = LocaleSettings.currentLocale;
  final _SettingsSchemaCache? cached = _schemaCache;
  if (cached != null && cached.locale == locale) return cached;
  final _SettingsSchemaCache fresh =
      _SettingsSchemaCache(locale, _buildDestinations());
  _schemaCache = fresh;
  return fresh;
}

/// 丢弃 schema 缓存。
///
/// 生产路径不需要它（locale 是唯一缓存键，已由 [_schemaSnapshot] 自动比对）；存在
/// 是为两件事：① debug 热重载——改了 `settings_schema_*.dart` 的树结构后，已缓存的
/// 旧树不会自己更新，故 `_HoshiReaderAppState.reassemble()` 调它；② 测试里需要观察
/// 「重新构造」而非缓存命中时的显式复位。
void resetSettingsSchemaCache() {
  _schemaCache = null;
}

/// 全部一级分类。返回的是**当前 locale 下共享的同一棵不可变树**（见
/// [_SettingsSchemaCache]）——调用方一律只读遍历，切勿就地改动返回的列表。
///
/// 形参 [context] 保留是为了调用点签名稳定与语义自述（这是「设置 schema」，逻辑上
/// 从属于某个设置宿主），收集路径本身不解引用它。
List<SettingsDestination> buildSettingsSchema(SettingsContext context) =>
    _schemaSnapshot().destinations;

/// 全部一级分类的声明树。**locale 之外不得依赖任何运行期状态**——见
/// [_SettingsSchemaCache] 的「为什么可以缓存」；新增分类若需要读动态状态，写进 item
/// 闭包，不要写在这里（有源码守卫 `settings_schema_cache_test.dart` 钉零参调用）。
List<SettingsDestination> _buildDestinations() {
  // 四块分层排序（用户拍板，取代阶段 G 的纯任务优先排序）——块内相关项相邻：
  // ① 外观：全局界面，装完 app 第一批要调的，置顶。
  // ② 内容：阅读 → 听书（同一本书的两面）→ 视频 → 下载（torrent/番剧，喂视频库）
  //   → 游戏（galgame 库/捕获，仅 Windows 可见）。
  // ③ 横切工具：查词 → 制卡（阅读/视频/galgame/扩展共用一套查词弹窗；制卡依赖查词）。
  // ④ 数据与设备：Profile（上述设置的快照）→ 同步备份 → 互联；「系统」惯例殿后。
  // unmodifiable：这棵树被所有设置宿主共享，任何就地改动都会污染其它面板。
  return List<SettingsDestination>.unmodifiable(<SettingsDestination>[
    buildAppearanceDestination(),
    buildReadingDestination(),
    buildListeningDestination(),
    buildVideoDestination(),
    buildMediaTrackingDestination(),
    // 「下载」大类：内联既有 torrent 设置组件（详见 buildDownloadsDestination）。
    buildDownloadsDestination(),
    // 「游戏」大类：游戏库 / 捕获工作台 / 诊断的可搜导航入口（仅 Windows，详见
    // buildGameDestination）。
    buildGameDestination(),
    buildLookupDestination(),
    buildCardCreationDestination(),
    buildProfilesDestination(),
    buildSyncBackupDestination(),
    // Hibiki 互联从同步分类拆出的独立一级分类（构建函数在 sync_settings_schema
    // 同库，与同步共享私有状态）。
    buildInterconnectDestination(),
    buildSystemDestination(),
  ]);
}

/// 遍历完整 schema，收集所有带 [ReaderPlacement] 的 item，按 group + order 升序分组。
/// 分组结果与 schema 树同寿命（惰性算一次，见 [_SettingsSchemaCache]）——阅读器快捷
/// 面板每次 setState 都要它，此前每次都连带把整棵树重建一遍。
Map<ReaderGroup, List<SettingsItem>> collectReaderItems(
  SettingsContext context,
) {
  final _SettingsSchemaCache snapshot = _schemaSnapshot();
  return snapshot.readerItems ??= _collectReaderItems(snapshot.destinations);
}

Map<ReaderGroup, List<SettingsItem>> _collectReaderItems(
  List<SettingsDestination> destinations,
) {
  final Map<ReaderGroup, List<SettingsItem>> grouped =
      <ReaderGroup, List<SettingsItem>>{};
  for (final SettingsDestination destination in destinations) {
    for (final SettingsSection section in destination.sections) {
      for (final SettingsItem item in section.items) {
        final ReaderPlacement? placement = item.reader;
        if (placement == null) continue;
        grouped.putIfAbsent(placement.group, () => <SettingsItem>[]).add(item);
      }
    }
  }
  for (final List<SettingsItem> items in grouped.values) {
    items.sort((SettingsItem a, SettingsItem b) =>
        a.reader!.order.compareTo(b.reader!.order));
  }
  return _freezeGroups(grouped);
}

/// 分组表连同各组 item 列表一并冻结：与整棵树同为共享只读数据，防止某个消费点
/// 就地排序 / 增删后污染其它面板。
Map<G, List<SettingsItem>> _freezeGroups<G>(
  Map<G, List<SettingsItem>> grouped,
) {
  return Map<G, List<SettingsItem>>.unmodifiable(
    grouped.map((G group, List<SettingsItem> items) =>
        MapEntry<G, List<SettingsItem>>(
            group, List<SettingsItem>.unmodifiable(items))),
  );
}

/// 把某个 [ReaderGroup] 的 item 包装成一个可被 SettingsRenderer 渲染的 destination。
SettingsDestination buildReaderGroupDestination(
  SettingsContext context,
  ReaderGroup group,
  String title,
) {
  final List<SettingsItem> items =
      collectReaderItems(context)[group] ?? <SettingsItem>[];
  return SettingsDestination(
    id: SettingsDestinationId.readerQuickSettings,
    title: title,
    icon: Icons.tune_outlined,
    sections: <SettingsSection>[SettingsSection(items: items)],
  );
}

/// 遍历完整 schema，收集所有带 [VideoPlacement] 的 item，按 group + order 升序
/// 分组（与 [collectReaderItems] 同款；阶段 B 视频面板据此投影渲染）。
Map<VideoGroup, List<SettingsItem>> collectVideoItems(
  SettingsContext context,
) {
  final _SettingsSchemaCache snapshot = _schemaSnapshot();
  return snapshot.videoItems ??= _collectVideoItems(snapshot.destinations);
}

Map<VideoGroup, List<SettingsItem>> _collectVideoItems(
  List<SettingsDestination> destinations,
) {
  final Map<VideoGroup, List<SettingsItem>> grouped =
      <VideoGroup, List<SettingsItem>>{};
  for (final SettingsDestination destination in destinations) {
    for (final SettingsSection section in destination.sections) {
      for (final SettingsItem item in section.items) {
        final VideoPlacement? placement = item.video;
        if (placement == null) continue;
        grouped.putIfAbsent(placement.group, () => <SettingsItem>[]).add(item);
      }
    }
  }
  for (final List<SettingsItem> items in grouped.values) {
    items.sort((SettingsItem a, SettingsItem b) =>
        a.video!.order.compareTo(b.video!.order));
  }
  return _freezeGroups(grouped);
}

/// 把某个 [VideoGroup] 的 item 包装成一个可被 SettingsRenderer 渲染的 destination。
/// 与 reader 版不同：按 [VideoPlacement.section] 把相邻同名条目并入同一个带标题小节
/// （mpv 组的「画质 / 画面几何 / 色彩均衡」等），复刻旧手写面板的组内分区结构。
SettingsDestination buildVideoGroupDestination(
  SettingsContext context,
  VideoGroup group,
  String title,
) {
  final List<SettingsItem> items =
      collectVideoItems(context)[group] ?? <SettingsItem>[];
  final List<SettingsSection> sections = <SettingsSection>[];
  String? sectionTitle;
  List<SettingsItem> pending = <SettingsItem>[];
  void flush() {
    if (pending.isEmpty) return;
    sections.add(SettingsSection(title: sectionTitle, items: pending));
    pending = <SettingsItem>[];
  }

  for (final SettingsItem item in items) {
    final String? next = item.video!.section;
    if (pending.isNotEmpty && next != sectionTitle) flush();
    sectionTitle = next;
    pending.add(item);
  }
  flush();
  return SettingsDestination(
    id: SettingsDestinationId.videoQuickSettings,
    title: title,
    icon: Icons.tune_outlined,
    sections: sections.isEmpty
        ? <SettingsSection>[const SettingsSection(items: <SettingsItem>[])]
        : sections,
  );
}

SettingsDestination buildReaderQuickSettingsDestination(
  SettingsContext context,
) {
  final Map<ReaderGroup, List<SettingsItem>> grouped =
      collectReaderItems(context);
  SettingsSection sectionFor(ReaderGroup group, String title) {
    return SettingsSection(
      title: title,
      items: grouped[group] ?? <SettingsItem>[],
    );
  }

  return SettingsDestination(
    id: SettingsDestinationId.readerQuickSettings,
    title: t.reader_settings_section,
    summary: t.source_description_epub,
    icon: Icons.tune_outlined,
    sections: <SettingsSection>[
      sectionFor(ReaderGroup.layout, t.section_layout),
      sectionFor(ReaderGroup.behavior, t.settings_destination_reading_controls),
      sectionFor(ReaderGroup.lookup, t.settings_destination_lookup),
      sectionFor(ReaderGroup.audiobook, t.section_audiobook),
    ].where((SettingsSection s) => s.items.isNotEmpty).toList(growable: false),
  );
}
