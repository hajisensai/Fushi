## BUG-4470 · Leaf/AQUAPLUS：WHITE ALBUM2 另一构建不被认领（准入钉在单个 exe 摘要 + glyph 返回点判据无选择性）
- **报告**：2026-11-11（引擎适配任务：WHITE ALBUM2 2011 PC 版另一构建，磁盘 exe SHA-256 `c395d93f74695d2bb7a4fb2fe30486a5d37715b4c30bf20451883569bba3990b`，x86）
- **真实性**：✅ 真 bug，两处根因：
  1. 准入钉在单个 exe 摘要：旧 `native/galgame_hook/hook/adapters/leaf_aquaplus_adapter.inc:665`（develop@8603d1a764）`MatchesLeafAquaplusProfile(kWhiteAlbum2LeafAquaplusProfile, digest…)`，摘要不同直接 -1，结构门都没机会跑；违反「只做引擎级适配」硬规则。
  2. 自推导里 glyph 单字节返回点的判据是「窗口内任意一条 rel32 call」：旧 `native/galgame_hook/hook/adapters/leaf_aquaplus_autoprofile.h:396`。traversal 函数体内插了 0x13 字节后，起点落空、±0x40 窗口里有 6 条 call → 判「不唯一」整体拒绝（离线 probe：`failed_at=glyph_single_return`）。
  - 任务描述里的「exe 有壳、磁盘字节与运行时不同」经核对**不成立**：磁盘 `.text` 与运行时主模块 dump 只差 7 处 5 字节 `E9` 跳转（注入模块的 inline detour，其中一处正落在 HSX0:0 文本 hook 点），`.rdata` 差异是 IAT 填充，可执行节熵 6.74 bit/byte（非压缩 / 加密）。
- **[x] ① 已修复** — 准入改为结构证明（`ProveLeafStructure`：锚点 → return site → 节角色），摘要只做诊断与已测量构建自检；glyph 派发函数改由「被 traversal 函数体 ≥3 处 rel32 调用」定位，三个返回点要求调向它、调用点前有 0x100 字节状态拷贝帧、彼此间距等于已测量间距；raster 返回点要求 `add esp,8; ret`（两条栈偏移由此有结构依据）。另加带壳构建的运行时映像证明（可执行节无原始数据 / 高熵时启用，500ms/120s 重扫，壳解完且指纹稳定即终局），运行时映像上 hook 点允许是跳出主映像的 detour。离线 `fushi_leaf_site_probe` 对磁盘 exe 与运行时 dump 解析出同一套 RVA；8 个他引擎样本（BGI×2、CS2、EAGLS、Liar、Nitro、Kaguya、ExHIBIT，含 BGI 带壳 exe 与其运行时 dump）全部拒绝。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/leaf_autoprofile_test.cpp`（函数体内插码后仍解析、间距不符 / 缺状态拷贝帧 / raster 后缀不符拒绝、hook 点 detour 只在运行时映像认、跳回映像内的 jmp 拒绝、节角色、带壳判据）；`native/galgame_hook/tests/adapter_structure_test.py`（准入不得用摘要、磁盘先于运行时、窗口内不写永久缓存）。
- **备注**：真机 accept4（四条 + 真卡）未跑，状态仍 `implemented_unverified`；已测量构建（`005e7110…`）本机无样本，新增的帧形状判据未在它上面离线复核，只靠其已测量 RVA 布局推断一致（raster 返回点 = traversal−9、单 / 双字节间距 0x150 / 0xC3 与本构建相同），并由运行期自检兜底（摘要等于已测量构建而推导出不同锚点即拒绝）。
