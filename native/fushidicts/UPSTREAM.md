# hoshidicts 上游同步基线（UPSTREAM baseline）

> 本文件是 `native/fushidicts/` C++ 引擎相对上游的**唯一基线真相源**。
> 每次从上游同步代码后更新「同步基线」与「已直抄/已合并的上游 commit」两节，
> 避免下次同步又对着几百行盲 diff。

## 上游仓库

- Repo: **Manhhao/hoshidicts** — https://github.com/Manhhao/hoshidicts
- 主线分支: `origin/main`
- 忽略的上游分支:
  - `origin/c-bindings`：Hibiki 已有自研 FFI/JNI 桥（见下「本地改动」），不采用上游 C bindings。
  - `origin/kanji` / `origin/main-mit`：非主线，按需评估。

## 同步基线

- **上游 `origin/main` 当前 tip**（批4 同步参照，2026-08-16）：`8993838`（"train zstd dict on import"）。
- **Hibiki 批4 同步后所含的上游主线 commit**：截至 `8993838`，但**跳过**了主线上的若干提交（见「批4 明确跳过/暂缓」）。
- Hibiki 是 hoshidicts 的**深度 fork**：在上游主线 `2dd5199`（"count freq and pitch entries"，2026-05-16）一带分叉后，
  额外吸收了 sibling commit `feb48f5`（"add detected_type to ImportResult"，非 origin/main 主线，分叉自 `2dd5199`），
  并自研了大量上游没有的功能（见「Hibiki 本地改动清单」）。因此上游与 Hibiki **不是线性 pull 关系，是双向 merge / cherry-pick**。

## 本轮（TODO-621 批1）直抄的上游 commit

| 上游 commit | 标题 | 落到 Hibiki 的文件 | 风险 |
|---|---|---|---|
| `3448d6d` | Accept numeric Yomitan term scores (#14) | `fushidicts_src/json/yomitan_parser.hpp`（`Term::score` `int`→`double`；`Tag::score` 不动） | 零盘格式风险（写盘不含 score） |
| `4975788` | consider all freq values when sorting within dict | `fushidicts_src/lookup.cpp`（`get_freq_value_for_dict`→`get_freq_values_for_dict` 返 `vector<int>` + 调用点） | 纯查询期排序，不碰 importer/写盘 |
| `1a34a59` | fix swift compilation on c++23 | `fushidicts_include/hoshidicts/query.hpp` + `fushidicts_src/query.cpp`（`Dictionary` pimpl 5 个特殊成员声明+定义） | 仅编译期，5 平台受益 |

> 上述三处 apply 前已逐字节确认 Hibiki 仍是上游旧版（OLD），diff 与上游对应 commit 一致（除 Hibiki 本地上下文如 `fushi::fs_path`）。

## 历史遗留记账修正（批4 复核）

批1 时列为「未同步/待评估」的两条，实际**早已在 Hibiki 落地**（当时忘了回写本文件）：

| 上游 commit | 标题 | Hibiki 实际状态 |
|---|---|---|
| `2d4f2a2` | add normalization processors（NFKC） | ✅ 已落地：utf8proc v2.11.3 vendored 进 `fushidicts_external/utf8proc/`，NFKC 处理器在 `text_processor.cpp` 日语链 |
| `e7dfdea` | add kanji standardization（异体字标准化） | ✅ 已落地（非直抄）：绕开 C++23 `#embed`，用离线预生成表 `kanji_standardization_data.{h,cpp}`（`tool/native_gen/gen_kanji_standardization.py`，kanji-processor pin 452cc2db，2122 条）。上游后来的 `4ffbffb`（replace #embed，提交生成的 C 数组源文件）自行收敛到与 Hibiki 等价的方案——数据集逐条同源，无需再动 |
| `1198201` | fix swift build | 仅 SwiftPM，跳过（不变） |

## 批4（2026-08-17）同步：`3448d6d`..`8993838`

**已移植（直抄或适配，见各文件内注释）：**

| 上游 commit | 标题 | 落到 Hibiki | 方式 |
|---|---|---|---|
| `9dc93b6` | expand iteration marks（々/ゝ/ゞ 展开） | `text_processor.cpp` | 适配（standardize_kanji 上下文已本地化） |
| `ee0384b` | fullwidth numbers → kanji（２→二） | `text_processor.cpp` | 直抄 |
| `aaf75c9` | collapseEmphaticSequences（っっ/ーー 折叠） | `text_processor.cpp`（插在假名转换后，对齐上游链序） | 直抄 |
| `1cb9b4b` | normalize kana width before script conversion | `text_processor.cpp`（NFKC 提到日语链首；半角片假名 ﾒｶﾞﾈ 修复） | 直抄 |
| `909c854`（仅 revert 部分） | revert `4975788` freq 向量比较 | `lookup.cpp`（回到单一最小值比较；score 排序+格式 bump 部分**未采纳**，见下） | 直抄 |
| `d4183d4` | bloom/hash size 校验 + flush before unmap + 删 bloom migration | `bloom.{hpp,cpp}`（size 校验，置空降级不拒载）、`memory.cpp`（flush）、`query.cpp`（删 migration，消掉穿 FFI 的 throw；hash 侧保留 fork 自研 BUG-1303 clamp，不用上游拒载版） | 适配 |
| `01630e8` | freq 嵌套 object 解析收紧 | `yomitan_parser.cpp`（optional display_value + error_on_missing_keys，对齐 flat 路径既有风格） | 直抄 |
| `79c55c2`（parser 先行部分） | pitch accent spec：position 收 `variant<int,string>` | `yomitan_parser.cpp`（pattern 字符串位不再让整条 meta 记录解析失败；nasal/devoice/pattern 的结构化输出 + FFI/UI 二期另议） | 部分适配 |
| `8993838` | train zstd dict on import | `importer.cpp`（train_zstd_dict + CDict 压缩 term glossary + 落盘 `dict.zstd`）、`query.cpp`（DDict + thread_local DCtx 解压）——引入 **v2 格式阶梯**（见下） | 适配 |
| `c5d8c6d`（仅 1 行） | `<climits>` include 修复 | `lookup.cpp`（fork 同样裸用 INT_MAX） | 直抄 |
| `64afa2f`（仅借鉴 stats 能力） | 上游 kanji dicts | kanji 记录 v2 追加 stats 段（见下）；上游 kanji 实现本体**跳过**（与 fork 自研 kanji 同 type byte 两套布局，互不兼容，fork 版能力更强） | 借鉴 |
| `909c854`（score 部分，批4 二轮补齐） | term score 落盘 + 排序 | v2 term 记录在 term_tags 后追加 i32 score（v2 未发布窗口内折入，免再升 v3）；`query.cpp` 版本门控读取 + 合并取 max；`lookup.cpp` 比较器 freq 档后 score 降序。score 不出 FFI（纯 native 排序信号） | 适配 |
| `79c55c2`（结构化部分，批4 二轮补齐） | Pitch{position,pattern,nasal,devoice} 完整规格 | `ParsedAccent`/`Pitch` 结构贯通 parser→query；pattern 出 FFI（`FfiPitch.patterns` 平行数组）→Dart（`FushiPitchEntry.patterns`）→popup JSON（`"patterns"`）→JS 渲染 `[pattern]` 文本项 + 制卡类别字段并入 pattern 名；popup_json/Dart 镜像 pkey 折 pattern（IPA 折 key 同型坑）。nasal/devoice 收在 native `Pitch` 数据模型，文本形态 UI 无渲染语义、暂不出 FFI | 适配 |
| `bc62d2b`（批4 二轮补齐） | lookup 排序选项 | `LookupOptions{frequency_dictionary, frequency_order}` + `Lookup::lookup` 第 4 参（默认 Auto 零行为变化，排序在截断前）；新 FFI 导出 `fushidicts_lookup_with_options`（老导出原样保留）+ Dart `lookup()` 可选参数。设置 UI 是产品决策，管道先行 | 适配 |
| `86c6e2f`（批4 二轮补齐） | primary_reading 优先 | `LookupOptions.primary_reading`，比较器最前档；同上管道贯通 | 直抄（叠在 options 上） |

**磁盘格式 v2（`.fushidicts_2`，fork 首个版本阶梯）：**
- `import_yomitan` 产出 `.fushidicts_2`；`write_simple_dict`（MDX/StarDict/DSL）仍产 `.fushidicts_1`。
- 读侧 `dict_format_version()`（query.cpp）：`.fushidicts_2`→2，`.fushidicts_1`/`.hoshidicts_1`（改名前存量，冻结只读）→1，无 marker→不加载。
- v2 增量：① kanji 记录尾部追加 stats 段 `[u8 count]([u8 klen][k][u16 vlen][v])*`（radical/strokes 之外全保留，JLPT/grade 等；S0 契约注释在 importer.cpp）；② term 记录尾部追加 `[i32 score]`（Yomitan 排序信号，多记录合并取 max）；③ term glossary 可能用训练字典压缩，`dict.zstd` 存在才挂 DDict（训练样本不足时不写，退普通压缩）。
- 兼容矩阵：新引擎读 v1 老盘**完全不变**；旧引擎读 v2 盘＝整目录不加载（降级后新导入词典不可见，不毁数据，重导可救）。kanji meanings / meta 记录恒普通 zstd 帧，不吃训练字典。
- FFI：`FfiKanjiResult` 追加 `stat_keys/stat_values/stat_count`（native+Dart 同 commit 镜像，照 918744d transcriptions 先例双层 malloc/free）；其余 ABI 零变化。
- 守卫：`tests/format_v2_upstream_sync_test.cpp`（v2 marker/stats 读回/marker 拒载/bloom 截断降级/zstd 往返/pitch pattern 容忍）+ `tests/text_processor_test.cpp` 新增 processor 用例。

**批4 明确跳过 / 剩余项（批4 二轮已把「没坏处」的暂缓项全部补齐；下表为终态）：**

| 上游 commit | 标题 | 处置 | 理由/重估条件 |
|---|---|---|---|
| `702dcc5` | build summary on import | 跳过 | 改写 index.json/删 styles.css，冲突 fork 读侧契约（弹窗样式丢失）+ 破坏 FfiImportResult；如需导入元数据留档，fork 自己加 sidecar |
| `64afa2f` | kanji dicts（实现本体） | 跳过 | 与 fork 自研 kanji 同 type byte 两套布局，换=毁存量；stats 能力已借鉴进 v2 |
| `88b073d` | c bindings 合入主线 | 跳过（政策不变） | fork 自研 FFI 桥等效且 errors 向量信息更全；原「忽略 c-bindings 分支」政策改述为「已合主线，仍跳过」 |
| `c5d8c6d`（submodule bump 部分） | 7 个依赖 pin 升级 | 不做（有真实坏处） | fork 是 vendored 实拷贝，7 库齐升有隐性构建/行为回归风险、收益近零（zstd 1.6.0 / utf8proc v2.11.3 均不落后关键功能）；单库确有需要时按需单独 vendor |
| `f9aa482` / `7bfdc8c` / `32b8ce5` / `e1a8c1c` / `6240e06` / `f151dbb` | submodule URL / cli+benchmark 开关 / swift cli / benchmark 修复×2 / readme | 跳过 | fork 无 submodule / 无 cli/benchmark target / 不用 SwiftPM |
| `d6c9ea2` | use native filesystem paths | 跳过 | 已被 fork 自研 `fushi::fs_path`/`to_wide`（`util/fs_utf8.hpp` + `memory.cpp` W 系 API + `win_utf8_import_test`）等价覆盖 |
| `e88430d` | MSVC /utf-8 | 跳过 | fork `CMakeLists.txt` 已有全局 `/utf-8 /Zc:__cplusplus /permissive-`，覆盖面更大 |

真正的后续（非上游同步，产品决策）：排序选项/primary_reading 的设置 UI 与弹窗内链消费方；pitch nasal/devoice 的图形化渲染（数据模型已收全）。

## TODO-687 批3 移植的上游 commit（IPA 音标支持）

| 上游 commit | 标题 | 落到 Hibiki 的文件 | 移植方式 |
|---|---|---|---|
| `918744d` | basic support for ipa dicts (#12) | `query.hpp`（`PitchEntry::transcriptions`）+ `importer.cpp` + `yomitan_parser.{hpp,cpp}`（`parse_ipa` + `RawIPA`/`TranscriptionsArray` glaze）+ `query.cpp`（pitch/ipa 二分支）+ `popup_json.cpp`（自有，序列化 transcriptions + 并入 pkey）+ FFI/Dart 透传 | **非直抄**，见下 |

> 移植偏差（上游 diff 不能直接 patch）：
> - **`query.cpp` 按 Hibiki BlobReader 重实现**：上游用自由函数 `read_val/read_str(blob_addr)`，Hibiki 已重构为 `BlobReader.read<>()/read_str(len)`，故 pitch/ipa 二分支按 BlobReader 风格重写，逐字段对照上游（reading 过滤、`if(!pitch_positions.empty()||!transcriptions.empty())` 空集守卫）。
> - **`detect_type` 也加 `||ipa`**（上游 diff 没碰）：上游只改了 `process_meta_bank` 的 count 分支；但 Hibiki 多一层分类（C++ `detect_type` + Dart `decodeDictTypeFromBlobHeader`），纯 IPA 词典若不归入 "pitch" 就落 "term"、永不注册成 pitch 词典、数据查不出来。故 `importer.cpp detect_type` 与 `app_model.dart decodeDictTypeFromBlobHeader` 同步加 ipa→pitch。
> - **`popup_json.cpp` 去重 pkey 并入 transcriptions**（Hibiki 自有文件，上游无）：IPA 项 pitch_positions 为空，仅按 positions 建 key 会把同 dict 多 IPA 折叠成 `dict:` 被吞，故把 transcriptions 折进 key。Dart 侧 `buildPopupJsonFromLookup` / fallback `buildLookupEntryExtra`+`_convertPitches` 同步对齐。
> - **FFI ABI 变更**（native+Dart 同 commit）：`FfiPitch` 加 `char** transcriptions; int32_t transcription_count`，convert 照 `display_values`（malloc 数组 + 逐元素 dup），free **双层**（先逐元素再数组）。Dart binding `FfiPitch` 镜像 `FfiFrequency.displayValues`。
> - **UI 渲染未做**（用户决策 ③A）：本批只到 native+FFI+Dart 数据贯通 + parity，JS 弹窗渲染 IPA 作后续 TODO。
> - 守卫：`tests/ipa_import_query_test.cpp`（import→query→`PitchEntry.transcriptions` e2e，红绿实证）+ `dictionary_popup_webview_test.dart` parity 手加 transcriptions 断言。

## Hibiki 本地改动清单（上游没有 / 已分叉）

- **自研多语言文本处理器**（`fushidicts_src/text_processor/text_processor.cpp`）：P1 Unicode 小写（`to_lower`）/ P2 阿拉伯语 harakat + 组合记号删除（`harakat`/`combining`）/ P3 预合成拉丁去变音（`precompos`）。上游 `text_processor` 此前为空（仅日英归一化骨架）。
- **自研 kanji 导入**：`fushidicts_src/importer.cpp` 上游 541 行 → Hibiki **1367 行**（+826），新增 kanji bank 写盘（`write_kanji`）+ `query_kanji` + `add_kanji_dict`。
- **多格式导入**（上游主线没有）：`fushidicts_src/mdx/`（MDX）、`fushidicts_src/stardict/`（StarDict）、`fushidicts_src/popup_json.cpp`（弹窗 JSON）、`fushidicts_src/scan/`（词边界感知扫描，对齐 Yomitan searchResolution）、`fushidicts_src/util/`。
- **安全上限**：导入/查询期的资源/尺寸上限加固。
- **FFI / JNI 桥**：`fushidicts_ffi.cpp`（Dart FFI）+ `fushidicts_jni.cpp`（Android JNI）。**不用上游 `c-bindings` 分支**。
  - 注意：`score` / `get_freq_value(s)_for_dict` / `Dictionary` 均为引擎内部符号，FFI/JNI 桥与 Dart binding 均未暴露——本批三处改动**不影响 FFI 签名**。
- **额外吸收的 sibling commit**：`feb48f5`（`ImportResult.detected_type`，自动词典类型检测），非 origin/main 主线。

## 依赖差异

- **上游**：`external/` 用 git submodule（utfcpp / glaze / zstd / unordered_dense / xxHash / libdeflate）。
- **Hibiki**：vendored 子目录 `native/fushidicts/fushidicts_external/`（glaze / libdeflate / unordered_dense / utfcpp / xxHash / zstd 实拷贝，不走 submodule）。批2 若引入 `utf8proc` 也照此 vendor 进 `fushidicts_external/`。

## 验证

- 本机 **MSVC 2022 可用**（批4 实证：`tests/run_all.bat` 走 vcvars64 + Ninja + ctest，全套 21 用例 ~6 秒）；「本机无 C++ 编译器」是过时说法。native 改动本地 ctest 先行，再由 **CI Linux ctest** + **5 平台 build** 兜异构。
- ctest 守卫：`tests/freq_pitch_import_query_test.cpp`（freq/pitch import→query e2e）+ `text_processor` / `kanji` 现有用例不回退。

## 2026-08 Hibiki→Fushi 改名映射（P6-2）

产品改名 Fushi 后，本引擎**对外符号面**同步改为 `fushidicts`。终局清算 W6（2026-08-07）又把**目录名**一并改掉：`native/hoshidicts/` → `native/fushidicts/`，内层 `hoshidicts_src/`→`fushidicts_src/`、`hoshidicts_include/`→`fushidicts_include/`、`hoshidicts_external/`→`fushidicts_external/`（vendored 第三方只改目录名，pristine 文件内容不动）。

W9-7（2026-08-08）补完 W6 只改了外层目录、没动内部命名的部分——内部符号与上游 diff 对照面无关，留着只会让「旧代号已清零」这句话不成立：
- 公共头 `fushidicts_include/hoshidicts.h`→`fushidicts.h`，公共头子目录 `fushidicts_include/hoshidicts/`→`fushidicts/`（源码 `#include "fushidicts/*.hpp"`）；
- 内部命名空间 `hoshi::`/`hoshi_test::`/`hoshidicts::`/`hoshidicts_json::` → `fushi` 系，线程封装类型 `HoshiThread`/`HoshiThreadFn`/`hoshi_thread_*` → `Fushi*`/`fushi_thread_*`；
- 宏 `HOSHI_EXPORT`→`FUSHI_EXPORT`、`HOSHI_LOG*`→`FUSHI_LOG*`；
- CMake 静态库 target `hoshidicts`→`fushidicts`，测试 harness 变量 `HOSHI_TEST_BUILD_DIR`→`FUSHI_TEST_BUILD_DIR`；
- CI workflow 文件名 `native-hoshidicts-gate.yml`→`native-fushidicts-gate.yml`。

**仍保持不变**：磁盘分片名 `.hoshidicts_1`（词典持久化契约，改名会让存量分片读不到）。对照表：

| 旧名 | 新名 | 说明 |
|---|---|---|
| C ABI 导出前缀 `hoshidicts_*`（22 个函数） | `fushidicts_*` | `fushidicts_ffi.cpp`，Dart 绑定同步 |
| CMake target/产物 `hoshidicts_ffi`（`hoshidicts_ffi.dll` / `libhoshidicts_ffi.{so,dylib}`） | `fushidicts_ffi`（`fushidicts_ffi.dll` / `libfushidicts_ffi.{so,dylib}`） | Windows/Linux/macOS/Android |
| iOS 合并归档 `libhoshidicts_ffi_merged.a` | `libfushidicts_ffi_merged.a` | `merge_ios_archives.sh` |
| CMake target `hoshidicts_jni`（`libhoshidicts_jni.so`） | `fushidicts_jni`（`libfushidicts_jni.so`） | Android popup JNI |
| JNI 注册 `Java_app_hibiki_reader_HoshiBridge_*` | `Java_app_fushi_reader_FushiBridge_*` | Kotlin 侧为 `app.fushi.reader.FushiBridge`（P2-1 已改） |
| 桥源文件 `hoshidicts_ffi.cpp` / `hoshidicts_jni.cpp` | `fushidicts_ffi.cpp` / `fushidicts_jni.cpp` | 仅这两个桥文件改名 |
| 构建变量 `HOSHIDICTS_*`（CMake/xcconfig/脚本环境契约） | `FUSHIDICTS_*` | `AppInfo.xcconfig` / 两个 pbxproj / `build_fushidicts_ffi.sh` |
| Dart 封装 `HoshiDicts` 及 `Hoshi*` 结果类 | `FushiDicts` / `Fushi*` | `packages/fushi_dictionary/lib/src/engine/fushidicts.dart` |
| 目录 `native/hoshidicts/`（含 `hoshidicts_{src,include,external}/`） | `native/fushidicts/`（`fushidicts_{src,include,external}/`） | W6；测试 harness 变量 `HOSHI_ROOT`→`FUSHI_ROOT`、ctest 函数 `add_hoshi_test`→`add_fushi_test`、CI 构建目录 `hoshi-tests`→`fushi-tests` 同批 |
