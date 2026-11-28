/// URL 视频导入（YouTube 等）的操作声明（spec §4）。实现在 app
/// `fushi/lib/src/ops/ctl_url_import_routes.dart`（[UrlImportOps.probe] /
/// [UrlImportOps.importVideo] 的 `bind`），CLI 命令在
/// `commands/url_import_commands.dart`，都引用这里的同一个对象。
///
/// 出站请求（spec §5.2「把数据发给已指派 LLM 以外的第三方」不可撤销）：
/// - `url.probe` 只对 YouTube 地址联网，且请求只发往 YouTube 自己（youtube_explode
///   从地址里只取 11 位 videoId，拼 `www.youtube.com/watch?v=<id>`；缩略图按 id 拼
///   `i.ytimg.com`）；直链 / 网页站只回种类、不联网（`ctl_url_import_routes_test.dart`
///   「直链 / 网页站探测只给种类，不联网」钉死）。调用方给的地址到不了它自己选的
///   主机，所以地址参数是 [OpParamRole.fixedHostUrl]，操作仍是 read。
/// - `url.import` 对直链 / HLS 会让 ffmpeg 直接请求给的地址抽封面帧（带给的
///   Referer / User-Agent），这一下请求撤销收不回：地址参数是
///   [OpParamRole.remoteUrl]，声明即要求先确认；导入本身照常可撤销。
library;

import '../fushi_op.dart';
import '../op_spec.dart';

abstract final class UrlImportOps {
  /// 路由根。
  static const String root = '/api/admin/url-import';

  static const OpParam probeUrl = OpParam.fixedHostUrl(
    'url',
    description: 'http(s) URL (YouTube watch / youtu.be, direct link, HLS).',
    required: true,
    httpOnly: true,
  );

  static const OpParam probeLang = OpParam.string(
    'lang',
    description:
        'Preferred caption language code for ordering (default: the '
        'study language).',
  );

  /// 导入前探测：种类、导入后的条目身份；YouTube 再取标题 / 封面、可选画质、字幕轨。
  static const OpSpec probe = OpSpec(
    id: 'url.probe',
    method: 'GET',
    pattern: '$root/probe',
    summary:
        'Inspect a video URL before importing: kind (youtube / webPage / '
        'stream) and the library id it would get; for YouTube also title, '
        'thumbnail, available qualities and caption tracks. Read-only.',
    params: <OpParam>[probeUrl, probeLang],
  );

  static const OpParam importUrl = OpParam.remoteUrl(
    'url',
    description: 'http(s) URL to import.',
    required: true,
    httpOnly: true,
  );

  static const OpParam importSubtitleUrl = OpParam.remoteUrl(
    'subtitleUrl',
    description: 'Optional external subtitle URL (http(s)).',
    httpOnly: true,
  );

  static const OpParam importReferer = OpParam.string(
    'referer',
    description: 'Optional Referer header for hotlink-protected streams.',
  );

  static const OpParam importUserAgent = OpParam.string(
    'userAgent',
    description: 'Optional User-Agent header for the stream.',
  );

  /// 与视频导入对话框粘贴 URL 的「导入」同一个方法：落一行视频库条目（不下载字节）。
  static const OpSpec importVideo = OpSpec(
    id: 'url.import',
    method: 'POST',
    pattern: root,
    summary:
        'Import a video URL into the video library like the import dialog '
        '(streamed on open; YouTube re-resolved each time; nothing is '
        'downloaded). Returns the new item key. Undo removes the item. '
        'Importing a direct / HLS link fetches that address to grab a cover '
        'frame, so the user confirms the address first.',
    risk: OpRisk.write,
    confirm: true,
    params: <OpParam>[
      importUrl,
      importSubtitleUrl,
      importReferer,
      importUserAgent,
    ],
  );
}
