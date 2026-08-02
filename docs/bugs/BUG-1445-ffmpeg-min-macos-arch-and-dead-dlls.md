## BUG-1445 · ffmpeg-min：macOS 二进制 arm64-only 无守卫钉住，Windows 两个 MinGW 运行时 DLL 是死重

- **报告**：2026-08-02（TODO-2701 ①②；③ 本轮不做）
- **真实性**：✅ 真 bug（① 是潜伏的发版级隐患，② 是每个用户白装 194 KB + 三处虚假事实注释）

### ① macOS 二进制是 arm64-only，架构前提没有任何守卫

`third_party/ffmpeg-min/macos/ffmpeg` 与 `ffprobe` 的头 8 字节是
`cf fa ed fe 0c 00 00 01`：magic `0xFEEDFACF`（`MH_MAGIC_64`，**thin**，不是 fat 的
`0xCAFEBABE`）、cputype `0x0100000C`（`CPU_TYPE_ARM64`）。即 **单架构 arm64，不是 universal**。

`.github/workflows/release-desktop.yml:637` 的 macos job 跑在 `macos-latest`（Apple Silicon），
架构正好一致，所以今天不出事——**纯属巧合**。任何一侧单独动都会当场 wrong-arch：
换 Intel runner（`macos-13`），或重新 vendor 出个 x86_64 产物，用户机上就是
`Bad CPU type in executable`，桌面制卡链（帧封面 / 句子音频 / cue 动图 / 片段导出 /
内封字幕抽取）全废，而且**只有发版之后才看得见**。

现存三条 ffmpeg-min 守卫都抓不到：`ffmpeg_min_vendored_recipe_guard_test` 只比对内嵌
configure 串（描述「编了什么能力」，不描述架构）；`ffmpeg_min_vendored_self_contained_guard_test`
只扫共享库绝对路径；`desktop_ffmpeg_bundling_guard_test` 只查 workflow 有没有装配步。

### ② `libwinpthread-1.dll` / `zlib1.dll` 是死重

`tool/ffmpeg-min/build-ffmpeg-min.sh:199-202` 的 Windows 分支传
`--extra-ldflags=-static --pkg-config-flags=--static`，zlib/pthread 已折进 exe。
从 `windows/ffmpeg.exe` 里抠出的**全部** DLL 名字符串（即 import 表 + 任何按名 LoadLibrary
所需的字符串）只有：`bcrypt / kernel32 / kernelbase / msvcrt / secur32 / shell32 / ws2_32`。
两个 dll **一次都没出现**，ffprobe.exe 同。
`.github/workflows/ffmpeg-min.yml:106-115` 的 artifact 也只上传 4 个 exe/bin 路径——
**配方从不产出这两个 dll**，它们是 `-static` 之前那一代动态链 MSYS2 时手工 vendor 的残留。

消费者穷举（删除前证伪「还有别的消费者」，多路搜法：全名 / `winpthread` / `zlib1` /
`zlib` / `pthread` / 通配拷贝）：

1. `.github/workflows/release-desktop.yml:417-422` `$runtimeFiles` **显式点名**（`:425-427`
   是 hard throw，删文件不改这里 → Windows 发版直接炸）。
2. `hibiki/test/build/windows_vendored_ffmpeg_guard_test.dart:52-64` 断言两文件存在，
   `:82-87` 断言 workflow 文本含这两个名字——两处 reason 都写着「ffmpeg.exe imports this
   DLL」，**是事实错误**。
3. `hibiki/windows/installer/hibiki.iss:45` `Source: "{#SourceDir}\*"` 通配整个 Release 目录
   （隐式消费者，但不点名，无需改）。
4. `hibiki/test/tools/ffmpeg_min_vendored_self_contained_guard_test.dart:266-274`
   `listSync` 通配扫描（6→4 仍满足 `>=4`，不会红，但注释「随包的 MinGW 运行时 DLL 也一起扫」
   会变成假话）。

**查空的地方**（逐一确认无命中）：`hibiki/pubspec.yaml` 的 `assets:`；所有 `CMakeLists.txt`
（Windows 侧 ffmpeg-min 完全不经 CMake）；`.gitattributes`；任何 Dart 侧路径拼接；
`.wxs` / `.nsi` 不存在；`native/galgame_hook/tools/build_distribution.ps1` 与 ffmpeg 无关；
`third_party/m_extension_server/upstream_src/setup.iss` 无命中。
另：bundle 里其它成员也不需要它们——本地 Windows 构建**从不**拷这两个 dll（拷贝步只在
release-desktop.yml 里），而本地构建的 app 正常启动，说明 mpv-2.dll 等 bundle 成员不依赖它们。

- **[x] ① 已修复（守卫）** — `ffmpeg_min_vendored_self_contained_guard_test.dart` 新增
  `machOArchitectures()`（真解析 Mach-O：fat `0xCAFEBABE/0xCAFEBABF` + thin
  `0xFEEDFACE/0xFEEDFACF` 双字节序）+ `_macRunnerArchitectures` 穷举表，断言
  **发版 runner 需要的架构必须落在二进制提供的架构集合里**。钉的是「两侧一致」而不是
  「必须永远 arm64」——后者会把改成 universal 这种改进也判红。
- **[x] ② 已修复（删除）** — 删 `third_party/ffmpeg-min/windows/{libwinpthread-1.dll,zlib1.dll}`；
  `release-desktop.yml` 的 `$runtimeFiles` 去掉两项；
  `windows_vendored_ffmpeg_guard_test.dart` 的两条断言**反转**为不变式守卫（见下）。
- **[x] ② 已加自动化测试** —
  `hibiki/test/tools/ffmpeg_min_vendored_self_contained_guard_test.dart`：Mach-O 解析器自检
  （thin arm64 / thin x86_64 / 大端 thin / fat 双切片 / 非 Mach-O）+ 架构一致性断言 +
  **三个规模哨兵**（macos 目录扫不到二进制必红 / 解析不出 runner 标签必红 / 解析不出架构必红），
  外加按平台的 `>=2` 哨兵。
  `hibiki/test/build/windows_vendored_ffmpeg_guard_test.dart`：vendored windows 目录必须
  **恰好**只有两个 exe（多一个 side-car DLL 就红，少一个也红）；两个 exe 引用的 DLL 名必须
  全在系统白名单内（含「扫不到任何 DLL 名 = 守卫坏了」的哨兵）；release 拷贝清单不得复活
  这两个 dll（断言**限定在 `$runtimeFiles` 数组内**，因为步骤旁的注释合法地提到它们）。
  变异实测 5 次全红：把 zlib1.dll 塞回拷贝清单 / 从系统白名单去掉 `bcrypt.dll` /
  往 vendored 目录塞一个多余 dll / 把 `macos-latest` 标成 x86_64（模拟 Intel runner）/
  把 macos 扫描根指向不存在的目录。
- **备注**：
  - **未改 vendored 二进制任何字节**：剩下 4 个文件 blob 哈希与 mode 位原样
    （`macos/ffmpeg`、`macos/ffprobe` 仍是 `100755`）。
  - 任务描述里说的「现有 5 个 `100755` 位」与事实不符：`third_party/ffmpeg-min/` 下
    **只有 2 个** 100755（两个 macOS 二进制）。windows 那 4 个在 git 里是 `100644`，
    工作树 `ls` 显示 `rwxr-xr-x` 是 NTFS 的假象。
  - TODO-2701 ③ 本轮未做。
