# 查词弹窗尺寸精细化 + 拖拽调整 设计（spec）

- 日期：2026-07-13
- 分支：`worktree-lookup-popup-resize`
- 状态：设计已确认，分期实现中（A→B→C→D）

## 1. 目标

让查词弹窗的**最大宽/高**可精细调整，且三种形态（app 内、app 外覆盖窗、浏览器扩展）可各自独立；并支持**直接拖拽弹窗边角**调整尺寸。列数改为「自动填充、封顶用户设定」。

## 2. 平台现实（约束设计的硬事实）

| 弹窗形态 | 存在平台 | 当前尺寸来源 | 当前可拖拽 |
|---|---|---|---|
| app 内查词弹窗（阅读器/视频） | 全 5 平台（Flutter overlay） | Dart 侧 `Positioned` = `popupMaxWidth×popupMaxHeight`，随屏幕/选区 clamp | 否 |
| app 外覆盖查词卡（瞬态悬浮） | **仅 Windows** 原生窗；macOS/Linux 不弹（退回主窗 tab）；Android 另一套独立悬浮服务；iOS 无 | 同 `popupMaxWidth/H × appUiScale × dpr`，native 明确「瞬态窗不进模态循环、无 chrome」 | 否 |
| 剪贴板查词面板 | 仅 Windows | 独立 `clipboardPanelRect` | **是**（Win32 grip，已有） |
| 浏览器扩展弹窗 | 平台无关（网页 DOM） | app theme 变量 `--hibiki-popup-max-*` 下发 | 否 |

**后果：** 「app 外拖拽」仅 Windows 可落地；app 内弹窗是唯一一次覆盖全 5 平台的表面；剪贴板面板已有拖拽，本设计不动它。

## 3. 数据模型（真值 = 偏好键）

```
app内（沿用现有）:   popupMaxWidth / popupMaxHeight
app外覆盖窗:         overlayLookupIndependentSize(bool, 默认 false)
                    + overlayLookupMaxWidth / overlayLookupMaxHeight
浏览器扩展:          extensionPopupIndependentSize(bool, 默认 false)
                    + extensionPopupMaxWidth / extensionPopupMaxHeight
列数（沿用现有语义收敛）: popupDictionaryColumns  → 语义改为「最多列数（自动填充）」
```

**有效尺寸解析**（纯函数，单元可测）：

```
effectiveLookupSize(scene) =
  scene.independent ? (scene.maxWidth, scene.maxHeight)
                    : (popupMaxWidth, popupMaxHeight)
```

- app 内始终用 `popupMaxWidth/H`。
- app 外 / 扩展默认 `independent=false` → 跟随 app 内；用户显式解锁后用各自键。

**拖拽的「解锁」规则（好品味）：** 在一个「跟随中」（`independent=false`）的表面上拖边角 = 自动把该场景 `independent` 置 `true` 并写入拖出来的尺寸。一动手定制它就脱钩。滑杆与拖拽写同一真值，实时同步。绝不引入「固定尺寸 override」这种第二套概念——弹窗仍是「撑到最大尺寸的准固定盒」，拖拽只是可视化地改这个「最大」。

## 4. 列数（自动为主 + 上限）

现状已是 `有效列数 = min(popupDictionaryColumns, 视口能装下的列数)`（`content.css` `--dict-columns-effective` / `popup.js updateEffectiveDictColumns`）——本质已是「自动填充、封顶用户值」。改动：

- 设置项文案/语义改为「**词典最多列数（自动填充）**」；默认自动最多 3 列。
- 确认三处（app 内 / app 外 / 扩展）都吃同一条 effective 逻辑。
- 不引入「列宽」新概念（YAGNI）。

## 5. 高度上限放宽

当前高度滑杆上限 800（宽度已 2000）。放宽高度上限到 1600，步进保持细粒度，让「精细/更大」有空间。

## 6. 分期与文件触点

### Phase A — 三套独立尺寸键 + 跟随/解锁 UI + 列数封顶语义 + 高度上限放宽（全平台配置，无原生）

- `hibiki/lib/src/models/preferences_repository.dart`：新增 6 个键的 getter/setter（overlay/extension 各 independent+maxW+maxH），默认值。参照现有 `popup_max_width/height`（:527-546）。
- `hibiki/lib/src/models/app_model.dart`：
  - 暴露新键（参照 `popupMaxWidth/H` 暴露处 :3895-3901）。
  - `browserExtensionThemeColors()`（:2298, 写 `--hibiki-popup-max-*` 于 :2349-2352）改为读扩展有效键。
- `hibiki/lib/src/lookup/global_lookup_controller.dart`：`cardW/cardH`（:512-513, :1068-1069, :210-211）改读 app 外有效键。
- `hibiki/lib/src/settings/settings_schema_lookup.dart`：
  - 现有 `popup_max_width`(:675-692) / `popup_max_height`(:693-707) 保留为 app 内；高度上限 800→1600。
  - 新增「app 外覆盖窗」「浏览器扩展」两组：各一个 `独立尺寸` 开关 + 条件展开的宽/高滑杆。
  - 列数项（:630 `popupDictionaryColumns`）文案改「最多列数（自动填充）」。
- i18n：新增 key 一律走 `hibiki/tool/i18n_sync.dart --add`，改完 `dart run slang` + `dart format`（17 语言）。
- 纯函数 `effectiveLookupSize` 抽到可测位置（如 lookup 下的 helper），Phase C/D 复用。

**验证：** `flutter analyze` + `flutter test`；新增 `effectiveLookupSize` / 解锁语义单元测试。

### Phase B — app 内弹窗拖拽 resize（全 5 平台，纯 Flutter）

- `hibiki/lib/src/pages/implementations/dictionary_popup_layer.dart`：
  - `HibikiPopupSurface`（:482-487）叠角落拖拽把手 widget（`GestureDetector`/`Listener`）。
  - 拖动改「有效宽高」，经缩放折算（宿主读的是 `popupMaxWidth * appUiScale`，见 `base_source_page.dart:457-458` / `dictionary_page_mixin.dart:125-126`）回写 `setPopupMaxWidth/Height`（`preferences_repository.dart:532-546`）。
  - reader 与 video 共用 `resolvePopupRect`/`parkedPopupLayer`（:190-260），改一处即覆盖两家。
- 交互：拖动时实时预览（可临时 state），松手落偏好；尊重屏幕/选区 clamp。

**验证：** widget 测试断言拖动后 `popupMaxWidth/H` 真写穿偏好；`flutter analyze` + `flutter test`；Windows 离屏 + 真机焦点驱动复测。

### Phase C — app 外覆盖窗拖拽（仅 Windows，原生）

- `hibiki/windows/runner/global_lookup_window.cpp`：给瞬态覆盖窗补 resize chrome（当前 native 明确「瞬态窗不进模态循环、无 chrome」，:1434-1436）；复用 `beginWindowResize` → `WM_NCLBUTTONDOWN(HTBOTTOMRIGHT)` 通路（:1011-1022），`WM_EXITSIZEMOVE` 回报 rect（:1430-1445）。
- `hibiki/assets/popup/global_lookup_host.js`：瞬态覆盖窗渲染 resize grip（当前 grip 仅 panel 模式，:375-391）。
- Dart 侧 `global_lookup_controller.dart`：接收 native 回报的 rect → 拖即解锁（`overlayLookupIndependentSize=true`）+ 写 app 外键。

**验证：** 本环境无法编译/运行 Windows 原生；**必须 Windows 真机复测并留证据**（本期交付标注「待真机」）。

### Phase D — 扩展弹窗拖拽（DOM）+ 经 bridge 回写 app

- `tools/browser-extension/content.js`（+ 镜像 `hibiki/assets/browser_extension/content.js`）：弹窗加拖拽手柄，拖动改 `hibikiHost` maxW/H（当前尺寸盒在 :1316-1323，placement 在 `hibikiComputePlacement` :1251-1282）。
- 拖完经 bridge 回写 app 的扩展键（拖即解锁 `extensionPopupIndependentSize=true`）；app 下一次 theme 下发时以新值为准。
- 三镜像 parity：改共享词典样式改 `assets/popup/popup.css` 后跑 `node tools/browser-extension/scripts/generate-content-css.mjs`；改扩展专属改 `content-css-overlay.css`。content.js 两份镜像字节相同。

**验证：** `browser_extension_popup_parity_guard_test.dart` + `popup-placement.test.js`；扩展需浏览器手测。

## 7. 测试与验收纪律

- 纯函数（有效尺寸解析、拖拽折算/解锁）→ 单元测试。
- 列数封顶 → popup.js 相关守卫。
- 三镜像 parity → 现有 guard test。
- app 内拖拽 → widget 测试写穿偏好。
- 声明「修好」前：`dart format .` + `flutter analyze`（含 test）+ `flutter test`；阅读器/查词路径按项目要求 Windows 离屏 + 真机焦点驱动复测留证据。
- Phase C（Windows 原生）、Phase D（扩展）交付标注「待真机/浏览器验收」。

## 8. 显式风险 / 取舍

- **app 外拖拽仅 Windows**：macOS/Linux 无覆盖窗，Android 是独立悬浮服务（`FloatingDictService`，不共享 Win32 机制），iOS 无 app 外查词。Android 悬浮窗 resize 若要做单开一期，不在本设计内。
- 独立尺寸键新增须走 i18n_sync + slang 重生成，勿手改生成文件。
- 拖拽写全局偏好 = 下次查词沿用新尺寸（预期行为，非 bug）。

## 9. 一句话本质

弹窗尺寸是一个「最大宽高」真值；滑杆和拖边角是它的两种编辑入口；三形态默认共享、可解锁独立；列数自动填充封顶。
