/// 「用哪个语音模型」的真相源：可选包的组装、用户手动接入的本地模型、每种语言
/// 选中了谁。
///
/// **为什么需要这一层**：`fushi_asr_core` 里模型是按语言查的——
/// `asrModelPackFor(language)` 取「当前注册表里服务该语言的第一个包」，而内置表
/// 每种语言恰好一个包。所以抽包后的默认行为是「语言定死模型」，用户没有选择权，
/// 也没有入口接自己的 sherpa-onnx 导出。
///
/// 包里已经把「当前认得哪些包」做成了可替换的一层（[AsrModelRegistry]），本文件
/// 就是本仓的那份组装：
///
/// ```text
/// 内置 kAsrModelPacks（omnilingual 换成扩语言版）  ─┐
/// 用户手动接入的本地模型包（catalog.customPacks）  ─┼→ 按 choices 置顶 → 注册表
/// 每语言的选择 catalog.choices                     ─┘
/// ```
///
/// **两条不变式**，改这里前先读：
///
/// 1. **默认不能变**。内置 8 个 transducer 包必须仍排在扩语言 Omnilingual 之前，
///    没做过选择的用户 `asrModelPackFor(ja)` 必须还是 ReazonSpeech。所以扩语言
///    Omnilingual 沿用**原位置**（清单末尾）而不是插到前面。
/// 2. **选择不能靠排序表达**。Omnilingual 一个包服务 9+ 种语言，把它整个提到最前
///    会顺带改掉其余每一种语言的默认——「给日语选 Omnilingual」不能是
///    「把 Omnilingual 排到第一」。所以选中的包会被复制成一份**只声明那一种语言**
///    的窄包置顶（`_withLanguages`）：`packForLanguage(ja)` 命中它，`packForLanguage(en)`
///    因为它不含 en 而继续落到英语包。窄包与原包**同 id**，所以模型目录
///    （`asr_models/<id>`）与任务哈希都指向同一处，选来选去不会重复下载。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:fushi_asr_core/asr_core.dart';

/// 目录文件名：数据根下 `asr_models.json`。
///
/// 与包里 [AsrModelRegistry.resolve] 探测的 `models.json` **不同名**，故意的：
/// 那份是「宿主之外的人手写的清单」（CLI 的 `--models`），这份是本 app 自己读写
/// 的状态，两者混用会让「用户手写的清单被 app 覆盖掉」。
const String kAsrModelCatalogFileName = 'asr_models.json';

/// 用户手动接入本地模型时，本仓给包 id 加的前缀。
///
/// 前缀而不是标志字段：id 决定磁盘目录与任务哈希，前缀让「这是自带的」在目录名
/// 上就看得见，也保证不会和上游将来新增的内置 id 撞车。
const String kAsrCustomPackIdPrefix = 'custom-';

/// 本地模型接入的失败原因。UI 据此给具体的话，不吐英文异常。
enum AsrLocalModelProblem {
  /// 目录里没有 `tokens.txt`。
  missingTokens,

  /// 既没认出 transducer 三件套，也没认出 CTC 模型文件。
  missingModel,

  /// 认出了 transducer 的一部分（例如只有 encoder），缺 decoder / joiner。
  incompleteTransducer,
}

/// 本地模型目录扫描的结果：要么一个可用的包，要么一条具体的问题。
sealed class AsrLocalModelScan {
  const AsrLocalModelScan();
}

class AsrLocalModelFound extends AsrLocalModelScan {
  const AsrLocalModelFound(this.pack);

  final AsrModelPack pack;
}

class AsrLocalModelRejected extends AsrLocalModelScan {
  const AsrLocalModelRejected(this.problem);

  final AsrLocalModelProblem problem;
}

/// 模型对当前平台的适配度。只有三档——再细分就得替用户猜他的机器，而我们手上
/// 只有「包多大」「fp32 要不要显存门槛」这两个真实可判的事实。
enum AsrModelFit {
  /// 小包，手机和桌面都跑得动。
  light,

  /// 大包，桌面（尤其有独显）合适。
  desktop,

  /// 大包 + 当前是移动端：能跑，但会很慢，得说清楚。
  heavyOnMobile,
}

/// 「大包」门槛：int8 全套超过 700 MB。
///
/// 取值依据是内置表本身的分布——8 个 transducer 包 int8 全套都在 200 MB 上下，
/// Omnilingual 1B 的 int8 单模型就 1.03 GB。门槛落在这条缝里，判的是模型的量级
/// 而不是某个 id，将来新增包不用回来改这里。
const int kAsrHeavyModelInt8Bytes = 700 * 1024 * 1024;

/// 纯函数：这个包在当前平台上的适配度。
///
/// [mobile] 由调用方给（`Platform.isAndroid || Platform.isIOS`，测试直接传），
/// 本函数不碰平台单例。
AsrModelFit asrModelFitFor(AsrModelPack pack, {required bool mobile}) {
  final bool heavy = pack.fp32GpuMinBudgetBytes != null ||
      pack.totalBytes(AsrEncoderVariant.int8) > kAsrHeavyModelInt8Bytes;
  if (!heavy) return AsrModelFit.light;
  return mobile ? AsrModelFit.heavyOnMobile : AsrModelFit.desktop;
}

/// 本仓的基础包清单 = 内置清单，但 Omnilingual 换成「多认几种语言」的版本。
///
/// Omnilingual ASR 1B 本身就是 1600+ 语言的模型，内置表只把它登记给了没有专用
/// transducer 包的那 9 种语言。给前 8 种也登记上，日语/英语/中文等就有了第二个
/// 可选模型——**位置不变**（仍在清单末尾），所以这 8 种语言的默认包一个都没变。
///
/// 同 id 复用同一个模型目录：给日语选它不会重下那 4 GB。
List<AsrModelPack> fushiAsrBasePacks() {
  return <AsrModelPack>[
    for (final AsrModelPack pack in kAsrModelPacks)
      if (pack.id == kAsrOmnilingualPack.id)
        _withLanguages(pack, <AsrLanguage>[
          ...pack.languages,
          for (final AsrLanguage language in AsrLanguage.values)
            if (!pack.languages.contains(language)) language,
        ])
      else
        pack,
  ];
}

/// 这个包的模型文件是不是就在用户自己的文件夹里；是则返回那个文件夹。
///
/// 判据是 [AsrModelPack.sourceUrl] 的 scheme——内置包那里是模型主页（https），
/// 手动接入的包是 `Uri.file(用户选的文件夹)`。不看 id 前缀：少一个要两处同步的特例。
///
/// **为什么需要它**：包里的 `AsrModelStore.open()` 把目录钉死成
/// `<数据根>/asr_models/<pack.id>`，就绪判定与下载都只在那个目录里发生，
/// [AsrModelFile.url] 只有下载时才读。所以「文件留在原处」不是自动成立的——
/// 宿主必须把 store 的目录改写成用户那个文件夹（见 `asr_host.dart` 的
/// `openAsrModelStore`），否则本地模型恒判未就绪，弹层会去下载一个 `file:` URL。
Directory? localAsrModelDirectory(AsrModelPack pack) {
  final Uri? uri = Uri.tryParse(pack.sourceUrl);
  if (uri == null || !uri.isScheme('file')) return null;
  try {
    return Directory(uri.toFilePath());
  } on UnsupportedError {
    return null;
  }
}

/// 用户的模型目录状态（手动接入的包 + 每语言的选择）。不可变，改动返回新实例。
class AsrModelCatalog {
  const AsrModelCatalog({
    this.customPacks = const <AsrModelPack>[],
    this.choices = const <String, String>{},
  });

  /// 用户手动接入的本地模型包。
  final List<AsrModelPack> customPacks;

  /// 语言标签（[AsrLanguage.tag]）→ 选中的包 id。没有条目 = 用默认。
  final Map<String, String> choices;

  static const AsrModelCatalog empty = AsrModelCatalog();

  bool get isEmpty => customPacks.isEmpty && choices.isEmpty;

  /// 解析失败一律抛 [FormatException]（包里 [AsrModelPack.fromJson] 的纪律）：
  /// 自带模型配错了必须当场报清楚，静默跳过会让用户对着「怎么没有它」猜半天。
  factory AsrModelCatalog.fromJson(Object? json) {
    if (json == null) return AsrModelCatalog.empty;
    if (json is! Map<String, Object?>) {
      throw FormatException('模型目录顶层必须是对象，实得 ${json.runtimeType}');
    }
    final Object? rawPacks = json['packs'];
    final Object? rawChoices = json['choices'];
    if (rawPacks != null && rawPacks is! List) {
      throw const FormatException('字段 packs 必须是数组');
    }
    if (rawChoices != null && rawChoices is! Map) {
      throw const FormatException('字段 choices 必须是对象');
    }
    return AsrModelCatalog(
      customPacks: <AsrModelPack>[
        for (final Object? entry
            in (rawPacks as List<Object?>? ?? const <Object?>[]))
          AsrModelPack.fromJson(entry),
      ],
      choices: <String, String>{
        for (final MapEntry<Object?, Object?> e
            in (rawChoices as Map<Object?, Object?>? ??
                    const <Object?, Object?>{})
                .entries)
          if (e.key is String && e.value is String)
            e.key! as String: e.value! as String,
      },
    );
  }

  Object toJson() => <String, Object?>{
        'packs': <Object>[
          for (final AsrModelPack pack in customPacks) pack.toJson()
        ],
        'choices': choices,
      };

  /// 选中某语言用哪个包。[packId] 为 null 表示回到默认（删掉这条选择）。
  AsrModelCatalog withChoice(AsrLanguage language, String? packId) {
    final Map<String, String> next = Map<String, String>.of(choices);
    if (packId == null) {
      next.remove(language.tag);
    } else {
      next[language.tag] = packId;
    }
    return AsrModelCatalog(customPacks: customPacks, choices: next);
  }

  /// 接入一个手动指定的本地包，必要时改 id 去重，返回新目录与**实际入库的包**。
  ///
  /// id 由显示名派生（`custom-<slug>`），两个不同文件夹很容易撞上同一个 id
  /// （两次都没改名，或两个不同盘上各有一个叫 model 的文件夹）。撞上而直接按 id
  /// 覆盖的话，先前那份连同指向它的选择会被悄悄改指到新目录，两者还共用同一个
  /// `asr_models/<id>` 磁盘目录。所以：同 id **同目录**视为重新接入（覆盖），
  /// 同 id **不同目录**则加数字后缀。
  ({AsrModelCatalog catalog, AsrModelPack pack}) withLocalPack(
    AsrModelPack pack,
  ) {
    String id = pack.id;
    for (int n = 2;; n++) {
      final AsrModelPack? existing = _packById(customPacks, id);
      if (existing == null || existing.sourceUrl == pack.sourceUrl) break;
      id = '${pack.id}-$n';
    }
    final AsrModelPack effective = id == pack.id ? pack : _withId(pack, id);
    return (catalog: withCustomPack(effective), pack: effective);
  }

  /// 接入（或按 id 覆盖）一个自带包。
  AsrModelCatalog withCustomPack(AsrModelPack pack) => AsrModelCatalog(
        customPacks: <AsrModelPack>[
          for (final AsrModelPack existing in customPacks)
            if (existing.id != pack.id) existing,
          pack,
        ],
        choices: choices,
      );

  /// 移除一个自带包，并把指向它的选择一起清掉——留着会让那些语言在下一次组装时
  /// 找不到包，退化成「选择静默失效」这种查不出来的状态。
  AsrModelCatalog withoutCustomPack(String packId) => AsrModelCatalog(
        customPacks: <AsrModelPack>[
          for (final AsrModelPack existing in customPacks)
            if (existing.id != packId) existing,
        ],
        choices: <String, String>{
          for (final MapEntry<String, String> e in choices.entries)
            if (e.value != packId) e.key: e.value,
        },
      );
}

/// 纯函数：目录 → 注册表。规则见文件头两条不变式。
AsrModelRegistry buildAsrModelRegistry(AsrModelCatalog catalog) {
  // 1) 基础表：内置（omnilingual 扩语言）；同 id 的自带包**就地**覆盖内置那份，
  //    位置不动——覆盖是覆盖，不该顺带改变谁是默认。
  final Map<String, AsrModelPack> custom = <String, AsrModelPack>{
    for (final AsrModelPack pack in catalog.customPacks) pack.id: pack,
  };
  final List<AsrModelPack> ordered = <AsrModelPack>[
    for (final AsrModelPack pack in fushiAsrBasePacks())
      custom[pack.id] ?? pack,
  ];
  // 2) 没撞 id 的自带包追加在末尾：接进来不等于成为默认，成为默认要靠下面的选择。
  final Set<String> seen = ordered.map((AsrModelPack p) => p.id).toSet();
  for (final AsrModelPack pack in catalog.customPacks) {
    if (seen.add(pack.id)) ordered.add(pack);
  }
  // 3) 每条选择生成一份只声明那一种语言的窄包置顶。
  final List<AsrModelPack> narrowed = <AsrModelPack>[];
  for (final MapEntry<String, String> entry in catalog.choices.entries) {
    final AsrModelPack? pack = _packById(ordered, entry.value);
    if (pack == null) continue;
    final AsrLanguage? language = _languageOf(pack, entry.key);
    // 选中的包不服务这门语言（用户换了自带包的语言列表）：忽略这条选择，让它
    // 回落到默认，而不是造一个跑不起来的窄包。
    if (language == null) continue;
    narrowed.add(_withLanguages(pack, <AsrLanguage>[language]));
  }
  return AsrModelRegistry(<AsrModelPack>[...narrowed, ...ordered]);
}

/// 纯函数：这门语言能选哪些包（按注册表展示顺序，同 id 只留一份）。
///
/// 结果第一项就是当前生效的那个（[asrModelPackFor] 的判据同样是「第一个服务它的
/// 包」），所以 UI 不需要另算「当前选中」。
List<AsrModelPack> asrModelChoicesFor(
  AsrLanguage language,
  AsrModelRegistry registry,
) {
  final List<AsrModelPack> out = <AsrModelPack>[];
  final Set<String> seen = <String>{};
  for (final AsrModelPack pack in registry.packs) {
    if (!pack.languages.contains(language)) continue;
    if (!seen.add(pack.id)) continue;
    out.add(pack);
  }
  return out;
}

/// 扫描用户选的本地模型目录，认出一个可直接跑的包。
///
/// 认的是 sherpa-onnx / icefall 导出的惯例文件名（就是内置 8 个包的文件名形态）：
/// `encoder-*.onnx` / `decoder-*.onnx` / `joiner-*.onnx` + `tokens.txt`，
/// 带 `.int8.` 的算 int8 变体；只有单个 `model.onnx` / `model.int8.onnx` 时按 CTC 认。
///
/// **只在目录里认，不复制不下载**：包里的就绪判据是「文件存在且非空」
/// （`isAsrModelFileReady`），所以指到哪就跑哪，url 填 `file:` 只为满足清单形状——
/// 真需要下载时（文件被删）下载器会失败并报出这个 url，比静默当成缺文件强。
///
/// 缺 `silero_vad.onnx` 不算问题：清单里补上内置那份的直链（643 KB），
/// 第一次跑会把它下下来。
AsrLocalModelScan scanLocalAsrModelDirectory({
  required Directory dir,
  required String displayName,
  required List<AsrLanguage> languages,
  String? id,
  int decoderContextSize = 2,
  AsrIndexType indexType = AsrIndexType.int64,
  String blankToken = '<blk>',
}) {
  final List<File> files = <File>[
    for (final FileSystemEntity entity in dir.listSync())
      if (entity is File) entity,
  ];
  File? pick(bool Function(String name) test) {
    for (final File file in files) {
      if (test(p.basename(file.path).toLowerCase())) return file;
    }
    return null;
  }

  bool isOnnx(String name) => name.endsWith('.onnx');
  bool int8(String name) => name.contains('.int8.') || name.contains('-int8.');

  final File? tokens = pick((String n) => n == 'tokens.txt');
  if (tokens == null) {
    return const AsrLocalModelRejected(AsrLocalModelProblem.missingTokens);
  }
  final File? vad = pick((String n) => n.contains('silero') && isOnnx(n));

  File? role(String stem, {required bool wantInt8}) => pick(
        (String n) => isOnnx(n) && n.startsWith(stem) && int8(n) == wantInt8,
      );

  final File? encoderFp32 = role('encoder', wantInt8: false);
  final File? encoderInt8 = role('encoder', wantInt8: true);
  final File? decoderFp32 = role('decoder', wantInt8: false);
  final File? decoderInt8 = role('decoder', wantInt8: true);
  final File? joinerFp32 = role('joiner', wantInt8: false);
  final File? joinerInt8 = role('joiner', wantInt8: true);

  final String packId = id ??
      '$kAsrCustomPackIdPrefix${_slug(displayName.isEmpty ? p.basename(dir.path) : displayName)}';
  final String name = displayName.isEmpty ? p.basename(dir.path) : displayName;

  AsrModelFile entry(File file, AsrModelRole modelRole) => AsrModelFile(
        fileName: p.basename(file.path),
        url: Uri.file(file.path).toString(),
        expectedBytes: file.existsSync() ? file.lengthSync() : 0,
        role: modelRole,
      );

  // 判据是「认出**任意一个** transducer 角色」而不是「认出 encoder」：只有
  // decoder / joiner 的目录（下载中断、导出脚本没写出 encoder）若落到下面的 CTC
  // 分支，`decoder-*.onnx` 会被当成 CTC 模型收下，用户拿到一个「加成功了」但必定
  // 跑不通的包。正确答案是 incompleteTransducer。
  final bool looksTransducer = encoderFp32 != null ||
      encoderInt8 != null ||
      decoderFp32 != null ||
      decoderInt8 != null ||
      joinerFp32 != null ||
      joinerInt8 != null;
  if (looksTransducer) {
    // transducer：两个变体的角色都必须齐（`filesFor()` 逐角色 firstWhere，缺一个
    // 就在 plan() 里抛 StateError 炸掉整个弹层）。上游对「没给 int8 decoder 的
    // 包」用的就是这条：缺的一侧指向另一侧的同一个文件。
    final File? decoder = decoderFp32 ?? decoderInt8;
    final File? joiner = joinerFp32 ?? joinerInt8;
    final File? encoder = encoderFp32 ?? encoderInt8;
    if (encoder == null || decoder == null || joiner == null) {
      return const AsrLocalModelRejected(
        AsrLocalModelProblem.incompleteTransducer,
      );
    }
    return AsrLocalModelFound(
      AsrModelPack(
        languages: languages,
        id: packId,
        displayName: name,
        sourceUrl: Uri.file(dir.path).toString(),
        decoderContextSize: decoderContextSize,
        indexType: indexType,
        blankToken: blankToken,
        files: <AsrModelFile>[
          entry(encoderFp32 ?? encoder, AsrModelRole.encoderFp32),
          entry(encoderInt8 ?? encoder, AsrModelRole.encoderInt8),
          entry(decoderFp32 ?? decoder, AsrModelRole.decoderFp32),
          entry(decoderInt8 ?? decoder, AsrModelRole.decoderInt8),
          entry(joinerFp32 ?? joiner, AsrModelRole.joinerFp32),
          entry(joinerInt8 ?? joiner, AsrModelRole.joinerInt8),
          entry(tokens, AsrModelRole.tokens),
          vad == null ? kAsrVadFile : entry(vad, AsrModelRole.vad),
        ],
      ),
    );
  }

  final File? ctcFp32 = pick(
    (String n) => isOnnx(n) && !int8(n) && !n.contains('silero'),
  );
  final File? ctcInt8 = pick(
    (String n) => isOnnx(n) && int8(n) && !n.contains('silero'),
  );
  final File? ctc = ctcFp32 ?? ctcInt8;
  if (ctc == null) {
    return const AsrLocalModelRejected(AsrLocalModelProblem.missingModel);
  }
  final File? weights = pick((String n) => n == 'model.weights');
  return AsrLocalModelFound(
    AsrModelPack(
      languages: languages,
      id: packId,
      displayName: name,
      sourceUrl: Uri.file(dir.path).toString(),
      architecture: AsrModelArchitecture.ctc,
      blankToken: blankToken,
      files: <AsrModelFile>[
        entry(ctcFp32 ?? ctc, AsrModelRole.ctcModelFp32),
        entry(ctcInt8 ?? ctc, AsrModelRole.ctcModelInt8),
        if (weights != null) entry(weights, AsrModelRole.ctcWeightsFp32),
        entry(tokens, AsrModelRole.tokens),
        vad == null ? kAsrVadFile : entry(vad, AsrModelRole.vad),
      ],
    ),
  );
}

// ── 磁盘读写 ─────────────────────────────────────────────────────────────────

/// 目录文件的位置（数据根下）。
Future<File> asrModelCatalogFile() async {
  final Directory root = await asrSupportRootDirectory();
  return File(p.join(root.path, kAsrModelCatalogFileName));
}

/// 读目录；文件不存在返回空目录。解析失败**抛**（配错了要当场报）。
Future<AsrModelCatalog> readAsrModelCatalog() async {
  final File file = await asrModelCatalogFile();
  if (!file.existsSync()) return AsrModelCatalog.empty;
  final String text = await file.readAsString();
  if (text.trim().isEmpty) return AsrModelCatalog.empty;
  try {
    return AsrModelCatalog.fromJson(jsonDecode(text) as Object?);
  } on FormatException catch (error) {
    throw FormatException('模型目录 ${file.path} 解析失败：${error.message}');
  }
}

/// 写目录：先整份编码，再写同目录的 `.tmp`，最后 rename 到位。
///
/// 两层都必要。先编码是防「open(write) 之后编码抛异常」把已有内容截成零字节；
/// 走 `.tmp` + rename 是防写到一半断电 / 磁盘满留下半截 JSON——那种文件下次启动
/// 解析失败，[loadAsrModelCatalog] 吞掉退回内置表，用户的自带模型配置就无声消失
/// 了。rename 在同一文件系统上是原子的。
Future<void> writeAsrModelCatalog(AsrModelCatalog catalog) async {
  final String text =
      const JsonEncoder.withIndent('  ').convert(catalog.toJson());
  final File file = await asrModelCatalogFile();
  await file.parent.create(recursive: true);
  final File tmp = File('${file.path}.tmp');
  await tmp.writeAsString(text, flush: true);
  await tmp.rename(file.path);
}

/// 同步读一份目录文件。
///
/// 后台转录 isolate 的引导里用：那边没有 await 的余地，也不该为读一个几 KB 的
/// JSON 去装一整套异步装配。文件不存在 / 为空返回空目录；解析失败照抛
/// （[AsrModelCatalog.fromJson] 的纪律）。
AsrModelCatalog readAsrModelCatalogSync(File file) {
  if (!file.existsSync()) return AsrModelCatalog.empty;
  final String text = file.readAsStringSync();
  if (text.trim().isEmpty) return AsrModelCatalog.empty;
  return AsrModelCatalog.fromJson(jsonDecode(text) as Object?);
}

// ── 内部 ─────────────────────────────────────────────────────────────────────

/// 换一份语言列表，其余字段逐字照抄。
///
/// 包里没有 `copyWith`，字段又全是 final public，所以手写一份——加字段时这里会
/// 编译报错，正好逼着来同步。
AsrModelPack _withLanguages(AsrModelPack pack, List<AsrLanguage> languages) =>
    AsrModelPack(
      languages: languages,
      id: pack.id,
      displayName: pack.displayName,
      sourceUrl: pack.sourceUrl,
      files: pack.files,
      architecture: pack.architecture,
      decoderContextSize: pack.decoderContextSize,
      indexType: pack.indexType,
      blankToken: pack.blankToken,
      fp32GpuMinBudgetBytes: pack.fp32GpuMinBudgetBytes,
    );

/// 换一个 id，其余字段逐字照抄（见 [_withLanguages] 同样的理由）。
AsrModelPack _withId(AsrModelPack pack, String id) => AsrModelPack(
      languages: pack.languages,
      id: id,
      displayName: pack.displayName,
      sourceUrl: pack.sourceUrl,
      files: pack.files,
      architecture: pack.architecture,
      decoderContextSize: pack.decoderContextSize,
      indexType: pack.indexType,
      blankToken: pack.blankToken,
      fp32GpuMinBudgetBytes: pack.fp32GpuMinBudgetBytes,
    );

AsrModelPack? _packById(List<AsrModelPack> packs, String id) {
  for (final AsrModelPack pack in packs) {
    if (pack.id == id) return pack;
  }
  return null;
}

AsrLanguage? _languageOf(AsrModelPack pack, String tag) {
  for (final AsrLanguage language in pack.languages) {
    if (language.tag == tag) return language;
  }
  return null;
}

/// 显示名 → 目录名可用的 id 片段（磁盘目录就叫这个，见 `AsrModelStore`）。
String _slug(String name) {
  final String lower = name.toLowerCase().trim();
  final StringBuffer sb = StringBuffer();
  bool lastDash = false;
  for (final int rune in lower.runes) {
    final String ch = String.fromCharCode(rune);
    final bool ok = RegExp(r'[a-z0-9]').hasMatch(ch);
    if (ok) {
      sb.write(ch);
      lastDash = false;
    } else if (!lastDash && sb.isNotEmpty) {
      sb.write('-');
      lastDash = true;
    }
  }
  final String out = sb.toString().replaceAll(RegExp(r'-+$'), '');
  return out.isEmpty ? 'model' : out;
}
