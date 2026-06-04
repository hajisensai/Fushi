# Windows 词典导入 UTF-8 路径根因修复 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复 Windows 上含非 ASCII 字符路径（日文词典文件名 / 日文词典标题目录）导致 `hoshidicts` C++ 词典导入与回读全部失败（报 "unsupported format or failed to open file"）的根因。

**Architecture:** 根因是 native 跨平台边界把 Dart 传入的 **UTF-8** 路径在 Windows 上当作 **ANSI 代码页** 解释（`CreateFileA` / `CreateFileMappingA` / `std::filesystem::path(std::string)` / `std::ofstream(std::string)` / glaze 文件 IO）。POSIX 的 narrow API 本就是 UTF-8 所以 Android/macOS/Linux 正常，唯独 Windows 非 ASCII 路径全崩。修法：① `memory.cpp` 的 Win32 文件打开改用宽字符 `CreateFileW`（UTF-8→UTF-16）；② 新增单一边界助手 `fs_utf8.hpp` 把 UTF-8 `std::string` 正确转成 `std::filesystem::path`；③ 在所有 fstream / filesystem / glaze-file-IO 触点统一过这个助手。消除"特殊情况"，让路径编码只在一个地方处理。

**Tech Stack:** C++23（hoshidicts 库，`native/hoshidicts/CMakeLists.txt` 设 `CMAKE_CXX_STANDARD 23`），Win32 API，`std::filesystem`，glaze JSON，Flutter FFI；Windows 验证用 VS2022 (`cl.exe` 14.44) + 项目 Flutter 3.44.0。

---

## 根因证据（已复现）

- 报错字符串全工程唯一来源：`native/hoshidicts/hoshidicts_src/importer.cpp:1068`，`zip.open()` 返回 false。
- `zip.open()` = `memory::map_rd()` + `parse_central_directory()`。后者平台无关；前者 Windows 分支用 `CreateFileA`。
- 独立 C++ 复现（本机 VS2022 编译运行）结论：
  - ASCII 路径 `JMdict_english.zip`：`CreateFileA` **OK**，`CreateFileW` **OK**。
  - 日文路径 `複合語起源.zip`（UTF-8 字节）：`CreateFileA` **FAILED `ERROR_INVALID_NAME(123)`**，`CreateFileW`(UTF-8→UTF-16) **OK**。
- 触发面：用户选日文命名的词典文件；推荐词典里 `複合語起源` / `日・モ辞典` / `Pixiv` 等 URL 经 `Uri.parse(url).pathSegments.last` 解码成日文/含特殊字符文件名（`dictionary_downloader.dart:635`），下载到 `download_temp/<日文名>.zip`。ASCII 名的推荐词典（JMdict_english 等）不受影响。
- Windows app 产品名 "Hibiki" 为 ASCII，故 appData 根路径 ASCII；问题只出在**文件名/词典标题**非 ASCII 时。

## 受影响文件（非第三方运行路径）

| 文件 | 触点 | 修法 |
|---|---|---|
| `hoshidicts_src/memory/memory.cpp` | `CreateFileA`/`CreateFileMappingA`（map_rd L16/27、map_rw L68/81） | UTF-8→UTF-16 + `CreateFileW`/`CreateFileMappingW`（仅 `_WIN32` 分支；POSIX 不动） |
| `hoshidicts_src/importer.cpp` | `std::ofstream/ifstream(path+...)`、`std::filesystem::*(std::string)`、`std::filesystem::path(name)`、`glz::write_file_json` | 全部过 `fs_utf8.hpp` 助手 |
| `hoshidicts_src/query.cpp` | `is_regular_file/exists/path(...).stem`、`std::ifstream`、`glz::read_file_json` | 同上 |
| `hoshidicts_src/stardict/stardict_reader.cpp` | `std::ifstream(path)`、`std::filesystem::path(ifo_path).stem` | 同上 |
| `hoshidicts_src/hash/hash.cpp`、`hash/bloom.cpp` | `memory::map_rw(path,...)` | **无需改**，随 memory.cpp 修复自动修好 |

新增：`hoshidicts_src/util/fs_utf8.hpp`（单一边界助手）。

---

## Task 1: 新增 UTF-8→path 边界助手

**Files:**
- Create: `native/hoshidicts/hoshidicts_src/util/fs_utf8.hpp`

- [ ] **Step 1: 写助手头文件**

```cpp
// fs_utf8.hpp — single platform-boundary helper for UTF-8 filesystem paths.
//
// Dart passes paths to native as UTF-8 bytes. On Windows, constructing a
// std::filesystem::path from a std::string decodes via the active code page
// (ANSI), NOT UTF-8, so any non-ASCII path silently breaks. On POSIX the
// narrow encoding is already UTF-8. This helper bridges both: it builds the
// path from the UTF-8 bytes explicitly so Windows stores the correct UTF-16
// internally. All fstream / std::filesystem access in this library MUST route
// UTF-8 strings through fs_path() (or the read/write helpers below).
#pragma once

#include <filesystem>
#include <fstream>
#include <string>

namespace hoshi {

// Build a std::filesystem::path from a UTF-8 std::string, correctly on all
// platforms. C++23: char8_t exists and std::filesystem::u8path is deprecated,
// so use the char8_t path constructor; older toolchains fall back to u8path.
inline std::filesystem::path fs_path(const std::string& utf8) {
#ifdef __cpp_char8_t
  return std::filesystem::path(
      std::u8string(reinterpret_cast<const char8_t*>(utf8.data()), utf8.size()));
#else
  return std::filesystem::u8path(utf8);
#endif
}

// Open helpers that take a UTF-8 path. fstream gained a std::filesystem::path
// ctor in C++17 which on Windows opens via the wide path → correct.
inline std::ifstream open_ifstream(const std::string& utf8_path,
                                   std::ios::openmode mode = std::ios::in) {
  return std::ifstream(fs_path(utf8_path), mode);
}

inline std::ofstream open_ofstream(const std::string& utf8_path,
                                   std::ios::openmode mode = std::ios::out) {
  return std::ofstream(fs_path(utf8_path), mode);
}

}  // namespace hoshi
```

- [ ] **Step 2: Commit**

```bash
git add native/hoshidicts/hoshidicts_src/util/fs_utf8.hpp
git commit -m "feat(native): add fs_utf8 UTF-8 path boundary helper"
```

---

## Task 2: memory.cpp 改用 CreateFileW（核心修复，让 zip.open 成功）

**Files:**
- Modify: `native/hoshidicts/hoshidicts_src/memory/memory.cpp`（仅 `_WIN32` 分支）

- [ ] **Step 1: 在文件顶部加 UTF-8→UTF-16 转换（Win32 段内）**

在 `#ifdef _WIN32 ... #include <windows.h>` 之后、`namespace memory {` 内的两个函数之前，加：

```cpp
#ifdef _WIN32
namespace {
std::wstring to_wide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(),
                              static_cast<int>(utf8.size()), nullptr, 0);
  std::wstring w(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()),
                      &w[0], n);
  return w;
}
}  // namespace
#endif
```

- [ ] **Step 2: map_rd 的 Win32 打开改宽字符**

把（约 L15-16）：

```cpp
  HANDLE file =
      CreateFileA(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
```

改为：

```cpp
  const std::wstring wpath = to_wide(path);
  HANDLE file = CreateFileW(wpath.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
```

并把 `CreateFileMappingA`（约 L27）改为 `CreateFileMappingW`（参数不变，name 仍为 nullptr）。

- [ ] **Step 3: map_rw 的 Win32 打开改宽字符**

把（约 L68-69）：

```cpp
  HANDLE file = CreateFileA(path.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
```

改为：

```cpp
  const std::wstring wpath = to_wide(path);
  HANDLE file = CreateFileW(wpath.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
```

并把 `CreateFileMappingA`（约 L81）改为 `CreateFileMappingW`。

> POSIX `#else` 分支（`open(path.c_str(), ...)`）**完全不动**——POSIX narrow 路径已是 UTF-8。

- [ ] **Step 4: 重编 Windows native lib 并跑独立打开复现，确认 CreateFileW 生效**

（见 Task 7 的独立测试 harness；此步先确认 map_rd 能打开日文名文件。）

- [ ] **Step 5: Commit**

```bash
git add native/hoshidicts/hoshidicts_src/memory/memory.cpp
git commit -m "fix(native): use CreateFileW for UTF-8 paths on Windows (BUG-045)"
```

---

## Task 3: importer.cpp 全部文件系统触点过 fs_utf8

**Files:**
- Modify: `native/hoshidicts/hoshidicts_src/importer.cpp`

- [ ] **Step 1: include 助手**

在现有 `#include <filesystem>`（L14）附近加：

```cpp
#include "util/fs_utf8.hpp"
```

- [ ] **Step 2: fstream 站点：把 `std::string` 路径参数包成 `hoshi::fs_path(...)`**

逐处改（保持其余参数不变）：
- L493 `std::ofstream media(path + "/media.bin", std::ios::binary);` → `std::ofstream media(hoshi::fs_path(path + "/media.bin"), std::ios::binary);`
- L494 `std::ofstream media_idx(path + "/media.idx", ...)` → 同式包裹
- L612 `std::ifstream file(mdx_path, std::ios::binary | std::ios::ate);` → `std::ifstream file(hoshi::fs_path(mdx_path), std::ios::binary | std::ios::ate);`
- L655 `std::ofstream out(temp_path, std::ios::binary);` → 包裹 `hoshi::fs_path(temp_path)`
- L697 `std::ofstream out(out_path, std::ios::binary);` → 包裹 `hoshi::fs_path(out_path)`
- L739 `std::ifstream file(dsl_path, ...)` → 包裹 `hoshi::fs_path(dsl_path)`
- L896 / L976 `std::ofstream styles_file(path + "/styles.css", std::ios::binary);` → 包裹
- L907 / L987 `std::ofstream blobs(path + "/blobs.bin", std::ios::binary);` → 包裹
- L933 / L1038 `std::ofstream sui(path + "/.hoshidicts_1", std::ios::binary);` → 包裹

- [ ] **Step 3: filesystem 站点：把 `std::string` 包成 `hoshi::fs_path(...)`**

- L651/L686 `std::filesystem::create_directories(temp_dir);` → `...create_directories(hoshi::fs_path(temp_dir));`
- L652 `std::filesystem::path(name).filename().string()` → `hoshi::fs_path(name).filename().string()`
- L660/L704/L709 `std::filesystem::remove_all(temp_dir);` → 包裹 `hoshi::fs_path(temp_dir)`
- L692 `std::filesystem::path(name).filename().string()` → `hoshi::fs_path(name)...`
- L693 `std::filesystem::path(filename).extension().string()` → `hoshi::fs_path(filename)...`
- L631/L826 `std::filesystem::path(mdx_path/dsl_path).stem().string()` → `hoshi::fs_path(...).stem().string()`
- L876/L956 `std::filesystem::path dict_path = std::filesystem::path(output_dir) / result.title;` → `std::filesystem::path dict_path = hoshi::fs_path(output_dir) / hoshi::fs_path(result.title);`
- L878/L958 `std::filesystem::weakly_canonical(output_dir)` → `...weakly_canonical(hoshi::fs_path(output_dir))`
- L941/L1046 `std::filesystem::remove_all(std::filesystem::path(output_dir) / result.title);` → `...remove_all(hoshi::fs_path(output_dir) / hoshi::fs_path(result.title));`

> `std::string path = dict_path.string();`（L885/L965）**保持不变**——`dict_path` 此时已是正确的 path 对象，`.string()` 在 Windows 返回的窄串仍是 ANSI，但它只再被喂回 `hoshi::fs_path(path + "...")`（已在 Step 2 包裹）→ 往返一致。注意：`path` 变量后续所有 `path + "/xxx"` 拼接点都必须经 fs_path（Step 2 与 Step 4 覆盖）。

- [ ] **Step 4: glaze 文件 IO 改为 buffer + fs_path 写盘（绕开 glaze 的窄路径）**

把 L888 / L971 的：

```cpp
    if (glz::write_file_json(index, path + "/index.json", std::string{})) {
      throw std::runtime_error("failed to write index.json");
    }
```

改为：

```cpp
    {
      std::string index_buf;
      if (glz::write_json(index, index_buf)) {
        throw std::runtime_error("failed to write index.json");
      }
      std::ofstream index_out(hoshi::fs_path(path + "/index.json"), std::ios::binary);
      index_out.write(index_buf.data(), static_cast<std::streamsize>(index_buf.size()));
      if (!index_out.good()) {
        throw std::runtime_error("failed to write index.json");
      }
    }
```

> `hash.table` / `bloom.filter` 经 `memory::map_rw`（Task 2 已修），无需改。

- [ ] **Step 5: 编译验证**

Windows 重编 hoshidicts（见 Task 7）。Android 侧 `flutter test` 不触发 native 重编，但需保证改动不破坏现有 Dart 测试。

- [ ] **Step 6: Commit**

```bash
git add native/hoshidicts/hoshidicts_src/importer.cpp
git commit -m "fix(native): route importer filesystem access through fs_utf8 (BUG-045)"
```

---

## Task 4: query.cpp 回读路径过 fs_utf8（日文标题词典查得到）

**Files:**
- Modify: `native/hoshidicts/hoshidicts_src/query.cpp`

- [ ] **Step 1: include 助手**（在现有 `#include <filesystem>` 附近）

```cpp
#include "util/fs_utf8.hpp"
```

- [ ] **Step 2: filesystem / fstream 站点包裹**

- L85 `std::filesystem::is_regular_file(path + "/.hoshidicts_1")` → `...is_regular_file(hoshi::fs_path(path + "/.hoshidicts_1"))`
- L96 `std::filesystem::path(path).stem().string()` → `hoshi::fs_path(path).stem().string()`
- L97 `std::filesystem::exists(path + "/styles.css")` → `...exists(hoshi::fs_path(path + "/styles.css"))`
- L98 `std::ifstream f(path + "/styles.css");` → `std::ifstream f(hoshi::fs_path(path + "/styles.css"));`

- [ ] **Step 3: glaze 读 index.json 改为 fs_path 读字节 + glz::read_json**

把 L92：

```cpp
  if (glz::read_file_json(index, path + "/index.json", buf)) {
    return;
  }
```

改为：

```cpp
  {
    std::ifstream index_in(hoshi::fs_path(path + "/index.json"), std::ios::binary);
    if (!index_in) return;
    std::string index_buf((std::istreambuf_iterator<char>(index_in)), {});
    if (glz::read_json(index, index_buf)) return;
  }
```

> `memory::map_rd(path + "/hash.table")` 等（L104/110...）随 Task 2 自动修好。

- [ ] **Step 4: Commit**

```bash
git add native/hoshidicts/hoshidicts_src/query.cpp
git commit -m "fix(native): route dictionary read-back through fs_utf8 (BUG-045)"
```

---

## Task 5: stardict_reader.cpp 过 fs_utf8

**Files:**
- Modify: `native/hoshidicts/hoshidicts_src/stardict/stardict_reader.cpp`

- [ ] **Step 1: include + 包裹**

加 `#include "util/fs_utf8.hpp"`；
- L14 `std::ifstream f(path, std::ios::binary | std::ios::ate);` → `std::ifstream f(hoshi::fs_path(path), std::ios::binary | std::ios::ate);`
- L92 `std::filesystem::path(ifo_path).stem().string()` → `hoshi::fs_path(ifo_path).stem().string()`

- [ ] **Step 2: Commit**

```bash
git add native/hoshidicts/hoshidicts_src/stardict/stardict_reader.cpp
git commit -m "fix(native): route StarDict reader through fs_utf8 (BUG-045)"
```

---

## Task 6: 源码守卫测试（防回归，最强可落地层之一）

**Files:**
- Create: `hibiki/test/dictionary/native_utf8_path_guard_test.dart`

- [ ] **Step 1: 写守卫测试（扫描 native 源码禁止裸 ANSI 触点）**

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// BUG-045: native hoshidicts must never reintroduce ANSI/narrow-codepage
// filesystem access on Windows. memory.cpp must use CreateFileW (not
// CreateFileA); all other UTF-8 path access must route through hoshi::fs_path.
void main() {
  final root = _repoRoot();
  final nativeSrc =
      Directory(p.join(root, 'native', 'hoshidicts', 'hoshidicts_src'));

  test('memory.cpp uses CreateFileW, never CreateFileA', () {
    final src = File(p.join(nativeSrc.path, 'memory', 'memory.cpp'))
        .readAsStringSync();
    expect(src.contains('CreateFileA'), isFalse,
        reason: 'CreateFileA mis-decodes UTF-8 paths as ANSI on Windows');
    expect(src.contains('CreateFileMappingA'), isFalse);
    expect(src.contains('CreateFileW'), isTrue);
  });

  test('importer/query/stardict route filesystem through fs_utf8', () {
    for (final rel in [
      p.join('importer.cpp'),
      p.join('query.cpp'),
      p.join('stardict', 'stardict_reader.cpp'),
    ]) {
      final src = File(p.join(nativeSrc.path, rel)).readAsStringSync();
      expect(src.contains('util/fs_utf8.hpp'), isTrue,
          reason: '$rel must include fs_utf8 helper');
      // glaze file IO takes a narrow path internally → must not be used.
      expect(src.contains('glz::write_file_json'), isFalse,
          reason: '$rel must write via fs_path, not glz::write_file_json');
      expect(src.contains('glz::read_file_json'), isFalse,
          reason: '$rel must read via fs_path, not glz::read_file_json');
    }
  });
}

String _repoRoot() {
  var dir = Directory.current;
  while (!File(p.join(dir.path, 'native', 'hoshidicts', 'CMakeLists.txt'))
      .existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate repo root from ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir.path;
}
```

- [ ] **Step 2: 跑测试（改前应红：memory.cpp 仍含 CreateFileA / 文件未 include 助手）**

Run: `cd hibiki && flutter test test/dictionary/native_utf8_path_guard_test.dart`
Expected (改 Task 2-5 前): FAIL。改完后: PASS。

- [ ] **Step 3: Commit**

```bash
git add hibiki/test/dictionary/native_utf8_path_guard_test.dart
git commit -m "test(native): guard against ANSI path regression on Windows (BUG-045)"
```

---

## Task 7: 独立 native 端到端测试（Windows 真实复现 → 转绿）

**Files:**
- Create: `native/hoshidicts/tests/win_utf8_import_test.cpp`
- Create: `native/hoshidicts/tests/run_win_utf8_test.bat`（本机/CI 手动跑）

- [ ] **Step 1: 写测试**：构造一个最小 yomitan zip（index.json + term_bank_1.json），写到 `<temp>/複合語起源.zip`（UTF-8 名），调用 `dictionary_importer::import(zip_path, <temp>/out)`，断言 `result.success == true` 且 `result.title` 非空；再 `DictionaryQuery::add_dict` 回读并 `query` 一个已知词条，断言命中。（该测试直接编译 `memory.cpp / zip.cpp / importer.cpp / query.cpp / hash.cpp / bloom.cpp / yomitan_parser.cpp` 等真实源，链接 libdeflate + glaze。）

- [ ] **Step 2: 编译运行（VS2022）**

```bat
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
cl /nologo /std:c++latest /EHsc /utf-8 /I <includes...> win_utf8_import_test.cpp <src...> /Fe:win_utf8_import_test.exe
win_utf8_import_test.exe
```

Expected（改前）: import FAILED "unsupported format or failed to open file"。改后: import OK + query 命中。

- [ ] **Step 3: Commit**

```bash
git add native/hoshidicts/tests/win_utf8_import_test.cpp native/hoshidicts/tests/run_win_utf8_test.bat
git commit -m "test(native): Windows UTF-8 dictionary import round-trip (BUG-045)"
```

---

## Task 8: 真机端到端验证 + BUG 登记

- [ ] **Step 1: 重建 Windows app 并真实导入日文名词典**

在 `hibiki/` 跑 `flutter build windows`（或 run），用"选文件"导入一个日文名 `.zip` + 在推荐词典里下载 `複合語起源`，确认两者都成功、能查词。留截图证据。

- [ ] **Step 2: 全量 Dart 测试**

Run: `cd hibiki && dart format . && flutter test`
Expected: 全绿（含新 guard 测试）。

- [ ] **Step 3: 按 docs/BUGS.md 追加 BUG-045**

记根因 `memory.cpp:CreateFileA` + 完整触点；① 根因修复勾选（Task 2-5 提交哈希）；② 自动化测试勾选（Task 6 guard + Task 7 native round-trip）。

- [ ] **Step 4: Commit**

```bash
git add docs/BUGS.md
git commit -m "docs(bugs): record BUG-045 Windows UTF-8 dictionary import failure"
```

---

## Self-Review 备注

- **Spec 覆盖**：5 个运行路径文件全部列入 Task 2-5；`hash/bloom` 经 `map_rw` 自动覆盖；glaze 文件 IO 三站点（importer ×2 写、query ×1 读）已显式改 buffer 法。
- **类型一致**：助手命名 `hoshi::fs_path` / `hoshi::open_ifstream` 全程一致；Task 3-5 一律调用 `hoshi::fs_path`。
- **向后兼容（Never break userspace）**：POSIX 分支零改动 → Android/macOS/Linux 行为不变；ASCII 路径在 Windows 上 `CreateFileW`/`fs_path` 结果与原先等价（已复现 ASCII 两法皆 OK）；已导入的 ASCII 名词典目录回读不受影响。日文名词典此前在 Windows 本就无法导入，无"既有可用行为"被破坏。
- **风险点**：`path + "..."` 字符串拼接点众多，遗漏任一处会导致该文件名仍走 ANSI；Task 6 guard 仅能抓 include/glaze，拼接遗漏靠 Task 7 端到端兜底。务必通读 importer.cpp 确保每个 `path +`/`temp_dir +`/`out_path` 喂入文件 API 处都经 `fs_path`。
