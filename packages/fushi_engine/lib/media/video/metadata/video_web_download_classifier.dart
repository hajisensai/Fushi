library;

import 'package:path/path.dart' as p;

/// 文件名是否是 yt-dlp 默认命名下载的 YouTube 视频：`标题 [videoId].ext`。
///
/// 这类视频（vlog、直播回放等）没有动画 / 影视资料源里的作品身份，拿标题去
/// AniDB / MAL / TMDB 搜只会产出一堆错误候选、永远停在待确认队列（反馈
/// m2pSnkT2mn）。库里没有「来自 YouTube」的标识列，扫描入库的文件只能凭文件名
/// 判断，所以这里只认 yt-dlp 的默认输出模板 `%(title)s [%(id)s].%(ext)s`。
///
/// 纯函数，不碰磁盘（[videoBookJoinsScrapePlan] 依赖这一点）。判据要和番剧发布
/// 文件名里常见的方括号标签区分开：
/// - videoId 恰好 11 个 `[A-Za-z0-9_-]` 字符：字幕组 CRC（8 位十六进制）、
///   `[1080p]`、`[BD]`、`[01]` 等长度都对不上；
/// - videoId 是 64 位整数的 base64url 编码，第 11 个字符只承载 4 个有效位，
///   只可能是 `AEIMQUYcgkosw048` 之一——`[Hi10p_1080p]`、`[WEBDL-1080p]`
///   这类恰好 11 位的标签以 `p` 结尾，被这一条挡掉；
/// - 方括号前必须是空白、且前面还有标题（模板里 `]` 前固定一个空格），连写的
///   `[Group][Title][Tag]` 不算；
/// - 方括号必须紧贴扩展名（允许 yt-dlp 未合并的分轨后缀 `.f137`）；
/// - 方括号内是常见编码 / 分辨率 / 片源记号（`x265`、`1080p`、`WEB` 等）的
///   不算，兜住剩下那些碰巧满足前几条的发布标签。
bool isYtDlpYoutubeDownloadPath(String path) {
  final String stem = p.basenameWithoutExtension(path);
  final RegExpMatch? match = _ytDlpStem.firstMatch(stem);
  if (match == null) return false;
  final String id = match.group(1)!;
  return !_releaseToken.hasMatch(id);
}

/// `<标题> [<11 位 id>]` + 可选分轨后缀 `.f137` / `.f137-1`。
final RegExp _ytDlpStem = RegExp(
  r'^\S.*\s\[([A-Za-z0-9_-]{10}[AEIMQUYcgkosw048])\](?:\.f\d+(?:-\d+)?)?$',
);

/// 发布文件名里常见的编码 / 分辨率 / 片源记号。
///
/// 只收 3 个字符以上的记号：videoId 是随机 base64url，`BD` / `4K` 这种两字符
/// 记号在真 id 里碰巧出现的概率约 1%，会把真 YouTube 视频放回刮削；3 字符以上
/// 的记号碰巧命中的概率在千分之几以下。
final RegExp _releaseToken = RegExp(
  r'(?:\d{3,4}[pi]|[xh]26[45]|hevc|avc|aac|flac|opus|10bit|8bit|hi10|'
  r'web|dvd|rip|remux|hdr|uhd)',
  caseSensitive: false,
);
