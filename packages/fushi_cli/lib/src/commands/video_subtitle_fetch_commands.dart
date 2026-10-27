import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `fushi_cli video` 组里的「在线字幕」命令（app 侧路由见
/// `fushi/lib/src/ops/ctl_video_subtitle_fetch_routes.dart`）：
/// 与刮削后自动补字幕同一个 app 服务，身份取已落库的刮削结论，不要求视频页开着。
/// 字幕落在视频旁（`<视频名>.<语言>.srt`），播放页按目录发现，之后用 `video subs` /
/// `video sub` 选用。
const List<CtlCommandSpec> videoSubtitleFetchCommands = <CtlCommandSpec>[
  CtlCommandSpec(
    name: 'sub-fetch',
    summary: '立即给一个库里的视频补在线字幕（与刮削后自动补同一条路：搜 → 校验 → 下载）',
    usage: '<bookUid>',
    configure: _configureFetch,
    build: _buildFetch,
    render: _renderInstall,
  ),
  CtlCommandSpec(
    name: 'sub-search',
    summary: '手动搜在线字幕（同字幕面板；只列候选与各来源失败原因，候选号给 sub-get）',
    usage: '<bookUid>',
    configure: _configureSearch,
    build: _buildSearch,
    render: _renderSearch,
  ),
  CtlCommandSpec(
    name: 'sub-get',
    summary: '下载 sub-search 列出的一条字幕放到视频旁（不覆盖已有同名字幕）',
    usage: '<候选号 vsN>',
    build: _buildGet,
    render: _renderInstall,
  ),
];

const String _fetchPath = '/api/admin/video/subtitle-fetch';
const String _searchPath = '/api/admin/video/subtitle-search';
const String _getPath = '/api/admin/video/subtitle-get';

void _addLanguageOption(ArgParser parser) {
  parser.addOption(
    'lang',
    valueHelp: 'ja',
    help: '只要这种语言的字幕（缺省按该系列记忆 / 设置里的默认字幕语言）',
  );
}

void _configureFetch(ArgParser parser) => _addLanguageOption(parser);

CtlRequestSpec _buildFetch(CtlCommandContext context) {
  final String? lang = context.option('lang');
  return CtlRequestSpec.post(
    _fetchPath,
    body: <String, Object?>{
      'bookUid': context.positional(0, 'bookUid'),
      if (lang != null) 'language': lang,
    },
  );
}

void _configureSearch(ArgParser parser) {
  _addLanguageOption(parser);
  parser
    ..addOption('query', valueHelp: '词', help: '换个检索词（作品身份 id 照旧带上）')
    ..addOption('episode', valueHelp: 'n', help: '按这一集搜（缺省取文件名里的集号；电影不带）');
}

CtlRequestSpec _buildSearch(CtlCommandContext context) {
  final String? lang = context.option('lang');
  final String? query = context.option('query');
  final String? episode = context.option('episode');
  int? episodeNumber;
  if (episode != null) {
    episodeNumber = int.tryParse(episode);
    if (episodeNumber == null || episodeNumber <= 0) {
      throw CtlUsageError('--episode 必须是正整数：$episode');
    }
  }
  return CtlRequestSpec.post(
    _searchPath,
    body: <String, Object?>{
      'bookUid': context.positional(0, 'bookUid'),
      if (lang != null) 'language': lang,
      if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
      if (episodeNumber != null) 'episode': episodeNumber,
    },
  );
}

String _renderSearch(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final List<String> lines = <String>[
    renderCtlTable(
      data,
      const <(String, String)>[
        ('候选', 'id'),
        ('来源', 'provider'),
        ('语言', 'language'),
        ('集', 'episode'),
        ('文件', 'fileName'),
      ],
      listKey: 'candidates',
      empty: '没有找到字幕',
    ),
  ];
  final Object? failures = data['failures'];
  if (failures is List && failures.isNotEmpty) {
    for (final Object? f in failures) {
      if (f is! Map) continue;
      lines.add(
        '来源失败：${f['provider']} ${f['kind']}'
        '${f['status'] == null ? '' : '（HTTP ${f['status']}）'}  ${f['message']}',
      );
    }
  }
  return lines.join('\n');
}

CtlRequestSpec _buildGet(CtlCommandContext context) => CtlRequestSpec.post(
  _getPath,
  body: <String, Object?>{'id': context.positional(0, '候选号')},
);

String _renderInstall(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final String outcome = '${data['outcome']}';
  final String detail = data['detail'] == null ? '' : '（${data['detail']}）';
  return switch (outcome) {
    'installed' => '已装上字幕（${data['language'] ?? '?'}）：${data['installedPath']}',
    'alreadyHasSubtitle' =>
      '已有字幕，没动它$detail'
          '${data['installedPath'] == null ? '' : '：${data['installedPath']}'}',
    'noCandidate' => '没有找到字幕$detail',
    'allCandidatesRejected' => '有候选但都没通过校验$detail（可用 sub-search 手动挑）',
    'noIdentity' => '这个视频还没有作品身份$detail',
    _ => '$outcome$detail',
  };
}
