# fushi_music

音乐模块的 Rust 胖核心（设计：`docs/specs/2026-10-23-music-module-design.md` §4.1）。P0 只有
曲库扫描：目录遍历 + 标签 / 音频属性（[lofty](https://crates.io/crates/lofty)）+ CUE 拆轨
（整轨 `.cue`、FLAC 内嵌 `CUESHEET` 注释、FLAC 二进制 CUESHEET 块）+ 内容派生 uid。Dart 绑定在
`packages/fushi_music/`（纯 Dart，无 Flutter / 插件依赖）。

**硬依赖，没有 Dart 回退**：Dart 侧加载失败抛 `FushiMusicUnavailableError`，测试找不到库判红、
不 skip。`tool/native_libs.ps1` 负责本机备库（兄弟 worktree 同源码产物直接拷，否则 cargo 编）。

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

歌词（P1，`src/lyrics/`，详见 `src/lyrics/ffi.rs`）：

| 符号 | 作用 |
|---|---|
| `ffm_lyrics_parser_version() -> u32` | 解析器版本（`music_lyrics.timeline_version` 失效判据） |
| `ffm_lyrics_parse(const u8*, usize, const u8* hint, usize, i64 durationMs, u8**, usize*) -> i32` | 任意格式 → 统一时间轴（线格式 `src/lyrics/wire.rs`）；失败 -3，out 为错误信息 |
| `ffm_lyrics_embedded(const u8* path, usize, i64 durationMs, u8**, usize*) -> i32` | 内嵌 USLT / SYLT / Vorbis LYRICS / MP4 ©lyr |
| `ffm_lyrics_merge(primary, len, secondary, len, lang, len, u8**, usize*) -> i32` | 翻译按时间配对（≤ 300 ms） |
| `ffm_lyrics_align_ruby(timeline, len, tokens, len, u8**, usize*) -> i32` | 自动注音与音节对齐 |
| `ffm_lyrics_export(timeline, len, format, len, u8**, usize*) -> i32` | 导出 `ttml` / `lrc` |

新增符号不升 `ffm_abi_version`（扫描批次格式没变）；Dart 侧按需 lookup，缺符号抛
`FushiMusicUnavailableError`。

状态码：0 成功；-1 空指针；-2 参数非法；-3 输入格式不对；-5 根不存在；-100 panic（已接住）。

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
encoding_rs（(Apache-2.0 OR MIT) AND BSD-3-Clause）、quick-xml（MIT）、
flate2（MIT OR Apache-2.0）、data-encoding（MIT）。
