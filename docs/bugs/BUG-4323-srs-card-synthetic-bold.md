## BUG-4323 · 复习卡词头 / 加粗段在单字重用户字体上被合成假粗体糊字
- **报告**：2026-11-08（应用内反馈 KuZmUL3U-l，OnePlus PJX110 / Android 16）
- **真实性**：✅ 真 bug（代码路径已核；「用户字体为单字重」为推测，未拿到其字体文件）。`srs_fushi_card_view.dart` 的 `_SrsCardStyle.term()` 无条件 `copyWith(fontWeight: FontWeight.w600)`，例句加粗段 `SrsRubyText._styleOf` 无条件 w700，音高序号徽章与分区标签也无条件 w600；而字体库每个文件条目在 `AppFontLoader._loadFileFamily` 里各自注册成**只有一个 face** 的 family。对单 face（如 Regular 400 手写体）请求 ≥600 时 minikin / Skia 按「请求 ≥600 且比实际重 ≥200」合成假粗体，笔画外扩粘连。正文 `text()` 早已对用户字体「保持原字重」，词头 / 加粗段却没有。
- **[x] ① 已修复** — 新增 `fushi/lib/src/models/font_face_weight.dart`：`sfntWeightClass` 读 OS/2 `usWeightClass`，`AppFontLoader` 注册文件字体时登记到 `FontFaceWeightRegistry`；共享判据 `wouldSynthesizeBold` / `faceSafeFontWeight` / `withFaceSafeWeight`，会合成假粗体时不请求加粗（保持字体原字重，词头靠字号、加粗段靠强调色区分）。卡面 term / `_styleOf` / 音高徽章 / 分区标签四处都走它；系统字体与读不出字重的字体不登记、行为不变。
- **[x] ② 已加自动化测试** — `fushi/test/models/font_face_weight_test.dart`（OS/2 解析含 TTC / 截断、假粗体判据、单字重字体 term 不带 w600 / 粗 face 与系统字体保留 w600、卡面源码不得再直写 w600+ 字重）。测试未在本分支运行，统一在合并后验证。
- **备注**：真机复测未做（本批次不做真机验证）。
