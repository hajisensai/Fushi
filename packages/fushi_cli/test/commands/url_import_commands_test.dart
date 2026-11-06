import 'package:args/args.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:test/test.dart';

CtlCommandGroup _group() =>
    kCtlCommandGroups.singleWhere((CtlCommandGroup g) => g.name == 'url');

CtlCommandSpec _spec(String command) => _group().find(command)!;

CtlRequestSpec _build(String command, List<String> args) {
  final CtlCommandSpec spec = _spec(command);
  final ArgParser parser = ArgParser();
  spec.configure?.call(parser);
  return spec.build(CtlCommandContext(parser.parse(args)));
}

Matcher _usageError() => throwsA(isA<CtlUsageError>());

const String _yt = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';

void main() {
  test('url 组只注册一次，含 probe / import', () {
    expect(
      kCtlCommandGroups.where((CtlCommandGroup g) => g.name == 'url'),
      hasLength(1),
    );
    expect(
      <String>[for (final CtlCommandSpec s in _group().commands) s.name],
      <String>['probe', 'import'],
    );
  });

  test('probe：url 进 query，--lang 只在给出时带上；非 http(s) 报用法错误', () {
    final CtlRequestSpec probe = _build('probe', <String>[_yt]);
    expect(probe.method, 'GET');
    expect(probe.path, '/api/admin/url-import/probe');
    expect(probe.query, <String, String>{'url': _yt});
    expect(
      _build('probe', <String>[_yt, '--lang', 'en']).query,
      <String, String>{'url': _yt, 'lang': 'en'},
    );
    expect(() => _build('probe', <String>[]), _usageError());
    expect(() => _build('probe', <String>['file:///a.mp4']), _usageError());
    expect(() => _build('probe', <String>['C:\\a.mp4']), _usageError());
  });

  test('import：可选的字幕 / Referer / UA 只在给出时进 body', () {
    final CtlRequestSpec plain = _build('import', <String>[_yt]);
    expect(plain.method, 'POST');
    expect(plain.path, '/api/admin/url-import');
    expect(plain.body, <String, Object?>{'url': _yt});
    final CtlRequestSpec full = _build('import', <String>[
      'https://cdn.example.com/a.m3u8',
      '--subtitle-url',
      'https://cdn.example.com/a.vtt',
      '--referer',
      'https://example.com/',
      '--user-agent',
      'UA/1',
    ]);
    expect(full.body, <String, Object?>{
      'url': 'https://cdn.example.com/a.m3u8',
      'subtitleUrl': 'https://cdn.example.com/a.vtt',
      'referer': 'https://example.com/',
      'userAgent': 'UA/1',
    });
    expect(() => _build('import', <String>['ftp://x/y']), _usageError());
  });

  test('render：探测列出画质 / 字幕轨 / 取不到的段；导入给出撤销命令', () {
    final String probe = _spec('probe').render!(<String, Object?>{
      'url': _yt,
      'kind': 'youtube',
      'bookUid': 'video/stream/yt:dQw4w9WgXcQ',
      'title': 'Never Gonna Give You Up',
      'qualities': <Object?>[
        <String, Object?>{'label': '1080p', 'codec': 'avc1', 'default': true},
        <String, Object?>{'label': '720p', 'codec': 'avc1'},
      ],
      'captions': <Object?>[
        <String, Object?>{'label': 'English', 'language': 'en', 'auto': true},
      ],
      'errors': <String, Object?>{'metadata': 'timeout'},
    });
    expect(probe, contains('YouTube'));
    expect(probe, contains('video:video/stream/yt:dQw4w9WgXcQ'));
    expect(probe, contains('1080p'));
    expect(probe, contains('自动'));
    expect(probe, contains('自动生成'));
    expect(probe, contains('metadata 取不到'));

    final String imported = _spec('import').render!(<String, Object?>{
      'bookUid': 'video/stream/abc',
      'key': 'video:video/stream/abc',
      'title': 'a',
      'kind': 'stream',
    });
    expect(imported, contains('library rm video:video/stream/abc --yes'));
  });
}
