# 设置系统重构 v2（2026-07-21）

用户授权：重构设置，允许完全重写。判断：框架数据结构（sealed 三层树 + 共享 schema 渲染组件）是对的，保留；重写病灶而非全部。

## 现状病灶（调查结论）

1. **视频快捷设置面板不消费 schema**：`media/video/video_quick_settings_sheet.dart`（2740 行）手写全部行，与 `settings/settings_schema_video.dart`（933 行）逐 id 镜像，`test/pages/video_settings_schema_guard_test.dart` 强制这份重复。阅读器面板早已用 `ReaderPlacement` 从 schema 投影（`reader_quick_settings_sheet.dart:589`），视频是唯一平行实现。
2. **文本/数字输入不是一等 item kind**：`SettingsSecretField`/`SettingsNumberField` 是散装 widget，13 处 `SettingsCustomItem` 逃生舱中约半数只是文本框（lookup 防抖/max-terms/Yomitan key、弹幕服务器、更新代理）。
3. **自定义行搜索不可见**：`settings_search.dart:36` 跳过空标题 item，主题/语言/API key 全搜不到。
4. **torrent 设置区游离**：`torrent_settings_section.dart`（361 行）只在 DownloadsPage 内，设置主页不可达、不可搜。
5. **样板重复**：`SettingsContext` 构造在 4 处宿主重复；两渲染器复制同一段滚动注释。

## 不动的边界（Never break userspace）

- 持久化契约：flat `preferences` KV + `PrefCodec` 类型标签编码 + `PreferencesRepository` 同步缓存（写完 → 下一次同步读必须可见）+ `prefs_version` 跨进程信号 + `ProfileKeys` 排除策略。**任何 pref key 不改名。**
- `shortcut_settings_page.dart` 及其 parts：并发 PR#296 在改，禁触。
- Cupertino renderer：隐藏内部能力，保留、维持共享分发路径的对等。
- 10 个 destination 结构、ReaderGroup 分组、现有 i18n key：不动。

## 阶段

### A. schema 模型扩展（难·Fable）
- 新增一等 item kind：`SettingsTextItem`（含 secret/防抖/重置）、`SettingsNumberItem`（范围/整型），渲染进 `settings_schema_widgets.dart`（内部复用现有 field widget 逻辑），Material/Cupertino 走既有共享分发。
- 搜索：新 kind 可搜；`SettingsCustomItem` 增加可选搜索元数据（title/keywords），空标题不再等于不可搜。
- `SettingsContext`：加统一构造 helper 消灭 4 处样板；新增可选 `video` 能力槽（承载播放器控制器上下文，为 B 铺路）。
- placement 泛化：仿 `ReaderPlacement` 增加 `VideoPlacement`（group/order），`collectVideoItems` + `buildVideoGroupDestination`。
- 测试：新 kind 渲染/写穿/搜索测试；既有 guard 全绿。

### B. 视频面板重写（难·Fable，依赖 A）
- `settings_schema_video.dart` 全部项打上 `VideoPlacement`；控制器绑定行（A/V 延迟、实时速度、shader 下载等）以 `SettingsCustomItem` + `visible: ctx.video != null` 入 schema（builder 移到 video actions 文件），全局设置页自然隐藏。
- 重写 `video_quick_settings_sheet.dart`：像阅读器面板一样投影 schema 分组渲染，删除全部镜像行。
- 删除 id 镜像 guard test，换成「视频面板消费 schema」结构 guard（仿 reader 的静态测试）。
- `video_hibiki_page.dart` 只做最小接线改动（构造 context、传控制器槽）。

### C. 声明式转换 + torrent 入册（中·Opus，依赖 A）
- 13 处 custom 逃生舱中的纯文本/数字项转为新 kind（lookup 防抖/max-terms/Yomitan key、弹幕服务器、更新代理等）。
- 其余 custom 项（主题/语言/design-system/UI-scale/profile picker）补搜索元数据。
- torrent 设置抽成 schema section（builder 化）——单一真相源，DownloadsPage 与设置页两处渲染（挂载位置见 G 的「下载」大类）。
- 需要新 i18n key 时用 `tool/i18n_sync.dart` + `dart run slang` + `dart format` 生成文件。

### E. 防截屏开关入设置页（用户新需求，随 C 实施）
- pref 已存在：`clipboard_panel_block_capture`（默认 true，Windows，native `SetWindowDisplayAffinity(WDA_EXCLUDEFROMCAPTURE)`，面板 🛡 按钮可切）。
- 在查词 destination「剪贴板与全局查词」区新增 `SettingsSwitchItem`（仅 Windows 可见），写穿该 pref 并即时通知 native 重应用（沿用 🛡 按钮同一条通道，见 `clipboard_panel_controller.dart`）。
- 核实全局查词弹窗各窗口（`global_lookup_window.cpp` / `flutter_window.cpp:1400` / `overlay_window_channel.dart`）是否全部尊重该 pref；如有硬编码防截屏路径，根修为读 pref，不允许只加开关不接线。
- 文案说明串流场景：关闭后弹窗可被截图/录屏/串流捕获。

### F. 文案统一（用户新需求，随 C/G 实施）
- 术语：「全局热键」→「全局快捷键」，与「快捷键设置」页统一；确认搜索能命中（若搜索只匹配标题不匹配描述，需把关键词并入 item 搜索元数据）。
- 搜索结果面包屑「系统 › 系统」重复：框架级修复——destination 与 section 同名时去重显示（消灭这一类，而不只改一处命名）。
- 「（实验性，可能不稳定）」「（桌面）」「（仅 Windows）」等后缀风格统一：平台标记与实验性标记各用一种固定格式。
- 只改 zh/en 文案值；不新增/删除 key 的改动不走 i18n_sync，但改完跑 `dart run slang` 验证生成一致。

### G. 配置项位置重构（用户新需求：支持完全打乱、删/增大类）
- 新增「下载」大类（`SettingsDestinationId.downloads`）：承载 torrent/qB 设置（来自 C），演示新增大类路径。
- 位置重排：快捷键设置所在 section 命名修正（消除「系统 › 系统」语义重复）；逐项审查放错位置的项并归位（记录清单）。
- 降低重排摩擦：guard 测试只锁「用户决策过的位置」与写穿行为，不再锁死无关项的相对顺序；确保 destination 增删只需改 `SettingsDestinationId` + `buildSettingsSchema` 两处 + i18n。

#### G 落地：分类与排序（旧→新 映射）

所有 item id / pref key / ReaderPlacement / VideoPlacement 均**不变**，只挪声明所属 section/位置。

**顶层大类顺序**（`buildSettingsSchema`）：
- 旧：外观 → Profile → 阅读 → 查词 → 制卡 → 视频 → 听书 → 下载 → 同步备份 → 互联 → 系统
- 新：**阅读 → 查词 → 制卡 → 视频 → 听书 → 下载 → 外观 → Profile → 同步备份 → 互联 → 系统**（内容类在前、外观/系统类殿后）。守卫 `test/settings/settings_destination_order_guard_test.dart`。

**阅读 destination**（`settings_schema_reading.dart`）分区重构：
- 旧分区序：排版 → 布局与显示 → 高级选项(collapsed) → 阅读界面 → 翻页与交互 → 翻页方向(collapsed) → 底栏布局(collapsed)
- 新分区序：**模式与排版方向**（新 key `reading_section_mode`；由旧「布局与显示」重命名，内含 view_mode → writing_mode → spread_mode → spread_direction → vert_text_orient → furigana_mode，翻页/滚动提到首位）→ **排版**（page_columns 移到 margins 之前）→ **阅读界面**（追加 `reverse_reader_bottom_bar`）→ 翻页与交互 → 翻页方向(collapsed) → **高级选项(collapsed，移到最后)**
- 「底栏布局」单项分区删除（i18n key `section_bottom_bar_layout` 保留但闲置）。

**查词 destination**（`settings_schema_lookup.dart`）分区重排 + 重命名：
- 「管理器」→ **「词典与来源」**（原地改 i18n key `manager` 的 en/zh-CN/zh-HK 值，该 key 仅此处用）。
- 旧序：词典与来源 → 查词触发 → 外部集成 → 剪贴板与全局查词 → 朗读与反馈 → 词条内容 → 弹窗窗口
- 新序：**词典与来源 → 查词触发 → 词条内容 → 朗读与反馈 → 弹窗窗口 → 剪贴板与全局查词 → 外部集成**（外部集成从第 3 移到末尾；各 collapsed 标志不变）。

**视频 destination**（`settings_schema_video.dart`）两个 item 换区（placement 不变）：
- `video.quality.loop`「单文件循环」：画质区 → **播放区**（紧随 `auto_play_next`）；VideoPlacement `mpv#200` 不变。
- `video.playback.pause_at_subtitle_end`「字幕暂停播放模式」：播放区 → **字幕区**（`obscure` 之前）；VideoPlacement `subtitle#30` 不变。
- `video.controls.reset_layout` 仍在播放区末尾。

**外观 → 系统 item 换区**：
- `appearance.startup_default_dictionary_tab`「启动时打开查词」：外观「应用」区 → **系统「通用」区**（`focus_navigation` 之后）；item id **保持 `appearance.` 前缀不变**。

**系统 destination**（`settings_schema_system.dart`）：
- 分区序：**通用 → 更新设置 → 诊断(collapsed)**（原为 更新 → 通用 → 诊断）。
- 通用区内序：**keyboard_shortcuts → focus_navigation → startup_default_dictionary_tab → low_memory_mode → app_version → github**。
- destination summary：`section_update`（更新设置，共享给更新区标题）→ 新 key `settings_destination_system_summary`「通用、更新与诊断」。

**新增 i18n key**：`reading_section_mode`、`settings_destination_system_summary`。**闲置 key**：`section_bottom_bar_layout`（停止引用，未删）。

### D. 收尾（中·Opus）
- 渲染器复制注释归一、`dispatchChange` 注释澄清、文档更新。
- 全量 `dart format` + `flutter analyze`（0 告警）+ `flutter test --no-pub` 全绿。

## 验证

每阶段：`flutter analyze` + 相关测试；B 结束后全量测试。最终推 draft PR，真机验证（阅读器面板、视频面板、设置搜索、torrent 设置写穿）后再合并。

## 风险

- B 是行为敏感重写：视频面板行为必须逐组对照旧实现（immersive/fit/倍速/字幕样式/弹幕/A-V 对轴）。schema 已有的 pref 行为为准绳，guard test 保证覆盖。
- 与视频页相关 draft PR（#303/#306 等）存在潜在合并冲突：本次尽量不动 `video_hibiki_page.dart` 主体。
