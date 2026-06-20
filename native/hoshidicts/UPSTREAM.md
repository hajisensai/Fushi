# hoshidicts 上游同步基线（UPSTREAM baseline）

> 本文件是 `native/hoshidicts/` C++ 引擎相对上游的**唯一基线真相源**。
> 每次从上游同步代码后更新「同步基线」与「已直抄/已合并的上游 commit」两节，
> 避免下次同步又对着几百行盲 diff。

## 上游仓库

- Repo: **Manhhao/hoshidicts** — https://github.com/Manhhao/hoshidicts
- 主线分支: `origin/main`
- 忽略的上游分支:
  - `origin/c-bindings`：Hibiki 已有自研 FFI/JNI 桥（见下「本地改动」），不采用上游 C bindings。
  - `origin/kanji` / `origin/main-mit`：非主线，按需评估。

## 同步基线

- **上游 `origin/main` 当前 tip**（本轮同步参照）：`3448d6d`（"Accept numeric Yomitan term scores (#14)"，2026-06-17）。
- **Hibiki 本轮同步后所含的上游主线 commit**（直抄，见下表）：截至 `3448d6d`，但**跳过**了主线上的若干提交（见「未同步/待评估」）。
- Hibiki 是 hoshidicts 的**深度 fork**：在上游主线 `2dd5199`（"count freq and pitch entries"，2026-05-16）一带分叉后，
  额外吸收了 sibling commit `feb48f5`（"add detected_type to ImportResult"，非 origin/main 主线，分叉自 `2dd5199`），
  并自研了大量上游没有的功能（见「Hibiki 本地改动清单」）。因此上游与 Hibiki **不是线性 pull 关系，是双向 merge / cherry-pick**。

## 本轮（TODO-621 批1）直抄的上游 commit

| 上游 commit | 标题 | 落到 Hibiki 的文件 | 风险 |
|---|---|---|---|
| `3448d6d` | Accept numeric Yomitan term scores (#14) | `hoshidicts_src/json/yomitan_parser.hpp`（`Term::score` `int`→`double`；`Tag::score` 不动） | 零盘格式风险（写盘不含 score） |
| `4975788` | consider all freq values when sorting within dict | `hoshidicts_src/lookup.cpp`（`get_freq_value_for_dict`→`get_freq_values_for_dict` 返 `vector<int>` + 调用点） | 纯查询期排序，不碰 importer/写盘 |
| `1a34a59` | fix swift compilation on c++23 | `hoshidicts_include/hoshidicts/query.hpp` + `hoshidicts_src/query.cpp`（`Dictionary` pimpl 5 个特殊成员声明+定义） | 仅编译期，5 平台受益 |

> 上述三处 apply 前已逐字节确认 Hibiki 仍是上游旧版（OLD），diff 与上游对应 commit 一致（除 Hibiki 本地上下文如 `hoshi::fs_path`）。

## 未同步 / 待评估（follow-up，按 TODO-621 计划 a9ae4ae38e9351fb4）

| 上游 commit | 标题 | 为什么不在批1 | 后续条件 |
|---|---|---|---|
| `2d4f2a2` | add normalization processors（NFKC 全角归一化） | 需 vendor `utf8proc` 进 `hoshidicts_external/` + 改 `CMakeLists.txt` + 把处理器追加到 Hibiki 自研处理链链尾（与 P1/P2/P3 共存，非替换） | 批2 |
| `e7dfdea` | add kanji standardization（异体字标准化） | **不能照搬**：上游用 C++23 `#embed` 嵌入数据表，Windows MSVC / Apple Clang 不支持，需改 CMake 生成 C 数组头。逻辑本身无害、与 Hibiki 自研 kanji 导入（`importer.cpp`）零冲突（落在 `text_processor.cpp`，非 importer/S0 二进制 contract） | 批3（慎，需 CMake 改写） |
| `918744d` | basic support for ipa dicts (#12) | 新增 IPA `transcriptions` 字段，需 Dart/FFI 侧消费才有意义 | 按需，独立 TODO |
| `1198201` | fix swift build | 仅 SwiftPM，Hibiki 不用 SwiftPM 构建 | skip |

## Hibiki 本地改动清单（上游没有 / 已分叉）

- **自研多语言文本处理器**（`hoshidicts_src/text_processor/text_processor.cpp`）：P1 Unicode 小写（`to_lower`）/ P2 阿拉伯语 harakat + 组合记号删除（`harakat`/`combining`）/ P3 预合成拉丁去变音（`precompos`）。上游 `text_processor` 此前为空（仅日英归一化骨架）。
- **自研 kanji 导入**：`hoshidicts_src/importer.cpp` 上游 541 行 → Hibiki **1367 行**（+826），新增 kanji bank 写盘（`write_kanji`）+ `query_kanji` + `add_kanji_dict`。
- **多格式导入**（上游主线没有）：`hoshidicts_src/mdx/`（MDX）、`hoshidicts_src/stardict/`（StarDict）、`hoshidicts_src/popup_json.cpp`（弹窗 JSON）、`hoshidicts_src/scan/`（词边界感知扫描，对齐 Yomitan searchResolution）、`hoshidicts_src/util/`。
- **安全上限**：导入/查询期的资源/尺寸上限加固。
- **FFI / JNI 桥**：`hoshidicts_ffi.cpp`（Dart FFI）+ `hoshidicts_jni.cpp`（Android JNI）。**不用上游 `c-bindings` 分支**。
  - 注意：`score` / `get_freq_value(s)_for_dict` / `Dictionary` 均为引擎内部符号，FFI/JNI 桥与 Dart binding 均未暴露——本批三处改动**不影响 FFI 签名**。
- **额外吸收的 sibling commit**：`feb48f5`（`ImportResult.detected_type`，自动词典类型检测），非 origin/main 主线。

## 依赖差异

- **上游**：`external/` 用 git submodule（utfcpp / glaze / zstd / unordered_dense / xxHash / libdeflate）。
- **Hibiki**：vendored 子目录 `native/hoshidicts/hoshidicts_external/`（glaze / libdeflate / unordered_dense / utfcpp / xxHash / zstd 实拷贝，不走 submodule）。批2 若引入 `utf8proc` 也照此 vendor 进 `hoshidicts_external/`。

## 验证

- 本机无 C++ 编译器（MSVC/NDK），native 改动由 **CI Linux ctest**（TODO-578 接入）+ **5 平台 build** 验。
- ctest 守卫：`tests/freq_pitch_import_query_test.cpp`（freq/pitch import→query e2e）+ `text_processor` / `kanji` 现有用例不回退。
