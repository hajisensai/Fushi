## BUG-1418 · 阅读器整卷 OCR 看不到「配对主机」选项：openBookOcr 漏传 remoteRunner
- **报告**：2026-08-02（用户：TODO-2633）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/media/manga/manga_module.dart:108-137`（修复前）——
  `MangaModule.openBookOcr` 构造 `MangaOcrWizardDialog` 时**漏传 `remoteRunner:`**，
  而同文件 `:99` 的 `openOcrImportWizard` 传了。唯一调用方是阅读器的整卷 OCR 动作
  `hibiki/lib/src/media/manga/reader/manga_hibiki_page.dart:2077-2083`。
  后果：该入口 `widget.remoteRunner == null` ⇒ `manga_ocr_wizard_dialog.dart` 的
  `MangaOcrEngineCapability(id: pairedHost, supported: widget.remoteRunner != null)` 恒 false，
  `_remoteAvailable` 恒 false ⇒ 引擎分段里**永远不出现**「配对主机」。全平台都中，
  **安卓最受伤**：它没有本地 ONNX 引擎（`isSupportedPlatform == false`）、也没有外部
  mokuro CLI（桌面专属），这条洞让阅读器整卷 OCR 只剩 Google Lens。
- **[x] ① 已修复** — 不是补一个参数（那样第三个入口还会再漏一次），而是消除
  「两个入口各自手抄一份依赖表」这个结构：新增
  `hibiki/lib/src/media/manga/manga_ocr_wizard_engines.dart` 的 `MangaOcrWizardEngines`
  收下四个引擎 runner + 默认引擎偏好，成为 `MangaOcrWizardDialog` 的**必填**参数
  （漏传编译不过），生产装配只在 `MangaOcrWizardEngines.resolve` 出现一次，
  `openOcrImportWizard` / `openBookOcr` 共用。顺带消掉阅读器里手抄的
  `Platform.isWindows || Platform.isLinux || Platform.isMacOS`（`isDesktopPlatform` 的副本）
  与导入框里重复的 `InterconnectMangaOcrClient` 构造。
  提交：见本分支 `fix(manga): 两个 OCR 向导入口共用引擎依赖装配` commit。
- **[x] ② 已加自动化测试** — `hibiki/test/media/manga/manga_module_ocr_entry_engines_test.dart`
  （5 例）：① 阅读器入口有可用 host 时「配对主机」选项出现；② 无 host 时不出现且
  引擎区不退化成「无可用引擎」；③ 导入向导入口依赖集同构不回归；④a/④b
  `externalRunner` 的 desktop 三元（有意差异）两个方向都钉住。
  变异实测：`openBookOcr` 不转发 runner → ①② 红；`resolve` 里 `remoteRunner: null`
  → ①②③ 红；`lensRunner: null` → ②③ 红；desktop 三元取反 → ④a④b 红。
- **备注**：同批查出的 TODO-2634（`auto` 引擎在安卓落到死默认）、TODO-2635
  （probe 不校验 `modelsReady`）**本轮不做**，与本条互不重叠。
