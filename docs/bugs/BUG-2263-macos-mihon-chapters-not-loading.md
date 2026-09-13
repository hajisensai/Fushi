## BUG-2263 · macOS Mihon 章节列表加载不出来（未复现）
- **报告**：2026-09-08（用户：mac 上漫画的 Mihon 和 Aidoku 都没有章节加载出来）
- **真实性**：❌ 未复现（提交者本机 Windows，无法在 macOS 上跑原始失败路径）。**沿真实代码路径逐跳查完，没有发现任何 macOS 专有的章节缺陷**——与同批报告的 Aidoku 半边（[BUG-2262](BUG-2262-macos-aidoku-partial-result-chapters-dropped.md)，已定案已修）不同，Mihon 这条链是平台无关的。

  **已排除（逐条带证据）**：
  - 平台门：`fushi/lib/src/media/manga/mihon/mihon_runtime_factory.dart` 明确把 macOS 与 Windows 同等对待，走同一个 `DesktopMihonRuntime`。
  - 资源路径：`fushi/lib/src/media/manga/mihon/desktop_mihon_runtime.dart` 的 `_defaultResourceDirectory()`（macOS 走 `Contents/Resources/mihon_bridge`）与 `_javaExecutablePath()`（按 `Abi.current()` 选 `runtime-macos-arm64` / `runtime-macos-x64`）拼装正确，与 `tool/mihon/build_desktop_runtime.sh` 的产物命名一致。
  - 章节调用链：`mihon_bridge_runtime.dart` 的 `getChapters` → `invokeBridge(..., 'getChapterList', ...)` 是 Android 与桌面**共用**的，没有平台分支；sidecar 侧 `MihonInvoker.invokeGetChapterList` 用 `getMangaUpdate(fetchDetails = false, fetchChapters = true).chapters`，而 `Source.getMangaUpdate` 的默认实现在源没迁移到 1.6 API 时正确回退到 `getChapterList(manga)`。
  - entitlements：`fushi/macos/Runner/Release.entitlements` 与 `DebugProfile.entitlements` 均已去沙盒且保留 `network.client` / `network.server`，回环连接与子进程监听不受限；两份无 debug/release 分叉。
  - 打包：两条 macOS job 都装 `mihon_bridge` 并跑 verify；发布 job 还给 JVM 单独授 `allow-jit` / `allow-unsigned-executable-memory` / `disable-library-validation`。
  - 空章节保护：`online_manga_library_service.dart` 在源返回空列表而库里原有章节时主动抛 `runtimeFailure`，不会静默清空。

  **仍未排除、需要用户机器上的证据才能定案**：
  1. `<fushi.app>/Contents/Resources/mihon_bridge/` 是否真的有 `m-extension-server.jar` 与 `runtime-macos-<abi>/bin/java`。**Xcode 工程里零接线**（`fushi/macos/Runner.xcodeproj/project.pbxproj` 无任何 mihon/aidoku build phase），两个 runtime 只由 CI 的 post-build 步骤和 `script/build_and_run.sh` 注入——所以任何直接 `flutter build macos` / `flutter run -d macos` 产出的 app 里两个 runtime**都是空的**，Mihon 与 Aidoku 会同时死。这与用户「两个都没章节」的描述高度吻合，是当前最可能的单一解释。
  2. `<数据根>/mihon/logs/sidecar.log`（`desktop_mihon_runtime.dart` 的 `_SidecarLogSink`）：sidecar 起来了的话，`getChapterList` 的完整 Java 栈一定在里面。
  3. Intel Mac 的话，见下面已补的架构门。
- **[ ] ① 未修复** — 无确证根因，不做投机修改。本轮只补了一条**可验证的** macOS 专有缺口（不宣称它就是用户的症状）：`tool/mihon/verify_desktop_runtime.sh` 原本只按 `uname -m` 冒烟宿主架构的 `java`，而 CI runner 恒是 Apple Silicon——交叉 jlink（arm64 宿主 + x64 jmods）出来的 `runtime-macos-x64` 从来没被核对过一次，一旦它实际是 arm64，Intel Mac 上会被内核以 EBADARCH 拒掉，表现为**整条 Mihon 链（源列表/搜索/详情/章节/看图）全废而 CI 全绿**。这与 Aidoku 侧 BUG-1668 / BUG-1922 同形，那边早已有 `tool/aidoku/verify_macos_runtime.sh` 的架构覆盖门，Mihon 侧一直缺。现按同一形状补上：verify 接受可选的 app 本体参数，逐个核对「app 能跑的每个架构都有对应的 JVM 镜像、且那个镜像真的是该架构」，两条 macOS job 都把 `$app_dir/Contents/MacOS/fushi` 喂进去。
- **[ ] ② 未加自动化测试** — 症状本身没有可落地的测试层（无根因）。已补的架构门有守卫：`fushi/test/build/macos_mihon_bundle_guard_test.dart` 新增 3 条（verify 脚本必须有 `lipo -archs "$app_executable"` 与可诊断的 EBADARCH 失败原因；构建脚本默认 `FUSHI_MIHON_ARCHS:-all`；两条 workflow 都必须把 app 本体传给 verify）。
- **备注**：下次拿到用户证据（上面的 1/2/3 任一）后再定案。取证顺序：先 `ls "<fushi.app>/Contents/Resources/mihon_bridge/"`，若为空或缺 `runtime-macos-<abi>/bin/java` 即可直接结案为「app 不是 CI 产物」；否则读 sidecar.log。
