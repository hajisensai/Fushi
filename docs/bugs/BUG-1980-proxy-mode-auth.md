## BUG-1980 · 网络代理无法显式禁用且不支持认证
- **报告**：2026-08-31（用户：）
- **真实性**：✅ 真 bug。原设置只有 `settings_schema_system.dart` 中单个 `host:port` 文本项；空值固定进入“环境变量 → 系统代理 → 直连”，无法表达“强制直连”，`app_proxy.dart` 也未设置 `HttpClient.authenticateProxy`，407 认证代理必然失败。
- **[x] ① 已修复** — 增加“自动 / 直连 / 手动”一等模式，手动模式显示服务器、用户名和遮蔽密码；网络装配层按模式裁决并仅在代理 challenge 时注入凭据（`116dc112f2`）。
- **[x] ② 已加自动化测试** — `test/utils/net/app_proxy_local_bypass_test.dart` 覆盖强制直连、手动配置非法时不偷用系统代理，以及 407 challenge 凭据注入。
- **备注**：本机、局域网与 mDNS 目标继续由共享闸门强制直连；P2P 仍需单独明确开启。
- **审查补修**（在 ① 的基础上，同一 PR 内）：
  - 407 凭据改成**同一 (host,port,scheme,realm) 只交付一次**。原实现每次 challenge 都
    无条件 `addProxyCredentials` 并返 true，而 `dart:io` 的 `retry()` 没有深度计数器，
    密码填错就会「407 → 移除已用凭据 → 再问回调 → 又加同一份 → retry」无限打转，
    请求永不返回、用户只看到转圈。
  - Digest challenge 直接放弃。原实现对任何 scheme 都塞 `HttpClientBasicCredentials`，
    `findCredentials(Digest)` 永远匹配不到，同样是无限环。文档注释也从
    「Basic/Digest」改成只声明 Basic。
  - 迁移判据从「地址非空」改成「地址**归一得出来**」。设置页历来对非法地址只弹
    SnackBar 却仍存原串，存量里有 `[::1]:7890`（IPv6 不支持）、带路径、带空格等值；
    按非空推成 manual、manual 归一失败又硬走 DIRECT = 这批用户升级即全应用断网。
    只有「用户显式选了 manual」才 fail-closed。
  - `network_proxy_mode` / `update_download_source` 补进 `ProfileKeys._excludedPrefKeys`。
    它们描述这台设备的网络与更新策略（与 `update_custom_proxy` /
    `update_beta_channel` 同族），漏登记会让切一次 Profile 就把全局网络出口翻掉。
- **第二轮审查欠账已清**（同一 PR 内，逐条根因修）：
  - **「首选下载源」在真实下载路径上基本不生效** → `updateDownloadUrls` 只返回一个裸
    `List<String>`，下游分不出「首项是用户钉的」还是「首项只是默认排序」，于是探针竞速
    （`orderedCandidatesAfterRace`，默认参数下门控必然成立）把用户选的源顶掉，只剩 500ms
    tie-break 宽限。改成返回 `UpdateDownloadPlan{candidates, requestedSource, pinnedUrl}`，
    `pinnedUrl` 一路透传到竞速入口，非空即**不竞速**（显式选择优先于测速），串行回退链
    原样保留。测试：`update_checker_race_test.dart` 一正一反（auto 仍竞速 / 钉源时连其它
    候选的探针都不发）。
  - **选 Cloudflare 在非官方资产上静默空转** → 同一个数据结构顺带解决：所选来源解析不出
    候选时 `preferenceUnavailable` 为真，成为可断言、可展示的一等信息。下载遮罩多一行
    「本次没用上所选来源」，并写进诊断日志；回退行为零变化。测试：
    `update_checker_mirror_fallback_test.dart` + `update_checker_dialog_test.dart`。
  - **两个代理装配点不对称** → 异步版 `applyAppProxy` 把模式裁决**烘焙**进闭包、且只在
    manual 分支装凭据钩子：auto 模式下建好的 client 之后改成 manual，既不改走手填代理也
    永远拿不到 407 应答。两个入口收敛到同一条 `_installAppProxy`：装的都是**请求时求值**
    的 `resolveAppProxyDirective` 闭包 + 无条件凭据钩子；异步版唯一多做的是现场解析一次
    GUI 系统代理。
  - **`'legacy'` 哨兵表达不了 `direct`** → 哨兵本身没法猜出用户的选择，真正的修法是让
    「偏好一读出来就接上」：四个进程级读取器的绑定从 `AppModel.initialise()` 下沉到
    `PreferencesRepository.loadFromDb()`。以前弹窗词典进程（`initialiseForDictionaryPopup`
    同样建仓库、同样读偏好却没绑）**整段生命周期**都落在兜底上——选了「直连」的用户在
    弹窗里照样走系统代理，那不是一个空窗口。哨兵同时改名 `kProxyModeUnresolved` 并写清
    它表达不了什么。
  - **i18n 命名易混** → `network_proxy_manual_hint`（地址输入框用途）改名
    `network_proxy_address_hint`，与 `network_proxy_mode_manual_hint`（模式项说明）不再
    只差一个 `_mode_` 中缀。走 `i18n_sync --rename`，17 种语言的翻译原位保留。
  - **搬正则时注释留在原地** → 「前缀+后缀双重限定是为了不误删 `fushi-recommended.fushi.zip`」
    这条理由搬到真相源 `backupArchiveNamePattern` 头上。
  - **`update_download_source` 结构性逃出设置覆盖守卫** → `_focusedSettingsRow()` 补认
    `AdaptiveSettingsPickerRow`，并给下拉行补一条专属驱动（Enter 开菜单 → 方向键 →
    Enter 提交；`FocusDriver.adjust` 的左右键在 `DropdownMenu` 里被映射成文本光标 intent，
    一步都动不了）。一次性暴露出 29 个下拉行 + 因列表滚动而新可达的 11 个互联开关，共 33
    条账目缺口，已逐条按真实消费点登记 `kCoveredElsewhere`。遍历行数 177 → 219。
    另外：驱动「界面语言」这一行会把之后所有行的标题换成另一种语言，而 verdict 的身份键
    就是渲染出来的标题——驱动完必须立刻复位渲染语言，否则账本整批对不上。
  - **15 种语言的新 key 仍是英文占位** → 本 PR 的 21 个 key 已补齐 17 种语言（判据：值 ==
    英文原文且 ≥3 个英文词，现为 0 条欠账）。
- **仍然存在的边界**（需要 native 改动，本 PR 不做）：
  - **代理认证到不了内置 torrent 引擎**。调研结论：C ABI `ht_apply_proxy(session,
    proxy_type, host, port)`（`native/fushi_torrent/fushi_torrent_include/fushi_torrent.h`）
    **只有四个参数**，实现里也只写 `proxy_type/proxy_hostname/proxy_port`，libtorrent 的
    `settings_pack::proxy_username/proxy_password` 与 `http_pw`/`socks5_pw` 变体全仓零处
    出现。要支持必须改 C++ + FFI 绑定 + Dart 引擎 + 宿主去重键 + 守卫测试五处并重编
    native（prebuilt 不入库），且必须走「新增导出 + 软探测」而不是改现有签名（`extern "C"`
    符号名不 mangle，老 DLL 上改签名是栈破坏而不是干净的 lookup 失败）。
    本 PR 只把边界写进 UI：手动代理用户名项的副标题明说「凭据仅用于 HTTP 请求；内置
    torrent 引擎无法使用」。
