import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/ctl_disc_routes.dart' show kDiscCtlMenuKeys;
import 'package:fushi/src/ops/op_describe_kit.dart';

/// 碟片：BD / DVD 原盘会话的操作描述（spec §4）。
///
/// 全部是 read：列盘 / 会话状态只读；开盘、退出会话与 `nav.go` / `library.item.open`
/// 同类，只是导航（推 / 关播放页），不改任何库数据；菜单键只驱动播放器里盘自己的
/// 导航机（libbluray / libdvdnav），不写偏好、不写库——之后真放起正片，观看进度照常
/// 按播放落库，与打开任何视频相同，不是这条操作写的。
List<OpDescription> describeDiscOps(OpDescribeKit kit) {
  final OpAvailability Function() video = kit.whenModule(ModuleId.video);
  return <OpDescription>[
    OpDescription(
      id: 'disc.list',
      method: 'GET',
      pattern: '$_root/discs',
      summary:
          'List Blu-ray / UHD / DVD discs in the video library (one row per '
          'physical disc; uid opens it). present=false when the disc folder / '
          'image is not reachable now.',
      availability: video,
      params: const <OpParam>[
        OpParam.string(
          'search',
          description: 'Keyword matched against disc label and title.',
        ),
      ],
    ),
    OpDescription(
      id: 'disc.open',
      method: 'POST',
      pattern: '$_root/open',
      summary:
          'Open a disc in its authored menu (immersive disc session) like "Play '
          'disc" on the detail page; brings the main window forward. Fails '
          'with the reason when this device cannot run the menu (BD-J on '
          'mobile, missing BD-J component). Navigation only.',
      availability: video,
      params: const <OpParam>[
        OpParam.string(
          'uid',
          description: 'Disc uid from disc.list (any title of the disc works).',
          required: true,
        ),
      ],
    ),
    OpDescription(
      id: 'disc.session.status',
      method: 'GET',
      pattern: '$_root/session',
      summary:
          'Current disc session: disc type, whether the menu is on screen or a '
          'title is playing, navigation title number, error. active=false when '
          'no disc session is open.',
      availability: video,
    ),
    OpDescription(
      id: 'disc.session.key',
      method: 'POST',
      pattern: '$_root/session/key',
      summary:
          'Press a disc remote key in the open disc session: arrows, select, '
          'back (BD: toggle popup; DVD: resume title), topMenu, titleMenu, '
          'popupMenu (DVD: chapter menu). Drives the disc menu only; changes '
          'no library data.',
      availability: video,
      params: <OpParam>[
        OpParam.string(
          'key',
          description: 'Remote key.',
          required: true,
          enumValues: kDiscCtlMenuKeys,
        ),
      ],
    ),
    OpDescription(
      id: 'disc.session.exit',
      method: 'POST',
      pattern: '$_root/session/exit',
      summary:
          'Leave the disc session (like "Exit disc"): back to the previous '
          'page; watch progress is saved as on any player exit. Navigation '
          'only.',
      availability: video,
    ),
  ];
}

const String _root = '/api/admin/disc';
