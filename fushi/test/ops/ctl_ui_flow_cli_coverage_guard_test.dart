import 'dart:io';

import 'package:test/test.dart';

/// 「界面里的导入 / 导出 / 选文件再做」流程必须进操作目录（CLI / AI / MCP 同一份），
/// 或写明为什么不进（拍板台 PGpPujl99g：CLI 要能做 app 里能点的操作）。
///
/// 扫描对象：`lib/`（`lib/src/ops/` 以外）里公开的 `Future<…> pickAnd*/import*/export*(`
/// 声明——这类函数几乎都是一个用户能点的「把东西搬进 / 搬出 app」的动作。它的名字
/// 在 `lib/src/ops/` 里出现过（路由直接调它）就算接上了；否则必须在 [_notRouted]
/// 登记一条，值以下列前缀之一开头：
/// - `covered:` 路由用别的入口做了同一件事（写明 CLI 命令）；
/// - `ui-only:` 只能由界面完成（写明为什么）；
/// - `internal:` 不是用户动作（同步 / 迁移 / 平台管线内部调用）；
/// - `pending <bug slug>:` 还没接，已登记待补（`docs/bugs/BUG-*-<slug>.md` 必须存在；
///   用 slug 不用号：撞号时 settle 会改号，slug 不变）。
///
/// 新写这样一个流程却没接路由也没登记，这里就红：要么同时接 ctl 路由 + CLI 命令 +
/// 操作描述，要么在这里写明理由。接上之后把条目删掉（留着也会红）。
const Map<String, String> _notRouted = <String, String>{
  // ── 已由别的路由覆盖 ──────────────────────────────────────────────────
  'exportProfileToJson':
      'covered: fushi_cli profile export（/api/admin/profiles/:id/export）',
  'importProfileFromJson':
      'covered: fushi_cli profile import（/api/admin/profiles/import）',
  'importAndSwitchProfile':
      'covered: fushi_cli profile import + profile activate',
  'importFromDirectory':
      'covered: fushi_cli dict import（/api/admin/dictionaries/import）',
  'importFromFile':
      'covered: fushi_cli dict import（/api/admin/dictionaries/import）',
  'importRecommendedPackFile':
      'covered: fushi_cli dict pack-import（/api/admin/dictionary-pack/import）',
  'importLocalAudioDbFile':
      'covered: 设置动作的 CLI 入口（settings/audio_sources_cli.dart，fushi_cli config run）',
  'importShaderFile':
      'covered: 设置动作的 CLI 入口（media/video/video_settings_cli.dart）',
  'importLuaScriptFile':
      'covered: 设置列表项 video.player.mpv_lua_scripts_list 的 cliList（fushi_cli config items）',
  'importFolder':
      'covered: fushi_cli library import <路径…>（ctl_library_import.dart）',
  'importFromInbox': 'covered: fushi_cli library import <路径…>（收件箱只是界面上的一个默认目录）',
  'importInboxDirectory': 'covered: fushi_cli library import <路径…>',
  'importLocalFolderOnce': 'covered: fushi_cli library import <目录>',
  'importLocalFolderOnceAt':
      'covered: fushi_cli library import <目录> / library source add + scan',
  'importBatchPaths': 'covered: fushi_cli library import --kind manga <路径…>',
  'importMangaBatchFolder':
      'covered: fushi_cli library import --kind manga <目录>',
  'importMangaBatchPaths':
      'covered: fushi_cli library import --kind manga <路径…>',
  'importMangaFromPdf': 'covered: fushi_cli library import --kind manga <pdf>',
  'importMangaAudioManifest':
      'covered: fushi_cli tts import（tts.manga.import，共用 checkMangaAudioManifest）',
  'pickAndImportMangaAudio': 'covered: fushi_cli tts import（tts.manga.import）',
  'importRemoteBookFolder':
      'internal: 云同步拉书时由 sync_orchestrator 调用（fushi_cli sync run）',
  'importRemoteBooks':
      'internal: 云同步拉书时由 sync_orchestrator 调用（fushi_cli sync run）',
  // ── 不是用户动作 ──────────────────────────────────────────────────────
  'exportPackage': 'internal: 追踪插件经互联共享时打包（interconnect_source_share_*）',
  'exportPresetIconToFile': 'internal: 应用图标换肤的平台管线（main.dart / app_icon_apply）',
  'importLogin': 'internal: Bangumi 旧 token 迁移到插件追踪器',
  'importSyncedLocalAudioDb': 'internal: 同步拉下本地音频库后的落地',
  'importAudioFiles': 'internal: 音乐导入端口的底层实现（用户入口 importMusicFiles 另行登记）',
  'exportBatch': 'ui-only: 旧版只读后的一次性迁移向导（migration_page），不是日常操作',
  'importPastedTextBook':
      'ui-only: 输入是剪贴板粘贴的文本；CLI 等价做法是存成 .txt 后 fushi_cli library import',
  // ── 待补（docs/bugs/BUG-*-cli-ui-only-ops-gaps.md 盘点清单） ────────────────────────────────────────
  'importMusicFiles': 'pending cli-ui-only-ops-gaps: 音乐库导入音频文件',
  'importChapters': 'pending cli-ui-only-ops-gaps: 音乐碟片按章节导入',
  'importMusicDiscChapters': 'pending cli-ui-only-ops-gaps: 音乐碟片按章节导入',
  'pickAndAddMusicDiscs': 'pending cli-ui-only-ops-gaps: 音乐碟片添加',
  'pickAndAddMusicDiscImages': 'pending cli-ui-only-ops-gaps: 音乐碟片镜像添加',
  'pickAndInstallMusicPlugin': 'pending cli-ui-only-ops-gaps: 音乐歌词 / 元数据插件安装',
  'exportBesideAudio': 'pending cli-ui-only-ops-gaps: 歌词导出到音频旁',
  'importAudioCdIfPresent': 'pending cli-ui-only-ops-gaps: 音频 CD 导入',
  'importIptvChannels': 'pending cli-ui-only-ops-gaps: IPTV 播放列表导入频道',
  'pickAndApplyVideoFrameCover': 'pending cli-ui-only-ops-gaps: 视频取帧当封面',
  'exportTranscribedSrt': 'pending cli-ui-only-ops-gaps: 有声书转录结果导出 SRT',
  'exportTo': 'pending cli-ui-only-ops-gaps: Galgame Hook 码配置导出',
  'exportWindowRecording': 'pending cli-ui-only-ops-gaps: 窗口录制导出',
  'importMinedSentencesIntoSrs': 'pending cli-ui-only-ops-gaps: 制卡历史导入 SRS',
  'importRecoveryCode': 'pending cli-ui-only-ops-gaps: 排行榜恢复码导入（凭据只经 stdin）',
  'importPageBackdropImage':
      'pending cli-ui-only-ops-gaps: 页面背景图导入（设置项缺 CLI 入口）',
  'importPageBackdropModuleImage':
      'pending cli-ui-only-ops-gaps: 模块页面背景图导入（设置项缺 CLI 入口）',
  'importNow': 'pending cli-ui-only-ops-gaps: 动画下载计划「立即导入」',
  'exportTtsAudiobookM4b': 'pending cli-ui-only-ops-gaps: TTS 有声书导出 M4B',
  'importSyncedBookFile': 'pending cli-ui-only-ops-gaps: 阅读历史云端列表里下载单本书',
};

final RegExp _flowDecl = RegExp(
  r'Future<[^;{=]*?>\s+((?:pickAnd|import|export)[A-Z]\w*)\s*\(',
);

final RegExp _reasonShape = RegExp(
  r'^(covered|ui-only|internal): \S|^pending ([a-z0-9-]+): \S',
);

void main() {
  final Directory lib = Directory('lib');
  final List<File> sources = <File>[
    for (final FileSystemEntity e in lib.listSync(recursive: true))
      if (e is File && e.path.endsWith('.dart') && !e.path.endsWith('.g.dart'))
        e,
  ];
  bool isOps(File f) => f.path.replaceAll(r'\', '/').startsWith('lib/src/ops/');
  final String opsText = <String>[
    for (final File f in sources)
      if (isOps(f)) f.readAsStringSync(),
  ].join('\n');

  final Map<String, String> flows = <String, String>{};
  for (final File f in sources) {
    if (isOps(f)) continue;
    for (final RegExpMatch m in _flowDecl.allMatches(f.readAsStringSync())) {
      flows.putIfAbsent(m.group(1)!, () => f.path);
    }
  }

  bool routed(String name) => RegExp('\\b$name\\b').hasMatch(opsText);

  test('扫描器自检：已接路由的流程与登记的流程都扫得到', () {
    expect(flows, contains('importMangaAudioManifest'));
    expect(flows.length, greaterThan(_notRouted.length));
    expect(flows.keys.where(routed), isNotEmpty);
  });

  test('导入 / 导出 / 选文件流程要么接了路由，要么登记了理由', () {
    final List<String> missing = <String>[
      for (final MapEntry<String, String> e in flows.entries)
        if (!routed(e.key) && !_notRouted.containsKey(e.key))
          '${e.key}（${e.value}）',
    ];
    expect(
      missing,
      isEmpty,
      reason:
          '新的界面流程没进操作目录：接 ctl 路由 + CLI 命令 + op 描述，'
          '或在 _notRouted 写明理由。\n${missing.join('\n')}',
    );
  });

  test('登记表没有过期条目（接上路由或删掉函数后要删登记）', () {
    for (final String name in _notRouted.keys) {
      expect(flows.containsKey(name), isTrue, reason: '$name 已不存在，删掉登记');
      expect(routed(name), isFalse, reason: '$name 已接路由，删掉登记');
    }
  });

  test('理由格式正确；pending 指向的 BUG 文件存在', () {
    final List<String> bugFiles = <String>[
      for (final FileSystemEntity e in Directory('../docs/bugs').listSync())
        e.uri.pathSegments.last,
    ];
    for (final MapEntry<String, String> e in _notRouted.entries) {
      final RegExpMatch? m = _reasonShape.firstMatch(e.value);
      expect(m, isNotNull, reason: '${e.key}：${e.value}');
      final String? bug = m!.group(2);
      if (bug != null) {
        expect(
          bugFiles.any(
            (String f) => RegExp('^BUG-\\d+-$bug\\.md\$').hasMatch(f),
          ),
          isTrue,
          reason: '${e.key} 指向的 $bug 没有 docs/bugs/BUG-*-$bug.md',
        );
      }
    }
  });
}
