import 'package:fushi_cli/fushi_cli.dart';

import 'package:fushi/src/media/music/plugin/music_plugin_gate.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/op_describe_kit.dart';

/// 音乐库导入 / 导出（音频文件、光盘、插件、歌词、音频 CD）的操作描述；路由见
/// `ctl_music_import_routes.dart`。
///
/// 撤销只拼现有路由：
/// - 加光盘 = 把这次新登记的盘从曲库移除（盘上文件不动；之前已在曲库里的盘不碰）；
/// - 启停插件 = 拨回原来的状态。
///
/// irreversible：
/// - 导入音频文件：已被音乐来源覆盖的文件触发来源重扫（按磁盘现状增删曲目，与
///   `music.scan` 同理没有前态）；
/// - 章节导入：重新导入只改盘上事实、不在这轮选择里的曲目软删，前一轮的曲目名可能是
///   MusicBrainz 结论，写不回；
/// - 移除光盘 / 卸载插件：删登记 / 删插件包、存储与凭据；
/// - 装插件：执行不可信代码（spec D9：装扩展一律先确认）；
/// - 导出歌词：写用户磁盘（`overwrite` 覆盖已有文件）；
/// - 抓音频 CD：写数据目录并导入曲库，取消也不删已抓的轨。
List<OpDescription> describeMusicImportOps(OpDescribeKit kit) {
  final OpAvailability Function() music = kit.whenModule(ModuleId.music);
  final OpAvailability Function() plugins = kit.all(<OpAvailability Function()>[
    music,
    () => isMusicPluginSourcesAvailable
        ? const OpAvailability.available()
        : const OpAvailability.unavailable(
            'plugins_unavailable',
            'this device cannot run music plugins',
          ),
  ]);
  return <OpDescription>[
    OpDescription(
      id: 'music.import',
      method: 'POST',
      pattern: '$_root/import',
      summary:
          'Import audio / music-video files into the music library (like "Add '
          'audio files" or dropping files on the music page). Files already '
          'under a music folder rescan that folder; the rest are imported '
          'once. Non-music files are skipped and listed.',
      risk: OpRisk.irreversible,
      availability: music,
      params: const <OpParam>[
        OpParam.stringList(
          'paths',
          description: 'Absolute file paths.',
          required: true,
        ),
      ],
    ),
    OpDescription(
      id: 'music.disc.list',
      method: 'GET',
      pattern: '$_root/discs',
      summary:
          'DVD / Blu-ray discs registered in the music library (album, path, '
          'titles already imported as tracks).',
      availability: music,
    ),
    OpDescription(
      id: 'music.disc.add',
      method: 'POST',
      pattern: '$_root/discs',
      summary:
          'Register DVD / Blu-ray discs as music albums (like "Add disc" / '
          '"Disc image…"): a disc folder, drive root or .iso, or a folder whose '
          'tree contains discs. Chapters are imported separately '
          '(music.disc.chapters). Undo removes the newly registered discs.',
      risk: OpRisk.write,
      availability: music,
      params: const <OpParam>[
        OpParam.string(
          'path',
          description: 'Absolute folder or .iso path.',
          required: true,
        ),
      ],
      undo: opCustomUndo(
        payloadOf:
            (CtlCall call, Map<String, Object?> before, Object? result) =>
                <String, Object?>{
                  'added': result is Map
                      ? opUndoStrings(result['added'])
                      : const <String>[],
                },
        describe: (Map<String, Object?> p) => 'discs ${p['added']}',
        revert: (Map<String, Object?> payload) async {
          for (final String uid in opUndoStrings(payload['added'])) {
            await kit.callRoute(
              'DELETE',
              '$_root/discs/:uid',
              params: <String, String>{'uid': uid},
              body: const <String, Object?>{'confirm': true},
            );
          }
          return const OpUndoOutcome.done();
        },
      ),
    ),
    OpDescription(
      id: 'music.disc.remove',
      method: 'DELETE',
      pattern: '$_root/discs/:uid',
      summary:
          'Remove a disc from the music library: its album goes away and its '
          'tracks leave the library (files on the disc are kept).',
      risk: OpRisk.irreversible,
      availability: music,
      params: const <OpParam>[
        _discUidParam,
        OpParam.userGate(
          'confirm',
          description: 'User confirmed removing the disc.',
        ),
      ],
    ),
    OpDescription(
      id: 'music.disc.titles',
      method: 'GET',
      pattern: '$_root/discs/:uid/titles',
      summary:
          'Read a registered disc: its titles (number, label, duration, '
          'chapter count, main feature, already imported).',
      availability: music,
      params: const <OpParam>[_discUidParam],
    ),
    OpDescription(
      id: 'music.disc.chapters',
      method: 'POST',
      pattern: '$_root/discs/:uid/chapters',
      summary:
          'Import the chapters of the chosen disc titles as tracks (like '
          '"Import chapters as tracks"). Without titles: the previous choice, '
          'or the main feature the first time. Re-importing keeps renamed '
          'tracks; tracks of titles not chosen leave the library.',
      risk: OpRisk.irreversible,
      availability: music,
      params: const <OpParam>[
        _discUidParam,
        OpParam.stringList(
          'titles',
          description: 'Title numbers from music.disc.titles.',
        ),
      ],
    ),
    OpDescription(
      id: 'music.plugin.list',
      method: 'GET',
      pattern: '$_root/plugins',
      summary:
          'Music plugins installed on this device (id, name, version, '
          'capabilities, permissions, signer, enabled).',
      availability: plugins,
    ),
    OpDescription(
      id: 'music.plugin.inspect',
      method: 'POST',
      pattern: '$_root/plugins/inspect',
      summary:
          'Check a music plugin package (.fushiplug / .zip) without installing: '
          'manifest, permissions, network domains, signer, digest, and whether '
          'the signer differs from the installed copy.',
      availability: plugins,
      params: const <OpParam>[_packagePathParam],
    ),
    OpDescription(
      id: 'music.plugin.install',
      method: 'POST',
      pattern: '$_root/plugins/install',
      summary:
          'Install (or upgrade) a music plugin package after the user reviewed '
          'music.plugin.inspect. A changed signer clears the old login and '
          'storage. Runs third-party code.',
      risk: OpRisk.irreversible,
      installsCode: true,
      availability: plugins,
      params: const <OpParam>[
        _packagePathParam,
        OpParam.string(
          'digest',
          description:
              'Digest from music.plugin.inspect; refuses if the file changed.',
        ),
        OpParam.userGate(
          'confirm',
          description: 'User reviewed the package and agreed to install it.',
        ),
      ],
    ),
    OpDescription(
      id: 'music.plugin.enable',
      method: 'PUT',
      pattern: '$_root/plugins/:id/enabled',
      summary: 'Enable or disable an installed music plugin.',
      risk: OpRisk.write,
      availability: plugins,
      params: const <OpParam>[
        _pluginIdParam,
        OpParam.boolean(
          'enabled',
          description: 'true = enable, false = disable.',
          required: true,
        ),
      ],
      undo: opCustomUndo(
        payloadOf:
            (CtlCall call, Map<String, Object?> before, Object? result) =>
                <String, Object?>{
                  'id': call.params['id'],
                  if (result is Map) 'previous': result['previous'],
                  if (result is Map) 'enabled': result['enabled'],
                },
        describe: (Map<String, Object?> p) =>
            'plugin ${p['id']} enabled=${p['enabled']}',
        revert: (Map<String, Object?> payload) async {
          final Object? previous = payload['previous'];
          if (previous is! bool) return const OpUndoOutcome.done();
          await kit.callRoute(
            'PUT',
            '$_root/plugins/:id/enabled',
            params: <String, String>{'id': '${payload['id']}'},
            body: <String, Object?>{'enabled': previous},
          );
          return const OpUndoOutcome.done();
        },
      ),
    ),
    OpDescription(
      id: 'music.plugin.uninstall',
      method: 'DELETE',
      pattern: '$_root/plugins/:id',
      summary:
          'Uninstall a music plugin: deletes its package, storage and saved '
          'login.',
      risk: OpRisk.irreversible,
      availability: plugins,
      params: const <OpParam>[
        _pluginIdParam,
        OpParam.userGate(
          'confirm',
          description: 'User confirmed uninstalling the plugin.',
        ),
      ],
    ),
    OpDescription(
      id: 'music.lyrics.export',
      method: 'POST',
      pattern: '$_root/tracks/:uid/lyrics/export',
      summary:
          'Write the lyrics currently shown for a local track next to its '
          'audio file (<name>.ttml lossless, or .lrc). An existing file is '
          'only replaced with overwrite.',
      risk: OpRisk.irreversible,
      availability: music,
      params: const <OpParam>[
        OpParam.string(
          'uid',
          description: 'Track uid from music.track.list.',
          required: true,
          inPath: true,
        ),
        OpParam.string(
          'format',
          description: 'ttml (default) or lrc.',
          enumValues: <String>['ttml', 'lrc'],
        ),
        OpParam.userGate(
          'overwrite',
          description: 'User agreed to replace an existing lyrics file.',
        ),
      ],
    ),
    OpDescription(
      id: 'music.audio-cd.status',
      method: 'GET',
      pattern: '$_root/audio-cd',
      summary: 'Progress / result of the last audio CD rip.',
      availability: music,
    ),
    OpDescription(
      id: 'music.audio-cd.rip',
      method: 'POST',
      pattern: '$_root/audio-cd',
      summary:
          'Rip an audio CD (Windows drive root with TrackNN.cda, or a macOS CD '
          'mount) to FLAC in the app data folder and import it into the music '
          'library as one album. Runs in the background.',
      risk: OpRisk.irreversible,
      longRunning: true,
      availability: music,
      params: const <OpParam>[
        OpParam.string(
          'dir',
          description: 'Absolute path of the CD drive / mount point.',
          required: true,
        ),
      ],
      taskStatus: (String taskId) => _audioCdTaskStatus(kit, taskId),
    ),
    OpDescription(
      id: 'music.audio-cd.cancel',
      method: 'POST',
      pattern: '$_root/audio-cd/cancel',
      summary:
          'Stop the running audio CD rip (tracks already ripped stay and are '
          'reused next time).',
      risk: OpRisk.irreversible,
      availability: music,
    ),
  ];
}

const String _root = '/api/admin/music';

const OpParam _discUidParam = OpParam.string(
  'uid',
  description: 'Disc uid from music.disc.list.',
  required: true,
  inPath: true,
);

const OpParam _pluginIdParam = OpParam.string(
  'id',
  description: 'Plugin id from music.plugin.list.',
  required: true,
  inPath: true,
);

const OpParam _packagePathParam = OpParam.string(
  'path',
  description: 'Absolute path of the .fushiplug / .zip package.',
  required: true,
);

Future<OpTaskStatus> _audioCdTaskStatus(
  OpDescribeKit kit,
  String taskId,
) async {
  final Object? raw = await kit.callRoute('GET', '$_root/audio-cd');
  final Map<Object?, Object?> job = raw is Map
      ? raw
      : const <Object?, Object?>{};
  if (job['id'] != taskId) {
    return OpTaskStatus(
      terminal: true,
      summary: 'task $taskId is no longer tracked',
      data: raw,
    );
  }
  final String status = '${job['status']}';
  return OpTaskStatus(
    terminal: status != 'running',
    succeeded: status == 'done',
    summary: status == 'done'
        ? 'done: ${job['imported']} tracks imported'
        : '$status: track ${job['track']}/${job['trackCount']}',
    data: raw,
  );
}
