## BUG-1769 · 非16bit游戏语音把所有音源拼成一句（卡顿重复）
- **报告**：2026-08-22（用户：白色相簿2 的「音频提取」会卡顿、重复）
- **真实性**：✅ 真 bug（代码层确定性缺陷，非推测）。根因在 `fushi/windows/runner/voice_hook_reader.cpp` 的 `GrabUtterance`：选语音源的唯一判据是每条 clip 的平均绝对幅值，而旧的 `ClipEnergy16Locked` 开头就是 `if (c->bits_per_sample != 16 || c->is_float) return -1.0;`。于是 **float32 输出的游戏（XAudio2 的默认格式）每条 clip 都算不出能量 → `any_energy` 恒假 → `filter_by_src` 退化成 false**，随后的拼接循环把窗口内**每一个 `source_ptr`** 的 PCM 顺序 `memcpy` 到同一段里（原注释白纸黑字写着「退化为拼所有源」）。同一时刻环里通常同时有语音源、BGM 源和混音输出，拼起来听感就是「同一句念两遍、中间夹一段断续杂音」——即用户说的「卡顿重复」。而且 `fmt` 取自首段，各源采样率/声道数不同的字节被当成同一格式播放，进一步变成字节级垃圾。

  相关放大项：`_settleLineUtterance`（`gal_hook_session_controller.dart`）每 250ms 调一次 `grabUtterance`、最长 6s（约 24 次），且只按「更长就更好」接受结果——一旦拼接产生了双倍长度，它会**主动**接受那个重复版本。

  **未能在本机复现的部分**：WHITE ALBUM2 没有安装在这台机器上（全盘 6 层搜索无结果；`galgames` 表只有 `TenShiSouZou_R18`(KiriKiri) 与 `屋上の百合霊さん`）。用户偏好里已捕获过的游戏格式全是 16-bit（`gal_capture_memory::…` 的 `excludedTracks` 形如 `0:48000:2:16:0`），所以那几个游戏走不到这条退化分支。WA2（Leaf/AQUAPLUS）在本仓**没有专属 engine profile 或 adapter**（`profiles/` 只有 artemis / bgi / catsystem2 / elf_ai6 / malie / qlie / reallive 七个），只能落到通用 `GenericWindowsAudioAdapter`（XAudio2 `SubmitSourceBuffer` / DirectSound `Unlock`）这条路径——也就是最容易命中本 bug 的那条。
- **[x] ① 已修复** — 能量计算改成**与位深/浮点无关**，退化分支整个删掉：
  - 新增 `native/galgame_hook/include/voice_clip_energy.h`：`ClipSampleAbs16Scale` / `ClipSumAbs16ScaleRange` / `ClipEnergy16Scale`，支持 PCM 8/16/24/32-bit 与 float32，统一归一到 16-bit 标度，位深真的不认识才返回 -1。
  - `voice_hook_reader.cpp` 的 `ClipEnergy16Locked` → `ClipEnergyLocked`，改为薄封装（只管环形覆盖判定）。
  - `GrabUtterance` 里 `any_energy` 为假时不再「拼所有源」，改用格式无关的代理判据（文本时刻窗内写入字节最多的源）选出**唯一一个**源；选不出就返回空交调用方回退。所有分支出口现在都是「一个源」或「空」。
  - 拼接循环新增 `ClipFormatMatches` 门：同一源中途换了采样率/声道/位深的段整段跳过，宁可短一点也不给用户字节级噪声。
  - 顺带修掉 BUG-1165 的老症状：`ListAudioTracks` 里非 16-bit 轨的 `avg_energy` 不再恒为 -1。
  - `native/galgame_hook/tools/ring_probe.cpp` 里那份手抄副本一并收进共享头——取证工具报「非 16-bit 无能量」会把以后的排查直接带偏。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/voice_clip_energy_test.cpp`（CTest 目标 `fushi_voice_clip_energy_test`，x64/x86 都跑）：①同一段确定性波形换成 8/16/24/32-bit 与 float32 后能量必须落在同一个值附近（这条就是整链的守门断言）；②支持的格式一律不得返回 -1；③跨环边界（偏移故意取成非样本对齐，逼出跨界样本按字节拼接那条路径）能量与不跨界一致；④静音段能量远低于有声段；⑤12-bit / float64 / 空段 / 空环才返回 -1。不用 `assert`（本目录测试目标没关 NDEBUG，Release 下会被整条编掉）。
  **变异实测**：把 `ClipSampleAbs16Scale` 的 float 分支改回「一律返回 -1」（BUG-1769 的旧行为）后，测试立刻报 3 条失败、退出码 1；还原后文件 sha256 与基线逐字节一致（`ebfedd56…`）并复绿。
- **性能（附带修复，有实测数字）**：能量原先在选源与拼接两处**各算一遍**，每次都先把整段 `memcpy` 到新 `vector` 再扫描；`GrabUtterance` 全程持锁跑在 Flutter 平台线程上，收敛循环每行调 ~24 次，环上限 64MB。现在改成环上就地单遍扫描 + 结果缓存复用。微基准（1024 clips × 24 次 grab、环 64MB、MSVC /O2）：**968ms → 434ms，2.23×**。
  ⚠ 中途有一次**反向教训**：第一版把逐样本判断写成函数调用，挡住了自动向量化，实测 968ms → 1195ms（**慢 19%**）。是基准把它抓出来的，改成「格式分派在循环外 + 每种格式一条紧凑循环」后才有上面的 2.23×。没有基准就会把一次性能回归当成优化提交。
- **验证**：native CTest x64 **33/33 通过**（`fushi_luna_symcheck` 除外——它依赖需要 .NET 8 的 `fushi_unity_audio_runtime`，本机只有 .NET SDK 6，是既有环境限制、与本改动无关）；x86 单独构建并运行 `fushi_voice_clip_energy_test` 通过；`ring_probe` x64 编译通过；Windows debug 全量构建通过（`√ Built`）；`flutter analyze` 零问题。
- **备注**：**未做真机 E2E**——WA2 不在本机，无法在原始路径上验「显示台词 → 捕获对应语音 → 真卡写入」。按 `docs/agent/galgame-hooking.md` 的证据分级，本条修复的等级是**代码层根因修复 + 离线单测 + 双架构构建**，不构成对 Leaf/AQUAPLUS 引擎的任何支持声明，`engine-support.yaml` 未做任何状态提升。用户装好 WA2 后需回到原始启动路径复验：若「重复」消失即坐实 float32 分支；若仍在，则要用 `fushi_voice_ring_probe.exe <pid>` dump 环里的 `VoiceClip` 格式与 `source_ptr` 重新分型。
