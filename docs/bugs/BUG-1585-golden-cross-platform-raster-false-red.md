## BUG-1585 · golden 基准图跨平台光栅必红：非 Windows 开发机全量套件恒 33 条伪红
- **报告**：2026-08-12（在 macOS 上跑 `dart run tool/flutter_test_failures.dart --no-pub` 全量门时暴露：18726 项里 42 项红，其中 33 项是 `test/goldens/` 下 7 个套件）
- **真实性**：✅ 真 bug（测试基础设施层，非产品缺陷）。基准图在 Windows 主开发机生成，而字体光栅化/抗锯齿是平台相关的；默认的 `LocalFileComparator` 要求**逐字节相等**，于是同一份 widget 树在 macOS 渲染出的 PNG 与基准必然不同。实测 33 条差异分布 **0.00% ~ 0.10%（最大 0.0010）**，全部是抗锯齿噪声，没有一条是真实 UI 差异。
  - 根因不在某个 golden 文件，而在**设计只实现了一半**：`fushi/dart_test.yaml:1-11` 已写明 golden「按 Flutter 惯例 gate 到参考平台：CI 用 `--exclude-tags golden` 跳过，开发机本地 `flutter test` 仍校验」——CI 那半截实现了，**「非参考平台的开发机怎么办」这半截是空的**。结果是任何 macOS / Linux 开发机跑全量门都必然见到 33 条恒红。
  - 危害不是「多 33 条红」本身，而是**它会训练出「golden 红了不用管」的条件反射**。全量门是合入 `develop` 的硬闸（CLAUDE.md「验证」节），一个恒红的子集会让真实 golden 回归混在噪声里一起被无视——那时 golden 的全部价值归零。
- **[x] ① 已修复** — `fushi/test/flutter_test_config.dart` 新增 `installToleranceGoldenComparator()`，在套件级把 `goldenFileComparator` 换成 `ToleranceGoldenComparator`：差异比例 ≤ `kGoldenMaxDiffRatio`（0.005）即通过，超出仍走 `generateFailureOutput`，失败图照常落 `test/goldens/failures/`。装在 `testExecutable` 里而不是各 golden 文件自己 `setUp`，因为新增 golden 文件应当自动继承该口径。
  - **阈值依据**：实测噪声上限 0.0010，取 0.005 = **5 倍余量**；而真实 UI 回归（改内边距 / 换配色 / 调字号 / 换圆角）的像素差异是量级更大的事——单是把 200px 宽控件内边距动 4px 就远超 0.5%。所以该容差吸收光栅噪声、不吸收布局回归。
  - **为什么不选「非 Windows 直接 skip」**：那样 macOS / Linux 开发机彻底失去 golden 覆盖，与 `dart_test.yaml` 自己写的「开发机本地仍校验」相悖；容差方案让三个平台都保留校验能力，代价只是 Windows 上从「逐像素精确」放宽到「0.5% 内」。（已与用户确认取容差方案。）
- **[x] ② 已加自动化测试** — `fushi/test/goldens/golden_tolerance_comparator_test.dart`，3 条，把阈值**双向**钉死：
  1. 阈值常量断言 = 0.005，且必须 > 实测噪声上限的 2 倍、< 0.01（防止后人随手调宽）；
  2. 差异 0.0040（< 阈值）必须**通过**——否则等于没修，非参考平台继续恒红；
  3. 差异 0.0100（> 阈值）必须**仍然抛 `FlutterError`**——否则容差退化成「永远通过」。
  用 `PictureRecorder` 逐像素画 1×1 黑块生成 100×100 图，差异像素数精确可数，不受抗锯齿干扰。
- **备注**：
  - 同一轮全量门里另外 9 条红是 [BUG-1583](BUG-1583-manga-ocr-test-platform-gate.md)（manga OCR 测试的平台闸门），与本条独立。两条修完后 macOS 上全量门 42 红清零。
  - 本条不改任何基准 PNG——重新生成 macOS 版基准会反过来让 Windows 主开发机全红，是把问题搬家而不是解决。
