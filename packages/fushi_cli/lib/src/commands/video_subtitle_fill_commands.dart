import 'package:args/args.dart';

import '../ctl_commands.dart';

/// `fushi_cli video sub-fill`：整库补字幕（app 侧路由见
/// `fushi/lib/src/ops/ctl_video_subtitle_fill_routes.dart`）。
///
/// 每集按目标语言判缺：已有 / 关了的不动；内封文本轨选上；内封图形轨 OCR；再不行在线
/// 下载（原盘按 ASR 逐句重定时，版本对不上改用 ASR 稿）；还没有就本地 ASR 生成。
/// 不发任何 AI 请求。任务在 app 里后台跑，`video job <id>` 看进度，`--status` 看报告。
const List<CtlCommandSpec> videoSubtitleFillCommands = <CtlCommandSpec>[
  CtlCommandSpec(
    name: 'sub-fill',
    summary: '整库补字幕：缺目标语言字幕的集按 内封 → OCR → 下载（原盘重定时）→ 生成 补上',
    usage: '--lang <ja> [--collection <id> | --books <uid,uid>] [--dry-run]',
    configure: _configure,
    build: _build,
    render: _render,
  ),
  CtlCommandSpec(
    name: 'sub-fill-undo',
    summary: '撤销一次整库补字幕（删新写的字幕、还原原来的字幕选择）',
    usage: '<任务 id fill-…>',
    build: _buildUndo,
    render: _renderUndo,
  ),
];

const String _path = '/api/admin/video/subtitle-fill';
const String _undoPath = '/api/admin/video/subtitle-fill-undo';

void _configure(ArgParser parser) {
  parser
    ..addOption('lang', valueHelp: 'ja', help: '目标字幕语言（必填，除非 --status）')
    ..addOption('collection', valueHelp: 'id', help: '只补这个合集')
    ..addOption('books', valueHelp: 'uid,uid', help: '只补这几集')
    ..addFlag('dry-run', negatable: false, help: '只列每集要怎么补，什么都不改')
    ..addFlag('no-generate', negatable: false, help: '下不到也不本地生成')
    ..addFlag('no-ocr', negatable: false, help: '不 OCR 内封图形字幕')
    ..addFlag('no-download', negatable: false, help: '不在线下载')
    ..addFlag('no-retime', negatable: false, help: '原盘下到的字幕不做 ASR 重定时')
    ..addFlag('wait', negatable: false, help: '等跑完再返回整份报告')
    ..addFlag('status', negatable: false, help: '看最近一次任务的进度与报告');
}

CtlRequestSpec _build(CtlCommandContext context) {
  if (context.flag('status')) return const CtlRequestSpec.get(_path);
  final String? lang = context.option('lang');
  if (lang == null || lang.trim().isEmpty) {
    throw CtlUsageError('要给 --lang（目标字幕语言，如 ja）');
  }
  final String? collection = context.option('collection');
  int? collectionId;
  if (collection != null) {
    collectionId = int.tryParse(collection);
    if (collectionId == null) {
      throw CtlUsageError('--collection 必须是合集 id：$collection');
    }
  }
  final String? books = context.option('books');
  return CtlRequestSpec.post(
    _path,
    body: <String, Object?>{
      'language': lang.trim(),
      if (collectionId != null) 'collectionId': collectionId,
      if (books != null) 'bookUids': books,
      if (context.flag('dry-run')) 'dryRun': true,
      if (context.flag('no-generate')) 'generate': false,
      if (context.flag('no-ocr')) 'ocr': false,
      if (context.flag('no-download')) 'download': false,
      if (context.flag('no-retime')) 'retime': false,
      if (context.flag('wait')) 'wait': true,
    },
  );
}

CtlRequestSpec _buildUndo(CtlCommandContext context) => CtlRequestSpec.post(
  _undoPath,
  body: <String, Object?>{'jobId': context.positional(0, '任务 id')},
);

String _render(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final List<String> lines = <String>[
    '任务 ${data['jobId']}  语言 ${data['language']}'
        '${data['dryRun'] == true ? '（只预览）' : ''}  '
        '${data['done']}/${data['total']}'
        '${data['running'] == true ? '  进行中' : ''}'
        '${data['videoJob'] == null ? '' : '  video job ${data['videoJob']}'}',
  ];
  final Object? counts = data['counts'];
  if (counts is Map && counts.isNotEmpty) {
    lines.add(
      counts.entries
          .map((MapEntry<Object?, Object?> e) => '${e.key} ${e.value}')
          .join('  '),
    );
  }
  final Object? outcomes = data['outcomes'];
  if (outcomes is List && outcomes.isNotEmpty) {
    lines.add(
      renderCtlTable(
        data,
        const <(String, String)>[
          ('结果', 'action'),
          ('计划', 'plan'),
          ('命中%', 'matchPercent'),
          ('标题', 'title'),
          ('说明', 'detail'),
        ],
        listKey: 'outcomes',
        empty: '',
      ),
    );
  }
  if (data['report'] != null) lines.add('报告：${data['report']}');
  return lines.join('\n');
}

String _renderUndo(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '已撤销 ${data['jobId']}：还原 ${data['undone']} 集';
}
