import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/settings/settings_actions.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/sync/sync_settings_schema.dart'
    show buildDataStorageLocationSection;
import 'package:hibiki/src/sync/sync_http.dart';
import 'package:hibiki/src/utils/misc/crash_dump_locator.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
import 'package:hibiki/utils.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

SettingsDestination buildSystemDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.system,
    title: t.settings_destination_system,
    summary: t.settings_destination_system_summary,
    icon: Icons.settings_suggest_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        // 文案统一（阶段 F/G）：本 section 原标题与 destination 标题同为「系统」，
        // 搜索面包屑显示「系统 › 系统」语义重复。改为「通用」——本区聚的是版本 /
        // 内存 / 手柄导航 / 快捷键 / GitHub 这类通用应用项。框架层另有面包屑去重
        // （settingsSearchBreadcrumb），双保险消灭整类重复。
        title: t.settings_section_general,
        items: <SettingsItem>[
          // 「界面语言」（id 'appearance.language'）已归位到「外观 · 界面」分区
          //（与主题/明暗/缩放并列）；id 前缀本就是 appearance，此前放系统分类
          // 是历史错配。
          SettingsNavigationItem(
            id: 'system.keyboard_shortcuts',
            title: t.shortcut_settings_title,
            // 「实验性」后缀已摘除（用户决策）：改键/冲突重分配/可视化键盘与
            // 手柄图/三通道实时录键均已齐备，页面不再是实验功能。
            icon: Icons.keyboard_outlined,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => const ShortcutSettingsPage(),
              );
            },
          ),
          SettingsSwitchItem(
            id: 'system.focus_navigation',
            title: t.focus_navigation_enabled,
            subtitle: t.focus_navigation_enabled_hint +
                t.settings_experimental_suffix,
            icon: Icons.gamepad_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.experimentalFocusNavigationEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setExperimentalFocusNavigationEnabled(value);
              settingsContext.refresh();
            },
          ),
          // 「启动时打开查词」从「外观 · 应用」分区归位到此处（启动落地页/导航行为，
          // 与键盘/手柄焦点导航同属通用应用项）。item id 保持 'appearance.
          // startup_default_dictionary_tab' 不变（历史命名，非持久化 key），仅换分区。
          SettingsSwitchItem(
            id: 'appearance.startup_default_dictionary_tab',
            title: t.startup_default_dictionary_tab,
            subtitle: t.startup_default_dictionary_tab_hint,
            icon: Icons.manage_search_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.startupDefaultDictionaryTab,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setStartupDefaultDictionaryTab(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'system.low_memory_mode',
            title: t.low_memory_mode,
            subtitle: t.low_memory_mode_hint,
            icon: Icons.memory_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.lowMemoryMode,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setLowMemoryMode(value);
              settingsContext.refresh();
            },
          ),
          SettingsCustomItem(
            id: 'system.app_version',
            icon: Icons.info_outline,
            builder: _buildRuntimeAppVersionRow,
          ),
          SettingsActionItem(
            id: 'system.github',
            title: t.options_github,
            icon: Icons.public_outlined,
            onTap: (_) async {
              await launchUrl(
                Uri.parse('https://github.com/hajisensai/hibiki'),
                mode: LaunchMode.externalApplication,
              );
            },
          ),
          // TMDB 署名 —— **合约义务，不是可选的致谢**。
          //
          // 视频封面/元数据刮削使用 TMDB API（内置 key，见 tmdb_default_key.dart），
          // 其 Terms of Use 第 3 节要求应用内显著位置展示 TMDB 标识与下面这句原文
          // 免责声明。声明句**刻意不翻译**：TMDB 要求逐字展示该英文原句，17 种语言
          // 都用同一份。文案照抄条款当前版本（2023-10-20）的括号占位句，应用场景取
          // "application"：`This application uses TMDB and the TMDB APIs but is not
          // endorsed, certified, or otherwise approved by TMDB.` —— 旧措辞
          // "not endorsed or certified" 少了 "or otherwise approved"，不是原句。
          //
          // logo 部分见 [_buildTmdbAttributionRow]：条款同时要求展示 TMDB 标识，
          // 原图已逐字节入库（assets/attribution/tmdb/，provenance 见该目录
          // README.md）。文字与 logo 是**一对合约义务**——删 about_tmdb_attribution
          // 前不要先删 logo，反之亦然；要走一起走（连同内置 key 一并移除时）。
          SettingsCustomItem(
            id: 'system.tmdb_attribution',
            searchTitle: 'TMDB',
            // 免责声明正文同时挂在 schema 上：custom 行的正文由 builder 自绘
            //（settings_schema_widgets 的 switch 只调 builder，不读 title/
            // subtitle/icon），所以这里的 subtitle 是**纯搜索元数据、零渲染影响**
            // ——filterSettingsEntries 的 haystack 取 `item.subtitle`，不挂就只剩
            // searchTitle 'TMDB' 可搜，用户搜声明正文里的词（endorsed / certified
            // / approved）搜不到这一行。同款用法见 settings_search 里
            // bodySearchEntries 的合成项。
            subtitle: t.about_tmdb_attribution,
            icon: Icons.movie_outlined,
            builder: _buildTmdbAttributionRow,
          ),
        ],
      ),
      // 「数据存储位置」从同步备份大类挪来（用户拍板：数据根是设备级存储配置，
      // 与备份无关）。构建函数在 sync_settings_schema（行 widget 是该库私有 part），
      // item id 'sync.data_storage_location' 不变。
      buildDataStorageLocationSection(),
      SettingsSection(
        title: t.section_update,
        // 更新分区在所有平台可见（至少能「检查→打开发布页」）；自动安装开关
        // 仅在支持应用内安装的平台显示（platformSupportsInAppInstall，见
        // platform_updater.dart 单一真相源）。
        visible: (_) => platformSupportsUpdateCheck(),
        items: <SettingsItem>[
          SettingsSegmentedItem<String>(
            id: 'system.update_channel',
            title: t.settings_section_update_channel,
            icon: Icons.system_update_alt_outlined,
            controlBelow: true,
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'stable',
                label: t.update_channel_stable,
                icon: Icons.verified_outlined,
                tooltip: t.update_channel_stable,
              ),
              SettingsSegmentOption<String>(
                value: 'beta',
                label: t.update_channel_beta,
                icon: Icons.science_outlined,
                tooltip: t.update_channel_beta,
              ),
              SettingsSegmentOption<String>(
                value: 'debug',
                label: t.update_channel_debug,
                icon: Icons.bug_report_outlined,
                tooltip: t.update_channel_debug,
              ),
            ],
            selected: _selectedUpdateChannel,
            onChanged: setUpdateChannel,
          ),
          // TODO-898：手动「立即检查更新」。分区已被 platformSupportsUpdateCheck()
          // 网关，按钮全平台可见（不能自装的平台仍可「检查→打开发布页」）。
          SettingsActionItem(
            id: 'system.check_update_now',
            title: t.settings_check_update_now,
            icon: Icons.system_update_outlined,
            onTap: _checkUpdateNow,
          ),
          // TODO-1310：应用内查看更新日志。推 ChangelogPage，在线拉本仓库 GitHub
          // releases 列表并用 Markdown 渲染各版本说明；customProxy 透传设置里现有的
          // 更新代理项，与「立即检查更新」同源。
          SettingsNavigationItem(
            id: 'system.view_changelog',
            title: t.settings_view_changelog,
            icon: Icons.history_outlined,
            onTap: (SettingsContext settingsContext) async {
              await pushSettingsPage(
                settingsContext,
                (_) => ChangelogPage(
                  customProxy: settingsContext.appModel.updateCustomProxy,
                ),
              );
            },
          ),
          SettingsSwitchItem(
            id: 'system.update_never_remind',
            title: t.update_never_remind,
            icon: Icons.notifications_off_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.updateNeverRemind,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setUpdateNeverRemind(value);
              settingsContext.refresh();
            },
          ),
          SettingsSwitchItem(
            id: 'system.update_auto_install',
            title: t.update_auto_install,
            icon: Icons.download_done_outlined,
            visible: (_) => platformSupportsInAppInstall(),
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.updateAutoInstall,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setUpdateAutoInstall(value);
              settingsContext.refresh();
            },
          ),
          // 「自定义更新代理」（TODO-871/862）：fake-ip/TUN 模式下系统代理写注册表、
          // Dart HttpClient 读不到时的兜底入口。空串=清除（合法）；非空但格式非法时
          // 弹 SnackBar 提示并仍存原串——运行时纯函数 normalizeUserProxyHostPort
          // 兜底忽略非法值、不阻断检查。
          SettingsTextItem(
            id: 'system.update_custom_proxy',
            title: t.update_custom_proxy_label,
            subtitle: t.update_custom_proxy_auto_hint,
            icon: Icons.dns_outlined,
            placeholder: t.update_custom_proxy_hint,
            keyboardType: TextInputType.url,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.updateCustomProxy,
            onChanged: (SettingsContext settingsContext, String value) async {
              final String trimmed = value.trim();
              await settingsContext.appModel.setUpdateCustomProxy(trimmed);
              // 云同步的共享 client 在首次使用时就把代理解析结果固化进 findProxy 了，
              // 不丢弃它，用户改完代理仍走旧出口——那等于这条设置对同步不生效
              // （BUG-1348）。更新检查每次新建 client，不受影响。
              resetSyncHttpClient();
              // 非空且无法归一成合法 host:port → 提示（仍保存原串，运行时忽略）。
              if (trimmed.isNotEmpty &&
                  normalizeUserProxyHostPort(trimmed) == null) {
                final BuildContext ctx = settingsContext.context;
                if (!ctx.mounted) return;
                ScaffoldMessenger.of(ctx).showSnackBar(
                  SnackBar(content: Text(t.update_custom_proxy_invalid)),
                );
              }
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.settings_destination_diagnostics,
        collapsedByDefault: true,
        items: <SettingsItem>[
          // 标题里的实时条数走 titleBuilder（渲染时求值）。写成构造期插值会把整棵
          // schema 变成「每次 setState 都得重建才能刷新计数」的状态载体——那正是
          // 全量重建的成因之一（见 settings_destination.dart 的 titleBuilder 注释）。
          SettingsNavigationItem(
            id: 'diagnostics.error_log',
            title: t.error_log_label(n: 0),
            titleBuilder: (_) =>
                t.error_log_label(n: ErrorLogService.instance.entries.length),
            icon: Icons.report_problem_outlined,
            builder: (_) => const ErrorLogPage(),
          ),
          // TODO-607 P0-3：崩溃转储（native minidump）。仅 Windows 显示——native
          // 端只在 Windows runner 经 SetUnhandledExceptionFilter 写 .dmp，移动端无此
          // 机制（仿 wgc_capture_log 的 isWindows 门控）。让纯 native 闪退（嵌套查词
          // 把进程带崩等，错误日志里看不到）有可上传的二进制证据。
          SettingsNavigationItem(
            id: 'diagnostics.crash_dumps',
            // 同上走 titleBuilder——这一行的计数还要同步扫目录，构造期算等于每次
            // setState 都做一次磁盘 IO。
            title: t.crash_dump_label(n: 0),
            titleBuilder: (_) => t.crash_dump_label(
              n: CrashDumpLocator.listCurrentPlatformDumps().length,
            ),
            icon: Icons.bug_report_outlined,
            visible: (_) => Platform.isWindows,
            builder: (_) => const CrashDumpPage(),
          ),
          SettingsSwitchItem(
            id: 'diagnostics.debug_log_enabled',
            title: t.debug_log_toggle,
            icon: Icons.rule_outlined,
            value: (_) => DebugLogService.instance.enabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await DebugLogService.instance.setEnabled(value);
              settingsContext.refresh();
            },
          ),
          SettingsNavigationItem(
            id: 'diagnostics.debug_log',
            title: t.debug_log_title(count: 0),
            titleBuilder: (_) => t.debug_log_title(
              count: DebugLogService.instance.entries.length,
            ),
            icon: Icons.terminal_outlined,
            visible: (_) =>
                DebugLogService.instance.enabled ||
                DebugLogService.instance.entries.isNotEmpty,
            builder: (_) => const DebugLogPage(),
          ),
        ],
      ),
    ],
  );
}

/// TODO-898：手动「立即检查更新」防连点旗标（模块级）。UI 重入保护真正靠它——
/// UpdateChecker 内部的 `_activeCheckCancellation` 是「中断」语义、不挡重入。
bool _manualCheckInFlight = false;

/// 手动「立即检查更新」编排（TODO-898）。
///
/// 手动语义：`neverRemind: false`（无视用户「免提醒」偏好，主动点就要看到结果）+
/// `autoInstall: false`（发现新版只弹确认对话框，不沿用自动安装偏好静默装）。
/// 三种反馈走 toast：点击即时「检查中」、已是最新、检查失败；发现新版复用
/// UpdateChecker 既有对话框/打开发布页（零改动）。
Future<void> _checkUpdateNow(SettingsContext settingsContext) async {
  if (_manualCheckInFlight) return;
  _manualCheckInFlight = true;
  // TODO-1024 / BUG-479：缓存优先即时反馈——先读上次检查结果（按当前通道），据它立刻给
  // 「已是最新已知 vX」/「发现新版 vY」（校验中…）的乐观提示，不等网络；网络刷新随后
  // 在后台校验，结果以既有 onUpToDate / 对话框收口。无缓存（首检/畸形/换通道）才退回
  // 原「正在检查…」提示。
  final String currentVersion = settingsContext.appModel.packageInfo.version;
  final String currentBuildNumber =
      settingsContext.appModel.packageInfo.buildNumber;
  final UpdateChannel channel = _channelFromSettings(settingsContext);
  // BUG-846「谁后用谁」：缓存乐观比较用本机 release sequence（无后缀 `X.Y.Z` 正式版包 /
  // beta/debug 包都能取到），与网络路径 scheduleCheck 同源。远端 seq 从缓存的 latestTag 串
  // 自取（beta/debug 带尾号；正式版无 → 保守走基版本比较，网络刷新随后收口）。
  final int? currentReleaseSeq = currentReleaseSequence(
    version: currentVersion,
    buildNumber: currentBuildNumber,
  );
  final UpdateCheckCacheEntry? cached = cachedEntryForChannel(
    settingsContext.appModel.updateCheckCache,
    channel,
  );
  if (cached != null) {
    final bool newer = updateTagIsNewerThanCurrent(
        cached.latestTag, currentVersion, channel,
        localSeq: currentReleaseSeq);
    HibikiToast.show(
      msg: newer
          ? t.update_cached_newer(version: cached.latestTag)
          : t.update_cached_up_to_date(version: cached.latestTag),
      severity: ToastSeverity.info,
    );
  } else {
    HibikiToast.show(
      msg: t.update_checking_now,
      severity: ToastSeverity.info,
    );
  }
  try {
    await UpdateChecker.scheduleCheck(
      settingsContext.context,
      currentVersion,
      currentBuildNumber: currentBuildNumber,
      neverRemind: false,
      autoInstall: false,
      betaChannel: settingsContext.appModel.updateBetaChannel,
      debugChannel: settingsContext.appModel.updateDebugChannel,
      customProxy: settingsContext.appModel.updateCustomProxy,
      // 网络刷新跑完写回缓存，下次手动检查直接乐观显示（恒快）。
      cacheWriter: settingsContext.appModel.setUpdateCheckCache,
      onUpToDate: () => HibikiToast.show(
        msg: t.update_already_latest,
        severity: ToastSeverity.info,
      ),
      onError: (Object _) => HibikiToast.show(
        msg: t.update_check_failed,
        severity: ToastSeverity.error,
      ),
    );
  } finally {
    _manualCheckInFlight = false;
  }
}

/// 当前设置选中的更新通道（与 [scheduleCheck] 内的 debug>beta>stable 优先级一致）。
UpdateChannel _channelFromSettings(SettingsContext settingsContext) {
  if (settingsContext.appModel.updateDebugChannel) return UpdateChannel.debug;
  if (settingsContext.appModel.updateBetaChannel) return UpdateChannel.beta;
  return UpdateChannel.stable;
}

String _selectedUpdateChannel(SettingsContext settingsContext) {
  if (settingsContext.appModel.updateDebugChannel) return 'debug';
  if (settingsContext.appModel.updateBetaChannel) return 'beta';
  return 'stable';
}

/// TMDB 官方标识（`Primary short (blue)`）在包内的路径。
///
/// 这张 PNG 由 themoviedb.org/about/logos-attribution 下发的**矢量原图**栅格化而来；
/// 原图 `assets/attribution/tmdb/blue_square_1.svg` 逐字节入库存证（sha256 即 TMDB
/// 直链文件名里那串摘要）。之所以不直接渲染 SVG：Flutter 唯一现实的 SVG 方案
/// `flutter_svg` 不支持 CSS，而 TMDB 原图把唯一填充写在 `<style>` 类里，解析后渐变
/// 全丢、整个标识渲染成纯黑——那本身就是「改色」。栅格化只做尺寸映射，未改色 /
/// 改比例 / 翻转 / 旋转 / 裁剪。来源、哈希、配方与守卫见同目录 README.md 与
/// `test/settings/tmdb_attribution_test.dart`。
@visibleForTesting
const String kTmdbLogoAsset = 'assets/attribution/tmdb/logo_tmdb.png';

/// logo 展示高度（dp）；宽度见 [_kTmdbLogoWidth]（24 × 190.24/81.52 ≈ 56.0）。
///
/// 条款要求展示 TMDB 标识，但它**不得比本应用自己的标识更显眼**。这条义务的实测
/// 依据（数字均可按下列位置复核）：
///
/// - 同一行左侧的图标徽标是 30dp：`_SettingsIcon` 在 Material 下走
///   `HibikiBadge(size: 18, padding: EdgeInsets.all(6))`，18+6*2 = 30
///   （`utils/components/settings_shared.dart`）。24dp 与之同量级。
/// - 应用自身图标在 Flutter widget 树里**只有一个真渲染点**：设置 › 外观 ›
///   应用图标 的预设瓦片（`miscellaneous_settings_page.dart` 的 `_AppIconTile`）。
///   `SizedBox.square(72)` 扣掉 `HibikiCard` 描边的 1dp 内缩与 `gap/2 = 4` 的
///   双侧 padding，图片实得 62×62dp。TMDB 标识 24dp 高 = 其 38.7%；面积
///   24×56.0 ≈ 1344dp²，是其 3844dp² 的 35%——两个维度都更小，满足条款的
///   "less prominent"。
/// - 除此之外应用图标一处都不画：本文件上方的关于分区只有版本文字，首页
///   dashboard 与 home 外壳零图片，侧栏 rail 的 `leading` 槽
///   （`utils/adaptive/adaptive_navigation.dart`）只有形参没有任何实参，
///   loading/splash 只传颜色不传图，`AppModel.appIcon`（`models/app_model.dart`）
///   是零读点死字段。且预设瓦片那一页仅 Android/Windows 可见，其余三端应用图标
///   的渲染点数为 0。
///
/// 所以旧注释那句「远小于应用自身 logo 的**任何**展示尺寸」结论对、依据错：可比
/// 的展示尺寸全仓只有 62×62dp 这一个。调整本值前请重跑上述核对——这段是「不得更
/// 显眼」的唯一书面依据，守卫只能钉住上限（≤32dp），钉不住依据本身。
const double _kTmdbLogoHeight = 24;

/// 原图 viewBox 是 `0 0 190.24 81.52`；宽度按该比例算死，配合 [BoxFit.contain]
/// 保证任何主题/文字缩放下都不会被拉伸变形（改比例同样是条款禁止项）。
const double _kTmdbLogoWidth = _kTmdbLogoHeight * 190.24 / 81.52;

/// TMDB 署名行：官方标识 + 条款原句免责声明，点击跳官网。
///
/// 用 [SettingsCustomItem] 而不是 [SettingsActionItem]，只因为 schema 的 `icon`
/// 槽是 `IconData`、放不下一张图；行本体仍是共享的 [AdaptiveSettingsRow]，
/// 焦点/密度/折叠行为与其它设置行完全一致。
Widget _buildTmdbAttributionRow(SettingsContext settingsContext) {
  return AdaptiveSettingsRow(
    title: 'TMDB',
    subtitle: t.about_tmdb_attribution,
    icon: Icons.movie_outlined,
    showIcon: true,
    trailing: SizedBox(
      height: _kTmdbLogoHeight,
      width: _kTmdbLogoWidth,
      child: Image.asset(
        kTmdbLogoAsset,
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        semanticLabel: 'TMDB',
      ),
    ),
    onTap: () async => launchUrl(
      Uri.parse('https://www.themoviedb.org/'),
      mode: LaunchMode.externalApplication,
    ),
  );
}

Widget _buildRuntimeAppVersionRow(SettingsContext settingsContext) {
  final packageInfo = settingsContext.appModel.packageInfo;
  return AdaptiveSettingsRow(
    title: t.app_version,
    subtitle: formatAppVersionDisplay(packageInfo),
    icon: Icons.info_outline,
    showIcon: true,
  );
}

/// 版本展示文案。versionName 是 semver（含 `-debug.5613` 等预发布段），
/// buildNumber 是 Android versionCode（如 `1000561300`），两者语义不同：
/// 绝不能用 semver 的 `+` build-metadata 把 versionCode 拼进 versionName，
/// 否则会渲染出畸形的 `0.11.1-debug.5613+1000561300`。用括号并列展示。
@visibleForTesting
String formatAppVersionDisplay(PackageInfo packageInfo) =>
    '${packageInfo.version} (${packageInfo.buildNumber})';
