## BUG-1225 · 读端共享内存写权限不可收紧：SelectTextThread 的原子写落在只读页上会崩

- **报告**：2026-07-28（用户：无——本条来自 BUG-1216 的跟进调查，是**预防性守卫**，不是线上故障）
- **真实性**：✅ 真隐患（未发布）。差点作为"零代价收紧"改动发出去，复核时拦下。

### 起因

BUG-1216（共享内存打不开只说一句「请重启 Hibiki」）的根治调查里，曾提出一个看似零代价的旁路：
读端 `voice_hook_reader.cpp` 用 `FILE_MAP_READ | FILE_MAP_WRITE` 打开映射，若读端其实从不写，
就能收紧成只读——不动 native、不改 IPC、不重发 helper，而且若拒绝访问是"写权限"引起的，
这一下就修好了。

该结论**是错的**。首轮审计用 `grep '=' 赋值` 与 `grep memcpy` 判定"读端从不写"，
而真正的写是**原子写**，两种都不是：

- `hibiki/windows/runner/voice_hook_reader.cpp:446`
  `InterlockedExchange64(reinterpret_cast<volatile LONGLONG*>(&h->selected_text_thread_id), ...)`
- 目标字段在**映射内**：`hibiki/windows/runner/voice_hook_ipc.h:162`
  `volatile uint64_t selected_text_thread_id;`
- 同处 `voice_hook_reader.cpp:442` 的 `SharedHeader* h` 是全文件**唯一**非 const 的 header 指针，
  首轮也一并漏看。

### 后果（若当时改了）

以 `FILE_MAP_READ` 映射的页是 PAGE_READONLY，往上面做原子写触发 **ACCESS_VIOLATION**，
`SelectTextThread` 周围没有 SEH ——**Hibiki.exe 直接崩**。且该路径在**自动**流程上
（`hibiki/lib/src/mining/gal_hook_session_controller.dart:2199` 自动挑选文本线程，无需用户手动），
即常规 galgame 文本 hook 一跑就崩，而不是"某个功能不可用"。

`selected_text_thread_id` 是一条真实的**读端 → 注入端控制通道**，注入端确实读它：
`native/galgame_hook/hook/adapters/kirikiri_adapter.inc:114`、
`native/galgame_hook/include/luna_text_selector.h`、
`native/galgame_hook/injector/injector_main.cpp:764`。

### 附带更正（BUG-1216 调查记录）

- "存在零代价、不动 ACL 的旁路"——**划掉，不存在**。
- 该调查给出的最小 DACL 形态 `(A;;GR;;;<用户SID>)` 只给读，**不够**，至少要到 `SECTION_MAP_WRITE`。
- 读端既然必须写，若对象带高完整性标签，Windows 默认 **NO_WRITE_UP 会直接挡掉写**，
  中完整性的 Hibiki 无解——除非提权或改对象 ACL/标签。即"可能绕不开信任边界"这一判断被加强。
- 仍不能排除用户那例是 helper 版本漂开而非 ACL；以下一份带 token 的报错为准再定。

- **[x] ① 已修复** — 无代码修复：正确行为就是**维持现状**（保留 `FILE_MAP_WRITE`）。本条交付的是
  防止再犯的守卫，见 ②。
- **[x] ② 已加自动化测试** — `hibiki/test/tools/voice_hook_reader_write_access_guard_test.dart`，2 例：
  ①**前提**断言 `SelectTextThread` 仍对映射内 `selected_text_thread_id` 做 `InterlockedExchange64`；
  ②**因此**断言 `Open` 里 `OpenFileMappingW` 与 `MapViewOfFile` **各自的实参**都含 `FILE_MAP_WRITE`
  （判据落在两处实参上而非"函数体里出现过"，否则"一处保留、另一处改只读"能骗过守卫，而两处
  任缺其一都同样让原子写落在只读页）。扫描前剥 `//` 与 `/* */` 注释，函数体扫不到即判红防空集。
  守卫**把要求绑在成因上**：哪天 `SelectTextThread` 真改走别的通道，第一条断言先失败并指明
  "前提没了，可以连同写权限一起撤"，守卫自行退休而非变成没人敢动的化石。

  变异实测（`git diff --stat` 实证落盘，跑完还原）：去掉 `MapViewOfFile` 的 `FILE_MAP_WRITE` → 转红；
  去掉 `OpenFileMappingW` 的 → 转红；把 `InterlockedExchange64` 换成普通赋值（前提伪装）→ 转红。

### 备注

🔴 **这条守卫只到源码扫描 + 编译门这一层，证明不了运行时行为。**
`hibiki/windows/runner/voice_hook_reader.cpp` 由 `hibiki/windows/runner/CMakeLists.txt` 编译进
Flutter Windows runner，与 `native/galgame_hook/` 那 22 条 ctest **不是同一构建单元**，
那些 ctest 一行都跑不到它。本轮也**未做真机验证**（不涉及行为变更，无可验之新行为）。

📌 通用教训（已请求存档）：审计"这段代码写不写某块内存"时，`=` 赋值与 `memcpy` **不构成全集**，
必须一并扫**原子操作**（`Interlocked*`）、**非 const 指针**、以及任何经 `&` 取址传出的路径。
