## BUG-1325 · 界面字体回退链被压成单值：中文默认字形难看、日文缺字逐字乱回退、用户第2条字体永不生效

- **报告**：2026-08-01（用户：中文默认字体很烂；日语缺字会导致回退；希望默认按语言用对应字体）
- **真实性**：✅ 真 bug，三个症状同一根因——字体本质是**有序回退链**，实现把它压成了单值。

### 根因（三处，同一个数据结构缺陷）

1. `hibiki/lib/src/models/app_font_loader.dart:43`（旧 `resolveAndLoad`）
   命中第一个 enabled 条目就 `return`，**丢弃列表其余全部条目**。用户在「外观 · 排版 · 字体库」
   里排的是一个有序列表（UI 上就是回退顺序），排第 2、3 位的字体从来没有机会参与缺字回退。
2. `hibiki/lib/src/models/app_model.dart:1511`（旧 `textStyle`）
   只设 `fontFamily`，**从不设 `fontFamilyFallback`**。主字体缺字时逐字掉进引擎默认 fallback：
   日文 face 缺简中「们/东/为」、中文 face 缺假名，同一行里字形忽宽忽窄。
   视频字幕层早已承认这个事实并加了链（TODO-088 `subtitleCjkFontFallbacks`），界面层没跟上。
3. 同上，未配自定义字体时 `fontFamily == null`，CJK 字形完全交给引擎默认 fallback。
   该回退不看 `TextStyle.locale`（Windows/Skia 尤甚），中文界面常落到并非为简中优化的 face
   上——即用户所说的「中文默认字体很烂」。BUG-068 已把「界面字形跟显示语言」定为规矩，
   但当时只解开了 `ja` 硬钉，没有正面给出各语言的字体。

附带（同一页面的可用性问题）：`settings_schema_appearance.dart` 的「排版」分区
`collapsedByDefault: true`，让高频的改字体操作每次多一次展开点击。

### 修复

- **[x] ① 已修复** — commit `PENDING_COMMIT`
  - 新增 `hibiki/lib/src/models/app_ui_font_chain.dart`：纯函数 `appUiFontChain()`，按
    `[用户自定义字体（全部，按序）] + [显示语言的系统字体] + [其余 CJK 语言字体]` 构造链，
    平台可注入（Windows / Apple / Noto 三套家族名，繁简分开）。
  - `AppFontLoader.resolveAndLoadAll()`：解析并注册**整张**列表（未注册的家族名在 Flutter
    回退链里是死名，所以注册必须覆盖全列表）。单家族目标（视频字幕，自带 CJK 链且与
    mpv/libass 字号换算耦合，见 BUG-929）仍用 `resolveAndLoad` 保持懒解析。
  - `AppModel.textStyle` 输出 `fontFamily` + `fontFamilyFallback`；链按 (locale, 自定义列表) memo。
  - 「排版」分区去掉 `collapsedByDefault`，默认展开。
  - **刻意不做**：显示语言非 CJK 且无自定义字体 → 返回空链，双 null，与改造前逐像素一致。
    因为 `fontFamily == null` 时引擎把 fallback 首项当主字体（拉丁字形也归它管），强塞 CJK 链
    会把一个 CJK 缺字问题换成全语言排版问题。
- **[x] ② 已加自动化测试** —
  - `hibiki/test/models/app_ui_font_chain_test.dart`（新，13 例）：链构造规则的行为契约——
    显示语言决定链首、繁简分流、非 CJK 界面不被接管、自定义列表整条进链、去重与裁空白、
    日文兜底排在其余 CJK 之前、平台家族不混淆、链不可变。
  - `hibiki/test/models/app_ui_font_locale_guard_test.dart`（扩充）：钉住 `textStyle` 的接线
    （`fontFamilyFallback: appFontFallbacks` + 链由 `appUiFontChain` 构造 + appUi 走
    `resolveAndLoadAll`）。
  - `hibiki/test/reader/font_targets_wiring_guard_test.dart`（更新）：appUi 目标必须走
    `resolveAndLoadAll`（`resolveAndLoad` 会静默丢掉用户自己排的回退顺序）。
  - 三处守卫均做过**变异实测**：删 `fontFamilyFallback` 行、把 appUi 改回 `resolveAndLoad`、
    把日文挪到繁中之后——各自都能让对应断言变红（首版的「日文在显示语言之后」是自洽废话，
    抓不到第三处变异，已改成「日文在兜底段内部排第一」）。

### 备注

- 未做真机目视复核：字体链的实际字形只有装了对应系统字体的真机能看到，链本身
  （顺序 / 平台家族 / locale 分流）已被上述纯函数测试覆盖。
- 未涉及：词典弹窗（`assets/popup/popup.css` 默认 `"Hiragino Sans", ...` 硬编码日文链）与
  阅读器正文（body target）仍各自沿用原默认。它们的语言由**内容**而非界面语言决定，
  与本条的界面链不是同一个判据，需要单独立项。
