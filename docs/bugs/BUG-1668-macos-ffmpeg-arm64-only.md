## BUG-1668 · macOS 随包 ffmpeg 是 arm64-only 瘦二进制，Intel Mac 上制卡/封面/内封字幕全线失效
- **报告**：2026-08-15（用户转述他人反馈：Mac 上网页制卡失败，「生成完成：已处理 0 · 失败 4」，用的是**最新版**）
- **真实性**：✅ 真 bug（打包缺陷，Intel Mac 上 100% 必现）

### 硬证据
直接解析已发布的 `fushi-2.1.1-macos.zip`（GitHub Release 资产，非本地构建）：

| bundle 内文件 | 架构 |
|---|---|
| `fushi.app/Contents/MacOS/fushi` | **universal：x86_64 + arm64** |
| `fushi.app/Contents/MacOS/ffmpeg` | **arm64 only** |
| `fushi.app/Contents/MacOS/ffprobe` | **arm64 only** |

入库的 `third_party/ffmpeg-min/macos/{ffmpeg,ffprobe}` 同样是 arm64-only 瘦 Mach-O
（`cputype=0x0100000C`）。

### 根因
`flutter build macos --release` 产出 **universal** app（支持 Intel），而
`tool/ffmpeg-min/build-ffmpeg-min.sh` 从来只编**构建机自己的架构**——没有任何
`-arch` / `lipo` 处理，`.github/workflows/ffmpeg-min.yml` 的 macOS job 又跑在
Apple Silicon runner 上。于是随包 helper 只有 arm64。

在 Intel Mac 上：app 本体照常启动、查词照常可用，但每次
`Process.start('…/Contents/MacOS/ffmpeg')` 都被内核以 `Bad CPU type in executable`
(EBADARCH) 拒掉 → 音频与首帧抽取全灭 → `requireAudio: true` → 整卡 abort。
用户看到的就是「已处理 0 · 失败 N」。同一条链路上受害的还有：内封字幕抽取、
内封字幕字体、cue 动图、片段导出、音频容器元数据。

**为什么所有既有门禁都放它过去**：`ffmpeg-min.yml` 的 smoke-test 和
`release-desktop.yml` 装配后的 `ffmpeg -version` 硬门**都跑在 arm64 runner 上**，
一份 arm64-only 的二进制在那里当然跑得通。这两道门验的是「能跑」，而真正的不变式
是「helper 的架构必须覆盖 app 本体的架构」。

- **[x] ① 已修复** — 提交 `<commit>`：
  - `build-ffmpeg-min.sh`：新增 `MACOS_ARCH`（默认 `uname -m`）。x264 走
    `--host` + `CC="clang -arch …"`；SVT-AV1 / libwebp 走
    `-DCMAKE_OSX_ARCHITECTURES`；ffmpeg configure 传 `--arch` /`--cc`/`--extra-cflags`
    /`--extra-ldflags`，跨架构时才加 `--enable-cross-compile`（同架构逐字保持旧行为）。
  - 同一提交把 `EXTRA_CONFIG` 从**字符串**改成 **bash 数组**：原先调用处是无引号的
    `$EXTRA_CONFIG`，任何带空格的参数都会被词法拆散——`--cc=clang -arch x86_64`
    会变成三个 argv，configure 拿不到交叉编译器，照旧编出构建机架构。这不是风格
    问题，是让本修复真正生效的前提。
  - `ffmpeg-min.yml`：macOS job 改为按架构各构建一次（**独立** `OUT`/`SRC`/
    `STATIC_DEPS`——脚本对静态库有 `if [ ! -f … ]` 缓存短路，共用 prefix 会让第二个
    架构复用第一个架构的 `.a`，lipo 出来的「universal」两片同架构），再 `lipo -create`
    合并，并加每切片 + 合并产物的架构硬门。
  - `release-desktop.yml`：装配冒烟不再只验「能跑」，改为按 **app 本体的 `lipo -archs`**
    逐个核对 ffmpeg/ffprobe 覆盖同样的架构，缺一即 fail（app 将来改单架构也不用改这段）。
- **[ ] ② 待加自动化测试** — 计划 `fushi/test/tools/ffmpeg_min_vendored_universal_guard_test.dart`：
  纯字节解析 Mach-O/FAT header，断言入库的 macOS ffmpeg/ffprobe 含 x86_64+arm64。
  **必须在新二进制 vendor 回仓库之后才能加**，否则守卫立刻把 develop 打红。
- **备注**：修复要真正到用户手里，还需跑一次 `ffmpeg-min.yml` 拿 universal artifact，
  替换 `third_party/ffmpeg-min/macos/{ffmpeg,ffprobe}` 并 `git update-index --chmod=+x`，
  然后发版。在那之前，Intel Mac 用户的临时绕过是自行装系统 ffmpeg（Homebrew）——
  `resolveFfmpegExecutable()` 的 PATH 回退会接住，但捆绑二进制仍在，回退只发生在
  捆绑那个跑不起来时。相关：[[BUG-1664]]（这次失败只报症状不报根因，正是它让本 bug
  在用户侧完全不可诊断）。
