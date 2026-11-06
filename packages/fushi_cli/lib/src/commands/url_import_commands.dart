import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `fushi_cli url …`：从 URL 导入视频（YouTube 等）（app 侧路由见 `fushi/lib/src/ops/ctl_url_import_routes.dart`）。
///
/// - `probe <url>`：导入前看一眼——种类、导入后的条目键；YouTube 再列标题、可选画质、
///   字幕轨（播放页同一组解析）；
/// - `import <url>`：与视频导入对话框粘贴 URL 的「导入」同一个方法，落进视频库（不下载
///   视频字节，打开时在线播放）。撤销 = `library rm video:<id> --yes`。
const List<CtlCommandGroup> urlImportCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'url',
    summary: '从 URL 导入视频（YouTube / 直链 / HLS）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'probe',
        summary: '探测 URL：种类、导入后的条目键；YouTube 列标题 / 画质 / 字幕轨',
        usage: '<url>',
        configure: _configureProbe,
        build: _buildProbe,
        render: renderUrlProbe,
      ),
      CtlCommandSpec(
        name: 'import',
        summary: '把 URL 导入视频库（与导入对话框粘贴 URL 同一路径，不下载）',
        usage: '<url>',
        configure: _configureImport,
        build: _buildImport,
        render: renderUrlImported,
      ),
    ],
  ),
];

const String _root = '/api/admin/url-import';

String _url(CtlCommandContext c) {
  final String raw = c.positional(0, 'url').trim();
  final Uri? uri = Uri.tryParse(raw);
  final String scheme = uri?.scheme.toLowerCase() ?? '';
  if (uri == null ||
      (scheme != 'http' && scheme != 'https') ||
      uri.host.isEmpty) {
    throw CtlUsageError('只认 http(s) 地址：$raw');
  }
  return raw;
}

void _configureProbe(ArgParser parser) {
  parser.addOption('lang', help: '字幕轨排序优先的语言码（缺省 = 学习语言）');
}

CtlRequestSpec _buildProbe(CtlCommandContext c) => CtlRequestSpec.get(
  '$_root/probe',
  query: <String, String>{
    'url': _url(c),
    if (c.option('lang') != null) 'lang': c.option('lang')!,
  },
);

void _configureImport(ArgParser parser) {
  parser
    ..addOption('subtitle-url', help: '外挂字幕地址（http(s)）')
    ..addOption('referer', help: '防盗链 Referer')
    ..addOption('user-agent', help: '播放用 User-Agent');
}

CtlRequestSpec _buildImport(CtlCommandContext c) => CtlRequestSpec.post(
  _root,
  body: <String, Object?>{
    'url': _url(c),
    if (c.option('subtitle-url') != null)
      'subtitleUrl': c.option('subtitle-url'),
    if (c.option('referer') != null) 'referer': c.option('referer'),
    if (c.option('user-agent') != null) 'userAgent': c.option('user-agent'),
  },
);

/// 种类 → 一句话。
String describeUrlKind(Object? kind) => switch (kind) {
  'youtube' => 'YouTube（打开时在线解析）',
  'webPage' => '网页视频站（用网页播放器打开，无自动封面）',
  'stream' => '直链 / HLS（在线播放）',
  _ => '$kind',
};

String renderUrlProbe(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final StringBuffer out = StringBuffer()
    ..writeln('种类：${describeUrlKind(data['kind'])}')
    ..writeln('导入后条目键：video:${data['bookUid']}');
  if (data['title'] case final String title) out.writeln('标题：$title');
  final Object? qualities = data['qualities'];
  if (qualities is List && qualities.isNotEmpty) {
    out.writeln('画质：');
    out.writeln(
      renderCtlTable(
        <Map<String, Object?>>[
          for (final Object? q in qualities)
            if (q is Map)
              <String, Object?>{
                'label': q['label'],
                'codec': q['codec'],
                'default': q['default'] == true ? '自动' : '',
              },
        ],
        const <(String, String)>[
          ('档', 'label'),
          ('编码', 'codec'),
          ('', 'default'),
        ],
      ),
    );
  } else if (data['muxedOnly'] == true) {
    out.writeln('画质：只有合流 ≤360p（YouTube 侧没有分离流）');
  }
  final Object? captions = data['captions'];
  if (captions is List) {
    out.writeln(captions.isEmpty ? '字幕轨：无' : '字幕轨：');
    if (captions.isNotEmpty) {
      out.writeln(
        renderCtlTable(
          <Map<String, Object?>>[
            for (final Object? t in captions)
              if (t is Map)
                <String, Object?>{
                  'label': t['label'],
                  'language': t['language'],
                  'kind': t['translatedTo'] != null
                      ? '机翻→${t['translatedTo']}'
                      : (t['auto'] == true ? '自动生成' : '人工'),
                },
          ],
          const <(String, String)>[
            ('语言', 'label'),
            ('代码', 'language'),
            ('来源', 'kind'),
          ],
        ),
      );
    }
  }
  final Object? errors = data['errors'];
  if (errors is Map && errors.isNotEmpty) {
    for (final MapEntry<Object?, Object?> e in errors.entries) {
      out.writeln('（${e.key} 取不到：${e.value}）');
    }
  }
  return out.toString().trimRight();
}

String renderUrlImported(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '已导入视频库：${data['title']}\n'
      '条目键：${data['key']}（${describeUrlKind(data['kind'])}）\n'
      '撤销：fushi_cli library rm ${data['key']} --yes';
}
