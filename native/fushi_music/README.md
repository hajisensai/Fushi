# fushi_music

音乐模块的 Rust 胖核心（设计：`docs/specs/2026-10-23-music-module-design.md` §4.1）。P0 只有
曲库扫描：目录遍历 + 标签 / 音频属性（[lofty](https://crates.io/crates/lofty)）+ CUE 拆轨
（整轨 `.cue`、FLAC 内嵌 `CUESHEET` 注释、FLAC 二进制 CUESHEET 块）+ 内容派生 uid。Dart 绑定在
`packages/fushi_music/`（纯 Dart，无 Flutter / 插件依赖）。

**硬依赖，没有 Dart 回退**：Dart 侧加载失败抛 `FushiMusicUnavailableError`，测试找不到库判红、
不 skip。`tool/native_libs.ps1` 负责本机备库（兄弟 worktree 同源码产物直接拷，否则 cargo 编）。

## 在线音源插件运行时（`src/plugin/`，`plugin` 特性）

QuickJS（rquickjs ≥0.14）沙箱跑用户安装的 `.fushiplug` JS 插件：包校验（`files.json` 逐文件
sha256 + 可选 Ed25519 签名）、原子安装、每次加载重新哈希、清单网络授权（默认拒绝、拒私网）、
同步 crypto / encoding 原生函数、`ffm_plugin_step` 步进式驱动（宿主调用 http / storage 交回 Dart
执行）。契约与边界见 `docs/specs/2026-10-28-music-plugins.md`，第三方开发包见 `tools/music-plugin-sdk/`；Dart 侧在
`packages/fushi_music/lib/src/plugin/`。`plugin` 是默认特性，**iOS 伞形库以
`default-features = false` 依赖本 crate，不编入 JS 引擎**（App Store 合规，守卫
`fushi/test/build/ios_store_compliance_guard_test.dart`）。rquickjs 0.9 在 CPU 预算中断后释放运行时
会触发 QuickJS 引用计数断言（实测），不要回退版本。

## ABI

| 符号 | 作用 |
|---|---|
| `ffm_abi_version() -> i32` | ABI 版本（当前 1）；批次格式变化也要升 |
| `ffm_free_bytes(u8*, usize)` | 释放本库交给调用方的缓冲区 |
| `ffm_scan_open(const u8* root, usize, u8 recursive, Scanner** out) -> i32` | 建扫描游标（根不存在 -5） |
| `ffm_scan_set_known(Scanner*, const u8*, usize) -> i32` | 已知文件清单（路径 → 修改时刻 + 大小）；没变的文件只回 `unchanged` |
| `ffm_scan_next(Scanner*, u32 max, u8** out, usize* len) -> i32` | 下一批（≤256 条，紧凑二进制，格式见 `src/wire.rs`） |
| `ffm_scan_close(Scanner*)` | 关闭游标 |
| `ffm_tags_embedded_cover(const u8* path, usize, u8** out, usize* len) -> i32` | 内嵌封面字节（没有时 len = 0） |
| `ffm_fp_version() -> u32` | 声纹算法 / 对齐判据版本（Dart 侧缓存按它失效） |
| `ffm_fp_item_ms() -> f64` | 一个声纹项的时长（≈ 123.8 ms） |
| `ffm_fp_compute(const i16* pcm, usize n, u32 rate, u32 ch, u8** out, usize* len) -> i32` | 整段交错 s16 PCM → 声纹（小端 u32 数组字节）；一集一次 |
| `ffm_fp_align(const u32* needle, usize, const u32* hay, usize, u32 min_items, FfmFpMatch* out) -> i32` | 短声纹在长声纹上滑窗对齐 → 偏移 / 起止 / 置信度（没出现 `found = 0`） |
| `ffm_fp_acoustid_encode(const u32* fp, usize n, u8** out, usize* len) -> i32` | 声纹 → AcoustID 查询串（chromaprint 压缩 + URL-safe base64，与 `fpcalc` 同形；音乐刮削 P4） |
| `ffm_tags_read_fields(const u8* path, usize, u8** out, usize* len) -> i32` | 读「写回标签」白名单字段（线格式 `src/tag_write.rs`；文件读不了 -3） |
| `ffm_tags_write_fields(const u8* path, usize, const u8* kv, usize) -> i32` | 写回白名单字段（空值 = 删除；键 / 数字非法 -2 且文件不动；写盘失败 -6） |

歌词（P1，`src/lyrics/`，详见 `src/lyrics/ffi.rs`）：

| 符号 | 作用 |
|---|---|
| `ffm_lyrics_parser_version() -> u32` | 解析器版本（`music_lyrics.timeline_version` 失效判据） |
| `ffm_lyrics_parse(const u8*, usize, const u8* hint, usize, i64 durationMs, u8**, usize*) -> i32` | 任意格式 → 统一时间轴（线格式 `src/lyrics/wire.rs`）；失败 -3，out 为错误信息 |
| `ffm_lyrics_embedded(const u8* path, usize, i64 durationMs, u8**, usize*) -> i32` | 内嵌 USLT / SYLT / Vorbis LYRICS / MP4 ©lyr |
| `ffm_lyrics_merge(primary, len, secondary, len, lang, len, u8**, usize*) -> i32` | 翻译按时间配对（≤ 300 ms） |
| `ffm_lyrics_export(timeline, len, format, len, u8**, usize*) -> i32` | 导出 `ttml` / `lrc` |

新增符号不升 `ffm_abi_version`（扫描批次格式没变）；Dart 侧按需 lookup，缺符号抛
`FushiMusicUnavailableError`。

### 与有声书 `fushi_audio` 的 `LrcParser` 的关系（2026-10-24 判断）

有声书侧 `packages/fushi_audio/lib/src/parsers/lrc_parser.dart` 继续剥词级 `<mm:ss.xx>` 标签、
产出行级 `AudioCue`，**本期不迁进本 crate**。按「Rust 胖核心」规则只认两种迁移动因，这里都不成立：
① 没有实测性能问题（剥标签已是整份一次 `stripHtmlTagsBatch` FFI）；② 有声书 cue 绑定书章节、
下游（匹配 / 对齐 / 制卡）只吃行级 cue，收编进音乐歌词核心并不减少跨边界次数，反而让
`fushi_engine` / 无头服务端（`dart build cli` 随包原生库）多一个硬依赖。真要给有声书接词级时间
时，再整段把 `LrcParser` 搬到这里（`ffm_lyrics_parse` + `LyricTimeline → AudioCue` 适配已就绪）
并删 Dart 版。音乐一律走本 crate。

状态码：0 成功；-1 空指针；-2 参数非法；-3 输入格式不对；-5 根不存在；-100 panic（已接住）。

## 声纹（`src/fingerprint.rs`）

作品图谱 L2 的 OP / ED 识别与 MV 偏移共用一组函数（`docs/specs/2026-10-24-cross-media-links.md` §2、
音乐方案 §8.3 第 1 条）。**不解码**：Dart 经统一 FFmpeg 后端把音轨解成 11025 Hz 单声道 s16
交过来（`packages/fushi_music/lib/src/audio_fingerprint.dart`），Rust 侧不引第二份 FFmpeg。

- 声纹 = [rusty-chromaprint](https://crates.io/crates/rusty-chromaprint)（MIT，chromaprint 纯
  Rust 移植）的 `preset_test2`（= chromaprint / AcoustID 默认配置）。
- 对齐 = 每个整项偏移上逐项比汉明距离（≤ 10 位算命中），找命中项间空档 ≤ 1 s 的最长段，按命中
  数取全局最优偏移；O(needle × haystack) 次 popcount，90 s 歌 × 24 min 集实测 ~30 ms（release）。
- 精度：偏移 ≤ 半项（≈ 62 ms）；段端点延伸到 needle 端点时由偏移推出（同精度），落在 needle
  中间（TV size 剪辑）时按「窗中点越过边界」估，合成样本实测 ≲ 0.6 s。
- 回归向量：`fingerprint_regression_vector`（声纹长度 + 前 4 项 + SHA-1）与
  `alignment_regression_vectors`（整首 / 剪头 / 剪尾 / 两头都剪 / 插在开头）。改了 crate 版本或
  对齐常数让向量变了，必须升 `FINGERPRINT_VERSION`。

## uid

- 曲目：`sha1("fushi-music-track-v1" ‖ 路径 ‖ CUE 起点 ‖ 时长/采样率/声道)` 前 128 bit。指纹取
  **音频属性**而不是文件字节：改标签会改写文件头 / 尾，字节指纹会让每次改标签都换 uid、歌单与
  播放记录全断。
- 专辑：有专辑艺人 → （专辑艺人, 专辑名）；没有 → （专辑名, 所在目录）——合辑不被按曲目艺人拆散。
- 艺人：归一化名字（去空白、全角 ASCII 折半角、小写）。

派生规则由 `src/uid.rs` 的固定向量冻结；要改就升命名空间版本。

## 测试

`cargo test`：单测 + `tests/lyrics.rs`（每种歌词格式一个样本，`tests/fixtures/lyrics/generate.py`
生成，经 C ABI 解析后与 `golden/` 比对；编码探测回归向量由旧 Dart `text_file_io.dart` 生成）+ `tests/scan.rs` 经 C ABI 扫 `tests/fixtures/library`，逐行比对
`tests/fixtures/scan_golden.txt`。样本由 `tests/fixtures/generate.sh` 用统一 FFmpeg 生成并入库
（FLAC / MP3 / ALAC / WavPack / TTA / DSF / 整轨 + Shift_JIS CUE / FLAC 内嵌 CUE）。

## 构建

| 平台 | 脚本 | 产物（不入库） | 状态 |
|---|---|---|---|
| Windows x64 | `build_windows_dll.ps1` | `prebuilt/windows-x64/fushi_music.dll` | 本机已验证 |
| Linux x64 | `build_linux_so.sh` | `prebuilt/linux-x64/libfushi_music.so` | 未验证 |
| macOS arm64 | `build_macos_dylib.sh` | `prebuilt/macos/libfushi_music.dylib` | 未验证 |
| Android | `build_android_so.{ps1,sh}` | `prebuilt/android/<abi>/libfushi_music.so` | 未验证 |
| iOS | 进 `native/fushi_ios_umbrella`（待接） | — | 未接 |

App 打包（Windows CMake 已接；Linux CMake / Android Gradle / macOS / iOS 伞形库与 CI 的
`setup-fushi-*` 动作待接）见 PR 说明。

## 许可

本 crate GPL-3.0-only。依赖：lofty（MIT OR Apache-2.0）、sha1（MIT OR Apache-2.0）、
encoding_rs（(Apache-2.0 OR MIT) AND BSD-3-Clause）、quick-xml（MIT）、flate2（MIT OR Apache-2.0）、data-encoding（MIT）、
rusty-chromaprint（MIT；其依赖 rubato /
realfft MIT、rustfft MIT OR Apache-2.0）。rusty-chromaprint 与 realfft 上游仓库在发版提交上都没有
LICENSE 文件，许可页按 SPDX 标准 MIT 文本收录（`pendingUpstreamLicense`）。`plugin` 特性另带：
rquickjs / rquickjs-sys（MIT；编入 QuickJS-ng C 源码，MIT）、serde / serde_json、zip、sha2 / md-5 /
hmac / aes / cbc / ecb、num-bigint、ed25519-dalek、getrandom、url（均 MIT OR Apache-2.0 或更宽）。
