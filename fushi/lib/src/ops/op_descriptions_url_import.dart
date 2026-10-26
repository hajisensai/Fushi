import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';

/// URL 视频导入（YouTube 等）的操作描述（spec §4）。
///
/// 导入只落一行视频库条目（不下载字节），撤销 = 删掉刚建的那条（library 域的
/// 条目删除路由，只删库里的行；流媒体条目没有本地视频文件）。条目已被删掉 =
/// superseded。只认视频模块门：导入不是下载中心的能力，iOS 同样可用。
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
          'downloaded). Returns the new item key. Undo removes the item.',
      risk: OpRisk.write,
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
