## BUG-1584 · iOS archive 的 STRIP_STYLE=all 抹掉 fushidicts FFI 导出符号，上架包启动即 Initialisation failed
- **报告**：2026-08-12（用户：iOS 反馈 `Initialisation failed` / `Invalid argument(s): Failed to lookup symbol 'hoshidicts_import': dlsym(RTLD_DEFAULT, hoshidicts_import): symbol not found`；符号名是改名前的，说明报的是 W6 改名前的包，但同一根因在改名后的 `fushidicts_import` 上原样存在）
- **真实性**：✅ 真 bug，且是 [BUG-554](BUG-554-ios-hoshidicts-release-export.md) 的漏网续集。BUG-554 当时只用 `flutter build ios --release --no-codesign` 验证，那条路径 `ACTION=build` / `DEPLOYMENT_POSTPROCESSING=NO`，**根本不跑 Strip 阶段**，所以 `-Wl,-export_dynamic` 一加就"验证通过"了。但 TestFlight / App Store 包不走这条路径，走的是 `xcodebuild archive`（= Xcode 的 Product > Archive），它置 `DEPLOYMENT_POSTPROCESSING=YES` + `STRIP_INSTALLED_PRODUCT=YES`，而 `fushi/ios/Runner.xcodeproj/project.pbxproj` 三套配置都没钉 `STRIP_STYLE`，取 Xcode 默认值 `all`，于是链接后执行 `strip -D <Runner>` 把主可执行的全局符号连同 LC_DYLD_EXPORTS_TRIE 一起抹掉。`-Wl,-export_dynamic` 只作用于链接期，拦不住链接之后的 strip。结果：`packages/fushi_dictionary/lib/src/ffi/fushidicts_ffi_bindings.dart:14` 的 `DynamicLibrary.process()`（iOS 走 RTLD_DEFAULT）在 `fushidicts_ffi_bindings.dart:200` 第一个 `lookupFunction('fushidicts_import')` 就抛，`FushiDicts.probeDictContent` / `initialize` 全线不可用。
  - 实测对照（同一份 `flutter build ios --release` 产出的未 strip 二进制，只改 strip 方式）：

    | 产出路径 | strip | `_fushidicts_*` FFI 导出 | 体积 |
    |---|---|---|---|
    | `flutter build ios --release` | 不跑 | 34（含 `_fushidicts_import`） | 1,883,872 |
    | `xcodebuild archive`（STRIP_STYLE=all，默认） | `strip -D` | **0** ← 上架包就是这个 | 1,617,312 |
    | STRIP_STYLE=non-global | `strip -x` | 34 | 1,647,296 |
    | STRIP_STYLE=debugging | `strip -S` | 34 | 1,851,600 |

    archive 后二进制里 `grep fushidicts` 还能剩 12 条，但全是 glaze 模板实例化的 `fushidicts_json` 命名空间 weak-def 数据符号，**一个 C ABI 入口都不剩**——只数 `grep -c fushidicts` 会误判成"符号还在"。
- **[x] ① 已修复** — `fushi/ios/Runner.xcodeproj/project.pbxproj` 的 Runner 目标 Debug/Profile/Release 三套配置各加 `STRIP_STYLE = "non-global";`：只剥局部/调试符号，保留 dlsym 要的全局导出。代价实测 +30KB（相对全剥）。不选 `STRIP_INSTALLED_PRODUCT = NO` 是因为那会把局部符号也整份留下，白涨 236KB 且无收益。（提交：本提交）
- **[x] ② 已加自动化测试** — `fushi/test/dictionary/fushidicts_ios_packaging_guard_test.dart` 新增 `iOS Runner keeps global symbols through the archive strip pass`：取三套 force_load FushiDicts 归档的 `buildSettings` 块，逐块断言 `STRIP_STYLE = "non-global";`。守卫钉在 pbxproj 源码位，因为真实失败只在 archive 产物里可见，而 CI 单测层跑不动 archive。
- **备注**：
  - 验证证据：修复后重跑 `xcodebuild archive`，`dyld_info -exports <archive>/Products/Applications/Runner.app/Runner` 能查到 `_fushidicts_import` 等 22 个 C ABI 入口（`dyld_info -exports` 读的正是 dlsym 走的那张导出表，比 `nm` 更贴近运行时语义）。
  - 运行时正向证据：iOS 模拟器与 macOS 各跑一遍临时集成测试（走 `FushiDicts.probeDictContent` + `initialize`/`disposeInstance`，覆盖 `FushidictsFfiBindings` 构造函数里全部 22 个 `lookupFunction`），均通过。
  - macOS 不受影响：macOS 走 Frameworks 里的 `libfushidicts_ffi.dylib` + `DynamicLibrary.open()`，dylib 的全局符号是链接契约的一部分，strip 不会动；且桌面发布走 `flutter build macos --release` 而非 archive。已实测 `dlopen` + `dlsym` 双符号命中。
  - **教训入档**：iOS 上任何依赖 `DynamicLibrary.process()` 的符号，验证必须落在 **archive 产物**上，不能用 `flutter build ios --release` 代替——两者的 strip 行为不同，后者会把这类 bug 全程隐藏。
