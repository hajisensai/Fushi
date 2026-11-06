import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';

/// URL 视频导入（YouTube 等）的操作描述（spec §4）。
///
/// 导入只落一行视频库条目（不下载字节），撤销 = 删掉刚建的那条（library 域的
/// 条目删除路由，只删库里的行；流媒体条目没有本地视频文件）。条目已被删掉 =
/// superseded。只认视频模块门：导入不是下载中心的能力，iOS 同样可用。
///
/// 出站请求（spec §5.2「把数据发给已指派 LLM 以外的第三方」不可撤销）：
/// - `url.probe` 只对 YouTube 地址联网，且请求只发往 YouTube 自己（youtube_explode
///   从地址里只取 11 位 videoId，拼 `www.youtube.com/watch?v=<id>`；缩略图按 id 拼
///   `i.ytimg.com`）；直链 / 网页站只回种类、不联网（`ctl_url_import_routes_test.dart`
///   钉死）。模型给的地址到不了它自己选的主机，所以仍是 read。
/// - `url.import` 对直链 / HLS 会让 ffmpeg 直接请求模型给的地址抽封面帧（带模型给的
///   Referer / User-Agent），这一下请求撤销收不回，所以 `confirm: true`：确认卡片写明
///   地址，用户点了才导入；导入本身照常可撤销。
List<OpDescription> describeUrlImportOps(OpDescribeKit kit) {
  final OpAvailability Function() video = kit.whenModule(ModuleId.video);
  return <OpDescription>[
    OpDescription(
      id: 'url.probe',
      method: 'GET',
      pattern: '/api/admin/url-import/probe',
      summary:
          'Inspect a video URL before importing: kind (youtube / webPage / '
          'stream) and the library id it would get; for YouTube also title, '
          'thumbnail, available qualities and caption tracks. Read-only.',
      availability: video,
      params: const <OpParam>[
        OpParam.string(
          'url',
          description:
              'http(s) URL (YouTube watch / youtu.be, direct link, HLS).',
          required: true,
        ),
        OpParam.string(
          'lang',
          description:
              'Preferred caption language code for ordering (default: the '
              'study language).',
        ),
      ],
    ),
    OpDescription(
      id: 'url.import',
      method: 'POST',
      pattern: '/api/admin/url-import',
      summary:
          'Import a video URL into the video library like the import dialog '
          '(streamed on open; YouTube re-resolved each time; nothing is '
          'downloaded). Returns the new item key. Undo removes the item. '
          'Importing a direct / HLS link fetches that address to grab a cover '
          'frame, so the user confirms the address first.',
      risk: OpRisk.write,
      confirm: true,
      availability: video,
      params: const <OpParam>[
        OpParam.string(
          'url',
          description: 'http(s) URL to import.',
          required: true,
        ),
        OpParam.string(
          'subtitleUrl',
          description: 'Optional external subtitle URL (http(s)).',
        ),
        OpParam.string(
          'referer',
          description: 'Optional Referer header for hotlink-protected streams.',
        ),
        OpParam.string(
          'userAgent',
          description: 'Optional User-Agent header for the stream.',
        ),
      ],
      undo: kit.inverseRouteUndo(
        payloadOf: (CtlCall call, Object? result) => <String, Object?>{
          'key': result is Map ? result['key'] : null,
        },
        describe: (Map<String, Object?> p) => '${p['key']}',
        inverse: (Map<String, Object?> payload) async {
          final Object? key = payload['key'];
          if (key is! String || key.isEmpty) return null;
          return kit.callRoute(
            'DELETE',
            '/api/admin/library/items/:key',
            params: <String, String>{'key': key},
            body: const <String, Object?>{'confirm': true},
          );
        },
      ),
    ),
  ];
}
