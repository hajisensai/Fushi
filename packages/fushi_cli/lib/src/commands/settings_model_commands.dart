import 'dart:io';

import 'package:args/args.dart';

import '../ctl_commands.dart';
import 'settings_commands.dart' show readCtlSecretFromStdin;

/// `models`（OCR / 语音转录 / 本机 GPT-SoVITS / 本机 Irodori-TTS 模型文件）与 `voice`（朗读声音）
/// 两个命令组。app 侧路由见
/// `fushi/lib/src/ops/ctl_settings_model_routes.dart`。
///
/// 下载是后台长任务：`models download` 立即返回，之后用 `models status` 看进度、
/// `models cancel` 取消。
const List<CtlCommandGroup> settingsModelCommandGroups = <CtlCommandGroup>[
  CtlCommandGroup(
    name: 'models',
    summary: '模型文件：OCR / 语音转录（asr）/ 本机 GPT-SoVITS / 本机 Irodori-TTS',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出全部模型与下载状态',
        build: _buildModelsLs,
        render: _renderModelsLs,
      ),
      CtlCommandSpec(
        name: 'status',
        summary: '查看一个模型的状态与下载进度',
        usage: '<asr|ocr|gpt-sovits|irodori> [<id>]',
        build: _buildModelStatus,
        render: _renderModel,
      ),
      CtlCommandSpec(
        name: 'download',
        summary: '后台下载模型（asr 的 id 是包 id 或语言，如 ja）',
        usage: '<asr|ocr|gpt-sovits|irodori> [<id>]',
        configure: _configureDownload,
        build: _buildModelDownload,
        render: _renderModel,
      ),
      CtlCommandSpec(
        name: 'cancel',
        summary: '取消进行中的下载（已下的部分留着，下次续传）',
        usage: '<asr|ocr|gpt-sovits|irodori> [<id>]',
        build: _buildModelCancel,
        render: _renderModel,
      ),
      CtlCommandSpec(
        name: 'rm',
        summary: '删除模型文件（手动接入的 ASR 包与用户自己的整合包只移除接入；需 --yes）',
        usage: '<asr|ocr|gpt-sovits|irodori> [<id>]',
        configure: _configureYes,
        build: _buildModelRm,
        render: _renderModel,
      ),
      CtlCommandSpec(
        name: 'start',
        summary: '启动本机 GPT-SoVITS / Irodori-TTS 服务（等服务就绪或失败后返回）',
        usage: '[gpt-sovits|irodori]',
        build: _buildModelStart,
        render: _renderModel,
      ),
      CtlCommandSpec(
        name: 'stop',
        summary: '停止本机 GPT-SoVITS / Irodori-TTS 服务',
        usage: '[gpt-sovits|irodori]',
        build: _buildModelStop,
        render: _renderModel,
      ),
      CtlCommandSpec(
        name: 'link',
        summary: '让本机 GPT-SoVITS 指向一份已解压的整合包',
        usage: '<目录>',
        build: _buildModelLink,
        render: _renderModel,
      ),
    ],
  ),
  CtlCommandGroup(
    name: 'voice',
    summary: '朗读声音（TTS 预设）',
    commands: <CtlCommandSpec>[
      CtlCommandSpec(
        name: 'ls',
        summary: '列出朗读声音',
        build: _buildVoiceLs,
        render: _renderVoiceLs,
      ),
      CtlCommandSpec(
        name: 'engines',
        summary: '列出可用朗读引擎与参数',
        build: _buildVoiceEngines,
        render: _renderVoiceEngines,
      ),
      CtlCommandSpec(
        name: 'add',
        summary: '新建一个声音（--param k=v；凭据用 --secret-stdin / --secret-from-env）',
        usage: '<引擎>',
        configure: _configureVoiceAdd,
        build: _buildVoiceAdd,
        render: _renderVoice,
      ),
      CtlCommandSpec(
        name: 'set',
        summary: '修改一个声音（--param k= 删掉该参数）',
        usage: '<id|名字>',
        configure: _configureVoiceSet,
        build: _buildVoiceSet,
        render: _renderVoice,
      ),
      CtlCommandSpec(
        name: 'use',
        summary: '设为默认朗读声音',
        usage: '<id|名字>',
        build: _buildVoiceUse,
        render: _renderVoice,
      ),
      CtlCommandSpec(
        name: 'rm',
        summary: '删除一个声音（需 --yes）',
        usage: '<id|名字>',
        configure: _configureYes,
        build: _buildVoiceRm,
      ),
      CtlCommandSpec(
        name: 'speed',
        summary: '查看 / 设置朗读语速（0.25–3.0）',
        usage: '[<倍速>]',
        build: _buildVoiceSpeed,
        render: _renderVoiceSpeed,
      ),
      CtlCommandSpec(
        name: 'voices',
        summary: '列出该声音所用引擎能提供的音色',
        usage: '<id|名字>',
        build: _buildVoiceVoices,
        render: _renderProviderVoices,
      ),
    ],
  ),
];

void _configureYes(ArgParser parser) {
  parser.addFlag('yes', abbr: 'y', negatable: false, help: '确认破坏性操作');
}

void _requireYes(CtlCommandContext context, String action) {
  if (!context.flag('yes')) throw CtlUsageError('$action是破坏性操作，确认请加 --yes');
}

// ── models ──────────────────────────────────────────────────────────────────

/// `<kind> [<id>]` → 路径；asr 必须给 id，ocr 缺省 default，gpt-sovits / irodori
/// 缺省 local。
String _modelPath(CtlCommandContext context) {
  final String kind = context
      .positional(0, 'asr|ocr|gpt-sovits|irodori')
      .toLowerCase();
  final String? id = context.optionalPositional(1);
  final String resolved = switch (kind) {
    'asr' =>
      id ?? (throw const CtlUsageError('asr 要给包 id 或语言（如 ja），models ls 查看')),
    'ocr' => id ?? 'default',
    'gpt-sovits' || 'gptsovits' || 'tts' => id ?? 'local',
    'irodori' || 'irodori-tts' => id ?? 'local',
    _ => throw CtlUsageError(
      '模型类别只能是 asr / ocr / gpt-sovits / irodori，收到「$kind」',
    ),
  };
  final String normalizedKind = switch (kind) {
    'asr' || 'ocr' => kind,
    'irodori' || 'irodori-tts' => 'irodori',
    _ => 'gpt-sovits',
  };
  return '/api/admin/models/$normalizedKind/${Uri.encodeComponent(resolved)}';
}

CtlRequestSpec _buildModelsLs(CtlCommandContext context) =>
    const CtlRequestSpec.get('/api/admin/models');

CtlRequestSpec _buildModelStatus(CtlCommandContext context) =>
    CtlRequestSpec.get(_modelPath(context));

void _configureDownload(ArgParser parser) {
  parser
    ..addOption(
      'variant',
      allowed: const <String>['standard', 'nvidia50'],
      help: 'gpt-sovits 整合包变体（缺省按显卡自动选）',
    )
    ..addOption('dir', help: 'gpt-sovits 安装目录（缺省在数据目录下）')
    ..addOption(
      'source',
      allowed: const <String>['hf', 'ms', 'hf-mirror'],
      help: '下载源：gpt-sovits 用 hf / ms（ModelScope），irodori 用 hf / hf-mirror',
    )
    ..addOption(
      'backend',
      allowed: const <String>['cu128', 'rocm', 'cpu'],
      help: 'irodori 的 PyTorch 后端（缺省按显卡自动选）',
    )
    ..addOption(
      'model',
      allowed: const <String>['small', 'mf'],
      help: 'irodori 模型：v4.1 Small / v4.1 Small MF（快，适合 CPU）',
    );
}

CtlRequestSpec _buildModelDownload(CtlCommandContext context) {
  final String path = _modelPath(context);
  final String? variant = context.option('variant');
  final String? dir = context.option('dir');
  final String? source = context.option('source');
  final String? backend = context.option('backend');
  final String? model = context.option('model');
  final bool gptSovits = path.startsWith('/api/admin/models/gpt-sovits/');
  final bool irodori = path.startsWith('/api/admin/models/irodori/');
  if ((dir != null || source != null) && !gptSovits && !irodori) {
    throw const CtlUsageError('--dir / --source 只用于 gpt-sovits / irodori');
  }
  if (variant != null && !gptSovits) {
    throw const CtlUsageError('--variant 只用于 gpt-sovits');
  }
  if ((backend != null || model != null) && !irodori) {
    throw const CtlUsageError('--backend / --model 只用于 irodori');
  }
  if (source != null &&
      ((gptSovits && source == 'hf-mirror') || (irodori && source == 'ms'))) {
    throw CtlUsageError('这个模型类别不支持 --source $source');
  }
  return CtlRequestSpec.post(
    '$path/download',
    body: <String, Object?>{
      if (variant != null) 'variant': variant,
      if (dir != null) 'dir': ctlAbsolutePath(dir),
      if (source != null) 'source': source,
      if (backend != null) 'backend': backend,
      if (model != null) 'model': model,
    },
  );
}

CtlRequestSpec _buildModelCancel(CtlCommandContext context) =>
    CtlRequestSpec.post('${_modelPath(context)}/cancel');

CtlRequestSpec _buildModelRm(CtlCommandContext context) {
  final String path = _modelPath(context);
  _requireYes(context, '删除模型');
  return CtlRequestSpec.delete(
    path,
    query: const <String, String>{'confirm': 'true'},
  );
}

String _gptSovitsPath(CtlCommandContext context, String verb) {
  final String kind = (context.optionalPositional(0) ?? 'gpt-sovits')
      .toLowerCase();
  if (kind == 'irodori' || kind == 'irodori-tts') {
    return '/api/admin/models/irodori/local/$verb';
  }
  if (kind != 'gpt-sovits' && kind != 'gptsovits' && kind != 'tts') {
    throw CtlUsageError('只有 gpt-sovits / irodori 有本机服务可起停，收到「$kind」');
  }
  return '/api/admin/models/gpt-sovits/local/$verb';
}

CtlRequestSpec _buildModelStart(CtlCommandContext context) =>
    CtlRequestSpec.post(_gptSovitsPath(context, 'start'));

CtlRequestSpec _buildModelStop(CtlCommandContext context) =>
    CtlRequestSpec.post(_gptSovitsPath(context, 'stop'));

CtlRequestSpec _buildModelLink(CtlCommandContext context) =>
    CtlRequestSpec.post(
      '/api/admin/models/gpt-sovits/local/link',
      body: <String, Object?>{
        'dir': ctlAbsolutePath(context.positional(0, '目录')),
      },
    );

String _mb(Object? bytes) =>
    bytes is num ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB' : '-';

/// 一行模型状态的人读摘要。
String _modelState(Map<Object?, Object?> m) {
  if (m['supported'] == false) return '本平台不支持';
  final Object? download = m['download'];
  if (download is Map) {
    final Object? state = download['state'];
    if (state == 'installingPython' || state == 'installingPackages') {
      final Object? last = download['lastLog'];
      return '$state${last == null ? '' : ' · $last'}';
    }
    if (state == 'downloading' ||
        state == 'downloadingUv' ||
        state == 'downloadingSource' ||
        state == 'downloadingModel' ||
        state == 'cancelling' ||
        state == 'listing' ||
        state == 'extracting' ||
        state == 'configuring') {
      final String extracted = state == 'extracting'
          ? ' · 已解压 ${download['extractedEntries']} 项'
          : '';
      return '$state ${_mb(download['receivedBytes'])} / '
          '${_mb(download['totalBytes'])}$extracted';
    }
    if (state == 'failed') {
      return '下载失败：${download['error'] ?? download['failure'] ?? ''}';
    }
  }
  if (m['ready'] == true) {
    return '已就绪${m['diskBytes'] == null ? '' : '（${_mb(m['diskBytes'])}）'}';
  }
  final Object? obtained = m['obtainedBytes'];
  if (obtained is num && obtained > 0) {
    return '下了一部分 ${_mb(obtained)} / ${_mb(m['totalBytes'])}';
  }
  return m['totalBytes'] == null ? '未安装' : '未下载（需 ${_mb(m['totalBytes'])}）';
}

String _renderModelsLs(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
  void add(Object? m) {
    if (m is! Map) return;
    final Object? languages = m['languages'];
    rows.add(<String, Object?>{
      'kind': m['kind'],
      'id': m['id'] ?? '',
      'name': m['name'] ?? (languages is List ? languages.join(',') : ''),
      'state': _modelState(m),
    });
  }

  final Object? asr = data['asr'];
  if (asr is Map) {
    for (final Object? pack in asr['packs'] as List<Object?>? ?? <Object?>[]) {
      add(pack);
    }
  }
  final Object? ocr = data['ocr'];
  if (ocr is Map) {
    for (final Object? model
        in ocr['models'] as List<Object?>? ?? <Object?>[]) {
      add(model);
    }
  }
  add(data['gptSovits']);
  add(data['irodori']);
  return renderCtlTable(rows, const <(String, String)>[
    ('类别', 'kind'),
    ('id', 'id'),
    ('名称', 'name'),
    ('状态', 'state'),
  ]);
}

String _renderModel(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final StringBuffer out = StringBuffer()
    ..write('${data['kind']} ${data['id'] ?? ''} ${data['name'] ?? ''}'.trim())
    ..write('：${_modelState(data)}');
  if (data['started'] == true) out.write('\n已开始下载（models status 查进度）');
  if (data['alreadyReady'] == true) out.write('\n已经下好了，没有重复下载');
  if (data['detached'] == true) out.write('\n已移除接入（用户的文件没动）');
  final Object? gpuError = data['gpuRuntimeError'];
  if (gpuError != null) {
    out.write('\nGPU 加速环境没装上（模型可用，先按 CPU 转录）：$gpuError');
  }
  final Object? freed = data['freedBytes'];
  if (freed is num) out.write('\n释放 ${_mb(freed)}');
  if (data.containsKey('filesDeleted')) {
    out.write(
      data['filesDeleted'] == true ? '\n已删除整合包文件' : '\n已移除（用户自己的整合包文件没动）',
    );
  }
  if (data['endpoint'] != null && data['ready'] == true) {
    out.write('\n服务地址 ${data['endpoint']} · ${data['server']}');
  }
  return out.toString();
}

// ── voice ───────────────────────────────────────────────────────────────────

String _voicePath(String ref) =>
    '/api/admin/voices/${Uri.encodeComponent(ref)}';

void _configureVoiceFields(ArgParser parser) {
  parser
    ..addOption('name', help: '显示名')
    ..addMultiOption('param', abbr: 'p', valueHelp: 'k=v', help: '引擎参数（可重复）')
    ..addOption('secret-stdin', valueHelp: 'KEY', help: '从标准输入读这个凭据参数')
    ..addMultiOption(
      'secret-from-env',
      valueHelp: 'KEY=VAR',
      help: '从环境变量读凭据参数（可重复）',
    );
}

void _configureVoiceAdd(ArgParser parser) {
  _configureVoiceFields(parser);
  parser.addFlag('use', negatable: false, help: '添加后设为默认');
}

void _configureVoiceSet(ArgParser parser) {
  _configureVoiceFields(parser);
  parser.addFlag('regenerate', negatable: false, help: '重新生成（旧缓存作废）');
}

Map<String, String> _keyValues(List<String> raw, String flag) {
  final Map<String, String> out = <String, String>{};
  for (final String item in raw) {
    final int eq = item.indexOf('=');
    if (eq <= 0) throw CtlUsageError('$flag 必须写成 key=value，收到「$item」');
    out[item.substring(0, eq).trim()] = item.substring(eq + 1);
  }
  return out;
}

Map<String, Object?> _voiceFields(CtlCommandContext context) {
  final Map<String, String> params = _keyValues(
    context.multiOption('param'),
    '--param',
  );
  final Map<String, String> secrets = <String, String>{};
  String? source;
  for (final MapEntry<String, String> e in _keyValues(
    context.multiOption('secret-from-env'),
    '--secret-from-env',
  ).entries) {
    final String? value = Platform.environment[e.value];
    if (value == null) throw CtlUsageError('环境变量 ${e.value} 未设置');
    secrets[e.key] = value;
    source = 'env';
  }
  final String? stdinKey = context.option('secret-stdin');
  if (stdinKey != null) {
    if (source != null) {
      throw const CtlUsageError('--secret-stdin 与 --secret-from-env 只能用一种');
    }
    secrets[stdinKey] = readCtlSecretFromStdin();
    source = 'stdin';
  }
  final String? name = context.option('name');
  return <String, Object?>{
    if (name != null) 'name': name,
    if (params.isNotEmpty) 'params': params,
    if (secrets.isNotEmpty) 'secrets': secrets,
    if (source != null) 'secretSource': source,
  };
}

CtlRequestSpec _buildVoiceLs(CtlCommandContext context) =>
    const CtlRequestSpec.get('/api/admin/voices');

CtlRequestSpec _buildVoiceEngines(CtlCommandContext context) =>
    const CtlRequestSpec.get('/api/admin/voices/engines');

CtlRequestSpec _buildVoiceAdd(CtlCommandContext context) => CtlRequestSpec.post(
  '/api/admin/voices',
  body: <String, Object?>{
    'engine': context.positional(0, '引擎'),
    ..._voiceFields(context),
    if (context.flag('use')) 'use': true,
  },
);

CtlRequestSpec _buildVoiceSet(CtlCommandContext context) {
  final String ref = context.positional(0, 'id|名字');
  final Map<String, Object?> body = <String, Object?>{
    ..._voiceFields(context),
    if (context.flag('regenerate')) 'regenerate': true,
  };
  if (body.isEmpty) throw const CtlUsageError('没有要改的字段');
  return CtlRequestSpec.put(_voicePath(ref), body: body);
}

CtlRequestSpec _buildVoiceUse(CtlCommandContext context) => CtlRequestSpec.post(
  '${_voicePath(context.positional(0, 'id|名字'))}/activate',
);

CtlRequestSpec _buildVoiceRm(CtlCommandContext context) {
  final String ref = context.positional(0, 'id|名字');
  _requireYes(context, '删除声音');
  return CtlRequestSpec.delete(
    _voicePath(ref),
    query: const <String, String>{'confirm': 'true'},
  );
}

CtlRequestSpec _buildVoiceSpeed(CtlCommandContext context) {
  final String? raw = context.optionalPositional(0);
  if (raw == null) return const CtlRequestSpec.get('/api/admin/voices');
  final double? speed = double.tryParse(raw);
  if (speed == null) throw CtlUsageError('倍速必须是数字，收到「$raw」');
  return CtlRequestSpec.put(
    '/api/admin/tts/speed',
    body: <String, Object?>{'speed': speed},
  );
}

String _renderVoiceSpeed(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  return '朗读语速：${data['speed']}x';
}

CtlRequestSpec _buildVoiceVoices(CtlCommandContext context) =>
    CtlRequestSpec.get('${_voicePath(context.positional(0, 'id|名字'))}/voices');

String _renderVoiceLs(Object? data) =>
    renderCtlTable(data, const <(String, String)>[
      ('id', 'id'),
      ('名称', 'name'),
      ('引擎', 'engine'),
      ('默认', 'active'),
      ('缺参数', 'problems'),
    ], listKey: 'voices');

String _renderVoiceEngines(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[
    for (final Object? e in data['engines'] as List<Object?>? ?? <Object?>[])
      if (e is Map)
        <String, Object?>{
          'id': e['id'],
          'name': e['name'],
          'category': e['category'],
          'params': <String>[
            for (final Object? spec
                in e['params'] as List<Object?>? ?? <Object?>[])
              if (spec is Map)
                '${spec['key']}${spec['required'] == true ? '*' : ''}'
                    '${spec['kind'] == 'secret' ? '(凭据)' : ''}',
          ],
        },
  ];
  return renderCtlTable(rows, const <(String, String)>[
    ('引擎', 'id'),
    ('名称', 'name'),
    ('类别', 'category'),
    ('参数（* 必填）', 'params'),
  ]);
}

String _renderVoice(Object? data) {
  if (data is! Map) return renderCtlJson(data);
  final Object? voice = data['voice'];
  if (voice is! Map) return renderCtlJson(data);
  final Object? problems = voice['problems'];
  return '${data['action']}：${voice['id']} ${voice['name']}（${voice['engine']}）'
      '${voice['active'] == true ? ' · 默认' : ''}'
      '${problems is List && problems.isNotEmpty ? '\n  还缺参数：${problems.join(', ')}' : ''}';
}

String _renderProviderVoices(Object? data) =>
    renderCtlTable(data, const <(String, String)>[
      ('音色 id', 'id'),
      ('名称', 'name'),
      ('语言', 'locale'),
      ('性别', 'gender'),
    ], listKey: 'voices');
