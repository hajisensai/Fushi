import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/scan_scale.dart';

/// 视频库路径的「文件在不在」只许走 `video_member_file.dart` 的两个入口。
///
/// 库里的 `videoPath` 不全是真实媒体文件：DVD 标题是虚拟路径
/// `<盘根>/VIDEO_TS/TITLE_nn.dvdtitle`（盘根可以是 `.iso`），裸
/// `File(videoPath).existsSync()` 对它恒为「不存在」——要么把仍在盘上的条目当成丢了
/// （搬家 / 离线判据），要么把「没有媒体字节」报成「文件丢失」（上传 / 备份）。根因修
/// 法是一个引擎侧入口：`videoMemberExists*`（这一条还在不在）与
/// `hasLocalMediaFile*`（有没有可直接读的媒体文件）与 `videoPathFileExists*`（这个路径
/// 本身是不是一个文件：打包 / 放 sidecar）。
///
/// 本守卫扫 app / 引擎 / 服务端的 `lib/`，对 `File(<…videoPath>)` 后接 `.exists` /
/// `.existsSync`（同一表达式，或先赋给局部变量再判）的写法报错。外部传进来的任意文件
/// 路径（命令行 / 文件关联参数，不是库路径）在 [_allowed] 里逐条登记理由。
const Map<String, String> _allowed = <String, String>{
  'packages/fushi_engine/lib/media/video/video_member_file.dart':
      '入口实现本身（先换成盘上真实文件 / 先排除无媒体字节的路径，再判 exists）',
  'fushi/lib/main.dart': '文件关联 / 命令行转交的任意候选路径（不是库路径），先确认文件在再决定入库',
  'packages/fushi_server/lib/src/commands/subs_commands.dart':
      'CLI `subs download --to <video>`：用户在命令行给的文件路径，不是库路径',
};

/// `File(<表达式以 videoPath 结尾>)` 直接接 `.exists(` / `.existsSync(`。
final RegExp _direct = RegExp(
  r'File\(\s*([\w.!?]*[vV]ideoPath)\s*\)\s*\.\s*exists(?:Sync)?\(',
);

/// `final File x = File(<…videoPath>);` 之后（同一段内）对 `x` 判 exists。
final RegExp _assigned = RegExp(
  r'(?:final|var)\s+File\s+(\w+)\s*=\s*File\(\s*([\w.!?]*[vV]ideoPath)\s*\)\s*;',
);

/// 去掉整行注释：文档里引用反面写法不算违规。
String _stripLineComments(String source) => source
    .split('\n')
    .map((String line) => line.trimLeft().startsWith('//') ? '' : line)
    .join('\n');

List<String> findBareVideoPathExistsChecks(String source) {
  final String code = _stripLineComments(source);
  final List<String> hits = <String>[];
  for (final RegExpMatch m in _direct.allMatches(code)) {
    hits.add(m.group(0)!);
  }
  for (final RegExpMatch m in _assigned.allMatches(code)) {
    final String name = m.group(1)!;
    final int end = m.end + 600 < code.length ? m.end + 600 : code.length;
    final String window = code.substring(m.end, end);
    if (RegExp(
      '(?:^|[^\\w])${RegExp.escape(name)}\\s*\\.\\s*exists(?:Sync)?\\(',
    ).hasMatch(window)) {
      hits.add(m.group(0)!);
    }
  }
  return hits;
}

void main() {
  test('判据本身：直接写法与先赋值再判的写法都认得出，注释与入口函数不算', () {
    expect(
      findBareVideoPathExistsChecks(
        'if (!File(row.videoPath).existsSync()) {}',
      ),
      hasLength(1),
    );
    expect(
      findBareVideoPathExistsChecks(
        'final File f = File(v.videoPath);\n  if (!await f.exists()) return;',
      ),
      hasLength(1),
    );
    expect(
      findBareVideoPathExistsChecks(
        '// 反例：File(videoPath).existsSync()\n'
        'if (!hasLocalMediaFileSync(videoPath)) return;\n'
        'final File f = File(videoPath);\nawait f.length();',
      ),
      isEmpty,
    );
  });

  test('库路径的存在性判断一律走 video_member_file.dart 的入口', () {
    final Directory repo = Directory(
      p.normalize(p.join(Directory.current.path, '..')),
    );
    final List<String> roots = <String>[
      'fushi/lib',
      'packages/fushi_engine/lib',
      'packages/fushi_server/lib',
    ];
    int scanned = 0;
    final Map<String, List<String>> offenders = <String, List<String>>{};
    final Set<String> allowedSeen = <String>{};
    for (final String root in roots) {
      final Directory dir = Directory(p.join(repo.path, root));
      expect(dir.existsSync(), isTrue, reason: '扫描根不存在：${dir.path}');
      for (final FileSystemEntity e in dir.listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        if (e.path.endsWith('.g.dart')) continue;
        scanned++;
        final List<String> hits = findBareVideoPathExistsChecks(
          e.readAsStringSync(),
        );
        if (hits.isEmpty) continue;
        final String rel = p
            .relative(e.path, from: repo.path)
            .replaceAll('\\', '/');
        if (_allowed.containsKey(rel)) {
          allowedSeen.add(rel);
          continue;
        }
        offenders[rel] = hits;
      }
    }
    expectScanScale(
      scanned,
      what: 'app / 引擎 / 服务端 lib 下的 .dart 文件',
      atLeast: 2000,
      measured: 2538,
    );
    expect(
      offenders,
      isEmpty,
      reason:
          '库路径（videoPath）的「文件在不在」不能裸调 File(...).exists*：DVD 标题是虚拟路径，'
          '裸判恒为不存在。「这一条还在不在」用 videoMemberExists*，「有没有可读的媒体文件」'
          '用 hasLocalMediaFile*，「这个路径本身是不是文件」用 videoPathFileExists*（packages/fushi_engine/lib/media/video/video_member_file.dart）。',
    );
    expect(
      allowedSeen,
      _allowed.keys.toSet(),
      reason: '白名单里有已经不再命中的条目：删掉它，别让豁免悄悄变宽',
    );
  });
}
