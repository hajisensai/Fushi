/// 偏好键（Drift `preferences`）：视频片段导出的视频目标码率，单位 kbps。
///
/// 值为 int：`0` = 跟随源（默认，能直接复制码流就不重编码，不能才 `-crf 20` 重编码，
/// 即加这个偏好之前的行为）；正数 = 导出时视频**必然**重编码到该码率。负数与 0 同义，
/// 由导出层 `normalizeClipVideoBitrateKbps` 归一。
///
/// 随 Profile 走：它是「我要导出多大的片段」这种阅读/剪辑偏好，与设备磁盘无关（对比
/// `kVideoScreenshotDirectoryPref` 那种被排除在 Profile 快照外的设备本地路径）。
const String kVideoClipExportVideoBitrateKbpsPref =
    'video_clip_export_video_bitrate_kbps';

/// 「跟随源」的落盘值。
const int kVideoClipExportVideoBitrateFollowSource = 0;

/// 输入框夹取上限（kbps）。libx264 对 1080p 素材 20 Mbps 已远超视觉透明；再高只是
/// 白白撑大文件，且 `-bufsize` 是两倍值，给个上限避免用户误敲多个零。
const int kVideoClipExportVideoBitrateMaxKbps = 100000;
