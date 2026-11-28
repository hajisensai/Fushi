# 架构审计：native-rust-ffi

2026-11-28 只读审计 + 独立反驳核验的原始结论。总方案见 [../../specs/2026-11-28-architecture-redesign.md](../../specs/2026-11-28-architecture-redesign.md)。

## 现状

只读审计。native/ 下现有 9 个 Rust crate（compute 6.2 万行、fsrs 21.7 万行、music、rwkv、web_core、corpus、p2p、shell_thumbs、anki_sync）和 3 个 C/C++ 模块（fushidicts、fushi_torrent、aacs），另有一个只给 iOS 用的伞形 staticlib（fushi_ios_umbrella）。桌面端和 Android 上每个 crate 各编一个 cdylib，Cargo.lock 也各管各的，没有 Cargo workspace，也没有共用的 FFI 基础 crate。每个 crate 自己写 status 常量、guard/catch_unwind、hand_over_bytes/free_bytes。报错走四套互不相同的通道：只回状态码、`char** error_out`、线程局部 last_error、JSON 信封。web_core 和 p2p 连 abi_version 握手都没有。Dart 侧每个绑定包各抄一份 200 多行的加载器（候选路径、测试宿主判定、往上找 prebuilt、iOS 走 process()、ABI 校验），复制之后语义已经分叉：有的抛错，有的返回 null，有的连异常一起吞掉。服务端在 native_libs.dart 里又写了一套，候选路径里还带当前目录。构建这边是 crate 数 × 平台数份几乎一样的 build_* 脚本，外加 6 份 verify_abi.sh，各自的阈值和能力已经走样。一个 crate 要「接进来」得在 native_libs.ps1、gradle、Windows/Linux 的 CMake、macOS/iOS 的脚本和 pbxproj、CI 的 action、各自的 hard_dependency 守卫等约 20 处手工登记，「是不是硬依赖」也是逐处手写，Android 上 fsrs/p2p 仍是「有就带上、没有不报错」（copy-if-present）。异步方面只有 compute 有原生线程经 DartPort 回发的机制（BUG-5413 之后补的）。其余包要么每次调用都 Isolate.run 一个新 isolate、在里面重新加载库，要么各自手写长驻 worker isolate 协议。fsrs 的类型化错误靠 Dart 用正则匹配 Rust 的英文报错文本来分类。

## native-crate-registry

**原生 crate 的接入点散在约 20 处手工登记，硬依赖与否逐处手写且已不一致（BUG-3427 同类）**

- 类型：缺单一登记源；规模 L；价值 high；不改外部行为
- 核验：部分成立

证据：

- tool/native_libs.ps1:64 `$NativeTestCrates` 手写 6 个 crate；:359 `$NativeAndroidCrates` 另手写 5 个，并注明要和 build.gradle、dist_test/worker_build.sh 保持一致
- fushi/android/app/build.gradle:202-209 fushi_p2p、fushi_fsrs 是有就带上、缺失照常构建（copy-if-present）；:461/:483/:504/:525/:549 另外五个 crate 各手写一个 checkFushi*Native 任务（每个约 20 行）
- fushi/windows/CMakeLists.txt:265-286 和 fushi/linux/CMakeLists.txt:207-226 每个 crate 各一段「必需依赖缺失就 FATAL_ERROR」的复制块
- fushi/ios/check_fushi_{compute,corpus,music,rwkv}.sh 只有 4 份；fushi/macos/bundle_fushi_*.sh 有 9 份；.github/actions/setup-fushi-{compute,corpus,music,rwkv,anki-sync} 每个 crate 一个 action
- fushi/test/build/fushi_{compute,corpus,music,rwkv}_hard_dependency_guard_test.dart 四份，215~394 行；corpus 和 music 两份做名字替换后只差 74 行
- native/fushi_ios_umbrella/Cargo.toml 的 [dependencies] 与 lib.rs:23-36 又手写一遍 crate 清单
- docs/bugs/BUG-3427-srs-ios-kernel-unlinked.md：iOS Runner 漏链 fushi_fsrs，CI 全绿、TestFlight 照发，正是「某个平台漏登记一个 crate」这一类问题
- packages/fushi_srs/lib/src/ffi/fushi_fsrs_library.dart:228-231 `on Object { return null; }` 吞掉加载失败；而 Android 上 fsrs 也是 copy-if-present，等于 BUG-3427 的 Android 版至今没被结构性堵住

机制：「仓库里有哪些原生库、每个库在哪些平台必需、产物叫什么、放在哪」这件事没有单一登记源。每个消费方（bootstrap 脚本、gradle、两份 CMake、Xcode 阶段脚本、CI action、dist worker、守卫测试）各写一份清单和判据，新增 crate 或把它改成硬依赖时只能靠人记住 N 处。守卫测试也是每个 crate 复制一份，等于用测试去兜一个本该由数据结构保证的不变量。

根本方案：新建 `native/crates.toml` 作为唯一登记源，每个 crate 一项：name、C 符号前缀、ABI 符号、各平台产物名、platforms（windows/linux/macos/android/ios）、required（只允许 true；app 能力的取舍写在 store_compliance 层，不靠「缺库降级」）、license、external_sources、android_abis。用一个生成器 `tool/native/gen_native_wiring.dart` 从它生成：`fushi/windows/native_libs.cmake`、`fushi/linux/native_libs.cmake`（循环校验缺失并 install）、`fushi/android/app/native_libs.gradle`（一个循环任务取代五个 checkFushi*Native，fsrs/p2p 一并变成 required）、macOS 一份 `bundle_native_libs.sh` 和 iOS 一份 `check_native_libs.sh`（各自读清单），伞形 crate 的依赖段，以及 native_libs.ps1 和 dist worker 读取的 crate 列表（脚本直接读 toml，不再内嵌数组）。CI 的 setup-fushi-* 合并成一个参数化的 `setup-native-crate` action，用矩阵展开。删掉 4 份 hard_dependency 守卫、4 份 check_fushi_*.sh、9 份 bundle_fushi_*.sh 和五段 gradle 任务，只留一个「生成物与 crates.toml 一致」的守卫。以后新增 crate 只在 crates.toml 加一项，再跑一次生成器。

要动：native/crates.toml(新)；tool/native_libs.ps1；fushi/android/app/build.gradle；fushi/windows/CMakeLists.txt；fushi/linux/CMakeLists.txt；fushi/macos/bundle_fushi_*.sh；fushi/ios/check_fushi_*.sh；fushi/ios/Runner.xcodeproj/project.pbxproj；fushi/macos/Runner.xcodeproj/project.pbxproj；native/fushi_ios_umbrella/*；fushi/tool/dist_test/worker_build.sh；.github/actions/setup-fushi-*；.github/workflows/*.yml；fushi/test/build/fushi_*_hard_dependency_guard_test.dart

核验说明：散落登记这一点属实：build.gradle:461/483/504/525/549 有五个 checkFushi*Native 任务，:202-209 的 p2p 和 fsrs 是 copy-if-present，windows/CMakeLists.txt:198-204 的 fsrs 也是 copy-if-present，native_libs.ps1 里有两份手写数组，每个 crate 各有一个 Cargo.lock。说法有误的地方：fsrs/p2p 的 copy-if-present 是 docs/agent/build.md:127 明文写下的设计（缺库时 SRS 原生内核判为不可用，不让构建失败）；Linux 出包时这三件一律必需（build.md:37）。所以说它是「BUG-3427 的 Android 版至今没堵住」，属于没有证据的推断，并不是漏登记。不过这个设计确实和 CLAUDE.md「原生库是硬依赖」相冲突，这部分成立。

方案风险：1) 方案写死 required 只能为 true，等于把 fsrs、p2p、torrent 的 copy-if-present 一起推翻。torrent 是 C++ 模块，缺库时会回退外接 qBittorrent，这是用户可见的能力降级，不能顺手改；fsrs/p2p 改成必需会改变 Debug 和 dist worker 的构建前提，要先上拍板台。2) native_libs.ps1 为了从兄弟 worktree 复用产物，按每个 crate 的源码树算哈希（:93-124），生成器和清单不能破坏这个缓存键。3) pbxproj 不适合用生成器去改，应该只让它调用一个读清单的脚本。

修正后的方案（以此为准）：保留 crates.toml 加生成器的方向，但每个 crate 的 required 按平台登记（取值 true / optional，optional 必须写明降级语义和对应文档）。fsrs/p2p 是否改为必需，单独写进拍板台；torrent 维持 optional。守卫合并成一份：参数化断言各平台的接线与清单一致，不删掉「缺库即失败」这类行为断言。

## dart-native-loader-dup

**Dart 侧原生库加载器复制了 7 份以上，语义已经分叉（抛错 / 返回 null / 吞异常 / 不做 ABI 校验），服务端还另写一套并带当前目录候选**

- 类型：缺单一登记源；规模 M；价值 high；不改外部行为
- 核验：成立

证据：

- packages/fushi_compute/lib/src/fushi_compute_library.dart:1-278 与 packages/fushi_corpus/lib/src/fushi_corpus_library.dart:1-249：isTestHost、_findRepoPrebuilt、libraryCandidates、load、_bindError 逐行相同，只差名字
- packages/fushi_p2p/lib/src/fushi_p2p_library.dart:57-118 没有往上找 prebuilt 的逻辑、不做 ABI 版本握手，加载失败一律 `continue` / 返回 null
- packages/fushi_web_core/lib/src/fushi_web_core_library.dart:56-82 不做 ABI 校验，缺符号时也 `on ArgumentError { continue; }` 静默换下一个候选（Rust 端只导出 fwc_version，没有 abi_version）
- packages/fushi_srs/lib/src/ffi/fushi_fsrs_library.dart:192-245 失败时返回 null，最外层 `on Object` 吞掉所有异常；同为硬依赖的 compute/corpus/music/rwkv 则抛 *UnavailableError
- packages/fushi_server/lib/src/native_libs.dart:14-25 服务端第八套候选规则，包含 `Directory.current`，与 fushi_compute_library.dart:121-123 写明的「正式 app 与服务端不能从当前目录的上级加载库（DLL 投毒面）」相矛盾；packages/fushi_server/lib/src/dictionary_host.dart:873-884 又给 fushidicts 单写了一个 resolver
- packages/fushi_srs/lib/src/store/srs_core.dart:626-631 为了跨 isolate 重新打开库，自己保存 libraryPath 后 reopen；web_core 的 _loaded map（fushi_web_core_library.dart:40-54）和 corpus 的 attach 又是另外两种写法

机制：每接一个原生库就把上一个包的加载器整份复制再改名，没有共用的纯 Dart FFI 基础包（fushi_ffi_view 只放了 asTypedList 的绕行）。修复只落在被修的那一份：BUG-5413 之后的「找到仓库根就停」、显式路径只试一个、往上找 prebuilt 等，在其他副本里或有或无。服务端没复用 app 的规则，另写了一套更宽松的。

根本方案：把 packages/fushi_ffi_view 扩成（或新建）纯 Dart 包 `fushi_native`，放唯一的 `NativeLibrarySpec`（baseName、envVar、abiSymbol、abiVersion、freeBytesSymbol、iosStatic、prebuiltCrateDir）和 `NativeLibraryLoader.load(spec) → LoadedNativeLibrary`。它统一负责候选路径（显式 → env → exe 同级 → bin/../lib → 测试宿主下的仓库 prebuilt → 裸名，不含 CWD）、iOS 的 process()、ABI 握手、逐候选的失败原因、按 isolate 缓存，以及 `reopen()` 供后台 isolate 使用；失败一律抛 `NativeLibraryUnavailableError`（继承 Error）。spec 常量由 crates.toml 生成。7 个 *_library.dart 缩成 spec 加 bindings 构造，删掉 fushi_server/native_libs.dart 和 dictionary_host 的 resolver，torrent/fushidicts 也改用同一个 loader。加一条守卫：`DynamicLibrary.open` 只许出现在 fushi_native 里；Win32 系统 dll（kernel32/user32 等）走 `systemLibrary(name)`，限定白名单。以后加库只写一个 spec。

要动：packages/fushi_ffi_view(扩为 fushi_native)；packages/fushi_compute/lib/src/fushi_compute_library.dart；packages/fushi_corpus/lib/src/fushi_corpus_library.dart；packages/fushi_music/lib/src/fushi_music_library.dart；packages/fushi_rwkv/lib/src/fushi_rwkv_library.dart；packages/fushi_srs/lib/src/ffi/fushi_fsrs_library.dart；packages/fushi_web_core/lib/src/fushi_web_core_library.dart；packages/fushi_p2p/lib/src/fushi_p2p_library.dart；packages/fushi_server/lib/src/native_libs.dart；packages/fushi_server/lib/src/dictionary_host.dart；packages/fushi_dictionary/lib/src/ffi/fushidicts_ffi_bindings.dart；packages/fushi_torrent/lib/src/embedded_torrent_engine.dart

核验说明：已核实：fushi_fsrs_library.dart:192-245 失败时返回 null，最外层 on Object 吞掉所有异常；fushi_server/lib/src/native_libs.dart:14-25 的候选路径包含 Directory.current，和 fushi_compute_library.dart:121-123 写明的「不能从当前目录加载（DLL 投毒面）」直接矛盾。web_core 和 p2p 的 src 里 grep 不到 abi_version。

方案风险：非测试代码里 DynamicLibrary.open 共有 68 处（packages 和 fushi/lib 合计），包括 onnxruntime、pdfium、mpv、系统 dll 等第三方库。守卫如果规定只许 fushi_native 调用，白名单会很大，要按「第一方库必须经 spec 加载」来写。fsrs 的 tryLoad 返回 null 被 isAvailable 等语义大量依赖（fsrs_library.dart:65-74），统一改成抛错前必须先改掉调用方的可用性判断。服务端那个 CWD 候选是安全问题，应当先按 bug 流程立刻修，不要等这次重构。

修正后的方案（以此为准）：同意。补两条：一是服务端 CWD 候选单独立 BUG 先修；二是 loader 同时提供 tryLoad（返回 null）和 load（抛错）两种入口，哪个库用哪种由 spec 的 required 字段决定，不由各包自行选择。

## rust-ffi-core-crate

**每个 Rust crate 各写一套 C ABI 约定：状态码编号冲突、四种报错通道、guard/free_bytes 复制，web_core 和 p2p 没有 ABI 握手**

- 类型：缺单一登记源；规模 L；价值 high；改持久化 / wire
- 核验：成立

证据：

- native/fushi_compute/src/lib.rs:60-75 定义 -4=BUFFER_TOO_SMALL、-5=IO_ERROR；native/fushi_corpus/src/lib.rs:37-48 定义 -4=IO；native/fushi_music/src/lib.rs:49-62 跳过 -4，-5=NOT_FOUND、-7=IO_FAILED；packages/fushi_srs/lib/src/store/srs_core.dart:306-309 里 fsrs 的 -4 又是 STORE_NOT_MIGRATED
- native/fushi_compute/src/lib.rs:80-105 与 native/fushi_corpus/src/lib.rs:51-97 的 guard、hand_over_bytes、free_bytes 逐字相同；fsrs lib.rs:914、music lib.rs:109、rwkv lib.rs:1961、web_core ffi_util.rs:91 各有一份 free_bytes
- 报错通道四套：compute/corpus/music 只回状态码；fsrs 用 `set_error(error_out: *mut *mut c_char)`（native/fushi_fsrs/src/lib.rs:922）加 JSON `{"error":..}`（lib.rs:10）；rwkv（lib.rs:1310 guarded + frwkv_last_error）和 web_core（ffi_util.rs set_last_error/fwc_last_error）用线程局部 last_error；p2p 用 guard_json 的 JSON 信封（native/fushi_p2p/src/lib.rs:616）
- 导出清单：web_core 只有 fwc_version，p2p 只有 fp2p_version，都没有 *_abi_version，所以 Dart 端无法做版本握手
- Dart 侧各自镜像一份状态码：FfcStatus（fushi_compute_library.dart:11-20）、FcorpStatus（fushi_corpus_library.dart:11-18）、music 的状态类（fushi_music_library.dart:12-26）

机制：没有共用的 Rust FFI 基础 crate，也没有 workspace，每个新 crate 从邻居那里复制样板、按需改编号。状态码和错误形状属于跨边界契约，却由 Rust、Dart 两头各手写一份，没有任何东西把它们绑在一起。缺 abi_version 的 crate 遇到旧库时只能靠缺符号碰运气发现。

根本方案：新建 `native/fushi_ffi_core`（rlib，零外部依赖）。内容：`#[repr(i32)] enum FfiStatus` 统一公共段编号（0、-1 NullArg、-2 InvalidArg、-3 BadInput、-4 BufferTooSmall、-5 Io、-6 Cancelled、-100 Panic），crate 专属码只能放在各自分配的号段（例如 fsrs -1000..-1099）；`OwnedBytes`（into_raw/free）；`ffi_guard(|| -> Result<T, FfiError>)` 统一 catch_unwind 并写线程局部 last_error，last_error 统一是结构化 JSON `{kind, message, data}`；宏 `fushi_ffi_exports!(prefix, ABI_VERSION)` 生成 `<p>_abi_version / <p>_free_bytes / <p>_free_string / <p>_last_error`。所有 crate 改为依赖它，删掉各自的 status 模块和样板；web_core、p2p 补上 abi_version。Dart 侧在 fushi_native 里只放一份 `FfiStatus` 和 `NativeError.decode(lastErrorJson)`，状态码常量从 Rust 生成（build script 输出 json 或 dart 片段），删掉 FfcStatus/FcorpStatus/... 这些镜像。以后新增导出函数只写业务体，报错统一走 FfiError。

要动：native/fushi_ffi_core(新)；native/fushi_compute/src/lib.rs；native/fushi_corpus/src/lib.rs；native/fushi_music/src/lib.rs；native/fushi_fsrs/src/lib.rs；native/fushi_rwkv/src/lib.rs；native/fushi_web_core/src/ffi_util.rs；native/fushi_p2p/src/lib.rs；packages/fushi_*/lib/src/*_library.dart

核验说明：状态码冲突、四套报错通道、web_core/p2p 缺 abi_version，这几点都和证据一致（web_core/src、p2p/src 里 grep abi_version 为空）。iOS 伞形库按 crate 名重新导出，正是为了绕开同名符号，也从侧面说明了这个问题。

方案风险：changesPersistenceOrWire 标成 true 夸大了：C ABI 只在同一个包内部使用，Dart 和 Rust 一起发布，不存在跨版本兼容问题。真正的约束是每改一个 crate 都要 bump abi_version，并同步改 Dart 侧映射。fushi_ffi_core 的宏生成 <p>_free_bytes 这类带前缀的符号，在伞形单库里不会重名，这点可行。

## ffi-async-per-call-isolate

**后台执行每个包各搞一套：要么每次调用起一个新 isolate 并重新加载库，要么手写长驻 worker 协议；只有 compute 有原生线程经 DartPort 回发**

- 类型：性能；规模 L；价值 medium；不改外部行为
- 核验：部分成立

证据：

- packages/fushi_music/lib/src/lyrics_ffi.dart:384-397 注释写明「每次调用在 Isolate.run 里加载库并执行」，parse、embedded、assRaw 各起一个 isolate
- fushi/lib/src/corpus/library_corpus_service.dart:123 与 :290-293、:336：一次例句搜索先起一个 Isolate.run 做词形归一，再起一个 Isolate.run 并在里面 `FushiCorpusIndex.attach(address)` 查询，每次搜索两个 isolate
- packages/fushi_web_core/lib/src/adblock/adblock_core.dart:321、comic_ad/comic_ad_detector.dart:127、article/web_novel_session.dart:350 也是每次调用 Isolate.run
- packages/fushi_rwkv/lib/src/rwkv_worker.dart:34/:358、rwkv_sched.dart:395/:532、packages/fushi_music/lib/src/music_scanner.dart:212-213/:291/:517-518/:605 各自手写 ReceivePort 命令和响应协议
- native/fushi_compute/src/dart_port.rs:1-16 已经实现「原生线程 → Dart_PostCObject → ReceivePort」，正是为 BUG-5413（NativeCallable.listener 在 isolate 销毁后被回调导致进程 abort）写的根因方案，但只存在于 compute；BUG-4730、BUG-3003 是同一类回调生命周期问题

机制：规则写的是「>1 ms 的调用放后台 isolate」，每个包就各自用最直接的办法 Isolate.run 落地：新 isolate 冷启动、重新 DynamicLibrary.open 并做 ABI 校验、结果整份复制回主 isolate。长驻任务则每个包手写消息协议。Rust 自己持有状态和线程的胖核心形态，在 FFI 层没有一个共用的异步完成通道。

根本方案：把 dart_port.rs 提进 fushi_ffi_core，做成通用异步执行层：每个库导出 `<p>_submit(cmd_ptr, cmd_len, port, out_job_id)` 和 `<p>_cancel(job_id)`；原生侧用进程级线程池执行，完成后经 Dart_PostCObject 把结果作为 external typed data（带 finalizer 释放）发到端口；isolate 销毁时 post 失败，结果直接丢弃，不会回调已释放的对象。Dart 侧在 fushi_native 里放一个 `NativeJobChannel`（每个库一个 ReceivePort，Future 按 job_id 完成），取代 FushiLyricsAsync、corpus 的 `_inIsolate`、web_core 的 Isolate.run 包装，以及 rwkv_worker/rwkv_sched/music_scanner 的手写协议（进度事件走同一端口的 event 帧）。加守卫禁止 packages/fushi_* 里直接用 Isolate.run 包 FFI 调用。性能结论是按代码路径推断的（isolate 冷启动、库重载、结果复制），没有实测；落地前建议先在 corpus 搜索和歌词解析上量一次单次延迟作为基线。

要动：native/fushi_ffi_core；native/fushi_compute/src/dart_port.rs；native/fushi_music；native/fushi_corpus；native/fushi_web_core；native/fushi_rwkv；packages/fushi_music/lib/src/lyrics_ffi.dart；packages/fushi_music/lib/src/music_scanner.dart；packages/fushi_rwkv/lib/src/rwkv_worker.dart；packages/fushi_rwkv/lib/src/rwkv_sched.dart；fushi/lib/src/corpus/library_corpus_service.dart；packages/fushi_web_core/lib/src/**

核验说明：写法确实不统一：lyrics_ffi.dart:384-397 每次调用都 Isolate.run，library_corpus_service.dart:123、275、293、547 有多处 Isolate.run 加 attach。但性能论断不成立：Isolate.run 起的 isolate 在同一个 isolate group 里，启动很轻；对已加载的库再 dlopen 只是增加引用计数，ABI 校验也只是一次调用。所谓「冷启动、重载库」的开销没有实测，审计自己也承认。

方案风险：rwkv_sched、music_scanner 是有状态的长驻任务，带取消和进度，整体换成 submit/cancel 范围很大，而且要在 Rust 侧重做调度。如果用守卫禁止所有 Isolate.run 包 FFI，会碰到纯 Dart 预处理（比如词形归一）。DartPort 的跨 isolate 生命周期也只在 compute 上验证过。

修正后的方案（以此为准）：先拿 corpus 搜索和歌词解析量出基线。真正收益明确的是把 dart_port.rs 提进 fushi_ffi_core，作为长驻、带回调的库（rwkv、music_scanner）唯一的回调通道，用来根治 BUG-5413 / 4730 / 3003 这一类问题。短调用的 Isolate.run 没有实测证据之前不动。

## fsrs-error-by-regex

**fsrs 的类型化错误靠 Dart 正则匹配 Rust 英文报错文本来分类，还要从报错字符串里截一段 JSON 出来解析**

- 类型：成类 bug；规模 M；价值 medium；改持久化 / wire
- 核验：成立

证据：

- packages/fushi_srs/lib/src/store/srs_core.dart:39-46 `SrsCoreException.of` 按顺序试 6 个 tryParse
- srs_core.dart:63-72 用正则 `^gen4: not wired yet: ...` 对应 native/fushi_fsrs/src/store/gen4/kernel.rs:57 的 `UNWIRED` 文本
- srs_core.dart:166-170 注释写着「改内核那句要同步改这里」，用 `message.contains('op too large: ')` 判断，对应 native/fushi_fsrs/src/gen4/op.rs:114
- srs_core.dart:310-321 `SrsStoreNotMigrated._parse` 从报错文本第一个 `{` 开始 jsonDecode 尾部，依赖「前面的说明文字里没有 `{`」
- native/fushi_fsrs/src/lib.rs:10 规定响应只能是 `{"error": "<原因>"}` 字符串，没有 kind 字段

机制：Rust 端明明有类型化的错误，过 FFI 时被压成一个字符串，Dart 只好按文本反推类型。Rust 改一句英文、加个前缀或冒号，Dart 端就静默退化成普通 SrsCoreException，界面失去专门提示，编译和测试都不会报。这里是推断风险，没在 docs/bugs 里找到已发生的漂移记录。

根本方案：Rust 侧定义 `enum KernelError { Unwired{op,owner}, Removed{..}, ProfileUnbound{..}, ReadOnly, OpTooLarge{..}, StoreNotMigrated{state,failure}, Migrating, LegacyUnmigrated, Other(String) }`，serde 序列化成 `{"error":{"kind":"unwired","op":..,"owner":..,"message":..}}`，直接复用 fushi_ffi_core 的结构化错误形状。Dart 侧用 sealed class 按 kind 的 switch 解码（kind 列表由 Rust 生成或用一份共享 json 契约测试锁住），删掉 6 个 tryParse、正则和截字符串解析 JSON 的逻辑。以后新增错误类型只在 Rust enum 加一个变体、Dart sealed class 加一个分支，switch 不完整时编译期就报错。

要动：native/fushi_fsrs/src/lib.rs；native/fushi_fsrs/src/store/ffi.rs；native/fushi_fsrs/src/store/gen4/kernel.rs；native/fushi_fsrs/src/gen4/op.rs；packages/fushi_srs/lib/src/store/srs_core.dart；fushi/lib/src/srs/srs_action_error_text.dart

核验说明：srs_core.dart:39-46 的 tryParse 链、:63-72 的正则、:166-170 的 contains('op too large: ')，以及「改内核那句要同步改这里」的注释都属实。packages/fushi_srs/test/store/srs_core_test.dart 里锁了这些文本，可以减轻风险，但这是靠测试去兜一个本该由契约保证的东西。

方案风险：changesPersistenceOrWire 同样只涉及包内的 FFI 形状。ffsrs 的 JSON 响应如果还被 fushi_server / ctl 路由透传给外部客户端（这一点我没查），改变 error 字段的形状就会影响外部 wire。建议保留 error 的字符串 message，另加 kind 字段，做向后兼容。

修正后的方案（以此为准）：把 Rust 响应改成 {"error":"<message>","kind":"unwired",...} 这种加字段的形式，不把 error 从字符串改成对象，以免 server 和 ctl 透传出去的消费方坏掉。

## build-script-matrix

**构建脚本按「crate × 平台」复制约 45 份，6 份 verify_abi.sh 能力和阈值已走样，p2p/web_core 的单独 iOS 脚本已是死代码**

- 类型：缺单一登记源；规模 L；价值 medium；不改外部行为
- 核验：部分成立

证据：

- native/fushi_compute/build_windows_dll.ps1 与 native/fushi_corpus/build_windows_dll.ps1 把 crate 名替换掉后 diff 为空；compute/corpus/music/p2p/web_core 的这份脚本都是 31 行，build_android_so.sh 都是 32 行
- verify_abi.sh 的哨兵阈值手写且各不相同：compute:36 是 135、corpus:36 是 12、fsrs:41 是 35、music:45 是 7、p2p:32 是 8、web_core:33 是 20
- native/fushi_corpus/verify_abi.sh 支持 ar 静态库，并带 Xcode nm 读不了 bitcode 时的退出码修正（BUG-3427 时补的）；native/fushi_web_core/verify_abi.sh 只认 ELF/Mach-O、期望集只扫单个 bindings 文件；修复只进了部分副本
- native/fushi_p2p/build_ios_staticlib.sh:6-7 和 native/fushi_web_core/build_ios_staticlib.sh:6-7 自己写着「app 已不接这份」，iOS 只走 native/fushi_ios_umbrella/build_ios_staticlib.sh
- native/fushi_ios_umbrella/Cargo.toml 的 [profile.release.package.*] 手抄了 fsrs/compute/rwkv/brotli/rav1d 的 opt-level（注释写着「依赖 crate 的 [profile] 在这里不生效，只能由根 crate 按包覆盖」），与各 crate 自己 Cargo.toml 的同名设置是两份真相

机制：没有 Cargo workspace，也没有参数化的构建驱动，每个新 crate 把邻居的五份脚本和 verify_abi 复制过来改名。修复（strip 绕行、nm 退出码、ar 支持）只落在当时出问题的那份。profile 因为没有 workspace，只能在伞形 crate 再抄一遍。

根本方案：1) 建 `native/Cargo.toml` workspace 覆盖全部 Rust crate，用一份 Cargo.lock，`[profile.*]` 和按包的 opt-level 只在 workspace 根写一次，伞形库和单独构建共用。每个 worktree 仍是一个 target 目录，符合 CLAUDE.md。2) 用 `tool/native/build.sh|ps1 --crate <name> --target <windows|linux|macos|android|ios>` 取代全部 native/fushi_*/build_*，参数和产物名取自 crates.toml。3) 用 `tool/native/verify_abi.sh --crate <name> <binary>` 取代 6 份 verify_abi：期望集来自绑定扫描，哨兵下界改成从 Rust 源码里 `extern "C" fn <prefix>_` 的计数自动算出，不再手写。4) 删掉 p2p/web_core/fsrs 的单独 iOS staticlib 脚本和对应文档段（docs/agent/build.md:119）。以后新增 crate 不写任何脚本。

要动：native/Cargo.toml(新 workspace)；native/fushi_*/build_*；native/fushi_*/verify_abi.sh；native/fushi_ios_umbrella/Cargo.toml；native/fushi_p2p/build_ios_staticlib.sh；native/fushi_web_core/build_ios_staticlib.sh；native/fushi_fsrs/build_ios_staticlib.sh；tool/native_libs.ps1；.github/workflows/*.yml；docs/agent/build.md

核验说明：复制属实：p2p 的 build_ios_staticlib.sh:6 自己写着「app 已不接这份」，verify_abi 的阈值各不相同（compute:36 是 135）。但说阈值「走样」是误读：compute/verify_abi.sh:33 写明，下界是「Dart 绑定里已知必有的符号数」，作用是发现正则解析塌掉，本来就该各不相同。

方案风险：1) 方案要把下界改成从 Rust extern 的计数自动算，这是错的：Dart 只绑定其中一部分，Rust 导出数大于绑定数，会让哨兵失去意义。2) 合成单一 workspace 加一份 Cargo.lock，会让各 crate 的依赖版本被迫统一（fsrs、rwkv 的重依赖可能互相冲突），而且 native_libs.ps1 按 crate 源码树算的复用缓存键会因为共用 lock 一起失效。3) AGPL 的 rwkv 进同一个 workspace 不影响许可，但要注意 workspace 的 features 统一合并。

修正后的方案（以此为准）：参数化的构建和 verify 驱动可以做，删掉死掉的单独 iOS 脚本也可以做。哨兵下界维持「绑定解析塌缩检测」的语义，可以改成按绑定文件实际计数加一个塌缩比例来判断。workspace 要先评估依赖冲突和缓存键怎么迁移，再决定做不做。

## single-native-cdylib

**iOS 已把全部 Rust crate 合成一个库，其余四端仍是 7 个独立 cdylib，各带一份 std 和重复依赖、各自加载和握手**

- 类型：其他；规模 XL；价值 medium；不改外部行为
- 核验：部分成立

证据：

- native/fushi_ios_umbrella/Cargo.toml 注释写明「每个 Rust staticlib 都自带一整份 std / core / alloc……合成一个 crate 编译，std 只有一份」
- native/fushi_ios_umbrella/src/lib.rs:19-36 为了避开 7 个 crate 的 ABI_VERSION/status 重名，专门改成按 crate 名重新导出
- serde/serde_json 在 fsrs、music、rwkv、web_core、p2p 的 Cargo.toml 中各声明一次，10 份独立 Cargo.lock 各自解析版本（各 crate 根目录的 Cargo.lock）
- Dart 侧桌面和 Android 每个库单独 DynamicLibrary.open 并做 ABI 校验，iOS 走同一个 process()，两种形态各要测一遍（见 dart-native-loader-dup 一条的证据）

机制：crate 是按功能陆续加进来的，每次都照前一个 crate 出一个独立 cdylib；iOS 是被链接器重复符号逼着才合并的，其他平台没有同样的强制力，于是出现两种部署形态。体积和加载开销是按结构推断的，本 worktree 没有 prebuilt，未实测。

根本方案：把伞形 crate 推广成全平台的 `fushi_native` 单库（crate-type 同时出 cdylib 和 staticlib），用 cargo feature 按消费方裁剪：app 全开；fushi_server 只开它实际用到的 fsrs/compute/music/p2p/corpus，不带 rwkv，避免 AGPL 网络条款传染到服务端。效果：五端只加载 1 个库、做 1 次 ABI 握手，crates.toml 里 crate 的平台登记变成 feature 登记，CMake/gradle/bundle 只处理一个产物。代价：单库重编时间变长（可用 workspace 增量和 quick profile 缓解），许可边界改由 feature 守住，需要一条守卫断言服务端产物里没有 frwkv_* 符号。会影响许可结构和部署形态，按 CLAUDE.md 应先交拍板台由用户决定。

要动：native/fushi_ios_umbrella(改名 fushi_native)；native/crates.toml；packages/fushi_native(loader)；fushi/windows/CMakeLists.txt；fushi/linux/CMakeLists.txt；fushi/android/app/build.gradle；fushi/macos/*；packages/fushi_server/tool/*

核验说明：现状描述属实：iOS 用伞形库，其余端是独立 cdylib，Cargo.lock 也各管各的。收益（体积、加载开销）是推断，没有实测。审计自己也认定这一条要先上拍板台。

方案风险：把 rwkv（AGPL，见 Cargo.toml:10）合进桌面和 Android 的单库后，整个 app 的原生库都要按 AGPL 对待，这是许可结构的变化。只编一个库会拖慢「编译—测试」循环，也会让 native_libs.ps1 按 crate 复用产物的机制失效。所有 crate 必须同时被 Dart 视为可用，和 copy-if-present 的 optional 语义冲突。

修正后的方案（以此为准）：不作为默认方向推进，只写进拍板台：列出许可影响、构建时间和缓存失效，配上实测的体积和加载数据，由用户决定。

## ffi-marshalling-boilerplate

**FFI 调用点手写「calloc 入参、拷贝、出参 ptr/len、状态判断、freeBytes」样板 100 多处，每次调用都重新分配内存；复用暂存区只有 compute 一家**

- 类型：缺单一登记源；规模 M；价值 low；不改外部行为
- 核验：部分成立

证据：

- `asTypedListOutOfLine(..).setAll(0` 在 packages/*/lib 里有 106 处、分布在 40 个文件（rg 计数），每处都是先 calloc 再把 Dart 字节拷进去
- packages/fushi_compute/lib/src/text/legacy_text.dart:100-125 是典型样板：calloc 入参、出参指针、出参长度三个分配，status 不为 ok 就 StateError，套 try/finally，再 freeBytes
- packages/fushi_compute/lib/src/native_scratch.dart:6-20 注释记了实测「每次新 malloc 几 MB……600 条字幕合成里这部分占了一半时间」，于是做了每 isolate 一份的复用暂存区，但只在 fushi_compute 内部用
- calloc.free/malloc.free 计数：fushidicts.dart 40 处、fushi_compute_image.dart 36 处、ffi_fsrs_engine.dart 21 处……每个包各自管理

机制：没有共用的 Dart FFI 调用辅助层，每个绑定函数手写内存编组。已经实测有效的优化（NativeScratch）被锁在单个包里，其他包看不到也用不上；生命周期规则靠 native_lifetime_guard_test 这类守卫在事后兜底。

根本方案：把 NativeScratch 搬进 fushi_native，作为共用的 `NativeCallScope`：每 isolate 一份可增长的入参暂存区、固定的出参 ptr/len 槽，`callBytes(fn, Uint8List input) → Uint8List`（内部统一做状态到 NativeError 的映射和 freeBytes），再加 `callJson` 和 `callStatus` 两个变体。短小、确定的调用标成 `isLeaf: true`，入参直接传 TypedData，省掉拷贝（长调用不能用 leaf，否则会挡住 isolate group 的 GC safepoint）。各包绑定改成一行调用，删掉手写的 calloc/try/finally，lifetime 守卫也就只需盯这一个文件。

要动：packages/fushi_ffi_view(fushi_native)；packages/fushi_compute/lib/src/native_scratch.dart；packages/fushi_compute/lib/src/**；packages/fushi_music/lib/src/**；packages/fushi_srs/lib/src/ffi/ffi_fsrs_engine.dart；packages/fushi_dictionary/lib/src/engine/fushidicts.dart；packages/fushi_web_core/lib/src/**

核验说明：样板确实很多。NativeScratch 在 compute 里有实测收益（native_scratch.dart:6-20），但那是几 MB 级的大入参场景，推广到所有调用点的收益没有依据。

方案风险：每 isolate 一份共用的暂存区，在调用会重入的情况下（回调里再调 FFI），或结果引用暂存区内存时，会出现别名 bug。isLeaf 直接传 TypedData 要求调用不回调、不阻塞，必须逐个函数审查，不能批量打标。

修正后的方案（以此为准）：共用 callBytes/callJson 辅助层可以做；NativeScratch 只给大入参的路径显式选用，不当作默认。

## 核验补充（审计漏掉的）

- 安全问题，应立即按 bug 流程修，不要等重构：packages/fushi_server/lib/src/native_libs.dart:23 的候选路径带 Directory.current。服务端从启动目录加载同名 dll/so，就是 fushi_compute_library.dart:121-123 自己写明要防的投毒面。
- 硬规则冲突：docs/agent/build.md:127 规定 fsrs 是 copy-if-present，fushi/windows/CMakeLists.txt:198-204 和 android build.gradle:206-209 都照此实现，fsrs_library.dart:65-74 用 isAvailable 返回 null 作为降级。这和 CLAUDE.md「原生库是硬依赖、不留回退」直接冲突，应写进拍板台，不由重构顺手决定。
- 审计只对着 Rust 写了 abi_version 的要求，漏了 C++ 模块（fushidicts、fushi_torrent）的 ABI 握手和统一加载。它们的 Dart 加载点（例如 packages/fushi_server/lib/src/dictionary_host.dart:873-884 的 resolver）也在 68 处非测试代码的 DynamicLibrary.open 之列，loader 统一的范围要包括它们。
