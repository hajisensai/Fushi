import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

import '../../integration_test/helpers/effect_probes.dart';
import '../../integration_test/helpers/focus_driver.dart';
import '../../integration_test/helpers/schema_settings_verifier.dart';
import '../helpers/test_platform_services.dart';

/// 这些设置在 widget/unit 覆盖 harness 里观测不到「真生效」（消费点在真实
/// WebView popup.js / 原生通知 / Android-only 更新路径 / 音量键回调 / 单例
/// 不进 settings DB），但各自有专项测试或登记为设备集成 backlog。映射到证据，
/// 让覆盖测试不对「别处已覆盖」的项裸喊 UNVERIFIED/FAIL，且强制每个 changed
/// 但未 effect-verified 的设置都必须有去处（no silent caps）。
const Map<String, String> kCoveredElsewhere = <String, String>{
  // v92 阅读空闲门（分钟）：写 prefsRepo（changed=true），生效点是阅读器建
  // StudyClock 时读一次 appModel.readingIdleTimeout——harness 里没有阅读器。
  // 空闲门行为由 study_clock_test「阅读空闲门」用例咬住，接线由
  // statistics_write_convergence_guard_test ⑤ 咬住。
  'reading/Idle timeout':
      'test/media/audiobook/study_clock_test.dart（空闲门）+ '
          'test/tools/statistics_write_convergence_guard_test.dart',
  // 「功能模块」七开关（五库页 + 下载/查词两个工具 tab）。写 prefsRepo
  // （changed=true），生效点是 HomePage/macOS 侧栏的可见 tab 列表——harness 里没有
  // 挂 HomePage 外壳，探不到底栏。行为由 homeActiveTabs 纯函数用例咬住：各开关
  // =false 各自隐藏对应 tab、首页/设置恒在。
  //
  // 键的两半都随「功能模块」搬家改过：destId `system` → `appearance`（本区管底栏
  // 出现哪些 tab，与「反转导航栏」同域），行标题不再是手抄的 module_*_label，而是
  // 底栏真值 homeNavItemFor 的 label（Novels→Books、Galgame→Game、
  // Browser extension→Extension）。键是 `$destId/${row.title}`，两处任一变了本表
  // 就得跟着变。
  // 互联「允许已配对设备读写本机配置」（host 侧许可，默认关）。写 prefsRepo
  // （changed=true），生效点在 **HTTP 端点**里：host 收到 GET/PUT
  // /api/interconnect/profile 时先查这个开关，关着回 403。harness 里没有起 server、
  // 也没有 TLS 会话与已配对 peer，探不到。由专项测试逐条咬住：开关默认关、开启后
  // 可用、依赖未接线时即使开着也不可用、以及端点三道门（TLS → peer token → 能力
  // → 本开关）的顺序守卫。
  'interconnect/Allow paired devices to read/write configuration':
      'test/sync/interconnect_profile_transfer_test.dart',
  'appearance/Books': 'test/pages/home_page_tabs_test.dart',
  'appearance/Manga': 'test/pages/home_page_tabs_test.dart',
  'appearance/Video': 'test/pages/home_page_tabs_test.dart',
  'appearance/Game': 'test/pages/home_page_tabs_test.dart',
  'appearance/Downloads': 'test/pages/home_page_tabs_test.dart',
  'appearance/Lookup': 'test/pages/home_page_tabs_test.dart',
  'appearance/Extension': 'test/pages/home_page_tabs_test.dart',
  // 漫画观看偏好五项。写 prefsRepo（changed=true），生效点全部在**漫画阅读器的
  // WebView 文档**里——这些值被注入成 CSS 过渡声明 / JS 常量（ZOOM_SENS、
  // TAP_ZONE_PAGING、IS_RTL、PAGE_ANIM），widget harness 里没有 WebView，也就没有
  // 可探的渲染输入。由 manga_overlay_html_test 逐项咬住：同一份生成器在不同参数下
  // 必须产出不同的文档（缩放上下限/灵敏度、点击翻页开关与 RTL 镜像、三种翻页动画
  // 各自的过渡声明），阅读方向另有既有的 RTL 几何用例。
  'manga/Reading direction': 'test/media/manga/manga_overlay_html_test.dart',
  'manga/Default zoom': 'test/media/manga/manga_overlay_html_test.dart',
  'manga/Zoom sensitivity': 'test/media/manga/manga_overlay_html_test.dart',
  'manga/Page turn animation': 'test/media/manga/manga_overlay_html_test.dart',
  'manga/Tap edges to turn pages':
      'test/media/manga/manga_overlay_html_test.dart',
  // galgame 窗口超分三态开关（PR#430）。写 prefsRepo（changed=true），生效点整条在
  // 本进程之外 —— 改写 Magpie 自己的 config.json、拉起 / 收掉一个独立的 Magpie 进程、
  // 由它去做全屏缩放，widget harness 里没有任何可探的渲染输入；而且它 Windows-only，
  // CI（Linux）连控件都不该渲染。由三层专项测试咬住：三态 → 后端裁决的纯函数、
  // profile 增量改写的每一条降级分支、以及「开/关对称」的生命周期编排（含退出清理、
  // 启动期孤儿对账、第二局仍能拉起），外加 native 广播监听的源码守卫。
  'lookup/Game window upscaling': 'test/mining/magpie_upscaling_test.dart + '
      'test/mining/magpie_native_guard_test.dart + '
      'test/mining/magpie_installer_test.dart',
  // 游戏内查词开关（KiriKiri/KAGEX）。写 prefsRepo（changed=true），生效点整条在
  // 本进程之外：置 header->lookup_enabled → 注入进游戏进程的 hook 装 TJS 传感器 →
  // 卡片像素经共享内存回投、由**游戏自己的渲染树**画出来。widget harness 里既没有
  // 目标游戏进程也没有共享内存，没有任何可探的渲染输入；且 Windows-only，CI（Linux）
  // 连控件都不该渲染。由四层专项测试咬住：Dart 侧命中→定位→投帧的契约测试、native
  // 侧 v14 契约测试（区寻址 + 帧闸门 + ShouldApplyLookupFrame 真值表）、会话 replay
  // （7 个变异体实测全红），以及禁止把查词链路搬回游戏进程的源码扫描守卫。
  // galgame 台词浮窗的九项外观设置（PR#938）。写 prefsRepo（changed=true），生效点
  // 全部在 runner 自有的 Win32 分层窗里：Direct2D/DirectWrite 直绘，widget harness
  // 既没有那个 HWND 也没有渲染目标，没有任何可探的渲染输入；而且整条 Windows-only，
  // CI（Linux）连控件都不该渲染。由三层源码守卫咬住：
  //   ① appearance 守卫：每个字段都真的过 MethodChannel 落进 native style，并被
  //      对应的绘制点消费（不是「接进来了但没人读」）；
  //   ② lyric-style 守卫：描边/字重的门控与**默认值等于改造前硬编码值**；
  //   ③ ruby-render 守卫：行距门控与默认行高恒等 1.0。
  // ②③ 那两条默认值断言是这批登记的前提：可配置化如果顺手改了默认观感，
  // 「没探针」就会变成「没人发现所有老用户的浮窗都变样了」。
  // hook 台词浮窗的交互三件套（单击查词 / 工具条自动隐藏 / 穿透时是否拦截鼠标）。
  // 写 prefsRepo（changed=true），生效点全在 runner 自有的 Win32 分层浮窗里：
  // 前者是 native 的 click_lookup_enabled_ 门控，后两者一个决定工具条窗显不显示、
  // 一个决定穿透态要不要铺行盒 catch fill——本进程内没有任何可探的渲染输入，故无
  // 适用探针。由偏好行为用例 + runner 源码守卫咬住（含「设置项必须 live 下发」
  // 这条：只落盘不推 channel = 开关本局不生效，要退出重进一局）。
  //
  // 「查词触发方式」是下拉（picker）不是开关。它以前根本不在 _focusedSettingsRow 的
  // 识别名单里，所以既不在遍历中、也不在此表——现在两者都补上了（见本表末尾「下拉型
  // 设置项」那一段）。
  'game/Tap a word to look it up':
      'test/lookup/gal_hook_overlay_interaction_prefs_test.dart',
  'game/Auto-hide the toolbar':
      'test/lookup/gal_hook_overlay_interaction_prefs_test.dart',
  'game/Caption still catches clicks while clicking through':
      'test/lookup/gal_hook_overlay_interaction_prefs_test.dart',
  // 台词折叠开关。写 prefsRepo（changed=true），生效点在 TexthookerService 这个
  // 进程级单例的 buffer 折叠上——harness 里没有跑着的 hook 会话，也就没有可探的
  // 输入。由折叠判据的纯函数用例 + service 级行为用例咬住（前缀/后缀/等长/过短
  // 四种形状 + 关掉开关必须退回旧的逐条追加行为）。
  'game/Merge split dialogue lines':
      'test/sync/texthooker_progressive_fold_test.dart',
  'game/In-game dictionary lookup':
      'test/lookup/gal_ingame_lookup_contract_test.dart + '
          'native/galgame_hook/tests/lookup_ipc_contract_test.cpp + '
          'native/galgame_hook/tests/lookup_session_replay_test.cpp + '
          'native/galgame_hook/tests/kirikiri_lookup_source_guard_test.py',
  // BUG-2066：游戏内查词卡独立尺寸开关。写 prefsRepo（changed=true），生效点在
  // runner 的直连覆盖窗（真实 HWND + WebView2），本进程内没有可探的渲染输入。
  // 由 test/lookup/gal_card_size_cap_test.dart 咬住这个开关唯一的行为后果：
  // galCard route 读 gal 那组键、桌面 route 继续读 overlay 那组，两组值不互串；
  // 关掉开关时跟随 app 内共享值。
  // 归属：与 #938 同一条理由，本项已从 settings_schema_lookup.dart 移进
  // settings_schema_game.dart 的双重 Platform.isWindows 门后，故 destId 是 game。
  // 兄弟两项（最大宽/高滑杆）带 visible 门、不进覆盖清单，不需要登记。
  'game/Independent in-game card size':
      'test/lookup/gal_card_size_cap_test.dart',
  // BUG-1095：galgame Hook 台词浮窗字号。写 prefsRepo（changed=true），生效点在
  // runner 自有的 Win32 分层浮窗（Direct2D/DirectWrite 直绘，不是 Flutter widget
  // 树），本进程内没有任何可探的渲染输入，故无适用探针；由三层专项测试咬住：
  // 偏好边界（默认/钳位/脏值）、控制器把字号经 show/updateStyle 真推给 native、
  // 以及 native 源码守卫（hook 模式不再按窗高缩放字号）。
  // 归属：#938 把整个 gal_hook_overlay section 从 settings_schema_lookup.dart 移到
  // settings_schema_game.dart（destination 级 + section 级双重 Platform.isWindows
  // 门控，比原先更严），故登记键的 destId 随之从 lookup 变 game。
  'game/Galgame caption font size':
      'test/models/preferences_repository_gal_hook_font_test.dart + '
          'test/lookup/gal_hook_text_overlay_controller_test.dart + '
          'test/build/gal_overlay_font_decoupled_guard_test.dart',
  // #938 的浮窗外观八项（字距/行高/字重/对齐/底板不透明度/描边宽度/内边距/圆角）。
  // 与上面的字号同一个消费点：runner 自有的 Win32 分层浮窗（Direct2D/DirectWrite
  // 直绘），本进程内没有任何可探的渲染输入——和 listening/ 那批有声书浮窗项同型
  // （其实是同一个 floating_lyric_window.cpp，galgame 走 hook_text_mode_ 分支）。
  //
  // 通路由 gal_overlay_appearance_guard 逐字段咬住：MethodChannel 上的
  // letterSpacing/lineHeight/bold/textAlignment/outlineWidth/textPadding/
  // cornerRadius/bgColor 必须接到 runner，且间距与对齐必须落在**同一个**
  // text_layout_ 上（否则点字命中会和显示错位）。渲染语义另由样式守卫咬：字重只
  // 在 hook 模式生效、描边半径每一处都经 clamp、默认底板全透明且 ◐ 恢复值非零、
  // ruby 让出的行距只在有注音时加。落到实际像素仍需 Windows 真机点验。
  'game/Letter spacing': 'test/build/gal_overlay_appearance_guard_test.dart + '
      'DEVICE: native hook overlay character spacing',
  'game/Line height': 'test/build/gal_overlay_appearance_guard_test.dart + '
      'test/build/overlay_ruby_render_guard_test.dart + '
      'DEVICE: native hook overlay line spacing',
  'game/Bold text': 'test/build/gal_overlay_appearance_guard_test.dart + '
      'test/build/gal_overlay_lyric_style_guard_test.dart + '
      'DEVICE: native hook overlay font weight',
  'game/Text alignment': 'test/build/gal_overlay_appearance_guard_test.dart + '
      'DEVICE: native hook overlay text alignment',
  // BUG-1890：垂直对齐——与上面那个水平「文字对齐」**正交的另一个轴**（不是三选一
  // 的第三档）。同一个消费点：floating_lyric_window.cpp 的 SetParagraphAlignment，
  // 同样没有可探的渲染输入。由专项测试咬住：偏好白名单二值收敛（真 DB，含「改水平
  // 对齐不冲掉垂直对齐」）、通道 String→int 编码，以及 native 源码守卫（每帧覆写处
  // 读该字段、且 hook_text_mode_ 门住不误伤有声书歌词条）。
  'game/Vertical alignment':
      'test/lookup/gal_hook_text_vertical_alignment_test.dart + '
          'test/build/gal_overlay_appearance_guard_test.dart + '
          'DEVICE: native hook overlay vertical alignment',
  'game/Window background opacity':
      'test/build/gal_overlay_appearance_guard_test.dart + '
          'test/build/gal_overlay_lyric_style_guard_test.dart + '
          'DEVICE: native hook overlay backplate alpha',
  'game/Outline width': 'test/build/gal_overlay_appearance_guard_test.dart + '
      'test/build/gal_overlay_lyric_style_guard_test.dart + '
      'DEVICE: native hook overlay outline radius',
  'game/Horizontal text padding':
      'test/build/gal_overlay_appearance_guard_test.dart + '
          'DEVICE: native hook overlay text padding',
  'game/Window corner radius':
      'test/build/gal_overlay_appearance_guard_test.dart + '
          'DEVICE: native hook overlay corner radius',
  // 视频条目自动刮削总闸。写 prefsRepo（changed=true），生效点在
  // VideoScrapeAutoService.sweep 的进场门（关=零网络请求、零资料落库），不是
  // reader CSS / 主题树，无适用探针；由专项服务测试咬住（关=不发请求、关→开
  // 同一实例下轮即刮）。
  'video/Auto-fetch series info':
      'test/media/video/scraper/auto_scrape_service_test.dart',
  // 库内自动补刮总闸。写 prefsRepo（changed=true），生效点在
  // VideoLibraryScrapeSweep.sweepOnce 的进场门（关=不发起任何补刮批次），不是
  // reader CSS / 主题树，无适用探针；由专项测试咬住（总闸关=不补刮但队列仍可见、
  // 总闸开=只补无规范身份的作品）。
  'video/Auto-fill missing series info':
      'test/media/video/metadata/video_library_scrape_sweep_test.dart',
  // BUG-1698：刮削完成后给仍缺字幕的视频补一条在线字幕。写 prefsRepo
  // （changed=true），生效点在 AppModel._backfillSubtitlesForScrapedWork 的进场门
  // （关=刮削回调直接 return，零字幕网络请求），不是 reader CSS / 主题树，无适用
  // 探针；由专项纯函数测试咬住「刮削结论 → 字幕目标」这一步——那才是这个功能的
  // 全部准确率所在（外部 id / 原名 / 季集号怎么传给 provider）。
  'video/Auto-fetch subtitles after scraping':
      'test/media/video/scraped_subtitle_targets_test.dart',
  // Jimaku 默认字幕语言（BUG-1189/1190 那批「Jimaku 设置统一到设置页」）。写
  // prefsRepo（changed=true），生效点是三个 Jimaku 界面打开时的语言预选（没有该
  // 系列的语言记忆时用它兜底），不在 reader CSS / 主题树里，无适用探针；由专项
  // 测试三层咬住（偏好往返 + AppModel 归一含仓库未就绪回退 + 番剧下载对话框
  // 真按它预选语言 chip）。
  'video/Default subtitle language':
      'test/pages/jimaku_default_language_test.dart',
  // mpv Lua 脚本装载开关。写 prefsRepo（changed=true），生效点在视频播放器创建后
  // 经 libmpv `load-script` 命令装载脚本目录（widget harness 无 libmpv Player，
  // 无可探渲染输入）；由专项测试咬住目录枚举（仅顶层 .lua、排序）、load-script
  // 命令构建与导入落盘，装载幂等语义见 video_lua_script_manager.dart 文件头。
  'video/Load Lua scripts':
      'test/media/video/video_lua_script_manager_test.dart',
  // 多端库联合视图（spec 2026-07-12 §2.6）：上传视频文件开关。写 SyncRepository
  // gate（changed=true），生效点在 SyncOrchestrator 云后端上传阶段（非 reader
  // CSS / 主题树），无适用探针；由专项 orchestrator 行为测试咬住（关=零上传、
  // 开=上传缺失+清单正确、重复跑幂等）。
  'syncBackup/Upload video files':
      'test/sync/sync_orchestrator_video_test.dart',
  // 多端库联合视图（spec §2.1）：显示远端条目开关。写 prefsRepo（changed=true），
  // 生效点在书架/视频页占位卡渲染门控；由两页 mixed-grid 专项 widget 测试咬住
  // （关=占位全隐藏、开=混排+云角标）。
  'syncBackup/Show remote entries':
      'test/pages/home_video_remote_mixed_grid_test.dart + test/pages/reader_remote_mixed_grid_test.dart',
  // （原「与 Hoshi/ッツ 共享」开关条目已删：Hoshi 共享空间功能按用户决策移除
  // （2026-08-07，恒用隐藏 appData 空间），设置项不复存在；残留偏好行
  // google_drive_hoshi_compat 由 fushi_core v72 迁移清行。）
  // 互联解耦（用户诉求「互联和同步后端不冲突」）：互联总开关，独立于 backendType
  // 云备份后端。写 SyncRepository（changed=true），生效点在同步触发的双通道门控 +
  // 互联各 section 可见性 + 远端内容来源选择（非 reader CSS / 主题树），无适用探针；
  // 由迁移守卫（fushiServer→独立开关）+ 可见性守卫（开关常显、配置区门控）咬住。
  'interconnect/Enable interconnect':
      'test/sync/sync_interconnect_decouple_migration_test.dart + test/sync/sync_settings_visibility_test.dart',
  // 漫画「在线目录」站点根 URL（O1 mokuro.moe 目录源）：网络端点，写穿偏好后
  // 消费点在 MokuroMoeClient 的请求 URL 拼接（widget harness 观测不到真生效）；
  // 由 client 专项测试咬住（base URL 归一 + URL 编码 + 端点拼接）。
  'reading/Online catalog URL':
      'test/media/manga/online/mokuro_moe_client_test.dart',
  // 专项 unit/widget 生效探针（docs/specs/2026-06-03-t4-effect-probes-plan.md T1–T9）
  'reading/Text orientation': 'test/reader/reader_content_styles_test.dart',
  'reading/Font kerning (vertical)':
      'test/reader/reader_content_styles_test.dart',
  'reading/VPAL (vertical alt)': 'test/reader/reader_content_styles_test.dart',
  'appearance/Design system': 'test/models/theme_notifier_test.dart',
  'appearance/UI size': 'test/models/theme_notifier_test.dart',
  'reading/Spread mode': 'test/epub/epub_spread_map_test.dart',
  // 阶段 G 重排后，「模式」分区（含 view_mode）在设置页排在「排版」分区（含
  // page_columns）之前，覆盖 harness 焦点遍历会先把 view_mode 从 paginated 切走，
  // 随后驱动 page_columns 时 reader 已非翻页态、T1 reader CSS 探针看不到 column-count
  // 变化（多列模型只在 _paginatedLayoutCss）。page_columns 的 CSS 生效（翻页态发
  // column-count、连续/VN 态不发）与 paginated-only 可见性由专项测试咬住。
  'reading/Columns per page':
      'test/settings/page_columns_paginated_only_test.dart',
  // TODO-1128：合并插图页到正文（reading_display.merge_image_pages）。结构性布局键，
  // 焦点遍历能切到并写穿 DB（changed=true），但生效点在 reader 分页布局（
  // notifyReaderLayoutChanged 需活 reader/WebView 重排），无适用 T4 探针；合并语义/
  // charOffset 不变/spread 优先由专项纯函数测试守住，渲染效果需真机验。
  'reading/Merge illustration pages into text':
      'test/epub/epub_spread_map_test.dart: mergeImagePages absorb/spread-priority/charOffset (reader layout effect needs live WebView, DEVICE for render)',
  'lookup/Popup max width': 'test/pages/dictionary_popup_layer_test.dart',
  'lookup/Popup max height': 'test/pages/dictionary_popup_layer_test.dart',
  // TODO-776: 查词弹窗「词典最多列数（自动填充）」（实验性）。PR#83 语义收敛后文案
  // 从「Dictionaries per row」改为「Max dictionary columns (auto-fill)」（底层算法不变，
  // 仍是 effective = min(用户值, 视口可容)），故此处登记键随标题更新。焦点遍历能切到滑块
  // 并写穿 DB（changed=true），但生效点在 popup WebView 的 CSS grid（--dict-columns 注入 +
  // popup.css grid 渲染，非 reader CSS / 主题树），无适用的 reader/appearance 探针；
  // 由专项 widget 契约 + popup.css/注入源码守卫覆盖。
  'lookup/Max dictionary columns (auto-fill)':
      'test/settings/popup_dictionary_columns_test.dart',
  // 弹窗尺寸精细化（spec 2026-07-13 §3）：app 外覆盖窗 / 浏览器扩展的「独立尺寸」开关
  // （PR#83 新增）。焦点遍历切到 switch 并写穿 DB（changed=true），但生效点在
  // effectiveLookupSize 解析——决定弹窗宽高取自身场景键还是回退 app 内共享值（overlay
  // 走原生窗尺寸测算、extension 经 theme 下发 --fushi-popup-max-*），无适用的
  // reader/appearance 探针；由专项纯函数 + AppModel 接线测试咬住（解锁切源 / 场景隔离 /
  // 关闭仍跟随共享值）。解锁后才可见的宽/高滑杆随开关一并被这两组测试覆盖。
  'lookup/Separate size for pop-out lookup':
      'test/lookup/effective_lookup_size_test.dart + test/models/lookup_effective_size_wiring_test.dart',
  'lookup/Separate size for browser extension':
      'test/lookup/effective_lookup_size_test.dart + test/models/lookup_effective_size_wiring_test.dart',
  'lookup/Instant popup scroll': 'test/reader/reader_caret_scripts_test.dart',
  // BUG-1026：滚轮速度倍率的生效面在 popup.js（WebView 内的 wheel 监听器），widget
  // 层没有可观测探针；由专项测试逐环锁死注入链路（偏好 → 注入/theme 下发 → 三份
  // popup.js 读取并乘进 factor）。
  'lookup/Popup scroll speed': 'test/reader/popup_wheel_speed_asset_test.dart',
  // TODO-108: 底部固定弹窗开关——生效点在纯函数 dockedPopupRect 与 base_source_page/dictionary_page_mixin 的路由分流（非 reader CSS / 主题树），
  // 无 reader/appearance 探针；由专项纯函数 + widget 测试覆盖。
  'lookup/Bottom-docked popup':
      'test/pages/dictionary_popup_layer_test.dart + test/settings/popup_bottom_docked_switch_test.dart',
  // 持久化/焦点/写穿由 settings_flatten_anki_profile_test 覆盖；真正加标签的消费点在
  // 制卡路径 reader_fushi/mining.part.dart 与 video_fushi/lookup_mining.part.dart 的
  // bookTitleTag（读 appModel.autoAddBookNameToTags）。原 tags_field_auto_add_book_test
  // 测的是已删死契约 TagsField.onCreatorOpenAction，已随该契约删除。
  'cardCreation/Auto-add book title to tags':
      'test/settings/settings_flatten_anki_profile_test.dart + live consume in '
          'reader_fushi/mining.part.dart & video_fushi/lookup_mining.part.dart (bookTitleTag)',
  // TODO-1650: 制卡图片/GIF 清晰度 + 音频质量两滑块（替代旧「压缩」开关）。写
  // AppModel.miningImageQuality / miningAudioQuality（prefsRepo），焦点遍历能切到
  // 并写穿 DB（changed=true），但消费点在 ffmpeg/截图编码参数（非 reader CSS / 主题
  // 树），无适用探针；由专项纯函数（档位工厂 + GIF 原片滤镜）+ pref round-trip 守卫覆盖。
  'cardCreation/Image / GIF quality':
      'test/settings/mining_media_quality_guard_test.dart + test/utils/desktop_audio_clipper_test.dart',
  'cardCreation/Audio quality':
      'test/settings/mining_media_quality_guard_test.dart + test/utils/desktop_audio_clipper_test.dart',
  // TODO-135: 默认标签区现无条件显示（hibiki/分类两开关移出 isConfigured 门控），
  // focus-driven 现能驱动到它们；但它们写的是 AnkiSettings（经 SharedPreferences，
  // 非本测试的内存 DB），故 changed=false。标签拼装行为本体由 hibiki_anki 真制卡
  // 测试咬住（tagIncludeHibiki/tagIncludeCategory 开/关各分支）。
  'cardCreation/Add "fushi" tag':
      'packages/fushi_anki/test/mining_tag_and_parallel_test.dart',
  'cardCreation/Add source category tag':
      'packages/fushi_anki/test/mining_tag_and_parallel_test.dart',
  // 媒体去重的两个自动开关。与上面两个标签开关同因：写的是 AnkiSettings
  // （经 SharedPreferences，非本测试的内存 DB），故 changed=false；而「自动直接
  // 删除」还是**从属开关**，自动处理关着（默认）时刻意 disabled，焦点驱动本就
  // 拨不动它。行为本体由专项测试咬死：默认关 / 打开后只干跑并要求确认 / 只有再
  // 显式打开自动直接删除才真删 / 7 天节流边界 / 源码守卫。
  'cardCreation/Automatic processing':
      'test/anki/anki_media_dedup_auto_test.dart + '
          'test/settings/settings_flatten_anki_profile_test.dart',
  'cardCreation/Delete automatically without asking':
      'test/anki/anki_media_dedup_auto_test.dart + '
          'test/settings/settings_flatten_anki_profile_test.dart',
  // PR#343: 互联「制卡到服务端」开关。写 prefsRepo mine_to_server（changed=true），
  // 生效点在 ankiRepositoryProvider——开关开时把本地仓库包一层 RemoteMiningAnkiRepository，
  // mineEntry/isDuplicate 经互联链路转发到已配对主机（用主机 Anki 落卡），配置类方法仍委派
  // 本地（非 reader CSS / 主题树），无适用 widget 探针；由专项测试咬住转发路由/字段透传/
  // 序列化契约（远端制卡仓库包装 + 转发载荷 + 服务端 handler）。
  // 归属：开关已从「制卡」分类移到「Hibiki 互联」→「交给已配对设备」（它的前置条件、
  // 目标设备、失效条件全由互联决定），故登记键的 destId 随之从 cardCreation 变 interconnect。
  'interconnect/Mine to paired device':
      'test/anki/remote_mining_anki_repository_test.dart + '
          'test/sync/forwarded_mine_payload_test.dart + '
          'test/sync/fushi_remote_mining_service_test.dart',
  'system/Low memory mode': 'test/models/app_model_low_memory_mode_test.dart',
  'system/Keyboard & gamepad focus navigation':
      'test/shortcuts/global_space_no_activate_test.dart + main.dart 门控安装 FushiFocusRoot/Ring',
  'lookup/Swipe dismiss sensitivity':
      'test/widgets/swipe_dismiss_wrapper_test.dart',
  'reading/Reverse keyboard left/right page-turn direction':
      'test/reader/reader_space_pause_test.dart + test/shortcuts/global_navigation_test.dart',
  // TODO-436/407②：查词弹窗"滑动关闭"开关。归「查词」分组（destId=lookup）。生效点
  // 在 DictionaryPopupLayer 的 swipe 边界（仅顶栏可滑）+ 平台默认纯函数
  // ReaderSettings.defaultSwipeToClose，由专项 widget 行为 + 纯函数真值表测试覆盖
  // （非 reader CSS / 主题树）。
  'lookup/Swipe to close popup':
      'test/pages/dictionary_popup_swipe_close_test.dart',
  // TODO-861②：「扫描非日文文字」查词开关（PreferencesRepository.scanNonJapaneseText，
  // 默认 true）。焦点遍历能切到并写穿 DB（changed=true），但生效点在注入 JS 的
  // window.scanNonJapaneseText + reader_selection_scripts 的 `scanNonJapaneseText
  // === false` 选区边界分支（非 reader CSS / 主题树），无适用 T4 探针；由专项持久化
  // 往返 + webview 注入 + 选区消费端源码守卫覆盖。
  'lookup/Scan non-Japanese text': 'test/reader/todo861_hoshi_ports_test.dart',
  // TODO-1030 M0：全局查词（应用外）抓取选中文本上下文开关（隐私敏感，默认关，仅桌面）。
  // 焦点遍历能切到并写穿 DB（changed=true），但生效点在 Windows UIA native 捕获 +
  // 纯函数句子裁剪 + 制卡 {sentence} 上下文（非 reader CSS / 主题树），无适用 T4 探针；
  // 由纯函数守卫（含与阅读器分隔符表的双端一致性）+ pref 往返覆盖。
  'lookup/Capture selection context':
      'test/lookup/sentence_extraction_test.dart',
  'system/Enable debug log': 'test/utils/misc/debug_log_service_test.dart',
  // BUG-1980 代理模式三态（自动/直连/手动）：写 prefsRepo（changed=true），生效点是
  // app_proxy.dart 的出口裁决与 HttpClient.findProxy / authenticateProxy 装配——
  // harness 里没有真实公网出站可探。三态语义（direct 忽略 env 与已填地址、manual
  // 归一失败时安全直连不偷用系统代理、legacy 存量值 fail-open、407 凭据只交付一次）
  // 由 app_proxy_local_bypass_test 的纯判据用例咬住。
  'system/Proxy mode': 'test/utils/net/app_proxy_local_bypass_test.dart',
  // P2P 代理三档（direct/proxy/mixed）：写 prefsRepo（changed=true），生效点是
  // libtorrent session 的 proxy 设置，harness 里没有原生引擎可探。档位语义
  // （默认直连 / 改档才跟全局出口 / mixed=tracker 经代理、DHT 与 peer 直连）
  // 由 resolveP2pProxyHostPort 纯函数用例 + C ABI 桥源码守卫 + overlay 补丁
  // 守卫咬住。
  'system/P2P (torrent) proxy':
      'test/torrent/download_http_client_proxy_test.dart',
  'syncBackup/Auto sync': 'test/sync/sync_gating_test.dart',
  'syncBackup/Sync statistics': 'test/sync/sync_gating_test.dart',
  'syncBackup/Upload book files': 'test/sync/sync_gating_test.dart',
  'syncBackup/Sync dictionaries': 'test/sync/sync_gating_test.dart',
  'syncBackup/Sync audiobook files': 'test/sync/sync_orchestrator_test.dart',
  'syncBackup/Sync local audio': 'test/sync/sync_orchestrator_test.dart',
  // TODO-212: video destination items are behavior-heavy; schema coverage proves
  // focus/change/persist/restore here, while these narrower probes guard their
  // runtime consumption or the desktop/device seam.
  // TODO-639: auto-play-next is a behavior-only pref (it gates the EOF episode
  // advance, no render-tree effect). Schema coverage proves focus/change/persist/
  // restore through the DB; the runtime gate is covered by the pure-predicate +
  // wiring guards below.
  'video/Auto-play next episode':
      'test/media/video/video_episode_start_policy_test.dart + test/pages/video_playlist_auto_advance_guard_static_test.dart',
  'video/Immersive mode':
      'test/pages/video_immersive_mode_levels_guard_test.dart + test/pages/video_statusbar_immersive_guard_test.dart',
  'video/Picture scaling':
      'test/pages/video_fit_mode_test.dart + test/pages/video_window_aspect_lock_static_test.dart',
  'video/Double-tap seek':
      'test/pages/video_double_tap_seek_guard_test.dart + test/pages/video_immersive_mode_levels_guard_test.dart',
  'video/Lock window to video aspect':
      'test/pages/video_window_aspect_lock_static_test.dart',
  // 点击画面播放/暂停：生效点在 media_kit 控制条主题（桌面单击）与
  // _handleVideoPointerUp 的移动端双击 fallback，两者都是真实手势 arena，harness 里
  // 探不到。由 config round-trip（含默认 true / 旧档回落）+ 三条源码守卫（桌面主题
  // 接线不得写死、移动端门控排在 playOrPause 之前、schema 行经双路写穿）咬住。
  'video/Tap video to play/pause':
      'test/media/video/video_asbplayer_config_test.dart + '
          'test/pages/video_double_tap_seek_guard_test.dart',
  'video/Obscure subtitles':
      'test/media/video/video_subtitle_obscure_mode_test.dart + test/media/video/video_subtitle_overlay_test.dart + test/shortcuts/video_shortcut_registry_test.dart',
  'video/Obscure secondary subtitle':
      'test/media/video/video_secondary_subtitle_obscure_test.dart + test/media/video/video_subtitle_overlay_test.dart',
  // TODO-286: pref-only video settings surfaced in home settings for parity with
  // the in-player sheet. Schema coverage here proves focus/change/persist/restore
  // through the DB; the runtime effect of each underlying config is guarded by the
  // model round-trip / apply tests below (they all flow into the controller on the
  // next play via applyMpvConfigToPlayer / VideoSubtitleOverlay / asb config).
  'video/Long-press speed':
      'test/media/video/video_asbplayer_config_test.dart + test/pages/video_settings_schema_guard_test.dart',
  'video/Seek seconds':
      'test/media/video/video_asbplayer_config_test.dart + test/media/video/video_seek_relative_test.dart',
  'video/Subtitle pause playback mode':
      'test/media/video/video_asbplayer_config_test.dart',
  'video/Quality enhancement':
      'test/media/video/video_mpv_config_test.dart + test/media/video/video_shader_manager_test.dart',
  // TODO-1120/BUG-538：sigmoid 上采样开关（画质增强/着色器等级组内并列开关），mpv 纯
  // pref，下次开视频 applyMpvConfigToPlayer 应用——效果需真机放视频验，单测覆盖默认关 +
  // encode/decode 往返 + emit yes/no。
  'video/Sigmoid upscaling': 'test/media/video/video_mpv_config_test.dart',
  'video/Hardware decoding': 'test/media/video/video_mpv_config_test.dart',
  'video/Debanding': 'test/media/video/video_mpv_config_test.dart',
  'video/Loop file': 'test/media/video/video_mpv_config_test.dart',
  // HDR：值写穿 videoMpvConfig，生效点在 libmpv（tone-mapping /
  // hdr-compute-peak），harness 探不到渲染输入。round-trip + 白名单挡脏值
  // 由下面这个文件咬住；真实 HDR 片源的映射效果需桌面设备验。
  'video/HDR tone mapping':
      'test/media/video/video_hdr_tone_mapping_test.dart',
  'video/Dynamic peak detection':
      'test/media/video/video_hdr_tone_mapping_test.dart',
  // TODO-1247：把播放页内 mpv 详情（画质余项/几何/色彩/音频）平移到首页后，这些
  // 纯 pref 项写穿 videoMpvConfig（下次开视频 applyMpvConfig 应用）；结构化字段
  // round-trip + buildMpvProperties 生效由 video_mpv_config_test.dart 咬住，真实
  // libmpv 渲染效果需桌面设备验（无 widget 探针）。
  'video/Dithering': 'test/media/video/video_mpv_config_test.dart',
  'video/Motion interpolation': 'test/media/video/video_mpv_config_test.dart',
  'video/Deinterlace': 'test/media/video/video_mpv_config_test.dart',
  'video/Linear downscaling': 'test/media/video/video_mpv_config_test.dart',
  'video/Rotation': 'test/media/video/video_mpv_config_test.dart',
  'video/Aspect ratio': 'test/media/video/video_mpv_config_test.dart',
  'video/Zoom': 'test/media/video/video_mpv_config_test.dart',
  'video/Pan & scan (crop borders)':
      'test/media/video/video_mpv_config_test.dart',
  'video/Brightness': 'test/media/video/video_mpv_config_test.dart',
  'video/Contrast': 'test/media/video/video_mpv_config_test.dart',
  'video/Saturation': 'test/media/video/video_mpv_config_test.dart',
  'video/Gamma': 'test/media/video/video_mpv_config_test.dart',
  'video/Hue': 'test/media/video/video_mpv_config_test.dart',
  'video/Preserve pitch when speeding':
      'test/media/video/video_mpv_config_test.dart',
  'video/Channels': 'test/media/video/video_mpv_config_test.dart',
  'video/Normalize downmix loudness':
      'test/media/video/video_mpv_config_test.dart',
  // TODO-1247：尊重 .ass 自带样式开关平移到首页（videoRespectAssStyle 纯 pref）；
  // 生效点在字幕 overlay 标记渲染，由 video_subtitle_overlay_markup_test.dart 咬住。
  "video/Respect subtitle's own style":
      'test/media/video/video_subtitle_overlay_markup_test.dart',
  'video/Font size':
      'test/media/video/video_subtitle_style_test.dart + test/media/video/video_subtitle_overlay_test.dart',
  'video/Font weight':
      'test/media/video/video_subtitle_style_test.dart + test/media/video/video_subtitle_font_consistency_test.dart',
  'video/Shadow': 'test/media/video/video_subtitle_style_test.dart',
  'video/Background opacity': 'test/media/video/video_subtitle_style_test.dart',
  'video/Vertical position':
      'test/media/video/video_subtitle_style_test.dart + test/pages/video_subtitle_push_up_guard_test.dart',
  // TODO-2838：主字幕垂直锚定（底/顶）。写 videoSubtitleStyle blob（changed=true），
  // 生效点在 VideoSubtitleOverlay 的统一锚定解析（resolveLayerForcedAnchor →
  // _positionCueGroup 强制置顶 + padding 语义变离顶距离），本 harness 的 video 分组
  // 无适用探针（与主/副字幕位置滑杆同理）。由专项测试咬住：解析纯函数优先级 /
  // overlay 顶锚真几何 / top reserve 避让 / 持久化 round-trip + 旧 blob 兼容。
  'video/Main subtitle anchor':
      'test/media/video/video_subtitle_anchor_drag_test.dart',
  // PR#610「主/副字幕垂直位置分开调节」新增的副字幕位置滑杆（与上面主字幕
  // 'Vertical position' 同量纲、各自独立）。写 prefsRepo（changed=true），生效点在
  // VideoSubtitleOverlay 副字幕层的真几何（_layerBaseline），需真播放器 + media_kit，
  // 本 harness 的 video 分组无适用探针（主字幕位置同理登记）。由专项测试四层咬住：
  // overlay 真几何两层各吃各自基线 / 改一层不牵动另一层 / null=跟随主字幕 /
  // 持久化 round-trip，外加「设置滑杆 → style → 视频页 → overlay」接线源码守卫
  // （群④）——否则删掉滑杆或断掉 layout.part.dart 传参时几何测试照样全绿。
  'video/Secondary subtitle position':
      'test/media/video/video_subtitle_secondary_position_test.dart '
          '(①②③ overlay 真几何/跟随/持久化 + ④ 设置滑杆→视频页→overlay 接线守卫)',
  'video/Show danmaku':
      'test/media/video/video_danmaku_settings_test.dart + test/pages/video_danmaku_wiring_guard_test.dart',
  'video/Online Dandanplay match':
      'test/media/video/video_danmaku_settings_test.dart + test/pages/video_danmaku_wiring_guard_test.dart',
  'video/Active danmaku limit':
      'test/media/video/video_danmaku_settings_test.dart + test/media/video/video_danmaku_layout_test.dart',
  // PR#227: 番剧下载后端选择（外部 qBittorrent / 内置 libtorrent 引擎）。生效点在
  // QbConnectionConfig.backend 字段（编解码 / 向后兼容 / isConfigured），由专项
  // codec 测试覆盖；真实引擎切换是桌面 native 集成，widget 测不到。
  'video/Download backend':
      'test/media/torrent/anime_download_config_backend_test.dart',
  // PR#267: 内置引擎「上传 / 做种」总开关（默认关）。写 QbConnectionConfig.uploadEnabled
  // （changed=true），生效点在纯函数 torrent_upload_policy.shouldAllowUpload +
  // EmbeddedTorrentHost.sweepUploadPolicy 每 tick 下发 native ht_set_upload_mode（非
  // reader CSS / 主题树），无适用 widget 探针；由专项纯函数 + host sweep 测试覆盖，
  // 真实做种回传是桌面/Android native 集成，widget 测不到。
  'video/Enable upload / seeding':
      'test/media/torrent/torrent_upload_policy_test.dart',
  // 阶段 G：「下载」destination 经 body 逃生口内联既有 TorrentSettingsSection
  // 组件（PR#300 在改其内部，不改写）。该组件的 AdaptiveSettingsSwitchRow 开关全部
  // 写 QbConnectionConfig（changed=true），焦点覆盖 harness 能切到并翻转它们，但
  // 生效点在内置 libtorrent 引擎的 session/anti-leech/上传策略下发（native，widget
  // 测不到）；由专项纯函数/编解码测试覆盖。桌面默认后端=embedded，故这些开关在
  // harness 里可达——全部登记（含反吸血二级开关，超集登记无害）。
  'downloads/Enable upload / seeding':
      'test/media/torrent/torrent_upload_policy_test.dart',
  // 「自动为新任务添加订阅 tracker」：生效点是 addTorrent 之后**多打一次**
  // `/api/v2/torrents/addTrackers`（qB 后端）／把 tracker 追加进 magnet（内置引擎），
  // 都在 widget 树之外。torrent_backend_test 咬住的是真行为而不只是编解码：开关为真时
  // 断言请求序列是 add → addTrackers 且 urls 正是订阅拉回来的那两条。
  'downloads/Automatically add subscription trackers to new downloads':
      'test/torrent/torrent_backend_test.dart',
  // 「限速也作用于局域网」：生效点在 native（ht_apply_limits_ex 把上限写进
  // libtorrent 的 local peer class），widget 测不到；由编解码 + 下发透传测试覆盖。
  'downloads/Apply limits to LAN peers':
      'test/media/torrent/anime_download_config_backend_test.dart',
  'downloads/DHT': 'test/media/torrent/anime_download_config_backend_test.dart',
  'downloads/Local peer discovery (LSD)':
      'test/media/torrent/anime_download_config_backend_test.dart',
  'downloads/UPnP port mapping':
      'test/media/torrent/anime_download_config_backend_test.dart',
  'downloads/NAT-PMP port mapping':
      'test/media/torrent/anime_download_config_backend_test.dart',
  'downloads/Anonymous mode':
      'test/media/torrent/anime_download_config_backend_test.dart',
  'downloads/Enable anti-leech':
      'test/media/torrent/anime_download_config_backend_test.dart',
  'downloads/Ban progress cheat':
      'test/media/torrent/anime_download_config_backend_test.dart',
  'downloads/Ban relative progress cheat':
      'test/media/torrent/anime_download_config_backend_test.dart',
  // 设备/集成 backlog（消费点真机/WebView/Android-only，widget 测不到）
  // 「点一下没识别的对话框就地开跑 OCR」。生效点整条都在 WebView 里：JS 空白点
  // 带落页 payload 回传 → Dart 起任务 → 该页文字层热替换 → 回放点击查词。widget
  // 树上看不到任何变化，故由 JS 契约守卫 + 引擎选择单测覆盖。
  'manga/Tap to recognise':
      'test/media/manga/manga_tap_ocr_overlay_contract_test.dart + '
          'test/media/manga/ocr/manga_ocr_auto_start_test.dart',
  'reading/Spread direction': 'DEVICE: spread page order in WebView',
  'reading/Highlight text on tap': 'DEVICE: WebView onTap lookup',
  // TODO-1029：开关显示名改为「悬浮控制栏」(en: 'Floating control bar')，覆盖 map
  // 的 key 按渲染英文标签命名，故同步改名。生效=WebView onTapEmpty 收 chrome（设备）
  // + TODO-975 决策#3 底栏切悬浮模式（reader_chrome_floating_test 覆盖）。
  'reading/Floating control bar':
      'DEVICE: WebView onTapEmpty chrome + test/reader/reader_chrome_floating_test.dart',
  // TODO-727: 顶部「阅读进度」百分比指示的显隐开关。生效点在 reader 页 _showTopProgress
  // getter 末尾的 && ReaderFushiSource.showTopProgressBar 与门（WebView 阅读器顶栏 Text
  // 显隐，非 reader CSS / 主题树）；由专项 getter 真值表 + 源码守卫覆盖。默认 true=保持现状。
  'reading/Reading progress indicator':
      'test/settings/top_progress_toggle_guard_test.dart',
  // TODO-975: 顶部进度悬浮开关 + 悬浮控件自动隐藏延时。生效点在 reader 页悬浮
  // chrome 状态机（_topProgressReserve/_bottomChromeReserve 派生 + 自动隐藏定时器，
  // 非 reader CSS / 主题树）；由专项纯函数真值表 + 持久化 + 源码守卫覆盖。
  'reading/Floating reading progress':
      'test/reader/reader_chrome_floating_test.dart',
  'reading/Auto-hide floating controls after':
      'test/reader/reader_chrome_floating_test.dart',
  'reading/Invert swipe page turn direction': 'DEVICE: WebView swipe direction',
  // TODO-120: 反转键盘方向键翻页方向——生效点在 reader 键盘处理器（纯函数
  // resolveReaderArrowPageTurn 的 reverse 参数），由专项纯函数测试覆盖。
  'reading/Reverse arrow-key page turn direction':
      'test/reader/reader_space_pause_test.dart',
  'reading/Mouse wheel page-turn interval':
      'DEVICE: WebView wheel page-turn throttle',
  'reading/Swipe page-turn sensitivity':
      'test/reader/swipe_page_turn_sensitivity_test.dart',
  'reading/Keep screen awake': 'DEVICE: WakelockPlus channel',
  'reading/Volume button page turning': 'DEVICE: native VolumeKeyChannel',
  'reading/Invert volume buttons': 'DEVICE: native volume-key direction',
  'lookup/Pause on lookup': 'DEVICE: audiobook pause on selection',
  // TODO-756b：悬停即查词（视频 onCharHover 门控 + 阅读器 window.__hoverAutoLookup
  // JS 门控）。change/persist/restore 经 DB 由本测试守，运行时悬停查词分流由
  // 行为测试 test/media/video/video_subtitle_hover_lookup_test.dart 覆盖。
  'lookup/Look up on hover':
      'test/media/video/video_subtitle_hover_lookup_test.dart',
  'lookup/Aggregate word frequencies': 'DEVICE: popup.js frequency aggregation',
  'lookup/Auto search': 'WIDGET-TODO: HomeDictionaryPage debounce gate',
  'lookup/Remote dictionary lookup': 'INTEGRATION: remote host lookup',
  'lookup/Yomitan API server':
      'INTEGRATION: yomitan-api server lifecycle (test/sync/yomitan_api_server_manager_test.dart)',
  'lookup/Texthooker (receive text)':
      'INTEGRATION: texthooker WS client lifecycle (test/sync/texthooker_ws_client_manager_test.dart)',
  // 阶段 E：防截屏开关。效果是 native SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)
  // （Windows-only，widget 树测不到）；写穿 + 即时重应用由专项测试咬住。
  'lookup/Block screen capture':
      'test/settings/settings_block_capture_test.dart (native display affinity)',
  'lookup/Auto read word on lookup': 'DEVICE: TTS auto-read',
  'lookup/Lookup audio volume':
      'test/reader/lookup_audio_volume_settings_test.dart + test/utils/misc/lookup_audio_volume_wiring_static_test.dart + test/settings/settings_renderer_test.dart',
  'lookup/Collapse dictionaries': 'DEVICE: popup.js collapse',
  // TODO-845: 折叠词典时仍展开前 N 本。效果在 popup.js createGlossarySection 的
  // <details>.open（WebView 渲染，widget 测不到）；由 node 行为守卫真执行覆盖。
  'lookup/Auto-expand rows':
      'test/pages/popup_auto_expand_dictionaries_test.js (popup.js node behaviour guard) + test/pages/popup_auto_expand_dictionaries_test.dart',
  'lookup/Show expression tags': 'DEVICE: popup.js expression tags',
  'lookup/Deduplicate pitch accents': 'DEVICE: popup.js pitch dedup',
  // TODO-702: 有声书退出即停（默认）/ 后台续播（可选）。pref-only（门控阅读器
  // dispose 时是否 stop 会话，无渲染树效果）；schema coverage 证 focus/change/
  // persist/restore 经 DB，运行时分流由偏好默认 + dispose 源码守卫覆盖。
  'listening/Keep playing after exit':
      'test/models/preferences_repository_test.dart + test/media/audiobook/audiobook_exit_stop_policy_static_test.dart',
  'listening/Show media notification':
      'DEVICE: native AudioHandler notification',
  // TODO-038: now visible on Windows desktop too (no longer Android-only). The
  // strip is a runner-owned Win32 window, so the real overlay needs a desktop;
  // covered by source guards + device backlog.
  'listening/Floating lyric overlay':
      'test/media/audiobook/floating_lyric_click_through_guard_test.dart + test/settings/floating_lyric_settings_visibility_guard_test.dart + DEVICE: native always-on-top strip',
  'listening/Floating subtitle font size':
      'test/media/audiobook/desktop_floating_lyric_test.dart + DEVICE: native strip font size',
  // TODO-370: 文字 / 按钮底色透明度作用于 ARGB alpha 通道，效果由 scaleAlpha 纯函数测试
  // 覆盖；落到原生悬浮窗的实际像素需真机。
  'listening/Floating subtitle text opacity':
      'test/media/audiobook/floating_lyric_opacity_test.dart (scaleAlpha) + DEVICE: native strip text alpha',
  'listening/Floating subtitle button background opacity':
      'test/media/audiobook/floating_lyric_opacity_test.dart (scaleAlpha) + DEVICE: native strip button alpha',
  // TODO-576: 条背景透明度（默认 70=更不挡视野）作用于条背景 ARGB alpha；缩放由
  // scaleAlpha 纯函数测试覆盖，落到原生悬浮窗的实际像素需真机。
  'listening/Floating subtitle background opacity':
      'test/media/audiobook/floating_lyric_opacity_test.dart (scaleAlpha) + test/settings/floating_lyric_bg_opacity_test.dart + DEVICE: native strip bg alpha',
  // TODO-708 P2: 圆角半径 / 宽度（dp，0=平台原生观感）。偏好往返 + 默认哨兵 + 两个样式
  // 构造点喂入由专项测试覆盖；落到原生悬浮窗的实际圆角/窗宽像素需真机点验。
  'listening/Floating subtitle corner radius':
      'test/media/audiobook/floating_lyric_style_dimensions_test.dart + DEVICE: native strip corner radius (Android GradientDrawable / Windows D2D)',
  'listening/Floating subtitle width':
      'test/media/audiobook/floating_lyric_style_dimensions_test.dart + DEVICE: native strip window width (Android LayoutParams / Windows SetWindowPos)',
  // TODO-708 P4: 悬浮字幕前后 N 行上下文块（N=0 单行）。偏好往返 + 上下文行区间
  // 构建（当前行 start/length 高亮）由专项测试覆盖；落到原生悬浮窗的多行渲染 +
  // 当前行明暗需真机点验。
  'listening/Floating subtitle context lines':
      'test/media/audiobook/floating_lyric_context_pref_test.dart + test/media/audiobook/floating_lyric_context_test.dart + DEVICE: native strip multi-line context + current-line highlight (Android FloatingLyricService / Windows floating_lyric_window)',
  'listening/Tap floating subtitle to look up':
      'test/media/audiobook/floating_lyric_click_through_guard_test.dart + DEVICE: native strip tap lookup',
  'listening/Volume key sentence navigation':
      'DEVICE: native volume-key cue nav',
  'system/Update channel': 'DEVICE: Android-only UpdateChecker (beta/stable)',
  "system/Don't remind me about updates": 'DEVICE: Android-only UpdateChecker',
  'system/Auto-install updates': 'DEVICE: Android-only UpdateChecker install',
  'appearance/Reverse navigation bar': 'WIDGET-TODO: HomePage nav order',
  // 阶段 G 归位：「启动时打开查词」从 appearance 移到 system·通用（item id 不变，
  // destId 随所属 destination 改为 system）。
  'system/Open lookup on startup': 'test/pages/home_page_tabs_test.dart',
  'reading/Reverse reader bottom bar':
      'DEVICE: reader bottom-bar layout order (like reverse nav bar)',
  // TODO-830: 反转有声书底栏 ⏮⏭ 前进/后退按钮的功能方向（per-reader）。change/
  // persist/restore 经 DB 由本测试守；运行时把 ⏮/⏭ 的 icon+tooltip+onPressed 互换
  // 的功能维度由专项 widget 行为测试覆盖（与 reverse-bottom-bar 的位置镜像正交）。
  'reading/Invert bottom-bar skip buttons':
      'test/media/audiobook/audiobook_play_bar_reverse_test.dart',
  // TODO-728: bottom-bar current-sentence toggle. change/persist/restore proven
  // here through the DB; the render effect (cue Text shown/hidden without a
  // layout jump) is covered by a dedicated widget test, and the per-reader
  // layering by the source pref round-trip.
  'reading/Show current sentence':
      'test/media/audiobook/audiobook_play_bar_show_cue_test.dart + test/media/sources/reader_chrome_prefs_728_test.dart',
  // TODO-728: top reading-progress position (left/center/right). Effect point is
  // the reader page _buildTopProgressBar Align/textAlign (WebView reader chrome,
  // not reader CSS / theme tree); covered by pure-fn mapping + tap-toggle guard.
  'reading/Progress position':
      'test/reader/reader_top_progress_test.dart + test/media/sources/reader_chrome_prefs_728_test.dart',

  // ───────────────────────────────────────────────────────────────────────────
  // 下拉型设置项（`SettingsSegmentedItem(dropdown: true)` → AdaptiveSettingsPickerRow）。
  //
  // 这一整类以前**结构性地**逃出了本测试：`_focusedSettingsRow()` 只认 switch /
  // slider / stepper / segmented 四种 widget，下拉行连「被看见」都没有，谈不上覆盖。
  // 补上识别 + 专属驱动（Enter 开菜单 → 方向键 → Enter 提交，见 _driveDropdownRow）
  // 之后，下面这些行第一次进入账目：绝大多数是「改了确实写穿 DB，但生效点在 libmpv /
  // ffmpeg 参数 / 远端制卡载荷 / 同步编排，本 harness 无渲染探针」。
  // 另有一批 changed=false 的，原因**不是**驱动失败而是写的根本不是 `preferences`
  // 表（`db.getAllPrefs()` 的 diff 结构上看不见），逐条在下面写明落点。
  //
  // 「真的被驱动」这一步由 main() 末尾的 picker 数量断言兜底（认出来 ≥20 行、真写穿
  // ≥18 行），所以这里登记的不是「没验」，而是「写穿已验、渲染生效无探针」。

  // 界面语言：pref 写入 + LocaleSettings 真切换 + 顶层 Key 重挂（整树重建才让 t 重算）。
  'appearance/Language settings':
      'test/settings/locale_switch_no_restart_test.dart',
  // HDR/10-bit 输出：storageValue 往返 + shouldUseHdrHostWindow 三态真值表 + 宿主窗
  // mpv 属性下发顺序；真实 HDR 片源效果需桌面设备验。
  'video/HDR / 10-bit output': 'test/media/video/video_hdr_output_test.dart',
  // YouTube 画质：消费点是 pickVideoStreamForTargetHeight（目标档优先/降档省流），
  // 外加「playbackTargetHeight 真被传下去」的接线守卫。
  'video/YouTube quality':
      'test/media/video/youtube_playback_stream_pick_test.dart + '
          'test/media/video/youtube_fast_load_guard_test.dart',
  // galgame 查词触发方式：偏好钳位/往返 + AppModel→controller 下发 + MethodChannel
  // 载荷 lookupTrigger + runner 侧读取，全在同一份偏好行为用例里。
  'game/Lookup trigger':
      'test/lookup/gal_hook_overlay_interaction_prefs_test.dart',
  // 视频制卡图片模式：真下发进 ImmersionMiningRequest，且单帧模式一次都不调动图抽取器。
  'cardCreation/Video card image':
      'test/mining/remote_mining_image_mode_test.dart + '
          'test/mining/immersion_capture_channel_test.dart',
  // 动图/静图格式：ffmpeg 参数按格式分派 + 扩展名跟实际字节 + 编码器缺失降级。
  'cardCreation/Video card animation format':
      'test/mining/mining_animated_format_test.dart + '
          'test/mining/remote_mining_animated_format_test.dart',
  'cardCreation/Video card screenshot format':
      'test/mining/mining_still_format_test.dart',
  'cardCreation/Galgame card image':
      'test/mining/gal_hook_mining_coordinator_test.dart',
  'cardCreation/Game card animation format':
      'test/mining/mining_animated_format_test.dart',
  'cardCreation/Game card screenshot format':
      'test/mining/gal_hook_mining_coordinator_test.dart + '
          'test/mining/mining_still_format_test.dart',
  // 同步后端选择：syncChannelScopeOf 是 resolveSyncBackend 的逆（选哪个就解析出哪个），
  // 外加 applyBackupBackendChange 真改变通道归属。
  'syncBackup/Storage backend': 'test/sync/sync_channel_scope_test.dart + '
      'test/sync/interconnect_backup_backend_test.dart',
  // 首选下载源：本 PR 的根因修复本体——所选来源钉住首项且不被探针竞速顶掉、不适用时
  // 降级可观测，正负对照都在这两个文件里。
  'system/Preferred download source':
      'test/utils/misc/update_checker_mirror_fallback_test.dart + '
          'test/utils/misc/update_checker_race_test.dart',

  // ── 下面这批 changed=false，因为值不写 `preferences` 表 ──
  // Profile 选择器写的确实是 preferences 的 active_profile_id，但 harness 里只有一个
  // Profile，onChanged 对同一个 id 直接 return——没有第二个值可切，不是驱动失败。
  'profiles/Profile': 'test/profile/profile_repository_test.dart',
  // 八个媒体类型绑定写的是 `media_type_profiles` 表，getAllPrefs() 的 diff 结构上
  // 看不到。穷尽断言「每个 ProfileMediaKind 都有绑定行」+ 表级往返 + resolveProfileId
  // 优先级链共同咬住；epub/srtbook/audiobook/lyrics 四类共用同一条
  // resolveProfileId/autoApplyBinding 链，没有逐类型 guard。
  'profiles/Book': _kMediaTypeBindingEvidence,
  'profiles/Subtitle book': _kMediaTypeBindingEvidence,
  'profiles/Audiobook': _kMediaTypeBindingEvidence,
  'profiles/Lyrics mode': _kMediaTypeBindingEvidence,
  'profiles/Video': _kMediaTypeBindingEvidence,
  'profiles/Manga': _kMediaTypeBindingEvidence,
  'profiles/Game': _kMediaTypeBindingEvidence,
  'profiles/Browser': _kMediaTypeBindingEvidence,
  // 制卡字号写的是 SharedPreferences 里的 AnkiSettings JSON blob（与本表既有的
  // cardCreation 开关同因），消费点是 composeLapisCss(fontScalePercent:)。
  'cardCreation/Card font scale':
      'packages/fushi_anki/test/lapis_styling_test.dart',

  // ───────────────────────────────────────────────────────────────────────────
  // 互联开关。这批行以前压根没被遍历到（下拉行接入后菜单开合改变了列表滚动位置，更多
  // 懒构建的行才进入 widget tree），不是新增设置，是新暴露的账目缺口。
  //
  // 前四条写的是**互联专属**键（setInterconnectSync*Enabled），与 syncBackup/* 那套
  // 云侧开关是两套；不能复用云侧的 orchestrator 证据（那条只咬云通道）。
  'interconnect/Upload book files':
      'test/sync/interconnect_upload_toggles_test.dart',
  'interconnect/Upload dictionaries':
      'test/sync/interconnect_upload_toggles_test.dart',
  'interconnect/Upload audiobook files':
      'test/sync/interconnect_upload_toggles_test.dart',
  'interconnect/Upload video files':
      'test/sync/interconnect_upload_toggles_test.dart',
  // 统计/收藏分享：AggregateSnapshot 按族裁剪、syncOverClient 上下行都裁、两个都关时
  // 整轮不发请求。
  'interconnect/Share statistics':
      'test/sync/interconnect_share_scope_test.dart',
  'interconnect/Share favorites':
      'test/sync/interconnect_share_scope_test.dart',
  // service-config 同步：开关是请求前的进场门（关 = 连请求都不发），且是设备本地键。
  'interconnect/Sync service configuration from host':
      'test/sync/interconnect_service_config_test.dart',
  // 开服开关：持久化的是「想开服」的意图（绑定失败也保留），启动失败映射成
  // FushiServerStartError 而不是把开关卡在「已开启」。
  'interconnect/Enable sync server':
      'test/sync/server_enabled_persist_test.dart + '
          'test/sync/server_start_lifecycle_test.dart',
  // 互联 TLS：设置项接 setServerTlsEnabled + 首次 hosting 默认 + TOFU 指纹保留；
  // 打开后真发生的事（自签证书被 SecurityContext 接受、pin 对则 200 / 错则握手失败）。
  'interconnect/Interconnect encryption (HTTPS/TLS)':
      'test/sync/interconnect_tls_entry_guard_test.dart + '
          'test/sync/tls/fushi_tls_identity_test.dart',
  // 远端查词：与 lookup 分类共享同一份 item 定义。⚠️ 门本身
  // （AppModel._searchRemoteDictionary 开头的 remoteLookupEnabled 短路）没有守卫，
  // 仍是设备 backlog；下面两个文件只覆盖偏好往返与开关打开后的客户端链路。
  'interconnect/Remote dictionary lookup':
      'INTEGRATION: remote host lookup（门本身仍无守卫）+ '
          'test/models/preferences_repository_test.dart + '
          'test/sync/fushi_remote_lookup_client_test.dart',
  // 显示远端条目：与 syncBackup/Show remote entries 是同一份 item 定义、同一个消费点。
  'interconnect/Show remote entries':
      'test/pages/home_video_remote_mixed_grid_test.dart + test/pages/reader_remote_mixed_grid_test.dart',
};

/// 八个媒体类型 → Profile 绑定行共用的证据（同一条 resolveProfileId /
/// autoApplyBinding 链 + 同一张 `media_type_profiles` 表）。
const String _kMediaTypeBindingEvidence =
    'test/profile/media_type_binding_new_kinds_guard_test.dart + '
    'test/profile/media_type_binding_video_guard_test.dart + '
    'test/profile/profile_repository_test.dart + '
    'test/database/profiles_test.dart';

/// 焦点驱动的 settings schema **全分组**覆盖测试（Phase 1 Task 4）。
///
/// 用仓库验证过的 settings_renderer harness（测试 AppModel + 内存 DB + 真实
/// schema + 真实 MaterialSettingsRenderer）逐个渲染**每个** destination 的明细
/// 页，再用 [FocusDriver] 以 Tab 焦点遍历整页：每个可聚焦节点若落在某个
/// `AdaptiveSettings*Row` 上就驱动它（Switch 用 Space 激活；Slider / Stepper /
/// Segmented 都是 _GamepadAdjustableValue 单一焦点停靠点，用 Left/Right 方向键
/// 原地调值），验证「改值 → 写穿 DB → 真生效 → 全局可还原」。
///
/// 生效探针按 destination 分派：reading → T1（`ReaderContentStyles.css` 渲染
/// 输入）；appearance → T2（`themeNotifier.theme` 渲染输入）；其余分组多为行为/
/// 持久类，暂无适用探针 → 按设计 §5 显式记为 UNVERIFIED 缺口（待 T4 行为探针），
/// 不静默放水也不误判失败。
///
/// 比 flutter drive 跑 app.main 更确定、更快、无 live-app 后台噪音；逐设置校验
/// 平台无关。整 app 流程的真机/桌面验证由 app_smoke 等承担（Phase 2-4）。
void main() {
  test('reverse arrow setting keeps schema title wired to i18n', () {
    // TODO-586：reverse_arrow 项随 reading destination 搬到 reading 领域文件。
    final String source = File('lib/src/settings/settings_schema_reading.dart')
        .readAsStringSync();

    expect(
      source,
      contains("id: 'reading_controls.reverse_arrow_page_turn'"),
    );
    expect(source, contains('title: t.reverse_arrow_page_turn'));
  });

  testWidgets(
      'all settings destinations: focus-driven, change persists and takes effect',
      (WidgetTester tester) async {
    // 折叠 section 默认收起会把行移出 widget 树、Tab 焦点驱动够不到它们，静默削弱
    // 本覆盖守卫。强制全展开，让每个 section 的每一行都能被驱动到（见
    // debugSettingsForceExpandAllSections）。
    debugSettingsForceExpandAllSections = true;
    addTearDown(() => debugSettingsForceExpandAllSections = false);
    // cardCreation 详情页现在内联渲染 AnkiSettingsBody（扁平化后不再藏在子路由
    // 后），它经 ankiViewModelProvider → BaseAnkiRepository 调
    // SharedPreferences.getInstance()；host 无插件实现会抛 MissingPluginException。
    // mock 空初值让其确定性成功，不依赖异步异常逃逸 takeException 窗口。
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final ReaderSettings? prevReaderSettings = ReaderFushiSource.readerSettings;
    final ReaderSettings readerSettings = ReaderSettings(db);
    await readerSettings.refreshFromDb();
    ReaderFushiSource.readerSettings = readerSettings;
    addTearDown(() => ReaderFushiSource.readerSettings = prevReaderSettings);

    final ThemeNotifier themeNotifier =
        ThemeNotifier(db, () => const TextTheme())
          ..loadFromPrefsSnapshot(<String, String>{
            'design_system': PrefCodec.encode('material'),
            'app_theme_key': PrefCodec.encode('system-theme'),
            'brightness_mode': PrefCodec.encode('system'),
            'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
          });
    addTearDown(themeNotifier.dispose);
    // 用现成公开 seam 把 schema 渲染需要的子系统全部 wire 到同一内存 DB（不改
    // app_model.dart，避开并发 agent 冲突）：wireDatabaseForTesting 设 database；
    // wireLocalAudioForTesting 设 prefsRepo(+localAudioManager) —— prefsRepo 是
    // appearance/lookup/cardCreation/listening/system 绝大多数 blocker 的根源。
    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_settings_cov_');
    addTearDown(() {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final PlatformServices platformServices = testPlatformServices();
    final AppModel appModel = _CoverageAppModel(platformServices)
      ..themeNotifier = themeNotifier
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo, databaseDirectory: tmpDir)
      // 语言选择器读 locales late-Map；populateLanguages/Locales 是公开纯 Dart
      // 静态注册（startup 也调它们），填好 system 分组的语言项才能渲染。
      ..populateLanguages()
      ..populateLocales();

    // 探针：reading→T1 reader CSS；appearance→T2 themeNotifier.theme 渲染输入。
    final ReaderCssEffectProbe readerProbe =
        ReaderCssEffectProbe(() => readerSettings);
    final RenderInputProbe themeProbe = RenderInputProbe(
      () => '${themeNotifier.theme.colorScheme}|'
          '${themeNotifier.darkTheme.colorScheme}|'
          '${themeNotifier.brightnessMode}|${themeNotifier.appThemeKey}',
      tier: EffectTier.t2WidgetTree,
    );
    EffectProbe? probeFor(SettingsDestinationId id) => switch (id) {
          SettingsDestinationId.reading => readerProbe,
          SettingsDestinationId.appearance => themeProbe,
          _ => null,
        };

    final ValueNotifier<SettingsDestination?> destNotifier =
        ValueNotifier<SettingsDestination?>(null);
    addTearDown(destNotifier.dispose);
    List<SettingsDestination> destinations = const <SettingsDestination>[];

    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[
        appProvider.overrideWith((Ref ref) => appModel),
        platformServicesProvider.overrideWithValue(platformServices),
      ],
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          platform: TargetPlatform.android,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
          extensions: <ThemeExtension<dynamic>>[
            FushiDesignSystemTheme(themeNotifier.designSystemTheme),
          ],
        ),
        home: Consumer(
          builder: (BuildContext ctx, WidgetRef ref, Widget? _) {
            final SettingsContext sctx = SettingsContext(
              context: ctx,
              appModel: ref.read(appProvider),
              ref: ref,
              readerSource: ReaderFushiSource.instance,
              refresh: () {},
            );
            final List<SettingsDestination> all = buildSettingsSchema(sctx);
            // 子 schema 页（SettingsNavigationItem.child）里的行也要进遍历：
            // 顶层枚举不到它们，覆盖会静默缩水。
            destinations = <SettingsDestination>[
              ...all,
              for (final SettingsDestination d in all) ..._childPagesOf(d),
            ];
            return ValueListenableBuilder<SettingsDestination?>(
              valueListenable: destNotifier,
              builder: (_, SettingsDestination? dest, __) {
                return MaterialSettingsRenderer().buildDetailPage(
                  settingsContext: sctx,
                  destination: dest ?? all.first,
                );
              },
            );
          },
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));

    final Map<String, String> initial =
        Map<String, String>.from(await db.getAllPrefs());

    final FocusDriver driver = FocusDriver(tester);
    final List<ItemVerdict> verdicts = <ItemVerdict>[];
    final List<String> destFindings = <String>[];

    for (final SettingsDestination dest in destinations) {
      destNotifier.value = dest;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      // 渲染该分组时可能抛多个异常（最小 harness 缺真实 AppModel 子系统状态）；
      // 全部 drain，记下第一条当发现，跳过该分组（不让残留异常判挂整测）。
      Object? renderEx;
      Object? e;
      while ((e = tester.takeException()) != null) {
        renderEx ??= e;
      }
      if (renderEx != null) {
        destFindings.add('${dest.id.name}: render threw $renderEx');
        debugPrint(
            '[schema-coverage] DEST ${dest.id.name} render FAILED: $renderEx');
        continue;
      }
      final EffectProbe? probe = probeFor(dest.id);
      final Set<FocusNode> seen = <FocusNode>{};
      final Set<String> driven = <String>{};
      int stale = 0;
      for (int step = 0; step < 400; step++) {
        final FocusNode? node = FocusManager.instance.primaryFocus;
        if (node != null && !seen.contains(node)) {
          seen.add(node);
          final _FocusedRow? row = _focusedSettingsRow();
          if (row != null && driven.add(row.title)) {
            verdicts.add(await _verifyFocusedNode(
              tester: tester,
              driver: driver,
              db: db,
              readerSettings: readerSettings,
              probe: probe,
              destId: dest.id.name,
              row: row,
            ));
          }
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump(const Duration(milliseconds: 16));
        final FocusNode? now = FocusManager.instance.primaryFocus;
        if (now == null || seen.contains(now)) {
          if (++stale > 8) break;
        } else {
          stale = 0;
        }
      }
    }

    // 全局还原：改过的 key 写回初值，测试新增的 key 删除，再校验快照一致。
    final Map<String, String> afterAll =
        Map<String, String>.from(await db.getAllPrefs());
    for (final MapEntry<String, String> e in initial.entries) {
      if (e.key == PreferencesRepository.prefsVersionKey) continue;
      if (afterAll[e.key] != e.value) {
        await db.setPref(e.key, e.value);
      }
    }
    for (final String k in afterAll.keys) {
      if (k == PreferencesRepository.prefsVersionKey) continue;
      if (!initial.containsKey(k)) {
        await db.deletePref(k);
      }
    }
    await readerSettings.refreshFromDb();
    final Map<String, String> restored =
        Map<String, String>.from(await db.getAllPrefs());
    final List<String> restoreDiff = _mapDiff(initial, restored);
    final bool globallyRestored = restoreDiff.isEmpty;

    // 「Yomitan API server」开关被焦点遍历真切到 ON 时会 shelf_io.serve 绑定一个
    // 真实 HttpServer，它带一个 2 分钟 idleTimeout 周期 Timer。全局还原只写回 DB
    // pref，不会停服 → 该 Timer 残留，触发测试结束的「A Timer is still pending」
    // 断言（原 develop 基线红）。必须在**测试 body 内**（FakeAsync 区、pending-
    // timer 校验之前）停服；放 addTearDown 太晚（teardown 在 timer 校验之后跑）。
    // stopYomitanApiServer() 是 async，但调用它会**同步**求值到 HttpServer.close()
    // ——close() 在第一个 await 挂起前就同步取消了 idleTimeout Timer。故只需触发调
    // 用、不能 await 它（await 真 socket-close 的 I/O Future 在 FakeAsync 区会死锁；
    // 用 tester.runAsync 又会冲掉无关的 image-cache 真异步引出 path_provider
    // MissingPluginException）。socket 真关闭随后在真实事件循环兑现，与本断言无关。
    // 仅 Yomitan 留 Timer（texthooker/clipboard 切 ON 不留 fake Timer），故只停它。
    unawaited(appModel.stopYomitanApiServer());

    for (final ItemVerdict v in verdicts) {
      debugPrint('[schema-coverage] ${_describe(v)}');
    }
    final int changed = verdicts.where((ItemVerdict v) => v.changed).length;
    final int effect =
        verdicts.where((ItemVerdict v) => v.effectVerified).length;
    final int unverified = verdicts
        .where((ItemVerdict v) => v.changed && !v.effectVerified)
        .length;
    debugPrint('[schema-coverage] ALL destinations: rows=${verdicts.length} '
        'changed=$changed effectVerified=$effect '
        'unverified(待 T4)=$unverified globallyRestored=$globallyRestored '
        'destFindings=${destFindings.length}');
    for (final String f in destFindings) {
      debugPrint('[schema-coverage] DEST-FINDING: $f');
    }

    // 账目：每个 changed 但未 effect-verified 的设置，要么有专项探针、要么登记
    // 设备 backlog（kCoveredElsewhere），不允许静默缺口。
    final List<ItemVerdict> stillUnaccounted = verdicts
        .where((ItemVerdict v) =>
            !v.effectVerified && !kCoveredElsewhere.containsKey(v.id))
        .toList();
    for (final ItemVerdict v in stillUnaccounted) {
      debugPrint('[schema-coverage] STILL-UNACCOUNTED: ${v.id} '
          '(${v.controlType}) — 既无探针也未登记 backlog');
    }
    debugPrint('[schema-coverage] coverage accounting: '
        'effectVerified=$effect '
        'coveredElsewhere=${verdicts.where((ItemVerdict v) => !v.effectVerified && kCoveredElsewhere.containsKey(v.id)).length} '
        'stillUnaccounted=${stillUnaccounted.length}');

    expect(stillUnaccounted, isEmpty,
        reason: '每个 changed 但未 effect-verified 的设置都必须登记到 '
            'kCoveredElsewhere（专项测试或设备 backlog），不允许静默缺口。'
            '未登记: ${stillUnaccounted.map((ItemVerdict v) => v.id).join(", ")}');

    expect(destFindings, isEmpty,
        reason: '全部 8 个 destination 都应能渲染（根本性修复：测试侧 wire 全部'
            '子系统）。渲染失败: ${destFindings.join("; ")}');
    expect(verdicts.length, greaterThan(40),
        reason: '应遍历到跨全部 8 个分组的大量可操作控件（焦点可达）');
    final List<ItemVerdict> notPersisted =
        verdicts.where((ItemVerdict v) => v.changed && !v.persisted).toList();
    expect(notPersisted, isEmpty,
        reason: '改了却没写穿 DB 的控件: '
            '${notPersisted.map((ItemVerdict v) => v.id).join(", ")}');
    expect(verdicts.where((ItemVerdict v) => v.effectVerified).length,
        greaterThanOrEqualTo(8),
        reason: 'reading(T1)+appearance(T2) 应有多项被探针确认真生效');
    // 下拉行（`SettingsSegmentedItem(dropdown: true)`）以前根本不在 _focusedSettingsRow
    // 的识别名单里，整类设置项一条账都没有。光「认出来」不够——`FocusDriver.adjust` 的
    // 左右键在 DropdownMenu 里被映射成文本光标 intent，一步都动不了，认出来也全是
    // changed=false。所以这里钉的是「真的被驱动、真的写穿了 DB 的下拉行数量」：
    // _driveDropdownRow 的 Enter→方向键→Enter 序列一旦退化，这条先红。
    final List<ItemVerdict> pickers = verdicts
        .where((ItemVerdict v) => v.controlType == _RowKind.picker.name)
        .toList();
    expect(pickers.length, greaterThanOrEqualTo(20),
        reason: '全仓下拉型设置项应被遍历到（认出来这一步）');
    expect(pickers.where((ItemVerdict v) => v.persisted).length,
        greaterThanOrEqualTo(18),
        reason: '下拉行必须真的被驱动并写穿 DB（驱动那一步）。未写穿的: '
            '${pickers.where((ItemVerdict v) => !v.persisted).map((ItemVerdict v) => v.id).join(", ")}');
    expect(globallyRestored, isTrue,
        reason: '全部设置必须能还原到初始快照。diff: ${restoreDiff.join("; ")}');
  });
}

String _describe(ItemVerdict v) {
  final String status = v.isPass
      ? 'PASS'
      : (v.changed && !v.effectVerified ? 'UNVERIFIED' : 'FAIL');
  return '[${v.controlType}] ${v.id} reached=${v.reached} '
      'changed=${v.changed} persisted=${v.persisted} '
      'effect=${v.effectVerified} restored=${v.restored} $status'
      '${v.note.isEmpty ? "" : " — ${v.note}"}';
}

_FocusedRow? _focusedSettingsRow() {
  final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return null;
  _FocusedRow? found;
  ctx.visitAncestorElements((Element el) {
    final Widget w = el.widget;
    if (w is AdaptiveSettingsSwitchRow) {
      found = _FocusedRow(title: w.title, kind: _RowKind.switchRow);
      return false;
    }
    if (w is AdaptiveSettingsSliderRow) {
      found = _FocusedRow(title: w.title, kind: _RowKind.slider);
      return false;
    }
    if (w is AdaptiveSettingsStepperRow) {
      found = _FocusedRow(title: w.title, kind: _RowKind.stepper);
      return false;
    }
    if (w is AdaptiveSettingsSegmentedRow) {
      found = _FocusedRow(
          title: (w as dynamic).title as String, kind: _RowKind.segmented);
      return false;
    }
    // `SettingsSegmentedItem(dropdown: true)` 渲染成 picker 行而不是分段条
    // （settings_schema_widgets.dart 的 `_segmented`）。这一支以前根本不在识别名单里，
    // 于是**所有**下拉型设置项都逃出了「改了能写穿 DB」的账目——不是没覆盖到，是压根
    // 没被看见。泛型 `<T>` 用 dynamic 取 title，同 segmented 那支。
    if (w is AdaptiveSettingsPickerRow) {
      found = _FocusedRow(
        title: (w as dynamic).title as String,
        kind: _RowKind.picker,
        optionCount: ((w as dynamic).options as List<Object?>).length,
      );
      return false;
    }
    return true;
  });
  return found;
}

/// 递归收集 [page] 里所有 `SettingsNavigationItem.child` 子页（含子页的子页）。
List<SettingsDestination> _childPagesOf(SettingsDestination page) {
  final List<SettingsDestination> out = <SettingsDestination>[];
  for (final SettingsSection section in page.sections) {
    for (final SettingsItem item in section.items) {
      if (item is! SettingsNavigationItem) continue;
      final SettingsDestination Function()? child = item.child;
      if (child == null) continue;
      final SettingsDestination sub = child();
      out
        ..add(sub)
        ..addAll(_childPagesOf(sub));
    }
  }
  return out;
}

Future<ItemVerdict> _verifyFocusedNode({
  required WidgetTester tester,
  required FocusDriver driver,
  required FushiDatabase db,
  required ReaderSettings readerSettings,
  required EffectProbe? probe,
  required String destId,
  required _FocusedRow row,
}) async {
  await readerSettings.refreshFromDb();
  final EffectSnapshot? effBefore = probe?.capture();
  final Map<String, String> before =
      Map<String, String>.from(await db.getAllPrefs());
  // 界面语言本身也是一个可驱动的设置，而 verdict 的身份键是**渲染出来的标题**。驱动
  // 它一次，之后每一行的 id 都换成另一种语言，与账本（英文标题）整批对不上——本轮的
  // 覆盖结论就会变成「几十条从没见过的新项」，而磁盘上什么都没少覆盖。所以驱动完立刻
  // 把渲染语言复位，让身份键在整轮里恒是同一种语言；语言 pref 本身由全局还原兜底。
  final AppLocale localeBefore = LocaleSettings.currentLocale;

  if (row.kind == _RowKind.switchRow) {
    await driver.activate();
    await tester.pump(const Duration(milliseconds: 50));
  } else if (row.kind == _RowKind.picker) {
    await _driveDropdownRow(
        tester: tester, driver: driver, db: db, before: before);
  } else {
    await driver.adjust(steps: 4);
    await tester.pump(const Duration(milliseconds: 50));
    if (_mapsEqual(before, await db.getAllPrefs())) {
      await driver.adjust(steps: -4);
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
  if (LocaleSettings.currentLocale != localeBefore) {
    LocaleSettings.setLocale(localeBefore);
    await tester.pump(const Duration(milliseconds: 50));
  }
  final Object? thrown = tester.takeException();

  final Map<String, String> after =
      Map<String, String>.from(await db.getAllPrefs());
  await readerSettings.refreshFromDb();
  final bool persisted = !_mapsEqual(before, after);
  final bool changed = persisted;

  bool effectVerified = false;
  String note = '';
  if (probe != null && effBefore != null && changed) {
    effectVerified = probe.compare(effBefore, probe.capture()).changed;
    if (!effectVerified) {
      note = 'EFFECT UNVERIFIED: ${probe.kind.name} 渲染输入无变化（多为行为类设置，待 T4）';
    }
  } else if (!changed) {
    note = 'no change observed（驱动键不对 / 控件被门控 disabled）'
        '${row.kind == _RowKind.picker ? "; options=${row.optionCount}" : ""}';
  } else {
    note = 'EFFECT UNVERIFIED: 该分组暂无适用探针（待 T4 行为探针）';
  }
  if (thrown != null) {
    note = '${note.isEmpty ? "" : "$note; "}THREW: $thrown';
  }

  return ItemVerdict(
    id: '$destId/${row.title}',
    controlType: row.kind.name,
    reached: true,
    changed: changed,
    persisted: persisted,
    effectVerified: effectVerified,
    restored: true,
    note: note,
  );
}

/// 焦点驱动一个下拉（picker）设置行。
///
/// 它不是「左右键调一格」的控件，所以 [FocusDriver.adjust] 那条路一步都动不了：
/// Tab 落在 `DropdownMenu` 尾部的展开 IconButton 上，而 `DropdownMenu` 把左右键映射
/// 成**文本光标** intent（`ExtendSelectionByCharacterIntent`），值永远不变。真实序列是
/// Enter 开菜单（焦点转到 DropdownMenu 内部节点）→ 方向键移动高亮 → Enter 提交选中。
///
/// 先试「下一项」，值没变再试「上一项」——当前值已经是列表末项时下一项会绕回自身。
Future<void> _driveDropdownRow({
  required WidgetTester tester,
  required FocusDriver driver,
  required FushiDatabase db,
  required Map<String, String> before,
}) async {
  for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowUp,
  ]) {
    await driver.activate();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.sendKeyEvent(key);
    await tester.pump(const Duration(milliseconds: 50));
    await driver.activate();
    await tester.pump(const Duration(milliseconds: 100));
    if (!_mapsEqual(before, await db.getAllPrefs())) return;
  }
}

bool _mapsEqual(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final MapEntry<String, String> e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

List<String> _mapDiff(Map<String, String> before, Map<String, String> after) {
  final List<String> out = <String>[];
  final Set<String> keys = <String>{...before.keys, ...after.keys};
  for (final String key in keys) {
    if (key == PreferencesRepository.prefsVersionKey) continue;
    if (!before.containsKey(key)) {
      out.add('+$key=${after[key]}');
    } else if (!after.containsKey(key)) {
      out.add('-$key=${before[key]}');
    } else if (before[key] != after[key]) {
      out.add('$key: ${before[key]} -> ${after[key]}');
    }
  }
  out.sort();
  return out;
}

enum _RowKind { switchRow, slider, stepper, segmented, picker }

class _FocusedRow {
  const _FocusedRow({
    required this.title,
    required this.kind,
    this.optionCount = 0,
  });
  final String title;
  final _RowKind kind;

  /// [_RowKind.picker] 的可选项数（其它 kind 恒 0）。
  final int optionCount;
}

class _CoverageAppModel extends AppModel {
  _CoverageAppModel(PlatformServices platformServices)
      : super(platformServices);

  final PackageInfo _packageInfo = PackageInfo(
    appName: 'Hibiki',
    packageName: 'jp.hibiki.test',
    version: '9.8.7',
    buildNumber: '654',
  );

  @override
  PackageInfo get packageInfo => _packageInfo;
}
