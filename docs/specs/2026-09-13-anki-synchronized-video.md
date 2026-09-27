# Anki 例句音画同步

## 使用

在 Anki 设置的「视频卡片图片」中选择「带声音的视频片段」，再从具有字幕时间窗的视频制卡。既有动图默认值不变；已有 GIF/WebP/AVIF 卡片需要从原视频重新制卡或覆盖，改 HTML 标签不会补回已丢失的音轨。

使用新版内置 Lapis 时保留 `SentenceAudio → {sentence-audio}`、`Picture → {card-image}` 映射。带声音的 MP4 只进入一次原生媒体队列，跟在单词音频之后；点击视频入口或例句重播该 MP4。自动播放服从 Anki 卡组设置。Windows Anki 可能打开独立播放器，不承诺三端都内嵌播放。

通过配对设备转发制卡时，发送端和接收端都需升级到包含此功能的版本；新协议仅传一份 MP4 和同步模式标记，旧版接收端不理解该标记。

已有用户模板不会被偷偷覆盖。要启用例句点击，需更新卡片背面为新版内置 Lapis 模板；保留自己的模板改动时，将新增的例句点击逻辑合入现有模板。AnkiMobile 的 URL scheme 只能导入笔记，不能更新模板，需在桌面更新模板后同步，或自行编辑手机模板。

自定义模板应只渲染一次原生例句媒体引用；多处按钮应复制已经渲染的按钮，不要重复插入 `[sound:]`。没有例句音频映射时，视频放回图片字段作为原生视频播放入口，自动播放顺序取决于用户模板，不能保证单词先播。没有更新模板的旧 Lapis 不保证例句点击行为。

## 实现决策

- 动图链路原先使用 `-an` 并循环；它没有可与例句音频共享的媒体时间轴。新增模式复用 `VideoMiningImageMode.videoClip`，仅普通视频启用 `AnkiMiningContext.synchronizedVideo`，不改变 Galgame 平台与采集行为。
- 应用内视频和可裁视频 URL 继续使用现有音轨选择、音频裁切、远端裁音和 TLS pin 路由，再将同一个时间窗的视频与裁好的句音频合入 H.264/yuv420p + AAC MP4。已经裁好的句音频从零开始，不重复使用原视频偏移。
- 浏览器录制片段直接保留音画导出一个 MP4。仅提供截图/音轨、没有视频内容的来源不能生成同步视频；明确报错，不降级成动图却声称同步。Bilibili 浏览器音轨解析路径暂不提供视频源，应使用应用内视频制卡。
- 同源录屏保留音视频的相对时间戳，不能各自清零而抹掉原有音轨延迟；独立裁好音频才按零起点对齐。视频裁切和降帧仍受正常帧边界精度限制。
- AnkiConnect / AnkiDroid 上传一份视频；`SentenceAudio` 使用原生 `[sound:]`，`Picture` 为无第二个媒体引用的重播入口。AnkiMobile 保留裸 MP4 URL 供客户端下载转换，不能将待下载 URL 包裹进 HTML。媒体服务器复制快照后，任务可清理自身导出临时文件。
- 原生播放器负责单个文件内的暂停、重播和音画同步。不给动图补静音，不用定时器估计单词音频时长，不以两次 `play()` 调用声称严格同步。

## 验证边界

已执行引擎与录屏请求测试、编码器参数和失败清理测试；实际使用仓库捆绑 FFmpeg 导出，ffprobe 确认 H.264/yuv420p、AAC、两流起点与时长，检查使用的是选定音轨。

AnkiConnect/AnkiDroid 媒体渲染、AnkiMobile 裸 URL 与媒体快照由自动化测试覆盖。三端安装版「生成卡片 → 同步 → 自动播放 → 点击例句重播」仍需设备验收，不以单元测试或浏览器按钮模拟代替真机结论。

依据：[Anki 媒体手册](https://docs.ankiweb.net/media.html) 推荐 MP4 为通用视频格式；[官方论坛关于 MP4 嵌入](https://forums.ankiweb.net/t/how-to-embed-mp4-files/264/) 说明原生 `[sound:]` 路径。

## 2026-09-27 更新：默认内嵌 WebM + 多格式

用户拍板：所有能拿到画面的制卡来源（应用内视频 / YouTube / Netflix 录制片段 / galgame 窗口录制）默认出**音画一体片段**，格式可选，默认最好的那种。

- **默认模式**：`VideoMiningImageMode.fromWireName(null)` 由 `gif` 改为 `videoClip`（视频与 gal 两个偏好）。显式选过的值原样保留；`ImmersionMiningRequest.imageMode` 值对象默认仍是 `gif`，不读偏好的调用方不变。
- **格式轴** `MiningClipFormat`（偏好 `video_mining_clip_format` / `gal_mining_clip_format`）：
  | 格式 | 卡片里怎么播 |
  |---|---|
  | `webm_vp9`（非 iOS 默认） | `<video>` 内嵌，翻面自动播放一次、点例句重播 |
  | `webm_av1` | 同上，体积最小、编码更慢 |
  | `mp4_h264`（iOS 默认） | `[sound:]` 交给 Anki 原生播放器（本文上半部分的形态） |
  为什么内嵌只能是 WebM：Anki 桌面 Qt WebEngine 无 H.264 / AAC 解码器。渲染方式由产物扩展名决定（`coverMediaRef`），转发 / 草稿 / 队列不加 wire 字段。编码失败按 AV1 → VP9 → MP4 降级，卡上扩展名跟随实际产物。
- **老用户不破坏**：格式没显式设过时从旧偏好推导——显式选过 `video_clip`（MP4 时代）的用户保持 MP4；切换到片段模式时先把推导值钉进格式偏好，避免新用户被误判。
- **Lapis 三处 Picture**：`<video>` 不写 `autoplay` 属性，由字段内脚本只播**可见**的那一个（隐藏副本照样会出声）；句子音频字段是带 `replay-button` 类的重播按钮，内置 Lapis 的「点例句重播」直接可用，模板不改。字段 JS 无反引号 / `${` / 反斜杠（Lapis 把 `{{SentenceAudio}}` 插进 JS 模板字面量）。Anki 媒体检查认 `<video src>`。
- **拿不到画面的来源降级而不报错**：无字幕时间窗 → 动图阶梯（最终静帧）；bilibili（只给音轨）/ Netflix 后台软解 / 网页截图 → 照常用手上的封面出卡，不声称同步。只有「录到了片段却导出失败」仍是硬错误。
- **galgame**：窗口录制片段混进了句子音频时按同步片段落卡（句子音频 = 片段本身），修掉此前「MP4 里一份 + 另挂一份」同一句播两遍的问题；引擎同步判据接受 `source: game` 的外部片段。
- **ffmpeg**：桌面 `ffmpeg-min` 加 `libvpx-vp9` / `libopus` 编码器与 `webm` muxer（macOS 静态自编，BUG-1443 规矩）。移动端 ffmpeg-kit **尚未重编**（构建机离线），移动端 WebM 尝试失败后自动出 MP4；重编需在 `build_x264_{android,ios}.sh` 加 `--enable-libvpx --enable-opus` 并同步 `ffmpeg_kit_mobile_recipe_guard_test.dart`。
- **已知限制**：卡片同时有单词音频时，单词音频（Anki 原生队列）与视频同时开始，不做「先单词后视频」的排队；Anki 的 R 键重播只重播 `[sound:]`，不重播内嵌视频（点例句或播放条即可）。
