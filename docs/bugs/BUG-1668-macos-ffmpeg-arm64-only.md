## BUG-1668 · macOS 随包 ffmpeg 是 arm64-only 瘦二进制，Intel Mac 上制卡/封面/内封字幕全线失效
- **报告**：2026-08-15（用户转述他人反馈：Mac 上网页制卡失败，「生成完成：已处理 0 · 失败 4」，用的是**最新版**）
- **真实性**：✅ 真 bug（打包缺陷，Intel Mac 上 100% 必现）

### 硬证据
直接解析已发布的 `fushi-2.1.1-macos.zip`（GitHub Release 资产，非本地构建），并在真
macOS 上用 Apple 官方 `lipo` 独立复核：

| bundle 内文件 | 架构 |
|---|---|
| `fushi.app/Contents/MacOS/fushi` | **universal：x86_64 + arm64** |
| `fushi.app/Contents/MacOS/ffmpeg` | **arm64 only** |
| `fushi.app/Contents/MacOS/ffprobe` | **arm64 only** |

### 根因
`flutter build macos --release` 产出 **universal** app（支持 Intel），而
`tool/ffmpeg-min/build-ffmpeg-min.sh` 从来只编**构建机自己的架构**——没有任何
`-arch` / `lipo` 处理，`ffmpeg-min.yml` 的 macOS job 又跑在 Apple Silicon runner 上。

在 Intel Mac 上：app 本体照常启动、查词照常可用，但每次
`Process.start('…/Contents/MacOS/ffmpeg')` 都被内核以 `Bad CPU type in executable`
(EBADARCH) 拒掉 → 音频与首帧抽取全灭 → `requireAudio: true` → 整卡 abort。
用户看到的就是「已处理 0 · 失败 N」。同链路受害的还有：内封字幕抽取、内封字幕字体、
cue 动图、片段导出、音频容器元数据。

**为什么所有既有门禁都放它过去**：`ffmpeg-min.yml` 的 smoke-test 和
`release-desktop.yml` 装配后的 `ffmpeg -version` 硬门**都跑在 arm64 runner 上**，
一份 arm64-only 的二进制在那里当然跑得通。这两道门验的是「能跑」，而真正的不变式
是「helper 的架构必须覆盖 app 本体的架构」。

### 打开 x86_64 这条从未走过的路后，连带挖出的三个坑
都只在 x86 目标存在，所以「只编构建机架构」的年代一个都碰不到：

1. **cpuinfo 的 CMake 版本门**：SVT-AV1 v2.3.0 只在 x86 目标
   （`if(… AND HAVE_X86_PLATFORM) add_subdirectory(third_party/cpuinfo)`）才引入
   vendored cpuinfo，而那份 CMakeLists 顶上是 `CMAKE_MINIMUM_REQUIRED(VERSION 2.8.12)`，
   CMake 4.x 已移除 <3.5 兼容 → configure 当场失败。加官方逃生开关
   `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`。
2. **CMake 没进交叉编译模式**（本 bug 里最难定位的一个）：cpuinfo 靠
   `CMAKE_SYSTEM_PROCESSOR` 决定编哪些源文件，但**只传 `-DCMAKE_SYSTEM_PROCESSOR`
   无效**——`project()` 会用检测到的 host 值覆盖同名普通变量（cache 里明明是 x86_64，
   取到的仍是 arm64）。必须同时设 `CMAKE_SYSTEM_NAME` 才真正进入交叉编译模式。
   不设它时 cpuinfo 只编出通用的 `api.c`/`init.c`，漏掉 x86 专属的 `isa.c` /
   `vendor.c` / `x86_init.c` / `x86_mach_init.c`，而 SVT-AV1 自己按 x86 编译并引用了
   那些符号 → `Undefined symbols: _cpuinfo_isa, _cpuinfo_x86_mach_init` → ffmpeg
   configure 只回一句 `SvtAv1Enc >= 0.9.0 not found using pkg-config`，完全指不到真因。
   设对之后 cpuinfo 的 7 个 .o 被正常并进 `libSvtAv1Enc.a`（`nm` 可见
   `T _cpuinfo_x86_mach_init`），**不需要任何 -lcpuinfo 补链**。
3. **自包含 smoke-test 对 universal 假阳性**：`otool -L | tail -n +2` 假设瘦二进制的
   单行表头；universal 是每个架构一段，第二段表头被当成依赖，而它是产物自身的绝对
   路径（CI 上正好是 `/Users/runner/…`）直接命中黑名单 → 自包含的产物被报 FATAL。
   改按「依赖行必有缩进」提取，顺带把两个架构的依赖都纳入检查。

### 过程中的两个 shell 坑（也已修）
- `$status`/`$extra_lib` 后紧跟**全角括号**时，macOS bash 3.2 把多字节字符并进变量名，
  `set -u` 直接报 `status<乱码>: unbound variable`——诊断代码在打印前先杀死了自己。
  一律改 `${var}`，并写了扫描器确认全文零同类残留。本机 Git Bash 复现不出，只在
  macOS 侧暴露（真机 bash 3.2.57 上复现并验证）。
- `EXTRA_CONFIG` 原是字符串 + 调用处无引号展开，任何带空格的参数都会被词法拆散
  （`--cc=clang -arch x86_64` → 三个 argv）。改成 bash 数组 + `"${EXTRA_CONFIG[@]}"`，
  这是让本修复真正生效的前提。

- **[x] ① 已修复** — 提交 `cf1c94b5d7` / `4b9dfbfb9d` / `08d8612e08` / `35d9cf3d28` /
  `8ad7fb8d80` / `c11f6d53a2` / `bd99b4a012` / `d771628ed2`：
  - `build-ffmpeg-min.sh`：新增 `MACOS_ARCH`；x264 用 `--host` + `CC="clang -arch …"`；
    SVT-AV1 用 `CMAKE_SYSTEM_NAME`/`CMAKE_SYSTEM_PROCESSOR`/`CMAKE_OSX_ARCHITECTURES`
    + policy 开关；ffmpeg configure 传 `--arch`/`--cc`/`--extra-cflags`/`--extra-ldflags`，
    跨架构才加 `--enable-cross-compile`（同架构逐字保持旧行为）；`EXTRA_CONFIG` 数组化；
    configure 失败时 dump `config.log` 关键片段。
  - `ffmpeg-min.yml`：macOS 按架构各构建一次（**独立** `OUT`/`SRC`/`STATIC_DEPS`——脚本
    对静态库有 `if [ ! -f … ]` 缓存短路，共用 prefix 会让第二个架构复用第一个架构的
    `.a`，lipo 出的「universal」两片同架构），再 `lipo -create`，并加每切片 + 合并产物
    的架构硬门。
  - `smoke-test.sh`：自包含检查适配 universal。
  - `release-desktop.yml`：装配冒烟改为按 **app 本体的 `lipo -archs`** 逐个核对 helper
    覆盖同样架构，缺一即 fail（app 将来改单架构也不用改这段）。
  - `third_party/ffmpeg-min/macos/{ffmpeg,ffprobe}`：换成 CI 产出的 universal 二进制
    （`lipo -archs` = `x86_64 arm64`，mode 保持 100755）。
- **[x] ② 已加自动化测试** — `fushi/test/tools/ffmpeg_min_vendored_universal_guard_test.dart`：
  纯字节解析 Mach-O/FAT header（不依赖 `lipo`/`file`，Windows/Linux CI 同样有效），断言
  入库的 macOS ffmpeg/ffprobe 同时含 x86_64 与 arm64，另有解析器自测区分 universal 与
  瘦二进制。**验证方式比人为变异更强**：该守卫是在旧的 arm64-only 二进制上先写好并
  实测报红的，vendor 新二进制后转绿。
- **验证**：真 macOS（Apple Silicon）上完整复刻 CI 的 macOS job——x86_64 与 arm64 干净
  构建各 `EXIT=0`，x86_64 产物经 Rosetta `-version` rc=0，lipo 合并后两个工具均为
  `x86_64 arm64` 且 `arch -x86_64` / `arch -arm64` 分别跑通；CI 三平台 job 全绿；
  `test/tools/` 341 条守卫全过。
- **备注**：修复要真正到用户手里还需**发一次版**。在那之前，Intel Mac 用户的临时绕过是
  自行装系统 ffmpeg（Homebrew）——`_runCliFfmpeg` 的 `on ProcessException` 分支注释里
  明确写了「损坏 / **架构不匹配** / 无执行权限」都回退 PATH，代码层面早已健壮，问题
  纯在打包。相关：[[BUG-1664]]（这次失败只报症状不报根因，正是它让本 bug 在用户侧完全
  不可诊断）。
