## BUG-2153 · galgame 引擎身份判据绑死单个 exe（文件名/SHA-256/硬编码 RVA），改名或换版本即整个 adapter 不被认领
- **报告**：2026-09-05（用户：「不可接受任何 exe 级别的」）
- **真实性**：✅ 真 bug。全仓盘点后确认存在两类 exe 级判据：
  - **纯 exe 名门**（本条已修）：`bgi_ethornell_profile.h:15` `_wcsicmp(candidate, L"BGI.exe")`、
    `catsystem2_profile.h:10-13` `cs2_open.exe`/`cs2.exe`、`elf_ai6_profile.h:40`
    `AI6WIN.exe`、`malie_profile.h:10-12` `malie.exe`/`malie_dsp.exe`/`malie_fabla.exe`。
    四处都是 `probe()` 的**全部内容或先决条件**——名字不符时后面的结构判据一行都不跑，
    改名的发行版整个 adapter 不被认领。
  - **exe hash / 硬编码 RVA 门**（本条**未**修，见下「剩余」）：`leaf_aquaplus_profile.h:49-79`
    （1 个 SHA-256 + 23 个硬编码 RVA）、`siglus_lookup.h:33-93`（2 个 profile × 双摘要 +
    7 个 RVA + 写死 1920×1080）、`siglus_lookup.h:224-228`（栈帧大小必须是 `0xDC`/`0xEC`）、
    `siglus_lookup.h:209-222`（选签名的判据是「RVA 是否等于已知常量」——要先知道地址才能
    去找地址，把签名设施反锁死了）、`malie_cfi.h:31-40`（单作品解密密钥）。
  - **对照：SGRE 不是门**。`sgre_anchors.h:1041` `ResolveSgreAnchors` 所有锚点由签名从
    `LoadedPeImage` 扫出，hash 只在命中已知行时做一次一致性否决（`RequireSgreKnownBuildRva`,
    `:1029`），未知 exe 照常走签名路。`tests/sgre_adapter_test.cpp:72-89` 专门把已知 digest
    翻掉一位来钉住这一点。**它是全仓正确范式**，本条修复照它的思路做。
  - 仓库自己踩过同一脚并修好过一次：Siglus 注入器原本只认 `SiglusEngine.exe`，改名的
    `iroseka_HD.exe` 识别不到 → 走错注入策略 → 被 Enigma 保护壳弹掉（`tests/siglus_launch_test.cpp:1-6`
    记录了完整因果），修法是换成 `Gameexe.dat + Scene.pck` 文件夹签名（`injector_main.cpp:2511`）。
    那四个名字门当时没一起改，一直停在修复前的状态。
- **[x] ① 已修复** — 四个名字门改为**纯结构判据，exe 名整条删掉**（不是 `名字 || 结构`：
  那样只会更宽松地放进改名的非本引擎进程；一个判据比两个好）。新增共享原语
  `hook/adapters/engine_dir_signature.h`（`ReadFilePrefix` / `ModuleDirectory` /
  `FileExists` / `FileSize` / `DirectoryHasFileStartingWith`，带 `scan_limit` 兜住病态目录）。
  各引擎新判据：
  - BGI/Ethornell：exe 同级任一 `*.arc` 以 `BURIKO ARC20` 开头。**只认 ARC20 是故意的**——
    本 adapter 的 `install()` 只装 ARC20 语音钩子，认领读不了的归档版本等于空喊支持。
  - CatSystem2：`config\startup.xml` **且** 任一 `*.int` 以 `KIF\0` 开头（缺一即不匹配）。
    顺手把 KIF 魔数收成单一真相源 `catsystem2_int.h` 的 `kIntSignature`，索引解析与身份
    判据共用，不再各写各的字面量。
  - elf AI6：原有的 `voice.arc` 索引自洽校验（索引长度 + 首条目 `packed==unpacked` +
    `offset==索引末尾`）本来就强到能单独定身份，只把它前面的名字先决条件删掉。
  - Malie：`data2.dat` 头 16 字节经 CFI 解块后是自洽 LIBP 头。这是**内容级**判据，
    与 exe 叫什么无关，改名的 Dies irae 反而也能认出来。
  提交：见下。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/engine_identity_layout_test.cpp`
  （CMake 目标 `fushi_engine_identity_layout_test`）。四个引擎各测三档：正确结构 + 目录里
  **没有**历史 exe 名 → 必须匹配（名字非必要）；只有同名 exe 而结构不对 → 必须不匹配
  （名字非充分）；测试进程自己的目录 → 必须不匹配。Malie 正向夹具需要 CFI 密文，测试
  自带 `EncryptCfiBlockAtZero` 逆变换并在 `main` 第一步做 `Decrypt(Encrypt(x)) == x`
  round-trip 自校验，避免「测的是我的逆而不是真解密」。
  **变异实测**：把 `DirectoryHasFileStartingWith` 里的 `memcmp` 短路掉后，测试在
  `engine_identity_layout_test.cpp:154` 断言失败（exit 127）；还原后恢复绿。
  验证：x64 / x86 双架构 `cmake --build` 零 error，各 `ctest -C Release` **65/65 通过**；
  `tests/*_test.py` 全部 10 个守卫通过。
- **剩余（本条**不**覆盖，需各自单独立项）**：
  1. Leaf/AQUAPLUS 的 1 摘要 + 23 硬编码 RVA → 需按 SGRE 范式改成签名推导。
     `tests/leaf_autoprofile_test.cpp` 已有合成 PE 推导 8/25 字段的半成品可续。
  2. Siglus 查词的 7 个 RVA + viewport。注意**拆 digest 门不够**：栈帧大小门
     （`siglus_lookup.h:224-228`）和「选签名靠已知 RVA」的循环依赖
     （`:209-222`）会各自继续挡住新构建，三条要一起拆。viewport 应改为运行期从窗口取。
  3. `config/luna_hook_profiles.tsv` 按 `exe_sha256` 键控并直接供给 hook code，5 行 5 个
     构建；未命中即空。Fate/stay night RN 的文本就依赖其中一行。
  4. Malie CFI 单作品密钥：别的密钥加密的 Malie 归档解不出 LIBP，诊断上「密钥不对」与
     「根本不是 Malie」同形，无法区分。要分辨得靠另一条独立证据。
  5. HunEx GGE 的 `WoH.exe` + `data04000.hfa` 两个名字门（`hunex_gge_profile.h:11,25-35`）
     本条未动：它的结构兜底要先有 HFA 归档魔数校验，需要真样本确认，另立。
- **备注**：本条一次动了四个引擎，与 `native/galgame_hook/CLAUDE.md`「一次任务只处理一个
  引擎」有出入。理由：四处是**同一个判据缺陷的四个实例**，且共用新增的同一个原语头和同一个
  测试文件，拆成四个分支会让原语和测试无处安放。审查按引擎分节看即可，四段互不耦合。
