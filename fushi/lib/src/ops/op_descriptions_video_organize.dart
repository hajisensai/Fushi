import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/media/video/organize/video_filename_organize_service.dart'
    show VideoFilenameOrganizePlan;

import 'package:fushi/src/ops/ctl_video_organize_routes.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';

/// 视频库整理的操作描述（路由见 `ctl_video_organize_routes.dart`）。
///
/// 撤销形态：
/// - 手动指定 / 清除季集 = 把手动指定与改绑动过的分集行恢复成执行前
///   （[restoreVideoEpisodePin]）；之后用户又改过这个文件的指定报 superseded。
/// - 整理文件名 / 点名搬动 = 按服务给的撤销计划逐文件搬回去（做种的仍走引擎，换过
///   目录身份的目录合集换回）。原位置被别的文件占了、或文件之后又被挪走的那几条
///   搬不回去，报 partial；一个视频都不在搬过去的位置上报 superseded。磁盘操作
///   因此满足 `fushi/CLAUDE.md` §13「AI 写操作必须可回滚」，不需要先确认。
List<OpDescription> describeVideoOrganizeOps(
  OpDescribeKit kit,
  OpAvailability Function() video,
) {
  OpUndo moveUndo() => opCustomUndo(
    payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) =>
        <String, Object?>{
          'plan': takeVideoOrganizeUndo(
            result is Map ? result['undoToken'] : null,
          ),
          'renamed': result is Map ? result['renamed'] : 0,
        },
    describe: (Map<String, Object?> p) => '${p['renamed'] ?? 0} file(s)',
    revert: (Map<String, Object?> payload) async {
      final VideoFilenameOrganizePlan? plan = videoOrganizePlanFromJson(
        payload['plan'],
      );
      // 什么都没搬成（全是 unchanged / 被挡下）：没有可撤销的。
      if (plan == null) return const OpUndoOutcome.done();
      if (!await videoOrganizeUndoStillApplies(plan)) {
        return const OpUndoOutcome.superseded('这些文件之后又被挪过，不再搬回');
      }
      final ({int reverted, List<String> errors}) outcome =
          await revertVideoOrganize(
            kit.context.appModel.videoFilenameOrganizeService,
            plan,
          );
      if (outcome.errors.isEmpty) return const OpUndoOutcome.done();
      final String detail = outcome.errors.take(3).join('; ');
      return outcome.reverted == 0
          ? OpUndoOutcome.failed(detail)
          : OpUndoOutcome.partial(
              '已搬回 ${outcome.reverted} 条，${outcome.errors.length} 条没搬回：$detail',
            );
    },
  );

  return <OpDescription>[
    OpDescription(
      id: 'video.work.get',
      method: 'GET',
      pattern: '$kVideoOrganizeCtlRoot/works/:id/detail',
      summary:
          'One video work in detail: type (movie / tv), scraped identity, its '
          'seasons, and every local file with its path (relative to the '
          'library root), duration and the episode(s) it is bound to. Use it '
          'to check whether a "season 0" really holds specials: a 90-minute '
          'file bound to S00E01 is usually a movie filed under the wrong work.',
      availability: video,
      params: const <OpParam>[
        _workIdParam,
        OpParam.boolean(
          'all',
          description:
              'Also list episodes that have no local file (can be hundreds).',
        ),
      ],
    ),
    OpDescription(
      id: 'video.episode.pin',
      method: 'POST',
      pattern: '$kVideoOrganizeCtlRoot/files/:uid/episode',
      summary:
          'Pin a video file to a season / episode of its work (same as '
          '"Set season / episode manually" on the episode card): it is '
          're-bound at once and later scrapes keep it. Use it when a regular '
          'episode was filed as a special or under the wrong number. The '
          'episode must exist in the scraped work (video.work.get all=true). '
          'clear=true removes the pin so the next scrape links it '
          'automatically again.',
      risk: OpRisk.write,
      availability: video,
      params: const <OpParam>[
        _fileUidParam,
        OpParam.integer('season', description: 'Season number (0 = specials).'),
        OpParam.integer('episode', description: 'Episode number.'),
        OpParam.boolean('clear', description: 'Remove the manual pin instead.'),
      ],
      undo: opCustomUndo(
        payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) {
          final Map<Object?, Object?> m = result is Map ? result : const {};
          return <String, Object?>{
            'uid': m['uid'],
            'applied': m['applied'],
            'previous': m['previous'],
          };
        },
        describe: (Map<String, Object?> p) {
          final Object? applied = p['applied'];
          return applied is Map
              ? 'S${applied['season']}E${applied['episode']}'
              : 'cleared';
        },
        revert: (Map<String, Object?> payload) async {
          final Object? uid = payload['uid'];
          if (uid is! String) return const OpUndoOutcome.failed('撤销载荷缺视频 uid');
          return await restoreVideoEpisodePin(
                kit.context.appModel.database,
                bookUid: uid,
                applied: payload['applied'],
                snapshot: payload['previous'],
              )
              ? const OpUndoOutcome.done()
              : const OpUndoOutcome.superseded('这个文件的季集之后又被手动改过');
        },
      ),
    ),
    OpDescription(
      id: 'video.files.organize.plan',
      method: 'GET',
      pattern: '$kVideoOrganizeCtlRoot/organize',
      summary:
          'Preview renaming video files on disk to the canonical name from '
          'their scraped identity ("Title (Year) - S01E02.ext", movies '
          '"Title (Year).ext"), optionally also moving them into '
          '"Title (Year)/Season 01/". Read-only; shows each old → new path '
          'and why items would be skipped.',
      availability: video,
      params: _organizeParams,
    ),
    OpDescription(
      id: 'video.files.organize',
      method: 'POST',
      pattern: '$kVideoOrganizeCtlRoot/organize',
      summary:
          'Rename video files on disk (with their subtitles / NFO / images) to '
          'the canonical name from their scraped identity; layout=directories '
          'also moves them into "Title (Year)/Season 01/". Seeding files are '
          'renamed through the download engine so torrents keep working. Fix '
          'the identity / season / episode first (video.work.identify, '
          'video.episode.pin): the names come from that data. Undo moves the '
          'files back.',
      risk: OpRisk.write,
      availability: video,
      params: const <OpParam>[
        ..._organizeParams,
        OpParam.userGate(
          'allowUnverifiedTorrents',
          description:
              'User agreed to rename although it could not be verified whether '
              'the files are being seeded (a seeding torrent may stop).',
        ),
      ],
      undo: moveUndo(),
    ),
    OpDescription(
      id: 'video.file.move',
      method: 'POST',
      pattern: '$kVideoOrganizeCtlRoot/files/:uid/move',
      summary:
          'Move one video file (with its subtitles / NFO / images) to a folder '
          'and / or file name you choose, inside its own library root. Use it '
          'when the scraped identity itself is wrong, e.g. a movie sitting in '
          '"Some Show/Season 00/Some Show - S00E01.mkv": move it to '
          '"Movie Title (2016)" named "Movie Title (2016)", then identify it '
          '(video.work.identify with type=movie) once the library has '
          're-scanned. Never overwrites an existing file. Undo moves it back.',
      risk: OpRisk.write,
      availability: video,
      params: const <OpParam>[
        _fileUidParam,
        OpParam.string(
          'directory',
          description:
              'Target folder relative to the library root, "/"-separated '
              '(e.g. "Your Name (2016)"). Omit to keep the folder.',
        ),
        OpParam.string(
          'name',
          description:
              'New file name without extension. Omit to keep the name.',
        ),
        OpParam.userGate(
          'allowUnverifiedTorrents',
          description:
              'User agreed to move although it could not be verified whether '
              'the file is being seeded.',
        ),
      ],
      undo: moveUndo(),
    ),
  ];
}

const OpParam _workIdParam = OpParam.string(
  'id',
  description:
      'Work id (book:<bookUid> or collection:<id>) from video.work.list.',
  required: true,
  inPath: true,
);

const OpParam _fileUidParam = OpParam.string(
  'uid',
  description: 'Video file uid (files[].uid from video.work.get).',
  required: true,
  inPath: true,
);

const List<OpParam> _organizeParams = <OpParam>[
  OpParam.stringList(
    'items',
    description: 'Video file uids. Give this or work, not both.',
  ),
  OpParam.string(
    'work',
    description:
        'Work id (book:<bookUid> or collection:<id>): all its local files.',
  ),
  OpParam.string(
    'layout',
    description:
        'filename (default) = rename in place; directories = also move into '
        'the canonical folder under the library root.',
    enumValues: <String>['filename', 'directories'],
  ),
];
