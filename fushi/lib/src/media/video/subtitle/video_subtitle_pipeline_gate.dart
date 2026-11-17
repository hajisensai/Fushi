/// 播放页「生成字幕」能不能在本机跑完整管线（`AppVideoSubtitleService`）的判据。
///
/// 判的是「本机能不能读到这一集的媒体」，不是「这是什么来源」：普通本机文件、蓝光
/// 原盘会话（当前 title 是盘里的 `.mpls`，ffmpeg 经 `BlurayFfmpegBackend` 按播放列表
/// 读）都一样走管线。原盘会话只看原盘 VM 给出的可抽取性
/// （`VideoPlayerController.discMiningAvailable`：AACS 加密没密钥、多角度、片段缺失时
/// 为假）与当前 title 是否已就绪（盘菜单正在前台 / title 还没绑定时不能用）——与仅本机
/// 转录、制卡抽取同一道闸门。
library;

/// 本机这一集能否跑字幕生成管线。
///
/// - [videoPath]：页面当前这一集的本机路径（原盘会话是当前 title 的 `.mpls`）；
/// - [isRemote]：互联 / 流媒体远端视频（走 host 管线，不在这里判）；
/// - [asrSupported]：本平台有语音识别；
/// - [discSession]：正处于原盘导航会话；
/// - [discExtractionAvailable]：原盘会话里当前 title 可抽取且已就绪（非原盘会话不看）。
bool canRunLocalVideoSubtitlePipeline({
  required String? videoPath,
  required bool isRemote,
  required bool asrSupported,
  required bool discSession,
  required bool discExtractionAvailable,
}) =>
    videoPath != null &&
    videoPath.isNotEmpty &&
    !isRemote &&
    asrSupported &&
    (!discSession || discExtractionAvailable);
