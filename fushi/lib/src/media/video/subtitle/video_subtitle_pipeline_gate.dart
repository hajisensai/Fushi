/// 播放页「生成字幕」能不能在本机跑完整管线（`AppVideoSubtitleService`）的判据。
///
/// 判的是「本机能不能读到这一集的媒体」，不是「这是什么来源」：普通本机文件、蓝光
/// 原盘会话（当前 title 是盘里的 `.mpls`，ffmpeg 经 `BlurayFfmpegBackend` 按播放列表
/// 读）、DVD 原盘会话（当前 title 是虚拟路径 `VIDEO_TS/TITLE_nn.dvdtitle`，ffmpeg 经
/// `DvdFfmpegBackend` 的 `dvdvideo` demuxer 按 title 读）都一样走管线。原盘会话只看原盘 VM 给出的可抽取性
/// （`VideoPlayerController.discMiningAvailable`：AACS 加密没密钥、片段缺失、角度还没
/// 报上来时为假；多角度 title 按正在播的角度抽，见 `discExtractionPathForAngle`）与
/// 当前 title 是否已就绪（盘菜单正在前台 / title 还没绑定时不能用）——与仅本机
/// 转录、制卡抽取同一道闸门。
library;

/// 本机管线读媒体的路径。
///
/// - [currentVideoPath]：页面当前这一集的身份路径（原盘会话是当前 title 的 `.mpls`，
///   不带角度）；
/// - [discSession]：正处于原盘导航会话；
/// - [discExtractionPath]：原盘 VM 给的抽取路径（`VideoPlayerController.videoPath`：
///   多角度 title 是带当前角度的角度成员路径 `00001.a2.mpls`，抽不了时为 null）。
///
/// 原盘会话读 [discExtractionPath]（ffmpeg 抽的才是正在播的角度），其余读
/// [currentVideoPath]。
String? localVideoSubtitlePipelineMediaPath({
  required String? currentVideoPath,
  required bool discSession,
  required String? discExtractionPath,
}) => discSession ? discExtractionPath : currentVideoPath;

/// 本机这一集能否跑字幕生成管线。
///
/// - [videoPath]：本机管线读媒体的路径（[localVideoSubtitlePipelineMediaPath]；原盘
///   会话是当前 title 按当前角度的抽取路径）；
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
