## BUG-675 · 网飞批量制卡有概率跳过某几张卡
- **报告**：2026-07-09（用户：制卡时好像有概率跳过某几张卡 / TODO-1361 ②）
- **真实性**：⚠️ 部分真 + 部分需真机复现。沿真实批量制卡路径端到端通读结论：
  - **扩展队列/生成逻辑不丢卡**：`tools/browser-extension/content.js` `hibikiRunNetflixBatch` 逐句 seek→录→`mineClip`；`hibikiClassifyMineResp` 只在 `success`/`duplicate` 返 `done` → 入 `okIds`；`hibikiRemoveQueued(okIds)` 只按 id 剔除**成功**项（storage 读-改-写）。录制/HTTP 失败（`beginClip` 失败 / `v.paused` / 缺音频被 BUG-603 守卫中止 / 401/连接拒绝）一律 `fail++` 且**留在队列**（可再点生成重试），不会误删。去重键 `hibikiQueueKey`=词(`fields.expression`恒有值)+句+站点+视频ID，不同词→不同键→都入队，无误杀。故**队列层面无静默丢卡**。
  - **用户感知「跳过」的真根因（两条）**：① Netflix 走 Widevine DRM 的**回放录制概率性失败**（seek 后缓冲未就绪/自动播放被拦/黑帧/转码丢音轨），失败项留在队列**未生成**；② 而跨集批量结束时 `hibikiMaybeResumeNetflixBatch` 一律 toast「✓ 全部剧集生成完成」**掩盖了被跳过的卡** → 用户以为都生成了。「假完成 + 静默跳过」是可落地根因；底层录制失败率属 DRM/网络/自动播放平台约束，需真机复现调参（与 [[BUG-630]] 同源）。
- **[x] ① 根因修复（可落地部分：消除假完成 + 静默跳过）** — 提交 `<PENDING>`。`tools/browser-extension/content.js`（两镜像字节一致）`hibikiMaybeResumeNetflixBatch` 收尾分支不再无条件报「✓ 全部完成」：批量结束时清点本次涉及剧集仍残留的网飞待生成项（`it.site==='netflix' && st.episodes.indexOf(it.netflixId)>=0`），>0 就明确 toast「✓ 生成完成：N 张录制失败未生成，可再点生成重试」，把静默跳过变成**可见可重试**（残留即失败，非丢失）。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/netflix_todo1361_fixes_guard_test.dart`（两镜像各守）：content.js 含残留计数过滤 + 「张录制失败未生成，可再点生成重试」提示。`node --check` 通过。
- **备注**：TODO-1361。底层「为什么会录制失败」需用户在真 Netflix 复现并提供 App 错误日志（`Anki.mineImmersion.netflix` / `extractAudioSegmentViaFfmpeg`）+ 扩展 toast + 是否关硬件加速，按命中失败点（缺音频/黑帧/HTTP）转真 bug 定位；本轮先根治「批量假报完成掩盖跳过」。另：同一词跨不同句被 Anki 判重跳过（`duplicate`→算 done 出队）是既有沉浸制卡去重设计（app 内同款），非本轮改动，如需允许重复卡属策略决策待用户确认。
