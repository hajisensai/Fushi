## BUG-1443 · macOS 随包 ffmpeg 动态依赖 Homebrew dylib，干净机器上 dyld 崩溃

- **报告**：2026-08-02（TODO-2692，发版阻塞级）
- **真实性**：✅ 真 bug，根因 `tool/ffmpeg-min/build-ffmpeg-min.sh:112-117`
- **[x] ① 已修复** — 配方改为自编静态第三方库；入库二进制已用 CI run `30736855579`
  （macOS job 绿，含 smoke-test 行为契约 + `otool -L` 自包含断言）的 artifact 重新 vendor
- **[x] ② 已加自动化测试** — `hibiki/test/tools/ffmpeg_min_vendored_self_contained_guard_test.dart`

### 现象

`third_party/ffmpeg-min/macos/ffmpeg` 在没装 Homebrew 的 Mac 上直接 `Abort trap: 6`（exit 134）。
CI run `30733265391`（head `1ec7d896a`，2026-08-02 05:15，workflow `Build Desktop and Apple Release
Artifacts` 的 macos job）步骤 `Install vendored ffmpeg-min runtime into macOS bundle` 里的
`"$target_dir/ffmpeg" -hide_banner -version` 冒烟就是这样炸的：

```
dyld[44901]: Library not loaded: /opt/homebrew/opt/svt-av1/lib/libSvtAv1Enc.4.dylib
  Referenced from: .../hibiki.app/Contents/MacOS/ffmpeg
  Reason: tried: '/opt/homebrew/opt/svt-av1/lib/libSvtAv1Enc.4.dylib' (no such file), ...
```

后果：macOS 桌面制卡链（帧封面 / 句子音频 / cue 动图 / 片段导出 / 内封字幕抽取）全废——
`_bundledExecutablePath()` 会挑中这个 ffmpeg，然后每次调用都 `Abort trap: 6`。

### 根因

`tool/ffmpeg-min/build-ffmpeg-min.sh` 只给 **Windows(MINGW)** 分支做了静态化：

```sh
MINGW*|MSYS*) EXTRA_CONFIG="... --extra-ldflags=-static --pkg-config-flags=--static ..." ;;
Darwin)       EXTRA_CONFIG="--enable-securetransport" ;;
```

macOS 分支没有任何静态化处理，于是 `.github/workflows/ffmpeg-min.yml:58` 的
`brew install ... x264 svt-av1 webp` 装出来的三个库全部以**动态依赖**留在产物里。
字节扫描（`grep -a '/opt/homebrew' third_party/ffmpeg-min/macos/{ffmpeg,ffprobe}`）证实
**两个 exe 各有 4 条**外部依赖，不只报错里那一条：

| 依赖 | 来源 formula | 配方开关 | 消费方 |
|---|---|---|---|
| `/opt/homebrew/opt/svt-av1/lib/libSvtAv1Enc.4.dylib` | `svt-av1` | `--enable-libsvtav1` | AVIF 动图封面（**默认格式**，`desktop_audio_clipper.dart:907`） |
| `/opt/homebrew/opt/webp/lib/libwebp.7.dylib` | `webp` | `--enable-libwebp` | WebP 动图封面（可选，`desktop_audio_clipper.dart:896`） |
| `/opt/homebrew/opt/webp/lib/libwebpmux.3.dylib` | `webp` | 同上 | 同上 |
| `/opt/homebrew/opt/x264/lib/libx264.165.dylib` | `x264` | `--enable-libx264` | 片段导出重编码兜底 + 有声书片段导出（无降级路径） |

系统库 `/usr/lib/libSystem.B.dylib`、`/usr/lib/libz.1.dylib` 无问题（每台 Mac 都有）。
对照组：`third_party/ffmpeg-min/windows/ffmpeg.exe` 只 import
`kernel32/kernelbase/msvcrt/ws2_32/secur32/shell32/bcrypt` 全部系统 DLL，零外部路径——
静态化在 Windows 分支是生效的。

### 为什么四道既有关卡都没拦住

| 关卡 | 为什么漏 |
|---|---|
| `ffmpeg_min_vendored_recipe_guard_test` | 只比对内嵌 configure 串的组件清单。`--enable-libsvtav1` 两边都在，完全一致 → 绿。configure 串描述「编了什么能力」，不描述「怎么链的」。 |
| `desktop_ffmpeg_bundling_guard_test` | 只查 workflow 里有没有装配步。 |
| `ffmpeg-min.yml` 的 smoke-test | 跑在刚 `brew install` 过的**同一台**机器上，dylib 就在 `/opt/homebrew` 下，必然通过——它天然测不到「干净机器」。 |
| `release-desktop.yml` 的 `-version` 冒烟 | 唯一真正照出缺陷的关卡，但它在**发版流水线**里：等它红就已经是发版被阻塞的时刻。（该步是 PR#721 `e1039c848` 新加的，**步骤本身工作正常**，不是回归。） |

### 修复方向取舍

- **(a) 重建时静态链入三个库** ← **采纳**。产物仍是单文件，能力零损失，与 Windows 分支同构。
- **(b) 禁用 libsvtav1/libwebp**：丢的是**默认**封面格式（AVIF），macOS 会静默降级 GIF——
  同口径实测 480px·8fps 4 秒窗 36 KB → 471 KB（~13×），原图档 3.5 秒/3.3 MB → 12 秒/17.8 MB，
  且每张卡白跑一次注定失败的 ffmpeg。libx264 更不能禁：片段导出与有声书片段导出**都没有降级路径**，
  禁掉直接 `Unknown encoder 'libx264'`（BUG-917 复发）。⇒ 否决。
- **(c) dylib 随包 + `install_name_tool` 改 `@executable_path`**：可行但把单文件产物变成一组文件，
  且 `install_name_tool` 会破坏已有签名，必须在 `codesign --force --sign -` **之前**改写，
  再重签整个 app——多一道顺序耦合，且 vendored 目录要多存 4 个 dylib。⇒ 备选，不首选。

### 落地状态

配方已按 (a) 改：三个库自己 `cmake -DBUILD_SHARED_LIBS=OFF` / `./configure --enable-static`
编进私有 prefix，`PKG_CONFIG_PATH` 只指向它（社区通行形态，见
`markus-perl/ffmpeg-build-script`、`arthenica/ffmpeg-kit` 的 `macos.sh`）。

CI run `30736855579`（ref `fix/macos-ffmpeg-self-contained`）macOS job **绿**，含
`smoke-test.sh` 的全部行为契约与新加的 `assert_self_contained`（`otool -L`）。
artifact 已 vendor 回 `third_party/ffmpeg-min/macos/`，独立字节复核：

- 两个 exe 的 `.dylib` 引用只剩 `/usr/lib/libSystem.B.dylib` 与 `/usr/lib/libz.1.dylib`；
- `/opt/homebrew` / `/usr/local` / `/opt/local` 命中数为 0；
- 内嵌 configure 串的 encoder 清单与配方逐字一致，`--enable-lib{svtav1,webp,x264}` 全在
  ⇒ **零能力损失**；
- 体积 5.7 MB → 11.5 MB（静态库折进去的必然代价）。

守卫已转绿。

### 备注（相邻发现，不在本 bug 范围）

- 入库 macOS 二进制是 **arm64-only**（Mach-O `cputype 0x0100000c`），不是 universal。当前
  `release-desktop.yml` 的 macos job 跑在 `macos-latest`（arm64），产物架构一致；但若将来改出
  universal 包或换 Intel runner，这个 ffmpeg 会当场 wrong-arch。
- `third_party/ffmpeg-min/windows/` 下的 `libwinpthread-1.dll` / `zlib1.dll` 已是死重：
  静态化后 `ffmpeg.exe` 的 import 表里根本没有它们。
