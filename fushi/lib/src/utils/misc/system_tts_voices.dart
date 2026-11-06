/// 系统语音的**引擎 / 声音清单**：各平台原生输出 → 统一的 [SystemTtsEngine] /
/// [TtsVoice]，以及声音 id 的编码。全是纯函数，平台差异只在「原始输出长什么样」。
///
/// 声音 id 是写进声音预设（`voice` 参数）的持久值，合成时原样交回平台：
/// - Android：`android.speech.tts.Voice.getName()`（如 `ja-jp-x-htm-local`），按引擎区分；
/// - iOS：`AVSpeechSynthesisVoice.identifier`；
/// - Windows：`onecore:<注册表 token 名>`（WinRT `Windows.Media.SpeechSynthesis`，含
///   「设置 › 时间和语言 › 语音」里装的全部 OneCore 声音）或 `sapi:<声音名>`（SAPI 5，
///   第三方 SAPI 声音只在这里）；
/// - macOS：`say -v ?` 列出的声音名；
/// - Linux：`openjtalk:<.htsvoice 路径>` 或 `espeak:<espeak-ng 语言名>`。
library;

import 'package:fushi_engine/tts/tts_types.dart';

/// 一个系统语音引擎（目前只有 Android 能在 app 里选引擎）。
class SystemTtsEngine {
  const SystemTtsEngine({
    required this.id,
    required this.label,
    this.isDefault = false,
  });

  /// 引擎包名（`com.google.android.tts`）。
  final String id;

  /// 引擎显示名（「Google 语音识别和语音合成」）。
  final String label;

  /// 是不是用户在系统设置里选的默认引擎。
  final bool isDefault;
}

/// BCP-47 化：`ja_JP` → `ja-JP`。
String _bcp47(String raw) => raw.trim().replaceAll('_', '-');

Map<Object?, Object?>? _asMap(Object? raw) =>
    raw is Map ? Map<Object?, Object?>.from(raw) : null;

String _string(Map<Object?, Object?> m, String key) {
  final Object? v = m[key];
  return v is String ? v : '';
}

/// Android 原生 `getEngines` 的返回：`[{name, label, isDefault}]`。默认引擎排第一。
List<SystemTtsEngine> parseAndroidTtsEngines(Object? raw) {
  final List<SystemTtsEngine> engines = <SystemTtsEngine>[
    if (raw is List)
      for (final Object? item in raw)
        if (_asMap(item) case final Map<Object?, Object?> m
            when _string(m, 'name').isNotEmpty)
          SystemTtsEngine(
            id: _string(m, 'name'),
            label: _string(m, 'label').isEmpty
                ? _string(m, 'name')
                : _string(m, 'label'),
            isDefault: m['isDefault'] == true,
          ),
  ];
  engines.sort((SystemTtsEngine a, SystemTtsEngine b) {
    if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
    return a.label.compareTo(b.label);
  });
  return engines;
}

/// Android 原生 `getVoices` 的返回：`[{name, locale, network}]`。
List<TtsVoice> parseAndroidTtsVoices(Object? raw) => <TtsVoice>[
  if (raw is List)
    for (final Object? item in raw)
      if (_asMap(item) case final Map<Object?, Object?> m
          when _string(m, 'name').isNotEmpty)
        TtsVoice(
          id: _string(m, 'name'),
          displayName: _string(m, 'name'),
          locale: _bcp47(_string(m, 'locale')),
          // 需要联网的声音标出来：离线时它会合成失败。
          gender: m['network'] == true ? 'network' : null,
        ),
];

/// iOS 原生 `getVoices` 的返回：`[{id, name, locale, quality}]`。
List<TtsVoice> parseAppleSpeechVoices(Object? raw) => <TtsVoice>[
  if (raw is List)
    for (final Object? item in raw)
      if (_asMap(item) case final Map<Object?, Object?> m
          when _string(m, 'id').isNotEmpty)
        TtsVoice(
          id: _string(m, 'id'),
          displayName: _string(m, 'name').isEmpty
              ? _string(m, 'id')
              : _string(m, 'name'),
          locale: _bcp47(_string(m, 'locale')),
          gender: _string(m, 'quality').isEmpty ? null : _string(m, 'quality'),
        ),
];

/// macOS `say -v ?` 的一行：`<声音名>  <语言>_<地区>  # 示例`。声音名可能带空格与括号
/// （`Good News`、`Kyoko (日语（日本）)`），所以按「名字 + 至少两个空格 + 语言标签」切。
final RegExp _sayVoiceLine = RegExp(
  r'^(.+?)\s{2,}([A-Za-z]{2,3}(?:[_-]\S+)?)\s+#',
);

/// macOS `say -v ?` → 声音清单。同名的行（同一声音的不同质量档）只留第一行：`say -v`
/// 只认名字，列两次用户也分不出。
List<TtsVoice> parseMacOSSayVoices(String sayVoiceList) {
  final Set<String> seen = <String>{};
  return <TtsVoice>[
    for (final String line in sayVoiceList.split('\n'))
      if (_sayVoiceLine.firstMatch(line) case final RegExpMatch m
          when seen.add(m.group(1)!.trim()))
        TtsVoice(
          id: m.group(1)!.trim(),
          displayName: m.group(1)!.trim(),
          locale: _bcp47(m.group(2)!),
        ),
  ];
}

/// Windows 声音 id 的两个前缀。
const String kWindowsOneCoreVoicePrefix = 'onecore:';
const String kWindowsSapiVoicePrefix = 'sapi:';

/// Windows 声音 id 拆成（引擎, 键）；不认识的前缀返回 null。
({String kind, String key})? parseWindowsVoiceId(String id) {
  for (final (String prefix, String kind) in const <(String, String)>[
    (kWindowsOneCoreVoicePrefix, 'onecore'),
    (kWindowsSapiVoicePrefix, 'sapi'),
  ]) {
    if (id.startsWith(prefix) && id.length > prefix.length) {
      return (kind: kind, key: id.substring(prefix.length));
    }
  }
  return null;
}

/// Windows 工作进程 `voices` 的返回（`[{kind: winrt|sapi, id, name, lang, gender}]`）
/// → 合并后的声音清单。
///
/// - OneCore（WinRT）声音的 id 是完整注册表路径
///   （`HKEY_LOCAL_MACHINE\…\Tokens\MSTTS_V110_jaJP_HarukaM`），只取最后一段 token 名，
///   短且跨 `HKLM` / `HKCU` 安装位置稳定；
/// - SAPI 5 声音名与某个 OneCore 声音的显示名完全相同时（用户把 OneCore 声音导进了
///   SAPI 注册表）只留 OneCore 那条，同一个声音不列两次；名字不同的（`Microsoft Haruka
///   Desktop` 与 `Microsoft Haruka` 是两套不同的声音数据）都留着；
/// - 第三方 SAPI 声音只在 SAPI 一侧，原样保留。
List<TtsVoice> mergeWindowsSpeechVoices(Object? raw) {
  final List<TtsVoice> oneCore = <TtsVoice>[];
  final List<TtsVoice> sapi = <TtsVoice>[];
  if (raw is! List) return oneCore;
  for (final Object? item in raw) {
    final Map<Object?, Object?>? m = _asMap(item);
    if (m == null) continue;
    final String id = _string(m, 'id').trim();
    final String name = _string(m, 'name').trim();
    if (id.isEmpty) continue;
    final String gender = _string(m, 'gender');
    final String? genderOrNull = gender.isEmpty || gender == 'NotSet'
        ? null
        : gender;
    switch (_string(m, 'kind')) {
      case 'winrt':
        final String token = id.split(r'\').last;
        oneCore.add(
          TtsVoice(
            id: '$kWindowsOneCoreVoicePrefix$token',
            displayName: name.isEmpty ? token : name,
            locale: _bcp47(_string(m, 'lang')),
            gender: genderOrNull,
          ),
        );
      case 'sapi':
        sapi.add(
          TtsVoice(
            id: '$kWindowsSapiVoicePrefix$id',
            displayName: name.isEmpty ? id : name,
            locale: _bcp47(_string(m, 'lang')),
            gender: genderOrNull,
          ),
        );
    }
  }
  final Set<String> oneCoreNames = <String>{
    for (final TtsVoice v in oneCore) v.displayName.toLowerCase(),
  };
  return <TtsVoice>[
    ...oneCore,
    for (final TtsVoice v in sapi)
      if (!oneCoreNames.contains(v.displayName.toLowerCase())) v,
  ];
}

/// Linux 声音 id 的两个前缀。
const String kLinuxOpenJTalkVoicePrefix = 'openjtalk:';
const String kLinuxEspeakVoicePrefix = 'espeak:';

/// Open JTalk 的 `.htsvoice` 文件 → 声音（都是日语）。
List<TtsVoice> openJTalkVoicesFromFiles(Iterable<String> paths) {
  final List<String> sorted = paths.toList()..sort();
  return <TtsVoice>[
    for (final String path in sorted)
      TtsVoice(
        id: '$kLinuxOpenJTalkVoicePrefix$path',
        displayName:
            'Open JTalk · ${path.split('/').last.replaceFirst(RegExp(r'\.htsvoice$'), '')}',
        locale: 'ja-JP',
      ),
  ];
}

/// `espeak-ng --voices` 的一行：`Pty Language Age/Gender VoiceName File [Other]`。
final RegExp _espeakVoiceLine = RegExp(
  r'^\s*\d+\s+(\S+)\s+\S+/([MF-])\s+(\S+)\s+\S+',
);

/// `espeak-ng --voices` → 声音清单（同一语言名只留一条：`-v <语言名>` 只认名字）。
List<TtsVoice> parseEspeakNgVoices(String output) {
  final Set<String> seen = <String>{};
  return <TtsVoice>[
    for (final String line in output.split('\n'))
      if (_espeakVoiceLine.firstMatch(line) case final RegExpMatch m
          when seen.add(m.group(1)!))
        TtsVoice(
          id: '$kLinuxEspeakVoicePrefix${m.group(1)!}',
          displayName: 'espeak-ng · ${m.group(3)!.replaceAll('_', ' ')}',
          locale: m.group(1)!,
          gender: switch (m.group(2)) {
            'M' => 'Male',
            'F' => 'Female',
            _ => null,
          },
        ),
  ];
}
