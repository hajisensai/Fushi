# 全平台自动 MD3 与翻页漂移复验设计

- 日期：2026-07-13
- 分支：`codex/md3-pagination-drift-20260713`
- 基线：`hajisensai/hibiki` 的 `develop@b177f858b`
- 用户确认：采用兼容方案；Cupertino/macOS 实现保留，设置入口暂时隐藏

## 背景

macOS 设置页截图同时出现了最外层原生 `Sidebar` 和应用内部 MD3 导航。代码路径显示，设计系统偏好虽然已经注入 `ThemeData`，但 `main.dart` 仍只按物理平台判断 macOS，无条件把整个 Navigator 包进 `MacosWindow + Sidebar`；内部 `HomePage` 则按设计系统继续构造 MD3 布局，因此形成双壳。

同一版本截图中的竖排分页表现为列带逐页下沉、后期分裂成上下两组并留下大块空白。该形态对应 TODO-792：旧版本的 multicol `body` 使用 `V + bottomOverlap`，而列宽和 JS 翻页步进使用纯视口高 `V`，真实列周期与名义周期每页相差约 22px。GitHub 最新 `develop` 已包含根因提交 `5af42a348`，将分页 `body` 高度统一为纯 `V`，并在 `8add9d5e3` 裁掉相邻页列带泄漏。本次不在没有当前版本复现证据时再次改动分页几何。

零改动基线执行完整 `flutter test` 的结果为 10969 通过、10 跳过、33 失败。失败属于拉取后的远端基线；本次以专项测试、相关测试和变更前后对照证明没有新增失败，不顺带修复无关测试。

## 目标

1. `auto` 在 Android、iOS、macOS、Windows、Linux 上都解析为 Material Design 3。
2. `material` 始终解析为 Material Design 3。
3. 保留 Cupertino/macOS 的枚举、渲染器和原生壳实现，便于后续重新开放；当前设置 UI 不提供入口。
4. 历史保存的 `cupertino`、`macos` 和未知设计系统值不再形成“界面显示自动、实际仍是 Apple 风格”的幽灵状态。
5. macOS 的 `MacosWindow + Sidebar` 与 `MacosScaffold` 只在有效设计系统为显式 `macos` 时出现；`auto/material` 只构造一套 MD3 导航。
6. 在当前 GitHub 基线上复验 TODO-792 的竖排分页不变式和实际 macOS 路径；只有当前版本仍可复现时才创建新的分页修复。

## 非目标

- 不删除 Cupertino、`macos_ui`、原生标题栏或显式 Apple 渲染路径。
- 不把 Cupertino/macOS 重新加入设置分段选择器。
- 不重做 HomeTab、导航信息架构或设置 master-detail 布局。
- 不修改 EPUB 内容、字体、ruby 布局或分页几何，除非当前版本得到新的可复现证据。
- 不处理远端全量基线的 33 项无关失败。

## 行为模型

### 设计系统解析

| 持久值/注入值 | 当前设置可选 | Android | iOS | macOS | Windows/Linux |
| --- | --- | --- | --- | --- | --- |
| `auto` | 是 | MD3 | MD3 | MD3 | MD3 |
| `material` | 是 | MD3 | MD3 | MD3 | MD3 |
| `cupertino` | 否 | Cupertino（内部显式路径） | Cupertino（内部显式路径） | Cupertino（内部显式路径） | Cupertino（内部显式路径） |
| `macos` | 否 | MD3 安全回退 | MD3 安全回退 | macos_ui（内部显式路径） | MD3 安全回退 |

`auto` 不再读取物理平台来选择皮肤。物理平台仍用于显式 `macos` 的安全门控，防止非 macOS 主机调用仅 macOS 可用的窗口能力。

### 隐藏旧值迁移

设置只允许写入 `auto` 或 `material`。读取持久化快照或数据库时，历史 `cupertino`、`macos`、未知值统一规范化为 `auto`，并在可写的数据库刷新路径中回写 `auto`。这样升级后的首帧即渲染 MD3，后续启动也不会恢复幽灵 Apple 状态。

内部测试或未来重新开放入口仍可直接向 `HibikiDesignSystemTheme` 注入显式 `cupertino/macos`，所以实现不会被删除。迁移针对用户持久值，不针对枚举能力。

### macOS 根壳

`main.dart` 不再使用 `Theme.of(context).platform == TargetPlatform.macOS` 作为唯一条件，而是调用与页面相同的有效设计系统判断。只有 `isMacosPlatform(context)` 为真时才包装：

- `MacosTheme`
- `MacosWindow`
- `buildHibikiMacosSidebar`

`HomePage` 继续以相同判断决定是否进入 `_buildMacosLayout()`。根壳和页面壳因此保持同源，不会再出现外层 Apple Sidebar 与内层 MD3 rail 同时存在。

## 翻页漂移验证策略

1. 保留并运行 `reader_vertical_realpitch_fix_guard_test.dart`，锁定分页 `body` 使用纯视口高及 JS 不恢复 `pageStep += overlapO`。
2. 运行 reader pitch/content style 专项测试和现有 headless probe，确认 `pageStep == columnCount × (used columnWidth + gap)`。
3. 在当前 macOS 构建打开竖排分页内容，多次前后翻页并留截图/日志证据，检查文字列不逐页下沉、页边缘不露相邻列带。
4. 若当前版本仍复现，先记录真实 WKWebView 的 `body height`、computed `columnWidth`、`columnCount`、`pageSize` 和实际列带周期，再另立 bug 进行新的根因修复；不沿用旧版 22px 假设盲改。

## 测试策略

### 自动化

- 参数化测试五个 `TargetPlatform`，断言 `auto` 时 `isCupertinoPlatform` 与 `isMacosPlatform` 都为 false。
- 正向测试显式 `cupertino` 仍能走 Cupertino；显式 `macos` 只在 macOS 走原生路径。
- `ThemeNotifier` 测试历史隐藏值/未知值规范化为 `auto`，并验证数据库刷新后的回写。
- 更新 macOS shell 守卫，断言根 `MacosWindow` 由 `isMacosPlatform(context)` 门控，而不是裸物理平台判断。
- 设置选择器守卫仅允许 `auto/material`，隐藏值不会只在显示层钳制而保留实际 Apple 状态。
- 运行现有 TODO-792 分页守卫和相关 reader 测试。

### 可见结果

- macOS 的 `auto` 和 `material`：只出现 MD3 导航，截图中的最左原生栏消失。
- 设置中的“自动”：五个平台都等价于 MD3。
- 升级前保存过 Cupertino/macOS 的用户：升级后显示并实际使用“自动”MD3。
- 竖排分页：连续翻页后文字列位置稳定，没有逐页累积偏移或相邻页列带泄漏。

## 风险与控制

1. **原生 macOS 路径失去公开入口**：这是用户确认的暂时隐藏；代码和显式注入测试保留，未来恢复分段即可。
2. **迁移写入发生在构建 getter**：禁止。规范化必须在快照/数据库加载或显式 setter 中完成，主题 getter 继续保持纯读。
3. **根壳与页面判断再次分叉**：两处都调用 `isMacosPlatform(context)`，并用源码/行为测试锁定。
4. **把旧截图误判成当前回归**：先验证 GitHub 最新构建；无当前复现不改分页核心。

## 验收标准

- 新增测试先红后绿，覆盖全平台 auto、旧值迁移和 macOS 单壳。
- 相关 MD3、macOS shell、ThemeNotifier 与 TODO-792 测试全部通过。
- `dart format .` 完成；全量测试结果与零改动基线比较，不新增失败。
- macOS 当前构建完成可见验证并保留证据后，才声明两处用户可见问题已解决。
