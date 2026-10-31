# fushi_fsrs

Fushi SRS（间隔重复）的排程内核：[fsrs-rs](https://github.com/open-spaced-repetition/fsrs-rs)
的薄 C ABI，给 Dart FFI（`packages/fushi_srs/lib/src/ffi/`，纯 Dart，无 Flutter / 插件依赖）用。
五个平台 app 与无头服务端都调这一份 Rust，不维护第二套公式。设计见
`docs/specs/2026-10-14-fushi-srs-design.md`。

## C ABI

| 符号 | 作用 |
|---|---|
| `ffsrs_call(const char*) -> char*` | 请求 JSON → 响应 JSON，按 `op` 分派（见下） |
| `ffsrs_fit(const char* req, const u8* ratings, const float* delta_days, usize n_reviews, const u32* card_offsets, const i64* card_ids, usize n_cards, const u32* item_cards, const u32* item_lengths, usize n_items, AtomicI32* cancel, AtomicI64* progress[2]) -> char*` | 参数优化 / 评估，阻塞；`req` 是 `{"op","algorithm","params"?}`（op：`compute_parameters` / `evaluate` / `evaluate_tss`）；训练集打包传（见下）；`card_ids` 可空，只给参数优化用；`cancel` 写非 0 即取消，`progress` 持续写 `[已处理, 总数]`，两者可空 |
| `ffsrs_retrievability_batch(const char* model, const float* s, const float* d, const float* sf, const float* elapsed, usize n, float* out) -> char*` | 同一组参数下批量算可提取度（统计页）：`model` 是 `{"algorithm","params"}`，四个输入数组与 `out` 长度均为 `n`，`sf` 可空（取 `s`）；返回 `{"ok":n}` / `{"error"}`，结果与逐张调 `retrievability` op 逐位一致 |
| `ffsrs_free_string(char*)` | 释放上面三个返回的串 |
| `ffsrs_zstd_decompress(const u8*, usize, usize* out_len) -> u8*` | zstd 解码（.apkg 新格式），失败返回 NULL |
| `ffsrs_free_bytes(u8*, usize)` | 释放解码缓冲区 |
| `ffsrs_abi_version() -> i32` | ABI 版本（当前 2）；Dart 侧不一致即判不可用 |
| `ffsrs_boot_time_ms() -> i64` | 自本次开机以来的毫秒，含睡眠、不受改系统时间影响（Linux / Android `CLOCK_BOOTTIME`、Apple `CLOCK_MONOTONIC`、Windows `GetTickCount64`；见 `src/boot_clock.rs`）；取不到返回 -1。SRS 可信时间按它推算 |
| `ffsrs_search_corpus_new(const u8* text, usize, const u32* layout, usize, char** err) -> Corpus*` | Anki 搜索语料的结构：笔记类型 / 字段名 / 标签 / 牌组 / 模板名（UTF-8 拼接）与字段排布（u32 布局，见 `src/search.rs` `Corpus::new`），**不含字段值**；失败返回 NULL 并在 `err`（可空）写错误串。句柄内部带锁，可跨线程调用 |
| `ffsrs_search_corpus_free(Corpus*)` | 释放语料（Dart 侧挂在 `NativeFinalizer` 上） |
| `ffsrs_search_corpus_needs(const Corpus*, const char* query) -> char*` | 一条查询要哪些字段值：`{"ok":{"all":true}}`（未限定字段的文本 / `re:`）或 `{"ok":{"all":false,"names":[字段名 id…]}}`；查询不合法时与 match 同形报错。只读建语料时定死的字段名表、**不拿语料锁**：另一线程上的 match 正在求值（持锁）时也立即返回 |
| `ffsrs_search_chunk_new(const u8*, usize) -> Chunk*` / `ffsrs_search_chunk_free(Chunk*)` | 校验并拷下一块字段值文本（UTF-8），不碰语料，任意线程可调（Dart 在编码用的后台 isolate 里调） |
| `ffsrs_search_corpus_attach(const Corpus*, Chunk*, const u32* fields, usize n, const u32* spans) -> i32` | 把文本块挂进语料：第 k 个值 = `chunk[spans[2k]..spans[2k+1]]`，属于字段 `fields[k]`；块的所有权无论成败都转走；成功 0 |
| `ffsrs_search_corpus_set_ints / _set_floats(Corpus*, i32 col, const i64*/const f64*, usize n) -> i32` | 卡片数值列（状态位、id、日序号、间隔、到期、复习 / 遗忘次数；稳定性 / 难度，NaN = 无），查询用到才传；成功 0 |
| `ffsrs_search_corpus_match(const Corpus*, const char* query, u8* out, usize n) -> char*` | 整批求值一条搜索（语法树 JSON，由 Dart 解析器产出）：`out[i]` 写 1 / 0；返回 `{"ok":命中数}` / `{"error","kind":"syntax"\|"internal","at"}`。最近一次结果缓存在句柄里（语料一改就清），后台 isolate 预求值后 UI isolate 再调只是取结果 |
| `ffsrs_search_dupe_norm_batch(const u8*, usize, const u32* offs, usize n, usize* out_len) -> u8*` | AnkiConnect 查重的首字段规范形（样式去重 → 去 HTML → trim），批量；返回 `[u32 LE 偏移 × (n+1)][UTF-8]`，用 `ffsrs_free_bytes` 释放 |
| `ffsrs_history_states(const u8* text, usize, const u32* offs, const i64* servers, usize n_logs, const u32* groups, usize n_groups, usize* out_len, char** err) -> u8*` | 卡片历史内核（`src/history.rs`）：落库日志原文 + 服务器时刻 → 每份历史的当前排程状态（定长记录 + 串表），批量；失败返回 NULL 并写 `err` |
| `ffsrs_history_select(const i64* ints, usize n_logs, const u8* text, usize, const u32* offs, const u32* groups, usize n_groups, usize* out_len, char** err) -> u8*` | 卡片历史内核（列模式）：排序与每条日志的选取标记（有效 / 撤销 / 等价导入 / 撤销者 / 排序键被钳位），批量 |
| `ffsrs_import_equivalent(const u8* text, usize, const u32* offs, usize n_logs, const u32* groups, usize n_groups, usize* out_len, char** err) -> u8*` | Anki 导入器入库前判重：每组（导入日志, 原生日志…）的落库 JSON → 每组一个字节；判据与卡片历史的等价导入是同一个函数 |
| `ffsrs_materialize(const u8* header, usize, const u8* text, usize, const u32* offs, const i64* servers, usize n_items, usize* out_len, char** err) -> u8*` | 字段寄存器内核（`src/registers.rs`）：组描述 JSON + 修改记录落库原文 / 服务器时刻 → 寄存器（支配、排序键、冲突候选、删除优先）与笔记 / 卡片标志（按前身血统继承）/ 笔记类型 / 牌组的物化视图，以及落库支配裁剪、no-op 的「值相同」；结果是 JSON，批量。排序键（`src/ordering.rs`）与释义样式去重规范形（`src/style_dedup.rs`）与卡片历史 / 查重共用一份 |
| `ffsrs_memory_input(const i64* ints, usize n_logs, i32 alg, i32 utc_offset_min, i32 rollover_hour, usize* out_len, char** err) -> u8*` | 记忆状态输入（铁律 A，`src/projection.rs` `memory_input`，排程用）：一份历史的有效日志（列模式，每条 14 个 i64，已排序）→ 评审序列（rating, 小数 / 整数天）与起点（同算法记忆状态 / SM-2 换算）、是否完整；`alg` 0 fsrs6 / 1 fsrs7 / 2 rwkv。与优化器直读命令同一个函数 |
| `ffsrs_rwkv_now_rows(const i64* ints, usize n_rows, i32 utc_offset_min, i32 rollover_hour, usize* out_len, char** err) -> u8*` | RWKV「此刻」行（ease 0，RWKV-Instant 排队 / 作答）：每行 9 个 i64（四个数字 id、最后保留评分、队列、此刻）→ 80 字节 `FrwkvReview`（packages/fushi_rwkv `RwkvRows` 布局；本库不链接 RWKV）|
| `ffsrs_store_open(const u8* path, usize, SrsCore** out, char** err) -> i32` / `ffsrs_store_close(SrsCore*)` | 打开 / 关闭 Rust 独占的 `srs.db`（`src/store/`，rusqlite bundled；设计 `docs/specs/2026-10-23-srs-rust-store.md`）。一条写连接 + 一条读连接，WAL；只开 srs.db，绝不开主库 |
| `ffsrs_store_exec` / `ffsrs_store_exec_batch` / `ffsrs_store_in_transaction` | Drift 执行器后端：写连接上执行语句（行页编码见 `src/store/rows.rs`）|
| `ffsrs_store_history_states(SrsCore*, const u8* groups, usize, usize n_groups, u8** out, usize*, char**) -> i32` | 缓存刷新：Rust 在写连接上直读日志 + 服务器时刻并选取（含事务里未提交的行），输出布局同 `ffsrs_history_states` |
| `ffsrs_store_optimizer_items(SrsCore*, const u8* page, usize, const i64* args, usize, u8** out, usize*, char**) -> i32` | 优化器训练集（P6，`src/store/projections.rs`）：读连接上一个读事务里直读血统的日志 + 服务器时刻，选取、记忆状态输入、「时间不确定」过滤，输出列式训练集（序列 + 前缀条目，按评分时刻排序）。`page` 两列 `[下标, 文本]`（g ≥ 0 血统里的卡，-1 profile），`args = [n, alg, utcOffsetMin, rolloverHour, 卡数字 id × n]` |
| `ffsrs_store_rwkv_rows` | RWKV 回放行（P6）：mode 0 逐卡（保留评分行、日志 ID、有效评分数、最后保留评分），mode 1 全量回放（本 profile 日志一条语句扫出，指纹与行同一快照，按评分时刻稳定排序，另报列卡之后才出现的「漏卡」）；签名同上，`args = [n, mode, utcOffsetMin, rolloverHour, since, 数字 id × 4n]` |
| `ffsrs_store_rwkv_log_tail` | RWKV 对齐：本 profile 日志的 (行数, 最大 rowid, since 之后的行数)，可选连同这些新行（id / 卡 / kind（review / undo / 其它）/ 撤销目标 / 时刻）；签名同上，`args = [since, with_rows, incremental?]`，incremental 时只数 since 之后的行（O(新增)） |
| `ffsrs_store_stat_projection` | 有效复习投影（`srs_stat_reviews` 的行）：写连接直读日志，一批归属组（归属卡 + 归它的前身卡）一次调用，按合并历史投影，回 9 列行页 |
| `ffsrs_store_legacy_state` / `_legacy_begin` / `_legacy_page` / `_legacy_commit` / `_legacy_abort` / `_legacy_mark_none` | 主库旧 srs_* 表的一次性搬迁（Dart 读、Rust 写，一个事务）|
| `ffsrs_store_snapshot(SrsCore*, const u8* path, usize, i32 strip_device_local, char**) -> i32` | 备份快照（`VACUUM INTO`，可清空设备本地表）|
| `ffsrs_store_debug_query` | 只读调试查询（测试 / 诊断）|
| `ffsrs_store_read_begin` / `_read_query` / `_read_end` | 只读会话：另开一条只读连接 + 一个读事务（开会话时快照即定），在里面跑只读查询（编码同 debug_query），结束回滚并关闭。备份读快照用（后台 isolate） |

响应恒为 `{"ok": …}` 或 `{"error": "…"}`；panic 一律接住转成 error，不越过 FFI。每个 op 带
`algorithm`（`"fsrs6"` 21 参 / `"fsrs7"` 34 参），`params` 空或缺省 = 该算法默认参数；elapsed
一律**小数天**。`op`：`version` / `defaults` / `validate` / `next_states` / `memory_state` /
`memory_state_from_sm2` / `retrievability` / `next_interval`。

`ffsrs_fit` 的训练集（BUG-3745）：每张卡只传一份完整历史（`ratings` / `delta_days` 按 `card_offsets`
切段，长 `n_cards + 1`），外加按评分时刻排好序的条目 `(item_cards[i], item_lengths[i])` = 卡
`item_cards[i]` 的前 `item_lengths[i]` 次评分。fsrs-rs 的 API 收每条自带前缀的 `Vec<FSRSItem>`，前缀在
Rust 里展开：过边界与 Dart 侧都是 O(总评分数)，展开后的 O(Σ 前缀长度)（每条评分 8 字节）只在本次调用
期间存在；fsrs-rs 内部 FSRS-6 训练 / 两种评估仍逐条前缀计算，这部分计算量仍是 O(Σ 前缀长度)。
取消后返回 `{"error":"cancelled"}`。

### Anki 搜索（`src/search.rs`）

浏览页搜索、统计页筛选、AnkiConnect `findNotes` / `findCards` / 查重的逐卡求值只有这一份实现
（Dart 侧只剩解析器 `packages/fushi_srs/lib/src/search/search_parser.dart`，入口
`SrsSearchCorpus` / `srsDupeNormBatch`）。正则与去 HTML 用 `regex` crate——与 Anki 桌面版 rslib 是同一个
引擎，`re:` 的语义以它为准（与旧 Dart `RegExp` 的差异逐条钉在
`packages/fushi_srs/test/search/search_engine_differences_test.dart`）。去 HTML 是 rslib 那条正则的手写线性
扫描（测试里以原正则为对照做 30 万例随机比对）；整值通配开头 / 结尾的 `*` 不编成 `^.*` / `.*$`（dotall 下
等价），引擎直接按子串找。

首次搜索的开销几乎全在「把字段文本交给原生侧」（10 万张卡的合成集合约 290 MB），所以语料分两步装：
结构一次给齐；字段值按查询要的列上传（`needs`），只看状态 / 牌组 / 标签的查询不传文本，`字段名:值` 只传
那一列，未限定字段的文本 / `re:` 才整条笔记连续上传（同一笔记的字段隔 0x1f，`n.flds` 直接切片）。
Dart 侧 `SrsSearchCorpus.prepare` 把编码分给多个 isolate（每个 isolate 自己调 `chunk_new` 校验、拷贝），
大集合再开一个 isolate 预先求值（去 HTML 并行做），UI isolate 只剩建结构与挂块；浏览页与 AnkiConnect
走这条路。去 HTML 后的字段值惰性缓存，同一条笔记的文本条件只算一次。删旧 Dart 实现前用它生成的固定向量
（5416 条搜索式 × 230 张卡、1500 条查重输入）见 `search_parity_test.dart`，Rust 版逐位一致。

逐张走 `ffsrs_call` 的固定开销（Dart 编码请求 + serde 解析参数 + FFI 往返）约 25～30 µs/次，建模型本身
不到 1 µs；成批的计算一律走专门的批量符号，卡片数据用 f32 数组传。基准
`packages/fushi_srs/benchmark/fsrs_ffi_bench.dart`（2026-10-18 本机 Windows x64，5 万张卡）：逐张
`retrievability` FSRS-7 1529 ms / FSRS-6 1242 ms，`ffsrs_retrievability_batch` 19 ms / 16 ms。

Dart 侧：`FushiFsrs`（`fushi_fsrs_library.dart`，定位 + ABI 核对，库缺失返回 null、永不抛）、
`FushiFsrsBindings`（lookup 名写成字符串字面量，`verify_abi.sh` 从这里抓期望符号集）、
`FfiFsrsEngine implements FsrsEngine`（JSON 往返，错误转 `SrsFsrsException`）、
`NativeSrsOptimizerControl`（calloc 的 int32 取消标志 + int64[2] 进度，地址可跨 isolate 传，
另一端 `fromAddress` 包装）、`FfiFsrsEngine.zstdDecompress`。

库定位顺序（与 `packages/fushi_p2p` 一致）：显式路径（给了就只试它）→ 环境变量
`FUSHI_FSRS_LIB` → exe 同级 → `bin/../lib/<名>`（无头服务端 bundle）→ 裸名（Android APK
native lib 目录、macOS `Contents/Frameworks`、Linux `bundle/lib/`）；iOS 用
`DynamicLibrary.process()`。

## 构建

| 平台 | 命令 | 产物 | 怎么进包 |
|---|---|---|---|
| Windows x64 | `powershell -ExecutionPolicy Bypass -File native/fushi_fsrs/build_windows_dll.ps1` | `prebuilt/windows-x64/fushi_fsrs.dll` | `fushi/windows/CMakeLists.txt` copy-if-present 到 exe 同级；服务端放 `bundle/lib/` |
| Android | `build_android_so.ps1 [-NdkRoot …] [-Abis …]` / `build_android_so.sh <ndk-root> [abi…]`（cargo-ndk，API 24） | `prebuilt/android/<abi>/libfushi_fsrs.so` | `fushi/android/app/build.gradle` 的 `jniLibs.srcDirs` copy-if-present |
| Linux x64 | `build_linux_so.sh` | `prebuilt/linux-x64/libfushi_fsrs.so` | `fushi/linux/CMakeLists.txt` copy-if-present 到 `bundle/lib/`；服务端放 `bundle/lib/` |
| macOS | `build_macos_dylib.sh`（只出 arm64，部署目标 13.4） | `prebuilt/macos/libfushi_fsrs.dylib`（install name `@rpath/…`） | Runner 构建阶段「Bundle fushi_fsrs dylib」（`fushi/macos/bundle_fushi_fsrs.sh`）copy-if-present 到 `Contents/Frameworks` |
| iOS | `native/fushi_ios_umbrella/build_ios_staticlib.sh [device\|simulator\|all]`（伞形 staticlib，部署目标 15.1） | `native/fushi_ios_umbrella/prebuilt/ios/{iphoneos,iphonesimulator}/libfushi_ios_umbrella.a` + `fushi_ios_umbrella.xcconfig` | `fushi/ios/Flutter/{Debug,Release}.xcconfig` 可选 `#include?` 那份 xcconfig → Runner `OTHER_LDFLAGS` 的 `$(FUSHI_IOS_NATIVE_LDFLAGS)`（`-force_load`），见下「iOS」 |

- **缺库 = 能力不可用，不是构建失败**：五端都是「prebuilt 有则随包」，没装 Rust 的机器照常出包。
- 构建脚本只断言文件存在；`verify_abi.sh <二进制> [nm]` 按 Dart 绑定里 lookup 的 `ffsrs_*`
  名逐个核对导出表（ELF `.so` / Mach-O dylib 与可执行文件 / ar 静态库）。
- `target/`、`prebuilt/` 不入库。访问 crates.io / GitHub（fsrs-rs 是钉 rev 的 git 依赖）不稳时设
  `CARGO_HTTP_PROXY`。
- 体积（release，`opt-level="z"` + fat LTO + strip，2026-10-14 本机实测）：Windows x64 DLL
  806,912 B；Android arm64-v8a 936,848 B（NEEDED 只有 libc / libm / libdl）。2026-10-18 加 Anki 搜索
  （`regex` crate 默认特性：Unicode 表 + 字面量 / DFA 加速）后 Windows x64 DLL 2,149,376 B；正则 / 子串查找 /
本 crate 改按 `opt-level = 3` 编（见 `Cargo.toml` 的 package profile）后 2,414,592 B。

### iOS：伞形静态库

每个 Rust staticlib 都自带一整份 Rust std / core / alloc。`libfushi_p2p.a` 与 `libfushi_fsrs.a`
同时 `-force_load` 进 Runner 会撞重复符号（`rust_eh_personality`、`__rdl_alloc` …），不
`-force_load` 又会被当无用成员整个丢掉。所以 iOS 走 `native/fushi_ios_umbrella`：一个 crate
依赖两个 path crate、re-export 两边，编成**一个** staticlib，std 只有一份，同时导出
`fp2p_*`（12 个）与 `ffsrs_*`（18 个）。为此 `native/fushi_p2p/Cargo.toml` 的 crate-type 加了
`rlib`（只用来被伞形 crate 依赖，其余平台产物不变）。伞形 crate 的 `Cargo.lock` 以两个 crate
各自的锁文件合并为种子再解析：fushi_p2p 那边的版本全部保持；fushi_fsrs 那边有 7 个
semver 兼容的小版本被统一到 fushi_p2p 锁的版本（libc、serde_json、syn 3.x、unicode-ident、
zerocopy 等）。

本机（Windows）只能验证到「伞形 crate 编得过、fat LTO 后归档里两组符号都在」：
`cargo build --release --target x86_64-pc-windows-msvc` 出的 `fushi_ios_umbrella.lib` 用
llvm-nm 核对，12 个 `fp2p_*` + 7 个 `ffsrs_*` 全是 `T`（2026-10-18 加 `ffsrs_retrievability_batch` 后复核）。真 iOS 链接只能在 macOS 上验。

`native/fushi_fsrs/build_ios_staticlib.sh` 仍保留：只出单独的 `libfushi_fsrs.a` 与
`FUSHI_FSRS_LDFLAGS`，供「只要 SRS 不要 P2P」的实验构建；**不能**与 fushi_p2p 的单独 .a 同时接。

**接线**（2026-10-15 起，此前 iOS 包里没有 `ffsrs_*`，复习页恒报「排程内核不可用」）：

- `fushi/ios/Flutter/Debug.xcconfig` 与 `Release.xcconfig` 可选
  `#include? "../../../native/fushi_ios_umbrella/prebuilt/ios/fushi_ios_umbrella.xcconfig"`；
  Runner 三个配置的 `OTHER_LDFLAGS` 用 `"$(FUSHI_IOS_NATIVE_LDFLAGS)"`。没编过伞形库 → 变量为空 →
  不链接，P2P 与 SRS 复习都判不可用，Runner 照常构建。
- CI：`build-multiplatform.yml` 的 ios job 与 `release-desktop.yml` 的 iOS job 编伞形库 device 切片，
  持久库名 `ios_native`（`.github/actions/native-store-names/names.sh`，输入
  `native/fushi_ios_umbrella` + `native/fushi_p2p` + `native/fushi_fsrs`），出包后在 Runner（debug
  构建是 `Runner.debug.dylib`）上 `native/fushi_p2p/verify_abi.sh` 与本目录的 `verify_abi.sh` 都跑；
  App Store archive 同样两个都跑。

## CI

| workflow | 平台 | 做什么 |
|---|---|---|
| `build-multiplatform.yml`（PR，路径门） | Windows | 编 DLL → 跑 `packages/fushi_srs` 真 FFI 测试 → 出包后核对 bundle 里有 `fushi_fsrs.dll` |
| | macOS | 编 arm64 dylib + ABI 核对 → 出包后核对 `Contents/Frameworks` 里的 dylib（install name / 架构 / 符号 / ctypes 冒烟） |
| | iOS | 编伞形 staticlib device 切片 + 核对归档两组符号 → 链进 Runner 后再核对 Runner 两组符号 |
| | linux-server | 编 .so + ABI 核对 → 装进服务端 bundle → 拿 bundle 里那份跑真 FFI 测试 |
| `native-fsrs-gate.yml`（PR，paths） | Android 三 ABI | cargo-ndk → ELF 架构 + 符号 |
| | ubuntu | `cargo test --release --locked`（lib.rs 单元测试） |
| `release-server.yml` | Linux x64 / Windows x64 | 编 → 放 `bundle/lib/` → 拿 bundle 里那份跑真 FFI 测试 |

真 FFI 测试在库加载失败时整组 skip 且退出码 0，所以 CI 额外断言输出里没有
`native library not found`。路径门正则（`changes` job）已把 `native/fushi_fsrs/`、
`packages/fushi_srs/` 路由给四个平台 job、`native/fushi_ios_umbrella/` 路由给 iOS，守卫
`fushi/test/build/multiplatform_pr_gating_guard_test.dart`。

`release.yml`（Android APK）与 `release-desktop.yml`（Windows / macOS / iOS，iOS 走伞形库）
的发布包都随带 fushi_fsrs，出包后逐一核对。
fushi_fsrs 编译只要约 20 s（本机，热缓存），没进 native-artifact-store。

## 测试

```
FUSHI_FSRS_LIB=<绝对路径>/fushi_fsrs.dll dart test test/ffi_fsrs_engine_test.dart   # 在 packages/fushi_srs 下
```

不设环境变量时测试按平台找本目录 `prebuilt/` 下的产物。覆盖：默认参数 21 / 34、参数校验
（个数错、FSRS-6/7 参数互换、NaN）、next_states 按评分单调、FSRS-7 小数天敏感、由历史重建
记忆状态、SM-2 换算、可提取度衰减、两种算法在合成数据上的参数优化、从另一个 isolate 在进度
> 0 后取消、外样本 / 训练集内评估、zstd 解码（预生成帧）与坏帧返回 null。库缺失时整组 skip。
Rust 侧单元测试：`cargo test --release`（本目录）。

`packages/fushi_srs/test/search/`、`packages/fushi_engine/test/srs/`（浏览 / 统计 / AnkiConnect）与主应用
`fushi/test/srs/srs_browse_page_test.dart` 的搜索测试同样要真实库，但**加载失败直接判红、不 skip**：搜索没有
Dart 回退，skip 会把「搜索整个不可用」显示成绿。CI 的包测试与主应用单测（`main.yml` 的 build / unit-tests、
`release.yml` 的 tests 矩阵）先编 Linux `.so` 再经 `FUSHI_FSRS_LIB` 指过去；本地跑这些测试同样要设它。

## 许可

本 crate GPL-3.0-only（随 app）。依赖：fsrs-rs **BSD-3-Clause**、ruzstd **MIT**、serde /
serde_json MIT OR Apache-2.0——都可以链进 GPL-3.0 的 app 本体。BSD-3 与 MIT 要求在二进制
分发的文档里保留版权与许可声明：发版前要确认 app 的开源许可页（`fushi/assets/licenses/`
与 `LicensePage` 注册）带上 fsrs-rs 与 ruzstd 的声明。
