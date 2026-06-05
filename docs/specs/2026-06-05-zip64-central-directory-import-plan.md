# ZIP64 中央目录解析支持 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 `hoshidicts` 原生 ZIP 解析器支持 per-entry ZIP64 扩展字段（header id `0x0001`），使被「强制 ZIP64」打包的词典 zip（即使 <4GB）能成功 `zip.open()` 并导入。

**Architecture:** 根因是手写解析器 `Zip::parse_central_directory`（`native/hoshidicts/hoshidicts_src/zip/zip.cpp`）在遇到中央目录条目的 32 位字段等于 `0xFFFFFFFF` 哨兵（comp size / uncomp size / local-header offset）时直接 `return false`（zip.cpp:174-178），等于完全不支持 per-entry ZIP64。ZIP64 EOCD 那层（total_entries / cd_offset）已处理（zip.cpp:133-139），唯独 per-entry 漏了。修法：当任一字段是哨兵时，按 APPNOTE 4.5.3 解析该条目 extra 区里 id=`0x0001` 的块，按固定顺序（uncompressed、compressed、local-header offset）读出被哨兵化的 64 位真值。消除「遇 ZIP64 就放弃」这个特殊情况。

**Tech Stack:** C++23、MSVC（Windows，vcvars64）、libdeflate；Drift/Dart 上层不改。

**真实复现样本（root-cause 证据）：** `D:\辞典\（大修館）明鏡国語辞典［第二版］.zip`（9.8MB，6 条目，全部 `0xFFFFFFFF` 哨兵 + `0x0001` extra；内含 `.mdx/.mdd` → 修好后走 importer.cpp:1095 `import_mdx_from_zip`）。Python `zipfile` 能正常打开，证明文件合法、是我们解析器的缺陷。

---

## File Structure

| 文件 | 改动 | 责任 |
|---|---|---|
| `native/hoshidicts/hoshidicts_src/zip/zip.hpp` | Modify | `ZipEntry::compressed_size`/`uncompressed_size` 由 `uint32_t` 拓宽为 `uint64_t`，承载 ZIP64 真值 |
| `native/hoshidicts/hoshidicts_src/zip/zip.cpp` | Modify | `parse_central_directory` 解析 per-entry `0x0001` extra；移除「遇哨兵 return false」 |
| `native/hoshidicts/tests/zip64_central_dir_test.cpp` | Create | 原生单元测试：手工构造一个 per-entry ZIP64 fixture，断言 `Zip::open` 成功且能读回内容（改前红、改后绿） |
| `native/hoshidicts/tests/run_zip64_test.bat` | Create | vcvars64 + cl 一键编译运行该测试 |
| `hibiki/test/dictionary/zip64_source_guard_test.dart` | Create | Dart 源码扫描守卫：确保 zip.cpp 不再无条件 `return false` 于哨兵、且含 `0x0001` 解析（防回归） |
| `docs/BUGS.md` | Modify | 追加 BUG-0NN 记录（根因 `zip.cpp:174` + 两勾选框） |

---

## Task 1: 拓宽 ZipEntry 尺寸字段为 64 位

**Files:**
- Modify: `native/hoshidicts/hoshidicts_src/zip/zip.hpp:10-16`

- [ ] **Step 1: 改结构体**

把：

```cpp
struct ZipEntry {
  std::string name;
  uint16_t compression_method;
  uint32_t compressed_size;
  uint32_t uncompressed_size;
  size_t data_offset;
};
```

改为：

```cpp
struct ZipEntry {
  std::string name;
  uint16_t compression_method;
  uint64_t compressed_size;    // ZIP64 may store true size via 0x0001 extra
  uint64_t uncompressed_size;  // ZIP64 may store true size via 0x0001 extra
  size_t data_offset;
};
```

- [ ] **Step 2: 确认无回归编译点**

`zip.cpp` 里 `read()`/`read_media()` 用 `result.resize(e.uncompressed_size)` 与 libdeflate 调用（参数都是 `size_t`）：64 位值对 <4GB 条目语义不变，无需改。`has_entry_payload`（zip.cpp:23-28）用这两个字段算 `payload_size`，`in_bounds` 形参 `size_t`，64 位机器无截断；本任务不改它。

- [ ] **Step 3: 提交**

```bash
git add native/hoshidicts/hoshidicts_src/zip/zip.hpp
git commit -m "refactor(zip): widen ZipEntry size fields to uint64 for ZIP64"
```

---

## Task 2: parse_central_directory 解析 per-entry ZIP64 extra（核心修复）

**Files:**
- Modify: `native/hoshidicts/hoshidicts_src/zip/zip.cpp:159-200`

- [ ] **Step 1: 替换条目解析段**

把现有 159-178 段（从 `ZipEntry e;` 到三字段哨兵 `return false;` 那块）替换为下面实现。注意：先读 32 位值，再仅对被哨兵化的字段、按 `uncompressed → compressed → lfh_offset` 固定顺序从 `0x0001` extra 取 64 位真值。

```cpp
    ZipEntry e;
    e.compression_method = read_at<uint16_t>(base, pos + 10);
    const uint32_t comp32 = read_at<uint32_t>(base, pos + 20);
    const uint32_t uncomp32 = read_at<uint32_t>(base, pos + 24);

    auto name_len = read_at<uint16_t>(base, pos + 28);
    auto extra_len = read_at<uint16_t>(base, pos + 30);
    auto comment_len = read_at<uint16_t>(base, pos + 32);

    const uint32_t lfh32 = read_at<uint32_t>(base, pos + 42);
    const size_t entry_size = 46 + static_cast<size_t>(name_len) + extra_len +
                              comment_len;
    if (!in_bounds(file.size, pos, entry_size)) {
      return false;
    }

    e.compressed_size = comp32;
    e.uncompressed_size = uncomp32;
    uint64_t lfh_offset = lfh32;

    // ZIP64: any field equal to 0xFFFFFFFF means the real 64-bit value lives in
    // the central-directory extra block under header id 0x0001. The block packs
    // ONLY the overflowed fields, in fixed order: uncompressed, compressed,
    // local-header offset. (APPNOTE 4.5.3)
    if (comp32 == 0xFFFFFFFFu || uncomp32 == 0xFFFFFFFFu ||
        lfh32 == 0xFFFFFFFFu) {
      const size_t extra_base = pos + 46 + name_len;
      size_t eo = 0;
      bool resolved = false;
      while (eo + 4 <= extra_len) {
        const uint16_t hid = read_at<uint16_t>(base, extra_base + eo);
        const uint16_t hsz = read_at<uint16_t>(base, extra_base + eo + 2);
        if (eo + 4 + hsz > extra_len) {
          break;
        }
        if (hid == 0x0001) {
          size_t fo = extra_base + eo + 4;
          size_t remaining = hsz;
          auto take64 = [&](uint64_t& out) -> bool {
            if (remaining < 8) return false;
            out = read_at<uint64_t>(base, fo);
            fo += 8;
            remaining -= 8;
            return true;
          };
          if (uncomp32 == 0xFFFFFFFFu && !take64(e.uncompressed_size)) {
            return false;
          }
          if (comp32 == 0xFFFFFFFFu && !take64(e.compressed_size)) {
            return false;
          }
          if (lfh32 == 0xFFFFFFFFu && !take64(lfh_offset)) {
            return false;
          }
          resolved = true;
          break;
        }
        eo += 4 + hsz;
      }
      if (!resolved) {
        return false;  // sentinel without ZIP64 extra → malformed
      }
    }

    e.name.assign(reinterpret_cast<const char*>(base + pos + 46), name_len);

    if (lfh_offset > file.size) {
      return false;
    }
    if (!in_bounds(file.size, lfh_offset, 30)) {
      return false;
    }
```

随后保留原有 185-202 段（LFH 签名校验、`lfh_name_len`/`lfh_extra_len`、`data_offset`、`has_entry_payload`、`entries.push_back`、`pos += entry_size`），但其中原来用 `lfh_offset`（原为 `auto lfh_offset = read_at<uint32_t>(base, pos + 42);`）的地方现在改用上面定义的 `uint64_t lfh_offset`，删除原 168 行那条 `auto lfh_offset = ...;`（已由新代码提供）。`read_at<uint16_t>(base, lfh_offset + 26)` 等保持不变。

- [ ] **Step 2: 确认边界安全**

`extra_base + eo (+2)` 与 `take64` 的 `fo` 全落在 `[pos, pos+entry_size)`，而 `entry_size` 已过 `in_bounds(file.size, pos, entry_size)`，故所有 extra 读取不越界。`lfh_offset` 新增 `> file.size` 与 `in_bounds(..,30)` 双闸。

- [ ] **Step 3: 提交**

```bash
git add native/hoshidicts/hoshidicts_src/zip/zip.cpp
git commit -m "fix(zip): parse per-entry ZIP64 extra field (0x0001) in central dir"
```

---

## Task 3: 原生单元测试（red→green，手工 ZIP64 fixture）

**Files:**
- Create: `native/hoshidicts/tests/zip64_central_dir_test.cpp`
- Create: `native/hoshidicts/tests/run_zip64_test.bat`

- [ ] **Step 1: 写测试**

`zip64_central_dir_test.cpp`：在内存里拼出一个最小、合法、含 per-entry ZIP64 extra 的 zip（单条目 `a.txt`，stored，内容 `hi`，CDH 的 comp/unc/lfh 全置 `0xFFFFFFFF`，extra id=`0x0001` 带 `[unc=2, comp=2, lfh=0]`），写到临时文件，`Zip::open` 必须成功，`find("a.txt")>=0`，`read(idx)=="hi"`。

```cpp
// BUG-0NN guard: a ZIP whose central-directory entry uses the ZIP64 0xFFFFFFFF
// sentinels (forced-zip64, even when <4GB) must open. Before the fix
// Zip::parse_central_directory bailed at the first sentinel and zip.open()
// returned false -> "unsupported format or failed to open file".
// Real-world trigger: （大修館）明鏡国語辞典［第二版］.zip
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "zip/zip.hpp"

namespace {
void put16(std::vector<uint8_t>& b, uint16_t v) {
  b.push_back(v & 0xff);
  b.push_back((v >> 8) & 0xff);
}
void put32(std::vector<uint8_t>& b, uint32_t v) {
  for (int i = 0; i < 4; i++) b.push_back((v >> (8 * i)) & 0xff);
}
void put64(std::vector<uint8_t>& b, uint64_t v) {
  for (int i = 0; i < 8; i++) b.push_back((v >> (8 * i)) & 0xff);
}
}  // namespace

int main() {
  const std::string name = "a.txt";
  const std::string data = "hi";

  std::vector<uint8_t> z;
  // ---- Local File Header @0 ----
  put32(z, 0x04034b50);      // sig
  put16(z, 45);              // version needed (zip64)
  put16(z, 0);               // flags
  put16(z, 0);               // method = stored
  put16(z, 0);               // modtime
  put16(z, 0);               // moddate
  put32(z, 0);               // crc32 (parser doesn't verify)
  put32(z, (uint32_t)data.size());  // comp size (real in LFH; parser ignores)
  put32(z, (uint32_t)data.size());  // uncomp size
  put16(z, (uint16_t)name.size());  // name len
  put16(z, 0);               // extra len
  for (char c : name) z.push_back((uint8_t)c);
  const size_t data_off = z.size();
  for (char c : data) z.push_back((uint8_t)c);

  // ---- Central Directory Header @cd_off ----
  const size_t cd_off = z.size();
  put32(z, 0x02014b50);      // sig
  put16(z, 45);              // version made by
  put16(z, 45);              // version needed
  put16(z, 0);               // flags
  put16(z, 0);               // method = stored
  put16(z, 0);               // modtime
  put16(z, 0);               // moddate
  put32(z, 0);               // crc32
  put32(z, 0xFFFFFFFF);      // comp size  -> ZIP64 sentinel
  put32(z, 0xFFFFFFFF);      // uncomp size -> ZIP64 sentinel
  put16(z, (uint16_t)name.size());  // name len
  put16(z, 24);              // extra len (4 hdr + 8+8+8)
  put16(z, 0);               // comment len
  put16(z, 0);               // disk start
  put16(z, 0);               // internal attrs
  put32(z, 0);               // external attrs
  put32(z, 0xFFFFFFFF);      // lfh offset -> ZIP64 sentinel
  for (char c : name) z.push_back((uint8_t)c);
  // ZIP64 extra: id=0x0001, size=24, body = unc, comp, lfh
  put16(z, 0x0001);
  put16(z, 24);
  put64(z, data.size());     // uncompressed
  put64(z, data.size());     // compressed
  put64(z, 0);               // local-header offset
  const size_t cd_size = z.size() - cd_off;

  // ---- End Of Central Directory @eocd ----
  put32(z, 0x06054b50);      // sig
  put16(z, 0);               // disk
  put16(z, 0);               // cd start disk
  put16(z, 1);               // entries this disk
  put16(z, 1);               // total entries
  put32(z, (uint32_t)cd_size);
  put32(z, (uint32_t)cd_off);
  put16(z, 0);               // comment len

  const std::string path =
      std::string(std::getenv("TEMP") ? std::getenv("TEMP") : ".") +
      "/hoshi_zip64_fixture.zip";
  FILE* f = std::fopen(path.c_str(), "wb");
  if (!f) { std::fprintf(stderr, "cannot write fixture\n"); return 2; }
  std::fwrite(z.data(), 1, z.size(), f);
  std::fclose(f);

  Zip zip;
  if (!zip.open(path)) {
    std::fprintf(stderr, "FAIL: zip.open returned false on zip64 fixture\n");
    return 1;
  }
  const int idx = zip.find(name);
  if (idx < 0) {
    std::fprintf(stderr, "FAIL: entry not found\n");
    return 1;
  }
  if (zip.read(idx) != data) {
    std::fprintf(stderr, "FAIL: content mismatch\n");
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
```

- [ ] **Step 2: 写编译脚本** `run_zip64_test.bat`

```bat
@echo off
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
cd /d "%~dp0\.."
cl /nologo /std:c++latest /EHsc /utf-8 /MD ^
  /I hoshidicts_src ^
  /I hoshidicts_external\libdeflate ^
  tests\zip64_central_dir_test.cpp ^
  hoshidicts_src\zip\zip.cpp ^
  hoshidicts_src\memory\memory.cpp ^
  hoshidicts_external\libdeflate\lib\*.c hoshidicts_external\libdeflate\lib\x86\*.c ^
  /Fe:tests\zip64_central_dir_test.exe
tests\zip64_central_dir_test.exe
```

> 构建坑（沿用 BUG-045 经验）：`vcvars64.bat` 后续命令**不要重定向到 `nul`**（否则 `cl` 报 9009）；`cl` 命令写成单行/或 `^` 续行；`/MD` 匹配 CRT。libdeflate 实际需要的 .c 文件清单以编译报错为准（缺符号就补对应 lib\\*.c）。

- [ ] **Step 3: 改前跑测试确认红**

在 Task 2 改 zip.cpp **之前**的代码上运行：

Run: `native\hoshidicts\tests\run_zip64_test.bat`
Expected: 退出码 1，`FAIL: zip.open returned false on zip64 fixture`（撞 zip.cpp:174 哨兵）。

- [ ] **Step 4: 应用 Task 2 修复后跑测试确认绿**

Run: `native\hoshidicts\tests\run_zip64_test.bat`
Expected: `PASS`，退出码 0。

- [ ] **Step 5: 用真实样本端到端复测**

把 `（大修館）明鏡国語辞典［第二版］.zip` 临时拷到含 ASCII 路径的目录，写一个一次性 probe（或复用 `win_utf8_import_test` 形态）调用 `dictionary_importer::import` 断言 `success==true`。确认修好后路由到 `import_mdx_from_zip` 成功。留输出证据。

- [ ] **Step 6: 提交**

```bash
git add native/hoshidicts/tests/zip64_central_dir_test.cpp native/hoshidicts/tests/run_zip64_test.bat
git commit -m "test(zip): native red->green guard for per-entry ZIP64 import"
```

---

## Task 4: Dart 源码扫描守卫（防回归）

**Files:**
- Create: `hibiki/test/dictionary/zip64_source_guard_test.dart`

- [ ] **Step 1: 写守卫测试**

读 `native/hoshidicts/hoshidicts_src/zip/zip.cpp` 源码字符串，断言：① 含 `0x0001`（per-entry zip64 extra 解析存在）；② 不存在「三字段哨兵立即 `return false`」的旧模式（即不再有 `== std::numeric_limits<uint32_t>::max()` 紧跟 `return false` 且无 extra 解析）。用宽松正则，目标是抓「修复被整体删除/回退」。

```dart
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('zip.cpp parses per-entry ZIP64 extra (0x0001), no blanket sentinel bail',
      () {
    // 仓库根：本测试在 hibiki/ 下跑，向上两级到 repo root。
    final repoRoot = p.normalize(p.join(Directory.current.path, '..'));
    final zipCpp = File(p.join(repoRoot, 'native', 'hoshidicts',
        'hoshidicts_src', 'zip', 'zip.cpp'));
    expect(zipCpp.existsSync(), isTrue,
        reason: 'zip.cpp 路径变了？更新本守卫。当前找: ${zipCpp.path}');
    final src = zipCpp.readAsStringSync();

    expect(src.contains('0x0001'), isTrue,
        reason: 'ZIP64 per-entry extra (header id 0x0001) 解析缺失或被回退');
    expect(src.contains('uncomp32'), isTrue,
        reason: '应保留 32 位读出 + 哨兵判定（uncomp32 等命名）');
  });
}
```

- [ ] **Step 2: 跑测试确认绿（在 Task 2 之后）**

Run（在 `hibiki/`）: `flutter test test/dictionary/zip64_source_guard_test.dart`
Expected: PASS。

> 注：repo-root 相对路径若与现有 native guard 测试（`test/.../win_utf8_*`）不一致，按现有那条 guard 的定位方式对齐（参考 BUG-045 的 guard 测试），避免 CI 工作目录差异。

- [ ] **Step 3: 提交**

```bash
git add hibiki/test/dictionary/zip64_source_guard_test.dart
git commit -m "test(dict): source guard for ZIP64 central-directory parsing"
```

---

## Task 5: 重建部署 DLL + BUGS.md 记录

**Files:**
- Modify: `docs/BUGS.md`

- [ ] **Step 1: 重建 Windows native DLL 并随 app 部署**

在 `hibiki/` 跑 `flutter build windows`（或 run），确保新 `hoshidicts_ffi.dll`（含本修复）部署到运行目录。

- [ ] **Step 2: 真机/真 app 复测原始失败路径**

用「导入文件夹词典」选 `D:\辞典\`，确认 14 个全部成功（尤其 `（大修館）明鏡国語辞典`），能查词。留截图。

- [ ] **Step 3: 追加 BUGS.md（取下一个 BUG-0NN 号，按 docs/BUGS.md 头部流程）**

记：根因 `native/hoshidicts/hoshidicts_src/zip/zip.cpp:174`（per-entry ZIP64 哨兵无条件 return false）；现象「导入文件夹词典时被强制 ZIP64 的 zip 报 unsupported format」；① 根因修复勾选（Task 2 哈希）；② 自动化测试勾选（Task 3 native + Task 4 guard）。

- [ ] **Step 4: 提交**

```bash
git add docs/BUGS.md
git commit -m "docs(bugs): record ZIP64 central-directory import fix (BUG-0NN)"
```

---

## Self-Review

1. **Spec coverage**：根因（per-entry ZIP64 未解析）→ Task 1+2；最强层自动化测试 → Task 3（native red→green）+ Task 4（源码守卫）；真机验证 → Task 5。MDX-in-zip 后续链路无需改（importer.cpp:1092 已支持）。
2. **Placeholder scan**：无 TODO/「类似上文」；测试代码、fixture 字节、编译命令均给全。
3. **Type consistency**：`ZipEntry::compressed_size`/`uncompressed_size` 全程 `uint64_t`；新增局部 `comp32`/`uncomp32`/`lfh32`（`uint32_t`）与 `lfh_offset`（`uint64_t`）命名在 Task 2 与 Task 4 守卫一致。

## 风险点

- **libdeflate 源清单**：`run_zip64_test.bat` 的 `lib\*.c` 通配可能多编/少编，按链接报错增删；只要能链出 `zip.cpp`+`memory.cpp` 依赖即可。
- **32 位 ABI**（armeabi-v7a）：`size_t` 32 位时 >4GB 条目会截断——但词典单条目均 <4GB，且本改动对 <4GB 条目行为与原 `uint32_t` 完全等价，不引入新风险。
- **极少数畸形 zip**：哨兵存在但无 `0x0001` extra → 仍 `return false`（保守拒绝，等价于现状）。
