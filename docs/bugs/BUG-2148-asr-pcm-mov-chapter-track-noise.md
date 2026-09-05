## BUG-2148 · ASR PCM 抽取 mov 容器混入章节 text 轨，奇数字节标题的整章解成白噪声
- **报告**：2026-09-05（用户：shishamo，同一报告「12、13 匹配率 0%」的第二根因）
- **真实性**：✅ 真 bug。第 13 卷转录产物按 10 分钟分桶，第 2/4/5/6/7/9/10/12/13 章整章 cue 平均 1.0 字、97~100% 是单字「あ/っ/う」，与 m4b 章节边界精确重合；第 1 卷全程正常。用任务原参数（`buildAsrPcmChunkArgs`，`fushi/lib/src/asr/asr_pcm_source.dart`）抽 3600 s 块：RMS 15500、过零率 0.34（白噪声级），ffmpeg-min 与完整版 ffmpeg 一致；加 `-map_chapters -1` 后 RMS 3266、过零率 0.09（语音）。根因：ffmpeg 默认把输入章节复制到输出，`-f mov` 输出时章节成一条 `text` 轨，其样本（章节标题）与 PCM **交错写进同一个 mdat**（坏文件 2 条 trak、mdat 多 41 字节）；`extractMovMdatPayload` 把 mdat 当纯 PCM，标题字节数为奇数的章节整块样本错位成噪声，偶数的只多几字节无感——所以整章交替。`-map 0:a:0 -vn -sn -dn` 管流不管章节。
- **[x] ① 已修复** — ① `buildAsrPcmChunkArgs` 加 `-map_chapters -1 -map_metadata -1`；② `extractMovMdatPayload` 解析 moov 数 trak，≠1 或缺 moov 直接 FormatException（不再静默产出噪声）；③ `AsrJobState.currentVersion` 1→2，`loadStateDetailed` 版本不符视为新任务，避免 UI 直接复用已坏的 finished 产物。ffmpeg-min 重建带 s16le 后 mov 回退分支整体删除。
- **[x] ② 已加自动化测试** — `fushi/test/asr/asr_pcm_source_test.dart`：参数含 `-map_chapters -1 -map_metadata -1`；合成 2 轨 / 0 轨 / 缺 moov 的 mov 判坏。`fushi/test/asr/asr_transcribe_job_test.dart`：v1 state.json 视为新任务、旧段落不复用。真机：第 13 卷重转后 realdata 对照见提交说明。
- **备注**：
