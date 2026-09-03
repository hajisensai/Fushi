## BUG-1661 · macOS 构建挂在「下载 pinned JDK 失败」，真因是 sha256 抄成 65 位
- **报告**：2026-08-15（用户：发 2.1 前巡检 develop CI 发现，非用户报告）
- **真实性**：✅ 真 bug（`tool/mihon/build_desktop_runtime.sh:27`）。
  PR #850 把 macOS 的 pinned JDK 从 Temurin 21.0.11+10 换成 Amazon Corretto
  21.0.12.8.1 时，x64 归档的期望 sha256 抄成了 **65 位**：
  `a018ae…736612ff` **`a`** —— 前 64 位与真值逐字节相同，末尾多了一个字符。
  实测：把 `amazon-corretto-21.0.12.8.1-macosx-x64.tar.gz`（202,985,567 字节）
  完整下载后本地实算 = `a018ae6221babf065f770479b1bf0ab0d23bea78ed18f236c40bb5d4736612ff`
  （64 位）。arm64 那份的 65→64 没抄错，所以只有 x64 一侧红。
- **症状为什么会误导**：`shasum -a 256 --check` 对长度不合法的期望值只会判
  FAILED，脚本的重试逻辑于是完整下完 193MB、重试三次、每次 mismatch，最后打印
  `failed to download the pinned macOS JDK archives` 并 exit 1。**报出来的现象是
  「下载失败」，真因却是抄错了一个字符**，很容易被归到网络/CDN 抖动上放过。
  实际影响：`Build and Test Android / macOS / Linux / Windows` 的 `macos` job
  自 #850 合入起在 develop 上恒红（#850 自己的 PR run 也是同一处红）。
- **[x] ① 已修复** — 去掉多出的那一位。
- **[x] ② 已加自动化测试** — `fushi/test/build/mihon_vendored_server_guard_test.dart`
  新增「$name 钉的 sha256 必须正好 64 位十六进制」，对 `.sh` / `.ps1` 两份构建脚本
  各跑一次。挑「长度」作断言是因为它是这类笔误唯一本地零成本可测的不变式：
  内容对不对要下 193MB 才知道，位数对不对读一行就知道。40 位的 git commit 不在
  规则内（只匹配 `..._sha256 = "..."` 这种显式命名的赋值）。
  变异实测：把 65 位的错值放回去 → 守卫红成「实际 65 位」；还原后脚本 sha256 与
  变异前逐字节一致（`15c78ba19969567c9eae4fbc910bfb8b72b7fcadc87bdb8fde29224f3a8e4eab`）。
- **备注**：Corretto 官方没有提供 `.tar.gz.sha256` 同名文件（`corretto.aws` 上取到的是
  S3 AccessDenied），换版本时只能下全量自己实算，所以这条长度守卫更有意义。
