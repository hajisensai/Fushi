# 通用文本归一化预处理器（补全 Yomitan 多语言查词召回）实现计划

> 执行者：按 TDD 逐步实现。改动全部在 `native/hoshidicts/hoshidicts_src/text_processor/text_processor.cpp`，外加一个独立原生测试。

**Goal:** 在 hoshidicts 查词前的文本归一化层补上缺失的预处理，使 18 张已加载 Yomitan 变换表对应的非拉丁/带变音语言（阿拉伯、希腊、带变音拉丁等）的查词召回真正可用——不引入任何“目标语言”开关，全部按码点驱动、全局生效。

**根因（已核实）：**
- `deinflector.cpp::load_transforms_json` 追加式加载全部 18 张表、`lang:key` 命名空间隔离，`deinflect()` 全局套用 → **去屈折 18 种语言现已支持**。
- `lookup.cpp` 查词语言无关 → **任何文字可命中**（需导入词典）。
- `text_processor.cpp::process()` 只挂 `get_japanese_processors()` + `get_english_processors()`，且 `to_lowercase` 仅 ASCII A–Z；第 144 行 `// TODO: implement rest of preprocessors`。**这是召回缺口的唯一根因。**

**Architecture:** `process()` 对输入做“变体扇出”——每个处理器把当前变体集合按其 options 映射成新变体集合，最终 lookup 逐变体命中。新增处理器都是 option `{0,1}`（0=原样，1=归一化），码点驱动、对所有语言无差别运行；非目标脚本的字符天然不被命中，故全局运行安全且零“语言切换”。

**Tech Stack:** C++23 / utfcpp（已在 include 路径）/ MSVC `cl` + vcvars 本地构建（CMake 不挂测试，照 `tests/win_utf8_import_test.cpp` 范式写独立 `main`）。

---

## 设计：新增三个码点驱动处理器

全部加在 `namespace {}` 内，并在 `process()` 的处理器列表里追加。沿用现有 `TextProcessor{options, process}` 结构与 `{0,1}` 选项约定。

### P1 — Unicode 范围小写（替换 ASCII-only `to_lowercase`）
覆盖且仅覆盖高置信、规则性强的双大小写区间：
- ASCII：`U+0041–005A` → `+0x20`（保留现状）
- Latin-1 Supplement：`U+00C0–00D6`、`U+00D8–00DE` → `+0x20`（德语 Ü/Ö/Ä、法/西重音大写）
- 希腊：`U+0391–03A1`、`U+03A3–03AB` → `+0x20`（跳过 `U+03A2` 空位）
- 西里尔：`U+0410–042F` → `+0x20`；`U+0400–040F` → `+0x50`

> 不在 P1 处理 Latin Extended-A 的交替式大小写（错误率高，且其小写形态多为预合成，P3 会覆盖匹配需求）。

### P2 — 组合记号 / 阿拉伯 harakat / 希伯来点 删除（纯删除，必然正确）
删除以下码点（option 1 变体）：
- 组合变音符：`U+0300–036F`
- 阿拉伯：`U+064B–065F`、`U+0670`（harakat）、`U+0640`（tatweel 连接符）
- 希伯来点：`U+0591–05BD`、`U+05BF`、`U+05C1–05C2`、`U+05C4–05C5`、`U+05C7`

### P3 — 预合成拉丁变音字母 → 基字母（curated 表）
覆盖 Latin-1 Supplement + Latin Extended-A 常见预合成字母到 ASCII 基字母的映射（如 `é→e ñ→n ü→u ß→ss? 否`，ß 不在此表，保留）。仅做**去变音**，不做大小写（P1 负责大小写）。表为静态 `unordered_map<char32_t,char32_t>`，仅含确定的单字母去变音项。option 1 = 全字符串逐字符映射（命不中保持原样）。

> P3 与 P2 互补：P2 处理“已分解”文本，P3 处理“预合成”文本（实际文本以预合成为主）。两者都作为独立变体，互不依赖。

---

## Task 1：原生测试骨架（先红）

**Files:**
- Create: `native/hoshidicts/tests/text_processor_test.cpp`

- [ ] **Step 1: 写失败测试**（独立 `main`，断言 `process()` 产出包含期望归一化变体）

```cpp
// 通用文本归一化守卫：阿拉伯 harakat 去除、带变音拉丁去变音、Latin-1/希腊/西里尔小写、
// 希伯来点去除。process() 必须在变体集合中产出归一化形（option-1 变体）。
// Usage: text_processor_test   (无参，纯内存断言)  Exit 0=PASS
#include <cstdio>
#include <string>
#include <vector>
#include "text_processor.hpp"

static bool has_variant(const std::vector<TextVariant>& vs, const char* utf8) {
  for (const auto& v : vs) if (v.text == utf8) return true;
  return false;
}
static int g_fail = 0;
static void expect(const char* name, const std::string& src, const char* want) {
  auto vs = text_processor::process(src);
  if (!has_variant(vs, want)) {
    std::fprintf(stderr, "FAIL %s: no variant '%s' for src '%s' (got %zu)\n",
                 name, want, src.c_str(), vs.size());
    ++g_fail;
  }
}

int main() {
  // P2: 阿拉伯 harakat 去除  كَتَبَ -> كتب
  expect("ar-harakat", "\xD9\x83\xD9\x8E\xD8\xAA\xD9\x8E\xD8\xA8\xD9\x8E",
         "\xD9\x83\xD8\xAA\xD8\xA8");
  // P1: Latin-1 大写小写  Ü -> ü
  expect("latin1-lower", "\xC3\x9C", "\xC3\xBC");
  // P1: 希腊大写小写  Λ -> λ
  expect("greek-lower", "\xCE\x9B", "\xCE\xBB");
  // P1: 西里尔大写小写  Д -> д
  expect("cyrillic-lower", "\xD0\x94", "\xD0\xB4");
  // P3: 预合成去变音  café -> cafe
  expect("latin-strip", "caf\xC3\xA9", "cafe");
  // 回归：纯 ASCII 大写仍小写  Gehen -> gehen
  expect("ascii-lower", "Gehen", "gehen");

  if (g_fail) { std::fprintf(stderr, "%d FAIL\n", g_fail); return 1; }
  std::printf("PASS\n");
  return 0;
}
```

- [ ] **Step 2: 编译跑，确认红**（`process()` 现仅日英、产不出上述变体）

```bash
# 在 native/hoshidicts 下，已 call vcvars64.bat（注意：vcvars 不可重定向 >nul）
cl /std:c++latest /EHsc /utf-8 /Zc:__cplusplus /permissive- /MD ^
  /I hoshidicts_src/text_processor /I hoshidicts_external/utfcpp/source ^
  tests/text_processor_test.cpp hoshidicts_src/text_processor/text_processor.cpp ^
  /Fe:tests/text_processor_test.exe
tests/text_processor_test.exe
```
Expected: 非零退出，多条 `FAIL ...`（ar-harakat / latin1-lower / greek-lower / cyrillic-lower / latin-strip）。`ascii-lower` 应已 PASS（现有 EN 小写）。

## Task 2：实现 P1 Unicode 范围小写

**Files:** Modify `text_processor.cpp`（替换 `to_lowercase` 主体，保持签名）

- [ ] **Step 1:** 把 `to_lowercase` 改为按上文 P1 区间映射（ASCII/Latin-1/希腊/西里尔）。
- [ ] **Step 2:** 编译跑测试，`latin1-lower`/`greek-lower`/`cyrillic-lower`/`ascii-lower` 转 PASS。

## Task 3：实现 P2 删除处理器 + 挂进 process()

**Files:** Modify `text_processor.cpp`

- [ ] **Step 1:** 加 `strip_combining(const std::u32string&)`：删 P2 列出的码点区间。
- [ ] **Step 2:** 加 `get_diacritic_removal_processors()` 返回一个 `{options={0,1}}` 处理器（opt1 调 `strip_combining`），并在 `process()` 的 `all_processors` 后 `insert`。
- [ ] **Step 3:** 编译跑，`ar-harakat` 转 PASS。

## Task 4：实现 P3 预合成去变音表

**Files:** Modify `text_processor.cpp`

- [ ] **Step 1:** 加静态 `unordered_map<char32_t,char32_t>`（Latin-1 Supplement + Extended-A 常见去变音项，大小写各含）+ `strip_precomposed(const std::u32string&)`。
- [ ] **Step 2:** 把 P3 作为同一去变音处理器的额外 option，或新增处理器追加到列表。
- [ ] **Step 3:** 编译跑，`latin-strip`（café→cafe）转 PASS，全绿。

## Task 5：变体扇出爆炸防护核查（无新代码，做账）

- [ ] 核对 `process()` 现在的处理器数与每个 options 基数：JA{0,1,2} × EN-lower{0,1} × P2{0,1} × P3{0,1}。最坏变体上界 = 3×2×2×2=24（去重后更少）。确认对单次查词可接受；若 Dart 侧 `lookup` 有 scanLength × 变体 的放大，量级仍有界。把该上界写进本文件“风险”一节。

## Task 6：构建与回归

- [ ] **Step 1:** 跑全套现有原生测试（`win_utf8_import_test` / `dict_name_lifetime_test`）确认未被 text_processor 改动波及。
- [ ] **Step 2:** 重建 `hoshidicts_ffi`（至少 Windows）：`cmake --build` 出 `hoshidicts_ffi.dll`，确认编译通过。
- [ ] **Step 3:** Dart 侧 `flutter test`（dictionary 相关）确认无回归（Dart 不直接测 native 归一化，但要确认 FFI 签名未变、无破坏）。

---

## 风险与边界
- **多平台重建**：本计划只在 Windows 本机构建验证 native 测试；Android/iOS/macOS/Linux 的 `hoshidicts_ffi` 需各自重建后才在真机生效（与历次 native 改动一致，真机归用户）。
- **不做完整 ICU/NFD**：P1/P3 用 curated 区间与表，覆盖 18 种语言里高频场景；土耳其语 i/İ 点状大小写、立陶宛语等特殊 casing 规则**不**处理（这些语言也不在 18 张表内或属边角）。明确记为已知不覆盖项，避免“看起来全覆盖”。
- **ß / 连字**：不做 ß→ss、Æ→ae 等扩展折叠（会改变长度与边界），保留原样。
- **不触碰** `implementations/`（3 个 Dart 语言类）与 `targetLanguage`：与查词召回无关，删除会断构建。
