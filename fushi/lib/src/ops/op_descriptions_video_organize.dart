import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_engine/media/video/organize/video_filename_organize_service.dart'
    show VideoFilenameOrganizePlan;
import 'package:fushi_engine/media/video/organize/video_work_regroup.dart';

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
/// - 拆 / 并作品 = 按执行时记下的原合集、原位置、原分集绑定挪回去
///   （[revertVideoRegroup]）；之后又被挪过的文件保留现状。
/// - 设置合集分栏 = 每个文件的手动分栏恢复成执行前
///   （[restoreVideoCollectionSections]）；之后又被改过的文件保留现状，报 partial /
///   superseded。
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
        OpParam.boolean(
          'ifFree',
          description:
              'Refuse (409 episode_occupied) when that episode is already bound '
              'to another local file, instead of unbinding that file.',
        ),
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
      id: 'video.section.list',
      method: 'GET',
      pattern: '$kVideoOrganizeCtlRoot/works/:id/sections',
      summary:
          'How the collection page splits a work into sections: one tab per '
          'season ("s1", "s2"...) plus "extras" (PV & extras), exactly as the '
          'app shows them. Per file: its section, why it is there '
          '(source=manual: set with video.section.set; pinnedEpisode: a '
          'manual season/episode pin, season 0 counts as extras; filename: '
          'guessed from the file name), the season/episode read from the file '
          'name, the scraped episode(s) it is bound to and the match rating. '
          'warnings[] flags what to check: bound_to_special = scraped as a '
          'special but shown as a regular episode; duplicate_episode_number = '
          'several files in one section share an episode number (shorts or '
          'specials mixed into the main episodes). scrapedExtras[] are files '
          'the scrape recognised as extras (NCOP etc.); the page lists them in '
          'a separate extras row, not in a section. Use it after merging or '
          're-scraping to verify the result.',
      availability: video,
      params: const <OpParam>[_workIdParam],
    ),
    OpDescription(
      id: 'video.section.set',
      method: 'POST',
      pattern: '$kVideoOrganizeCtlRoot/sections',
      summary:
          'Put video files into a section of their collection page: '
          'section=season with season=N (main episodes of a single-season '
          'show are season 1), section=extras for PV & extras, or '
          'section=auto to drop the manual choice (then a manual '
          'season/episode pin decides, else the file name). The choice '
          'belongs to the file: merging collections, regrouping works and '
          're-scraping keep it. It only changes where the file is listed; '
          'use video.episode.pin to change which scraped episode it is. '
          'Answers each file\'s resulting section; check the whole work with '
          'video.section.list.',
      risk: OpRisk.write,
      availability: video,
      params: const <OpParam>[
        OpParam.stringList(
          'items',
          description: 'Video file uids (files[].uid from video.section.list).',
          required: true,
        ),
        OpParam.string(
          'section',
          description: 'season, extras, or auto.',
          required: true,
          enumValues: <String>['season', 'extras', 'auto'],
        ),
        OpParam.integer(
          'season',
          description: 'Season number, 1 or more (only with section=season).',
        ),
      ],
      undo: opCustomUndo(
        payloadOf: (CtlCall call, Map<String, Object?> before, Object? result) {
          final Map<Object?, Object?> m = result is Map ? result : const {};
          return <String, Object?>{
            'applied': m['applied'],
            'previous': m['previous'],
          };
        },
        describe: (Map<String, Object?> p) {
          final Object? previous = p['previous'];
          return '${previous is Map ? previous.length : 0} file(s) → '
              '${p['applied'] ?? 'auto'}';
        },
        revert: (Map<String, Object?> payload) async {
          final ({int reverted, int superseded}) r =
              await restoreVideoCollectionSections(
                kit.context.appModel.database,
                applied: payload['applied'],
                previous: payload['previous'],
              );
          if (r.superseded == 0) return const OpUndoOutcome.done();
          return r.reverted == 0
              ? const OpUndoOutcome.superseded('这些文件的分栏之后又被改过，保留现状')
              : OpUndoOutcome.partial(
                  '已恢复 ${r.reverted} 个；${r.superseded} 个之后又被改过，保留现状',
                );
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
          '"Movie Title (2016)" named "Movie Title (2016)". Moving a file does '
          'not change which work it belongs to: use video.work.regroup for '
          'that. Never overwrites an existing file. Undo moves it back.',
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
    OpDescription(
      id: 'video.library.files',
      method: 'GET',
      pattern: '$kVideoOrganizeCtlRoot/files',
      summary:
          'The whole video library as one joined table: every local video '
          'file with the work it belongs to, how that work is identified '
          '(tv / movie / unidentified), the season+episode it is bound to, '
          'its length in minutes (when already probed) and its path relative '
          'to the library root. Use it to look across the library yourself '
          'instead of opening works one by one: season=0 lists everything '
          'filed as a special, unbound=true the files that matched no '
          'episode, minMinutes=60 the feature-length files, q a substring of '
          'the path or work title. Columnar: rows[] follow columns[]; work '
          'titles are given once in works{}. Page with nextOffset.',
      availability: video,
      params: const <OpParam>[
        OpParam.string(
          'work',
          description: 'Only this work (collection:<id> or book:<uid>).',
        ),
        OpParam.integer(
          'season',
          description: 'Only files bound to this season (0 = specials).',
        ),
        OpParam.boolean(
          'unbound',
          description: 'Only files bound to no episode.',
        ),
        OpParam.integer(
          'minMinutes',
          description:
              'Only files at least this long (files with unknown length are '
              'left out).',
        ),
        OpParam.string(
          'type',
          description: 'Only works identified as tv / movie / unidentified.',
        ),
        OpParam.string(
          'q',
          description: 'Substring of the relative path or the work title.',
        ),
        OpParam.integer('limit', description: 'Rows per page (default 300).'),
        OpParam.integer('offset', description: 'Rows to skip.'),
      ],
    ),
    OpDescription(
      id: 'video.library.audit',
      method: 'GET',
      pattern: '$kVideoOrganizeCtlRoot/audit',
      summary:
          'Audit the whole video library for files filed in the wrong place: '
          'feature-length files (60+ min and at least twice the regular '
          'episode length) bound to a specials season ("season 0") of a '
          'series. One call instead of opening every work. '
          'kind=feature_in_specials: split the file out with '
          'video.work.regroup to=standalone, then identify it as a movie; '
          'movie_as_series: re-identify that work with type=movie; '
          'features_only_work: every local file of the work is such a film, '
          'decide per file. Durations of not-yet-probed season-0 files are '
          'probed on the spot (first call can take a while); unknownDuration '
          'counts files that still could not be judged. The length rule is '
          'only a first pass: detail=true also lists, per series, every local '
          'file bound to season 0 or bound to no episode at all (path, '
          'minutes, the special it is bound to and that special\'s title / '
          'length) so you can judge each one yourself.',
      availability: video,
      params: const <OpParam>[
        OpParam.boolean(
          'detail',
          description:
              'Also return works[]: the facts to judge every season-0 / '
              'unbound file, not only the ones the length rule flags.',
        ),
        OpParam.boolean(
          'probe',
          description:
              'false = only use durations already cached, do not probe '
              'unprobed files (fast; those files count as unknownDuration).',
        ),
      ],
    ),
    OpDescription(
      id: 'video.work.regroup',
      method: 'POST',
      pattern: '$kVideoOrganizeCtlRoot/regroup',
      summary:
          'Move video files between works. Which work a file belongs to is '
          'decided by collection membership, not by where it sits on disk, so '
          'this (not video.file.move) is how a movie filed as "season 0" of a '
          'series is fixed: to=standalone makes each file its own work (then '
          'video.work.identify it with type=movie and video.files.organize to '
          'rename), to=new groups the files into a new work, '
          'to=collection:<id> moves them into an existing work. The old '
          'work\'s episode bindings and manual pins for these files are '
          'cleared, and later scans do not pull them back. Files the user '
          'added to the collection by hand are skipped. Refuses to move every '
          'member out of a work.',
      risk: OpRisk.write,
      availability: video,
      params: const <OpParam>[
        OpParam.stringList(
          'items',
          description: 'Video file uids (files[].uid from video.work.get).',
          required: true,
        ),
        OpParam.string(
          'to',
          description:
              'standalone, new (with name), or collection:<id> of an existing '
              'work.',
          required: true,
        ),
        OpParam.string(
          'name',
          description: 'Title of the new work (only with to=new).',
        ),
      ],
      undo: opCustomUndo(
        payloadOf:
            (CtlCall call, Map<String, Object?> before, Object? result) =>
                <String, Object?>{
                  'previous': result is Map ? result['previous'] : null,
                },
        describe: (Map<String, Object?> p) {
          final Object? previous = p['previous'];
          final Object? items = previous is Map ? previous['items'] : null;
          return '${items is List ? items.length : 0} file(s)';
        },
        revert: (Map<String, Object?> payload) async {
          // 什么都没挪（全是 unchanged / 用户亲手放的成员）：没有可撤销的。
          if (payload['previous'] == null) return const OpUndoOutcome.done();
          final VideoRegroupRevert r = await revertVideoRegroup(
            kit.context.appModel.database,
            payload['previous'],
          );
          if (r.reverted == 0) {
            return r.failed > 0
                ? const OpUndoOutcome.failed('原来的作品合集已经不存在')
                : const OpUndoOutcome.superseded('这些文件之后又被挪过，保留现状');
          }
          return r.failed + r.superseded == 0
              ? const OpUndoOutcome.done()
              : OpUndoOutcome.partial(
                  '已挪回 ${r.reverted} 个；${r.superseded} 个之后又被挪过、'
                  '${r.failed} 个的原作品已不存在，保留现状',
                );
        },
      ),
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
