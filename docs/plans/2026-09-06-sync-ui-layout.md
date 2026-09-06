# C · 同步/互联 UI 排版重组计划

用户诉求：四类界面（设置页 / 同步对比对话框 / 手动同步面板与进度 / 互联配对与远程库）全部重做优化；痛点 **「一屏铺太长、分组乱」**，重点是设置的排版。
原则：在现有 schema 化设置体系上改（不从零写、不换渲染器）；MD3 list-detail 不动（`docs/specs/2026-06-02-desktop-settings-md3-design.md` 已定案）；宽屏 detail 不设最大宽度（BUG-1643 用户决策）。

## 现状（子代理盘点，file:line 见盘点原文）

**同步与备份页**（`sync_settings_schema.dart:83`）4 节 / 22 项：
```
§同步方式   mode 选择器 | 账号状态(OAuth) | WebDAV 3 字段表单 | FTP 5 项表单 | SFTP 5 字段表单 | 互联指路行      ← 5 个按 backend 条件显隐
§同步内容   auto_sync | statistics | 资产旧格式提示 | 词典 上传/下载 | 本地音频 上传/下载 | content | audiobook_files | video_files | show_remote_entries   ← 开关与动作行混排 11 项
§操作       server_mode_note | 立即同步 | 对比
§备份(折叠)  导出 | 导入 | 迁移(Android)
```
**互联页**（`:446`）7 节 / 19 项：
```
§(无题)     总开关
§客户端     _FushiServerConfigWidget（~660 行：对端列表+排序+修复+删除+添加+token 折叠+测试）| _LanDiscoveryWidget
§上传       content | dictionary | audiobook_files | video_files
§共享       statistics | favorites
§委托主机   mine_to_server | backup_backend | service_config_sync | profile 上传 | profile 下载
§主机服务   _ServerModeWidget（开关+端口+TLS+token+复制/重生成+已配对列表）| profile_transfer_host
§相关       远程查词 | 音频源 | 显示远程条目   ← 三个别处设置的镜像
```
问题的本质：**页面把"选择方式 / 填凭据 / 选内容 / 触发操作 / 管理设备 / 当主机"六种不同频率的事平铺在一层**；最高的三个 custom widget（对端列表、LAN 发现、主机服务）与一行开关同层排列，正是 BUG-037 说的高度悬殊来源。

**框架可用原语**：`SettingsSection.collapsedByDefault`、`SettingsNavigationItem`（推任意页）、`SettingsCustomItem`；**没有**状态行/横幅/子 schema 页原语。子页现在只能推非 schema 的自定义页，其内容进不了设置搜索（只能靠 `bodySearchEntries` 手工登记——这是个特殊情况补丁）。

## 方案

### C0 · 框架：子页也是 schema（消除 bodySearchEntries 这个特殊情况）
- `SettingsNavigationItem` 新增 `child: SettingsDestination Function()`；渲染器点进去推 `SettingsDetailPage(child())`（onboarding 已经这么推顶层页，`onboarding_wizard_page.dart:832`）。
- `settings_search.dart` 索引时递归走 `child`，命中后先进父页再进子页并定位（复用 `SettingsSearchReveal.pendingItemId`）。
- 新增 `SettingsStatusItem`（图标 + 标题 + 状态文本 + 可选动作按钮）替换现在 4 处用 `SettingsCustomItem` 手拼 `AdaptiveSettingsRow` 的状态/指路行（`sync.interconnect_config_note` / `sync.server_mode_note` / `sync.asset_legacy_notice` / `sync.account_status` 的展示部分）。
- 守卫：`settings_schema_coverage_test`（焦点遍历）要能遍历进子页；`settings_schema_cache_test`（零参构造）对子页构造器同样成立。

### C1 · 同步与备份页 → 两层
```
§同步方式      [mode 选择器]  [账号状态 / 服务器设置 ›]            ← 凭据表单挪进子页「服务器设置」，主页不再随 backend 伸缩
§同步什么      statistics | content | audiobook_files | video_files | show_remote_entries      ← 五个同形态开关
§何时同步      auto_sync | 立即同步 | 对比 | (server_mode_note 状态行)
§资产传输      词典 [上传][下载] | 本地音频 [上传][下载] | 旧格式提示      ← 用户定：上传/下载不各占一行，合成一行两个按钮；压缩后留主页不进子页
§备份与恢复 ›  子页：导出 | 导入 | 迁移
```
主页 5 节 ~12 项 + 2 个子页。`sync.mode` 等 id 不改（`settings_redesign_static_test` 钉 `sync.mode`/`sync.statistics`/`sync.dictionary_upload`/`sync.local_audio_download` 是 `SettingsCustomItem`——挪到子页仍满足）。

### C2 · 互联页 → 两层
```
§(无题)        总开关 + footer
§设备          [已配对 N 台 · 状态摘要]  配对与设备 ›     ← 子页：对端列表 + LAN 发现（两个最高的 widget）
§作为主机      [主机服务 开关 + 端口/状态摘要]  主机服务 ›  ← 子页：端口 / TLS / token / 已配对 / profile_transfer_host
§同步内容      content | dictionary | audiobook_files | video_files | statistics | favorites   ← 上传+共享合一组，footer 合并
§委托主机      mine_to_server | backup_backend | service_config_sync | profile 上传/下载
§相关设置      三个镜像改成 footer 文字链接（或删除，待定）
```
主页 6 节 ~13 项 + 2 个子页。`_FushiServerConfigWidget` / `_LanDiscoveryWidget` / `_ServerModeWidget` **代码不重写**，只是从主页挪到子页；主页摘要行是新的薄 widget（读同一份状态）。

### C3 · 同步对比对话框
- 三段（冲突 / 全部书籍 / 词典）改 sticky 段头 + 计数 chip；顶部加「只看冲突」过滤；批量选择菜单从溢出菜单提到段头右侧（现在藏在 `FushiOverflowMenu` 里）。
- 每行的三态 segmented 保留；宽度上限 720 不动。

### C4 · 手动同步反馈
- 现状已是最小（1 行横幅 + 2px 进度；SnackBar），排版上没有"太长"问题。只做一件事：横幅文案接 `SettingsStatusItem` 同一套状态语义，保证设置页的状态行与库页横幅用词一致。若用户没有别的痛点，C4 可不做。

### C5 · 远程库
- 浏览远程库的 UI 内联在 `reader_history/remote.part.dart`（1199 行）和 `media_sources_view.dart`（1721 行），不在设置页；本轮**不动**（另立项）。配对流程已被 C2 的子页覆盖。

## 前置：先拿基线截图
- 用 `test/goldens/` 的 golden 机制渲染 `buildSyncBackupDestination()` / `buildInterconnectDestination()` 在 1280×800（宽屏两栏）与 400×800（窄屏）两档，作为改前基线；改后同样出图对比。比真机快、可进 CI。

## 守卫更新清单（有意重钉）
- `test/sync/sync_settings_visibility_test.dart`：两页节数 / 每节 id 顺序 / 可见性谓词——按新结构重写断言（这是布局的规格书，不是障碍）。
- `test/settings/settings_schema_coverage_test.dart` / `settings_detail_scroll_stable_test` / `sync_settings_no_touch_scroll_test` / `sync_action_rows_focus_test`：渲染路径变了要复跑；子页要进覆盖遍历。
- `md3_design_system_static_test`：新 `SettingsStatusItem` 的渲染要过它的 MD3 白名单。
- `interconnect_*_guard_test`（token 折叠、客户端面板、配对入口）：源码扫描面从 `interconnect.part.dart` 变成子页文件，逐个改扫描路径。
- onboarding 两处深链（`onboarding_wizard_page.dart:832/851`）与 `media_sources_view.dart:306` 的第二个互联开关：不受影响，但要复测。

## PR 切分
```
PR-C0 框架：child 子页 + 搜索递归 + SettingsStatusItem   （不改任何 sync 页面，零视觉变化）
PR-C1 同步与备份页重组                                    依赖 C0
PR-C2 互联页重组                                          依赖 C0
PR-C3 对比对话框                                          独立
PR-C4 手动同步反馈（可选）
```

## 已拍板（2026-09-06）
1. 互联页「相关设置」三个镜像 → footer 文字链接（可点跳转），不再重复渲染开关。
2. 资产传输：上传/下载**不各占一行**——词典、本地音频各合成一行，行尾一个「传输 ▾」菜单按钮（上传 / 下载两项）。不用"一行两个按钮"：焦点模型是「一行 = 一个 FushiFocusTarget」（BUG-016，`actions.part.dart:17-20` 明文），两个按钮要给手柄/键盘开左右键特例；菜单让鼠标、键盘、手柄走同一条路径。压缩后留主页成节，不进子页。
3. C4 不做。
4. 基线/验收用 golden 渲染（1280×800 宽屏两栏 / 400×800 窄屏）。
