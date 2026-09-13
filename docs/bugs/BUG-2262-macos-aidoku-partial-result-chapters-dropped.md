## BUG-2262 · macOS Aidoku 章节列表恒为空：桌面 runtime 丢弃 send_partial_result 回传的章节
- **报告**：2026-09-08（用户：mac 上漫画的 Mihon 和 Aidoku 都没有章节加载出来）
- **真实性**：✅ 真 bug（Aidoku 半边）。根因 `native/aidoku_runtime/src/main.rs:149`（`imports::generate_imports` 的 import object 被原样使用），对照 `native/aidoku_runtime/src/embedded.rs:860-874`（iOS 自己实现了同一个 import）与 `embedded.rs:2228-2240`（iOS 的合并）。

  **链路**：`MangaSeriesPage._refreshFromSource`（`fushi/lib/src/media/manga/library/manga_series_page.dart`）→ `AidokuLibraryAdapter.refresh`（`fushi/lib/src/media/manga/library/online_manga_runtime_adapter.dart`）→ `chaptersOf(details)`（同文件，只读 `details['chapters']`）→ `DesktopAidokuRuntime.getDetails`（`fushi/lib/src/media/manga/aidoku/aidoku_runtime.dart`）→ 子进程 `fushi-aidoku-runtime details` → `AidokuRuntime::details()` 调 wasm 的 `get_manga_update(manga, 1, 1)`。

  **根因**：aidoku-rs 的源**不在 `get_manga_update` 的返回值里**给章节列表——它把章节通过 host import `env.send_partial_result` 单独推出来（搜索的补充条目同理）。桌面 runner 直接用了上游 `aidoku-test-runner` 生成的 import object，而上游把这个 import 注册成**显式空实现**：

  > `crates/test-runner/src/imports/env.rs:22`（rev `1a6bb691`）
  > `pub fn send_partial_result(_env: FunctionEnvMut<WasmEnv>, _value: i32) {`
  > `    // leaving this function unimplemented for now since the test runner doesn't use partial results`

  于是整份章节列表被丢进黑洞。返回值里 `chapters` 是 `None`，`chaptersOf()` 直接返回空列表，**不抛异常**；`_refreshFromSource` 只在抛异常时才置 `_refreshError`，所以 UI 既不弹 toast 也不挂错误横幅——用户看到的就是「搜索正常、点进作品页章节永远是空的、什么错都不报」。

  iOS 从来没有这个 bug：`embedded.rs` 用 wasmi 自己搭 linker，实现了 `send_partial_result` 并在 `details()` / `search()` 里合并 partial。这是一条**只在 macOS 成立**的 iOS/桌面不对等。
- **[x] ① 已修复** — `native/aidoku_runtime/src/main.rs`：新增 `PartialResults` env + `host_send_partial_result`，在 `AidokuRuntime::load()` 里用 `import_object.define("env", "send_partial_result", ...)` 覆盖上游的空实现（wasmer 的 `define` 是替换语义，与既有的 `std.abort` / `std.print` 覆盖同形）；`details()` 按 `embedded.rs` 同一口径把 partial 里非空的 `chapters` 合并进结果，`search()` 按 `key` 去重合并 partial 条目。线格式（小端 u32 总长 + 8 字节头 + postcard 负载）抽成可单测的 `partial_result_payload_length()`。
- **[x] ② 已加自动化测试** — `fushi/test/build/aidoku_partial_result_parity_guard_test.dart`（6 条）：钉「`embedded.rs` 与 `main.rs` 对 partial result 的处理必须对等」这条不变式——两侧都得有 `send_partial_result` 实现、都得合并章节、都得按 key 去重合并搜索条目，外加桌面侧的 take 语义、头长度解析、以及 Dart 消费口仍是 `details['chapters']`。已做变异验证：把 `result.chapters = partial.chapters;` 改坏后该测试立刻红。另加 Rust 单测 `decodes_a_partial_result_payload_length` / `rejects_a_partial_result_shorter_than_its_header`。
- **备注**：提交者本机 cargo 不可用，Rust 侧编译由 PR 的 macOS job 兜底——`build-multiplatform.yml` 的 macos job 会跑 `tool/aidoku/build_macos_runtime.sh`，里面就是 `cargo build --locked --release`。仓库目前**没有任何 `cargo test` / `cargo fmt` / `cargo clippy` 门**，所以新增的两条 Rust 单测不会被 CI 执行（守卫那 6 条会）。**尚未在真 Mac 上复测原始失败路径**（提交者是 Windows），按 CLAUDE.md 验证纪律，合入后需在 Mac 上用任一 Aidoku 源验证作品页章节列表非空再关掉这条。Mihon 半边另见 [BUG-2263](BUG-2263-macos-mihon-chapters-not-loading.md)。
