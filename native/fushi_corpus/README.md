# fushi_corpus

「我库里的例句」的 Rust 胖核心（作品图谱 L4，设计：`docs/specs/2026-10-24-cross-media-links.md` §3）：
用户库里的书 / 字幕 / 歌词 / 游戏台词按句喂进来，每句带 fushidicts 给出的**词典形**词元
（`fushidicts_corpus_terms`，按已加载词典的词形还原归一，不分语言）；查词弹窗用词头一次查询拿回
分组好的 top-N 例句。倒排索引与查询状态全在 Rust（`src/corpus.rs`），Dart 只送原文、取结果。
Dart 绑定在 `packages/fushi_corpus/`（纯 Dart，无 Flutter / 插件依赖）。无外部 crate 依赖。

**硬依赖，没有 Dart 回退**：Dart 侧加载失败抛 `FushiCorpusUnavailableError`，测试找不到库判红、
不 skip。`tool/native_libs.ps1` 负责本机备库（兄弟 worktree 同源码产物直接拷，否则 cargo 编）；
测试可用 `FUSHI_CORPUS_LIB=<库绝对路径>` 指定。无头服务端（`fushi_server`）不依赖它。

## ABI（均为 `fcorp_` 前缀；线格式见 `src/wire.rs`）

| 符号 | 作用 |
|---|---|
| `fcorp_abi_version() -> i32` | ABI 版本（当前 1）；线格式 / 磁盘格式变化也要升 |
| `fcorp_free_bytes(u8*, usize)` | 释放本库交给调用方的缓冲区 |
| `fcorp_open(const u8* dir, usize, Corpus** out) -> i32` | 打开（不存在则创建）语料目录，载入倒排 |
| `fcorp_close(Corpus*)` | 关闭句柄 |
| `fcorp_put(const Corpus*, const u8* doc, usize, const u8* terms, usize) -> i32` | 写入 / 整份替换一个文档（一本书 / 一集字幕 / 一首歌词 / 一段游戏台词一次） |
| `fcorp_remove(const Corpus*, u8 kind, const u8* key, usize, i32 part, u8 all_parts) -> i32` | 删一个文档（或某 key 的全部 part）；返回删除数 |
| `fcorp_remove_kinds(const Corpus*, u32 kind_mask) -> i32` | 按种类掩码批量删（游戏台词是唯一持久副本，重建不删它）；返回删除数 |
| `fcorp_docs(const Corpus*, i32 kind, const u8* key, usize, u8** out, usize* len) -> i32` | 列文档身份 + 指纹（Dart 据此判缺失 / 过期） |
| `fcorp_stats(const Corpus*, u8** out, usize* len) -> i32` | 统计 |
| `fcorp_query(const Corpus*, const u8* query, usize, u8** out, usize* len) -> i32` | 词头查询 → 分组 top-N 例句 |
| `fcorp_split(const u8* text, usize, u32 max_units, u8** out, usize* len) -> i32` | 一章正文切句 → 句 span 数组 |

状态码：0 成功；-1 空指针；-2 参数非法；-3 输入格式不对；-4 读写语料目录失败；-100 panic（已接住）。

## 存储

派生数据，不进 Drift / 备份 / 同步：磁盘一文档一文件（`<目录>/<身份哈希>-<序号>.fcd`，原子
rename 换代），内存只常驻倒排与每句 12 字节元数据。格式与并发语义见 `src/corpus.rs` 文件头注释。

## 构建

`build_windows_dll.ps1` / `build_linux_so.sh` / `build_macos_dylib.sh` / `build_android_so.*`
产出 `prebuilt/<平台>/`；`verify_abi.sh` 核对导出符号与 Dart 绑定 lookup 的字面量一致。iOS 经
`native/fushi_ios_umbrella` 合进伞形静态库。
