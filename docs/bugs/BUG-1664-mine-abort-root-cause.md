## BUG-1664 · 制卡中止只报症状不报根因（macOS 缺 ffmpeg 时批量制卡整批失败且不可诊断）
- **报告**：2026-08-15（用户：mac 的网页制卡失败）
- **真实性**：✅ 真 bug（两条独立缺陷）。用户症状：Mac 上 YouTube 页批量制卡 toast「生成完成：已处理 0 · 失败 4」。

### 现场取证（远程 Mac 192.168.1.34）
扩展连的服务端是安装版 `/Applications/Hibiki.app`（1.2.0 / build 885 / 2026-07-21），
不是同机跑着的 worktree debug 构建。对它直发 `/api/mine` 复现：

```
POST 127.0.0.1:19633/api/mine {youtubeVideoId, clipStartMs, clipEndMs}
→ {"result":"error","message":"YouTube 制卡失败：required audio missing",
   "detail":"required audio missing"}
```

沙盒容器内的错误日志（`~/Library/Containers/com.example.hibiki/Data/Documents/error_log.txt`）
才给出真因：

```
[2026-08-15 17:21:03] extractAudioSegmentViaFfmpeg
ffmpeg launch failed: executable=ffmpeg; errorCode=2; message=No such file or directory
```

`/Applications/Hibiki.app/Contents/MacOS/` 只有主可执行，无 ffmpeg/ffprobe；该机 PATH 上
也没有（macOS 不自带）→ `resolveFfmpegExecutable()` 回退裸 `'ffmpeg'` → ENOENT →
音频与首帧抽取全灭 → `requireAudio: true` → 整卡 abort，4 条全失败。

### 根因
1. **打包缺口（已由 BUG-1421 于 2026-08-02 修复，晚于用户这个包）**：
   `release-desktop.yml` 过去只有 Windows 有 ffmpeg 装配步骤，macOS bundle 从不带
   ffmpeg。用户装的 build 885（07-21）在修复之前。已核实 `fushi-2.1.1-macos.zip` 的
   central directory 内确有 `fushi.app/Contents/MacOS/ffmpeg` 与 `ffprobe`。
   跨包名改名（Hibiki→Fushi）导致旧包收不到自动更新，需手动装一次。
2. **本次修复 A — 中止原因丢根因**
   `fushi/lib/src/mining/immersion_mining_engine.dart`（旧 341 行处）
   抽取层算好的精确摘要经 `onFailure` 已到达引擎，调用方却只把它丢进诊断日志
   （`app_model.dart` 的 `logDiagnostic`），引擎回的是**常量** `'required audio missing'`。
   于是根因既不进 `/api/mine` 响应、也不进扩展 toast，用户与排查者只能去翻沙盒容器日志。
3. **本次修复 B — 环境变量旧名回退从未生效**
   `fushi/lib/src/media/video/ffmpeg_backend.dart`（旧 235 行处）
   5 个调用点全写成 `env['FUSHI_FFMPEG'] ?? env['FUSHI_FFMPEG']`——两边同名，注释承诺的
   `HIBIKI_FFMPEG` 旧名回退是改名批次的复制粘贴漏改。旧名是改名前公开给用户的变量，
   而这恰恰是「机器上没有 ffmpeg」时的自救出口。`FUSHI_FFPROBE` 同样。

- **[x] ① 已修复** — 提交 `<commit>`：
  - A：引擎就地留存两个上报口的**首个**失败摘要，abort 时经 `_withRootCause()` 并进
    `abortReason`（症状前缀不变 → 既有调用方/测试不破；根因为空时逐字保持旧文案；
    截断 300 字防糊爆 toast）。
  - B：把「新名优先、旧名回退」收成单一入口 `ffmpegEnvOverride()` / `ffprobeEnvOverride()`
    + 纯函数 `resolveEnvOverrideFrom(env, names)`，5 个调用点改为调它——让"回退去问哪个
    名字"只存在一处，这类漏改无处可写。空串视同未设。
- **[x] ② 已加自动化测试** —
  - `fushi/test/mining/immersion_mining_engine_test.dart`：根因进 abortReason / 无根因时
    文案逐字不变 / 超长根因截断（3 条）。
  - `fushi/test/media/video/ffmpeg_executable_resolve_test.dart`：新名优先 / **只设旧名必须
    回退** / 新名空串不挡旧名 / 都没设回 null（4 条）。
  - 两组均做过变异实测：还原旧行为后对应用例转红，还原后源文件 sha256 逐字节一致。
- **备注**：用户侧解决办法是装 Fushi 2.1.1 macOS 包（跨包名改名，旧 Hibiki 收不到自更新）。
  本次代码修复不改变「缺 ffmpeg 就制不出卡」这一事实，改变的是**失败必须自解释**。
