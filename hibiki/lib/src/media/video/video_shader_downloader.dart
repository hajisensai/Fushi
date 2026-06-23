import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki/src/media/video/video_shader_manager.dart';

/// Anime4K（bloc97/Anime4K）GLSL 着色器一键下载：定义官方推荐预设、生成多镜像
/// 下载 URL、把一组 `.glsl` 拉到 [mpvShaderDirectory] 供视频页勾选启用。
///
/// 着色器经 libmpv 的 `glsl-shaders-append`（见 [applyShadersToPlayer]）逐文件叠加，
/// 叠加顺序即勾选顺序（视频页按目录列表顺序排出启用集）。一个「预设」是官方推荐的一条
/// 着色器链（多个 `.glsl` 按序），下载后落到同一目录、文件名取仓库 basename（扁平化），
/// 用户在着色器对话框逐个勾选即复现该链。
///
/// 数据来源：bloc97/Anime4K master 分支 `glsl/` 目录（截至 v4.0.1）。文件名/路径见
/// 官方 `md/GLSL_Instructions_Windows_MPV.md` 的 input.conf 模板（Mode A/B/C 的 Fast 与
/// HQ 预设）。仅桌面 libmpv 实测可用（移动端 [applyShadersToPlayer] 静默 no-op）。

/// 单个 Anime4K 着色器文件在仓库里的相对路径（含子目录），用于拼下载 URL。
/// 落盘文件名取其 [fileName]（basename），保证在扁平的 mpv_shaders 目录里唯一。
class Anime4kShaderFile {
  const Anime4kShaderFile(this.repoPath);

  /// 仓库内相对路径，如 `glsl/Restore/Anime4K_Clamp_Highlights.glsl`。
  final String repoPath;

  /// 落盘 / 启用集里用的文件名（basename），如 `Anime4K_Clamp_Highlights.glsl`。
  String get fileName => p.posix.basename(repoPath);
}

/// 一个 Anime4K 推荐预设：显示名 + 说明 + 一条按序的着色器链。
class Anime4kPreset {
  const Anime4kPreset({
    required this.id,
    required this.name,
    required this.description,
    required this.shaders,
    this.repo = 'bloc97/Anime4K',
    this.ref = 'master',
  });

  /// 稳定 id（持久化 / 测试用），如 `mode_a_fast`。
  final String id;

  /// 显示名（已本地化文案由 UI 层提供，这里存英文标识名作回退）。
  final String name;

  /// 一句话说明（英文回退；UI 用 i18n）。
  final String description;

  /// 着色器链（按 libmpv 叠加顺序）。
  final List<Anime4kShaderFile> shaders;

  /// 着色器所在 GitHub 仓库 `owner/name`（默认 Anime4K；ArtCNN 等其它 MIT 仓库覆写）。
  final String repo;

  /// 仓库 ref（分支/标签，默认 master）。
  final String ref;

  /// 本预设涉及的全部落盘文件名（去重，保序）。
  List<String> get fileNames {
    final List<String> out = <String>[];
    for (final Anime4kShaderFile s in shaders) {
      if (!out.contains(s.fileName)) out.add(s.fileName);
    }
    return out;
  }
}

/// Anime4K 官方推荐预设（截至 v4.0.1 的 input.conf 模板）。
///
/// Fast 档用 S/M 变体（中低端 GPU 也能 24fps）；HQ 档用 VL/L 变体（需较强 GPU）。
/// - Mode A：1080p 动画（模糊多）；Mode B：720p 旧番（重采样伪影）；Mode C：480p SD（压缩涂抹）。
/// 链结构遵循官方：Clamp_Highlights → Restore(_Soft) / Upscale_Denoise → Upscale_CNN_x2 →
/// AutoDownscalePre_x2/x4 → Upscale_CNN_x2（第二次匹配屏幕尺寸）。
const List<Anime4kPreset> kAnime4kPresets = <Anime4kPreset>[
  // ── Mode A (Fast)：最常用，1080p 动画首选 ──
  Anime4kPreset(
    id: 'mode_a_fast',
    name: 'Mode A (Fast)',
    description: 'For most 1080p anime. Lower GPU load.',
    shaders: <Anime4kShaderFile>[
      Anime4kShaderFile('glsl/Restore/Anime4K_Clamp_Highlights.glsl'),
      Anime4kShaderFile('glsl/Restore/Anime4K_Restore_CNN_M.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_Upscale_CNN_x2_M.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_AutoDownscalePre_x2.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_AutoDownscalePre_x4.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_Upscale_CNN_x2_S.glsl'),
    ],
  ),
  // ── Mode B (Fast)：720p 旧番（重采样伪影） ──
  Anime4kPreset(
    id: 'mode_b_fast',
    name: 'Mode B (Fast)',
    description: 'For some older 720p anime with resampling artifacts.',
    shaders: <Anime4kShaderFile>[
      Anime4kShaderFile('glsl/Restore/Anime4K_Clamp_Highlights.glsl'),
      Anime4kShaderFile('glsl/Restore/Anime4K_Restore_CNN_Soft_M.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_Upscale_CNN_x2_M.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_AutoDownscalePre_x2.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_AutoDownscalePre_x4.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_Upscale_CNN_x2_S.glsl'),
    ],
  ),
  // ── Mode C (Fast)：480p SD 老番（压缩涂抹），带去噪 ──
  Anime4kPreset(
    id: 'mode_c_fast',
    name: 'Mode C (Fast)',
    description: 'For most old SD (480p) anime with compression smearing.',
    shaders: <Anime4kShaderFile>[
      Anime4kShaderFile('glsl/Restore/Anime4K_Clamp_Highlights.glsl'),
      Anime4kShaderFile(
          'glsl/Upscale+Denoise/Anime4K_Upscale_Denoise_CNN_x2_M.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_AutoDownscalePre_x2.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_AutoDownscalePre_x4.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_Upscale_CNN_x2_S.glsl'),
    ],
  ),
  // ── Mode A (HQ)：高画质，需较强 GPU ──
  Anime4kPreset(
    id: 'mode_a_hq',
    name: 'Mode A (HQ)',
    description: 'Highest quality for 1080p anime. Needs a strong GPU.',
    shaders: <Anime4kShaderFile>[
      Anime4kShaderFile('glsl/Restore/Anime4K_Clamp_Highlights.glsl'),
      Anime4kShaderFile('glsl/Restore/Anime4K_Restore_CNN_VL.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_Upscale_CNN_x2_VL.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_AutoDownscalePre_x2.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_AutoDownscalePre_x4.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_Upscale_CNN_x2_M.glsl'),
    ],
  ),
  // ── Mode B (HQ)：720p 旧番高画质（重采样伪影），VL 变体 ──
  Anime4kPreset(
    id: 'mode_b_hq',
    name: 'Mode B (HQ)',
    description: 'High quality for older 720p anime with resampling artifacts.',
    shaders: <Anime4kShaderFile>[
      Anime4kShaderFile('glsl/Restore/Anime4K_Clamp_Highlights.glsl'),
      Anime4kShaderFile('glsl/Restore/Anime4K_Restore_CNN_Soft_VL.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_Upscale_CNN_x2_VL.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_AutoDownscalePre_x2.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_AutoDownscalePre_x4.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_Upscale_CNN_x2_M.glsl'),
    ],
  ),
  // ── Mode C (HQ)：480p SD 老番高画质（压缩涂抹），带去噪 VL 变体 ──
  Anime4kPreset(
    id: 'mode_c_hq',
    name: 'Mode C (HQ)',
    description:
        'High quality for old SD (480p) anime with compression smearing.',
    shaders: <Anime4kShaderFile>[
      Anime4kShaderFile('glsl/Restore/Anime4K_Clamp_Highlights.glsl'),
      Anime4kShaderFile(
          'glsl/Upscale+Denoise/Anime4K_Upscale_Denoise_CNN_x2_VL.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_AutoDownscalePre_x2.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_AutoDownscalePre_x4.glsl'),
      Anime4kShaderFile('glsl/Upscale/Anime4K_Upscale_CNN_x2_M.glsl'),
    ],
  ),
];

/// ── 画质档位用的 GLSL 预设（无独立数据，复用上面 Anime4K 链 + 新增 ArtCNN）────────
/// 这三个常量是 [VideoShaderTier]「中/高/极高」三档映射到的着色器集（见
/// video_shader_tier.dart）；与上面 [kAnime4kPresets] 共享同一下载/落盘/勾选管线。

/// 「中」档：Anime4K Mode A Fast（中低端 GPU 可跑）。直接复用 [kAnime4kPresets] 里的
/// `mode_a_fast` 着色器链（同文件，避免重复枚举）。
final Anime4kPreset kAnime4kFastPreset =
    kAnime4kPresets.firstWhere((Anime4kPreset p) => p.id == 'mode_a_fast');

/// 「高」档：Anime4K Mode A HQ（需较强 GPU）。复用 `mode_a_hq` 链。
final Anime4kPreset kAnime4kHqPreset =
    kAnime4kPresets.firstWhere((Anime4kPreset p) => p.id == 'mode_a_hq');

/// 「极高」档：ArtCNN C4F32 **DS（denoise + sharpen）变体**（Artoriuz/ArtCNN，MIT，
/// 2025 最强 HD 番上采样，需旗舰 GPU）。
///
/// **为什么用 DS 而非中性 C4F32**（TODO-706）：中性 `ArtCNN_C4F32` 只做数学最优上采样，
/// 对干净 HD 源最佳，但对 web 压制番（去压缩伪影、轻锐化）毫无帮助——这正是用户吐槽
/// 「极高反而比高弱」的真因（高档 = Anime4K Mode A HQ 有完整去振铃/去压缩修复链）。
/// `ArtCNN_C4F32_DS` 是同网络的 denoise+sharpen 训练变体，专为压制源训练，对脏源真有
/// 去噪锐化作用，与「高档 = Anime4K A HQ」的文件集不同 → [tierFromState] 反查无歧义。
///
/// 单文件 `.glsl`（内含 MIT license 注释 + `//!HOOK` 指令，[looksLikeGlslShader] 全文
/// 扫描可通过）。经 [downloadAnime4kFiles] 同款多镜像下载，repo/ref 由本预设覆写。
///
/// **ref = `main`**：Artoriuz/ArtCNN 主分支是 `main`（非 `master`），raw 路径
/// `/main/GLSL/ArtCNN_*.glsl`（联网核对 2026-06-23：`ArtCNN_C4F32_DS.glsl` 在
/// `main` 返回 200；`master` 虽因 GitHub 把默认分支同时挂在旧名下也能解析，但 `main`
/// 才是规范分支名，钉死 `main` 避免依赖 GitHub 的兼容别名）。
const Anime4kPreset kArtCnnC4F32DsPreset = Anime4kPreset(
  id: 'artcnn_c4f32_ds',
  name: 'ArtCNN C4F32 DS',
  description:
      'Strongest HD anime upscaler with denoise + sharpen for web-encoded '
      'sources (MIT). Needs a flagship GPU.',
  repo: 'Artoriuz/ArtCNN',
  ref: 'main',
  shaders: <Anime4kShaderFile>[
    Anime4kShaderFile('GLSL/ArtCNN_C4F32_DS.glsl'),
  ],
);

/// GitHub raw 直连不通（GFW 机器、app 运行时**不走**本机命令行代理）时的镜像回退源。
/// 与 `update_checker.dart` 的 `_kProxyPrefixes`（BUG-319）同一范式：公共镜像会不定期
/// 轮换/下线，按顺序逐个尝试，全部失败才放弃；具体哪个通取决于用户机器与时段，多备几个。
///
/// 分两类：
/// - **jsDelivr 多 CDN 节点**：同一 GitHub 仓库内容的不同边缘网络（cdn/fastly/gcore/
///   testingcf）。单源不可达多是某个边缘节点缓存未命中 / 限流 / 抖动——换一个独立 CDN
///   边缘网络即可成（这是「中档 6 个文件偏偏失败 1 个」的真根因：原来 jsDelivr 只挂
///   一个 `cdn.` 节点，那个节点对某文件抖动一次就回退到中国本就不稳的 raw / 单一代理）。
/// - **gh 加速代理前缀**：套在 `raw.githubusercontent.com` 直链前的反代（BUG-319 名单）。
///
/// 顺序：jsDelivr 多节点（最稳、中国可达）→ 代理前缀 → raw 官方直连兜底。
const List<String> _kJsDelivrHosts = <String>[
  'cdn.jsdelivr.net',
  'fastly.jsdelivr.net',
  'gcore.jsdelivr.net',
  'testingcf.jsdelivr.net',
];

/// 套在 `raw.githubusercontent.com` 直链前的 GitHub 加速代理前缀（BUG-319 同款名单）。
const List<String> _kGhProxyPrefixes = <String>[
  'https://ghfast.top/',
  'https://gh-proxy.com/',
  'https://ghproxy.net/',
  'https://ghproxy.cc/',
];

/// 为仓库相对路径 [repoPath] 生成按优先级排序的下载 URL 列表（多镜像回退）。纯函数。
///
/// 顺序：① jsDelivr 多 CDN 节点（[_kJsDelivrHosts]，独立边缘网络互为后备，中国可达）→
/// ② gh 加速代理前缀套 raw 直链（[_kGhProxyPrefixes]，BUG-319 名单）→ ③ raw.githubusercontent.com
/// 官方直连兜底。app 运行时下载**不走**本机命令行代理，故必须靠这些镜像在中国网络兜底。
/// 逐个尝试，前一个失败回退下一个；整组跑完仍失败由 [downloadAnime4kFiles] 做有界重试
/// （瞬态 CDN 抖动换轮再试）。
List<String> anime4kMirrorUrls(
  String repoPath, {
  String repo = 'bloc97/Anime4K',
  String ref = 'master',
}) {
  // jsDelivr / 代理 / raw 都不需要对路径里的 `+`（如 Upscale+Denoise 目录）做转义。
  final String rawUrl =
      'https://raw.githubusercontent.com/$repo/$ref/$repoPath';
  return <String>[
    for (final String host in _kJsDelivrHosts)
      'https://$host/gh/$repo@$ref/$repoPath',
    for (final String prefix in _kGhProxyPrefixes) '$prefix$rawUrl',
    rawUrl,
  ];
}

/// **纯函数**：把用户粘贴的着色器链接规整成「按优先级尝试的 URL 列表」。
///
/// **直链优先、镜像兜底**：用户粘的就是 GitHub 链接，先试它本身（`blob` 链接转成可
/// 直接下载的 `raw` 形式）——能直连 / 有系统代理 VPN 就直接用；**跑不通才回退**与
/// [anime4kMirrorUrls] 同款的 jsDelivr 多 CDN 节点（[_kJsDelivrHosts]）+ gh 加速代理
/// 前缀（[_kGhProxyPrefixes]，BUG-319 名单）兜底（中国网络）。其它任意直链原样单条返回。
/// 让用户从 GitHub/教程里复制任意 `.glsl` 链接粘进来即可下，不必本机装 mpv。
List<String> shaderDownloadUrlsFor(String userUrl) {
  final String url = userUrl.trim();
  final RegExpMatch? blob =
      RegExp(r'^https?://github\.com/([^/]+)/([^/]+)/blob/(.+)$')
          .firstMatch(url);
  final RegExpMatch? raw =
      RegExp(r'^https?://raw\.githubusercontent\.com/([^/]+)/([^/]+)/(.+)$')
          .firstMatch(url);
  final RegExpMatch? m = blob ?? raw;
  if (m == null) return <String>[url];
  final String owner = m.group(1)!;
  final String repo = m.group(2)!;
  final String refAndPath = m.group(3)!; // `<ref>/<path...>`
  final String direct =
      'https://raw.githubusercontent.com/$owner/$repo/$refAndPath';
  return <String>[
    direct, // 直链优先（用户粘的链接 / 其 raw 形式 / 有 VPN 时直连）
    // 跑不通才走镜像（与 anime4kMirrorUrls 同款多节点 + 代理前缀，中国网络兜底）。
    for (final String host in _kJsDelivrHosts)
      'https://$host/gh/$owner/$repo@$refAndPath',
    for (final String prefix in _kGhProxyPrefixes) '$prefix$direct',
  ];
}

/// **纯函数**：从着色器链接推断落盘文件名。取 URL 路径 basename，去查询串/锚点；无
/// `.glsl`/`.hook` 扩展名则补 `.glsl`；非法字符折叠为 `_`。
String shaderFileNameFromUrl(String url) {
  String name = url.trim();
  final int cut = name.indexOf(RegExp(r'[?#]'));
  if (cut >= 0) name = name.substring(0, cut);
  name = name.replaceAll(RegExp(r'/+$'), '');
  final int slash = name.lastIndexOf('/');
  if (slash >= 0) name = name.substring(slash + 1);
  if (name.isEmpty) name = 'shader.glsl';
  final String ext = p.extension(name).toLowerCase();
  if (ext != '.glsl' && ext != '.hook') name = '$name.glsl';
  return name.replaceAll(RegExp(r'[^A-Za-z0-9_.+\-]'), '_');
}

/// 下载用户粘贴的**单个**着色器链接到 [targetDir]（默认 [mpvShaderDirectory]）。
///
/// 按 [shaderDownloadUrlsFor] 顺序尝试镜像/直链，任一成功且 [looksLikeGlslShader] 通过
/// 即落盘。成功返回落盘文件名；全部失败 / 内容不像着色器 → 返回 null（UI 提示失败）。
/// [dio] 可注入（测试）；[cancelToken] 取消时 rethrow。
Future<String?> downloadShaderFromUrl(
  String url, {
  Directory? targetDir,
  Dio? dio,
  CancelToken? cancelToken,
  void Function(double? progress)? onProgress,
}) async {
  final String trimmed = url.trim();
  if (trimmed.isEmpty) return null;
  final Directory dir = targetDir ?? await mpvShaderDirectory();
  final Dio client = dio ??
      Dio(BaseOptions(
        // 连接超时调短（8s）：直链优先，直连不通时尽快回退镜像，不让用户干等。
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 60),
        followRedirects: true,
        maxRedirects: 10,
        responseType: ResponseType.bytes,
        headers: const <String, String>{
          'User-Agent': 'Mozilla/5.0 (Hibiki) Shader-Downloader/1.0',
          'Accept': '*/*',
        },
      ));
  final String fileName = shaderFileNameFromUrl(trimmed);
  final String destPath = p.join(dir.path, fileName);

  for (final String u in shaderDownloadUrlsFor(trimmed)) {
    try {
      onProgress?.call(null);
      final Response<List<int>> resp = await client.get<List<int>>(
        u,
        cancelToken: cancelToken,
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: (int received, int total) {
          onProgress?.call(total > 0 ? received / total : null);
        },
      );
      final List<int> bytes = resp.data ?? const <int>[];
      if (!looksLikeGlslShader(bytes)) continue; // HTML 错误页 / 404 占位。
      File(destPath).writeAsBytesSync(bytes, flush: true);
      return fileName;
    } on DioError catch (e) {
      if (e.type == DioErrorType.cancel) rethrow;
      continue; // 该镜像失败，回退下一个。
    }
  }
  return null;
}

/// 下载结果：成功/失败的文件数与失败明细（供 UI 提示）。
class Anime4kDownloadResult {
  const Anime4kDownloadResult({
    required this.downloaded,
    required this.failed,
  });

  /// 成功落盘的文件名。
  final List<String> downloaded;

  /// 失败的文件名（所有镜像均失败）。
  final List<String> failed;

  bool get allOk => failed.isEmpty;
}

/// 下载到的内容是否像一个 GLSL 着色器（文本、含 mpv `//!` 指令或 GLSL 关键字）。纯函数。
///
/// 防镜像返回 HTML 错误页 / 404 占位被当成有效着色器。Anime4K 的 `.glsl` 是纯 UTF-8
/// 文本，且**整文件**含 libmpv 的 `//!HOOK` / `//!DESC` 指令块——但文件开头是一大段
/// MIT License 注释（数百字节），指令在其后，故**必须扫全文**而非只看前若干字节（早期只
/// 探前 512 字节会把 license 当作非着色器而误拒，是真 bug）。判定：① 头部无 NUL（排
/// 二进制）② 全文含 `//!`（mpv hook 指令）或常见 GLSL 标志。
bool looksLikeGlslShader(List<int> bytes) {
  if (bytes.isEmpty) return false;
  // 头部探 NUL 排二进制（图片/压缩包等），文本文件不含 NUL。
  final int nulProbe = bytes.length < 1024 ? bytes.length : 1024;
  for (int i = 0; i < nulProbe; i++) {
    if (bytes[i] == 0) return false;
  }
  String text;
  try {
    text = String.fromCharCodes(bytes);
  } catch (_) {
    return false;
  }
  return text.contains('//!') ||
      text.contains('vec4 hook') ||
      text.contains('#version') ||
      text.contains('//!HOOK');
}

/// **单文件多镜像下载**：把 [repoPath] 的着色器按 [anime4kMirrorUrls] 顺序逐个镜像尝试，
/// 任一镜像成功且 [looksLikeGlslShader] 通过即写入 [destPath] 返回 true；整组镜像全失败
/// （网络错 / 返回非着色器内容）返回 false。取消（[DioErrorType.cancel]）一律 rethrow。
///
/// 不含重试——重试由 [downloadAnime4kFiles] 在更外层按文件做（瞬态 CDN 抖动换轮再试整组
/// 镜像）。[onProgress] 透传单文件 0..1 进度（total<=0 时 null）。
Future<bool> _downloadFileViaMirrors({
  required Dio client,
  required String repoPath,
  required String destPath,
  required String repo,
  required String ref,
  CancelToken? cancelToken,
  void Function(double? progress)? onProgress,
}) async {
  final List<String> urls = anime4kMirrorUrls(repoPath, repo: repo, ref: ref);
  for (final String url in urls) {
    try {
      onProgress?.call(null);
      final Response<List<int>> resp = await client.get<List<int>>(
        url,
        cancelToken: cancelToken,
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: (int received, int total) {
          onProgress?.call(total > 0 ? received / total : null);
        },
      );
      final List<int> bytes = resp.data ?? const <int>[];
      if (!looksLikeGlslShader(bytes)) {
        continue; // 镜像返回了非着色器内容（HTML 错误页等），换下一个。
      }
      File(destPath).writeAsBytesSync(bytes, flush: true);
      return true;
    } on DioError catch (e) {
      if (e.type == DioErrorType.cancel) rethrow;
      continue; // 该镜像失败，回退下一个。
    }
  }
  return false;
}

/// 把预设 [preset] 的全部着色器逐个下载到 [targetDir]（默认 [mpvShaderDirectory]）。
///
/// 每个文件按 [anime4kMirrorUrls] 顺序尝试镜像，任一成功且 [looksLikeGlslShader] 通过即
/// 落盘（已存在则跳过下载，视作已就绪）。**有界重试**：整组镜像跑完仍失败的文件，等一个
/// 递增退避（[retryBackoff] × 轮次）后再跑整组镜像一轮，最多额外重试 [maxRetries] 次
/// （默认 2，共 3 轮）——根因是公共 CDN / 代理对单个文件的瞬态抖动（缓存未命中、限流、
/// 偶发超时），换轮重试整组多镜像远比单源单试稳，正治「整档 6 个文件偏偏失败 1 个」。
/// [onFileProgress] 在每个文件下载推进时回调（当前文件 index、总数、单文件 0..1 进度，
/// total<=0 时进度为 null）。整组逐文件串行，best-effort：单文件耗尽重试仍失败计入
/// [Anime4kDownloadResult.failed]，不中断其余文件。
///
/// [dio] 可注入（测试用假 client）；默认构造带超时/重定向的真实 Dio。[cancelToken] 透传
/// 给每次下载，取消会 rethrow [DioException]（cancel 类型）由调用方处理。
Future<Anime4kDownloadResult> downloadAnime4kFiles(
  Anime4kPreset preset, {
  Directory? targetDir,
  Dio? dio,
  CancelToken? cancelToken,
  int maxRetries = 2,
  Duration retryBackoff = const Duration(seconds: 1),
  void Function(int fileIndex, int fileTotal, double? fileProgress)?
      onFileProgress,
}) async {
  final Directory dir = targetDir ?? await mpvShaderDirectory();
  final Dio client = dio ??
      Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(minutes: 5),
        followRedirects: true,
        maxRedirects: 10,
        responseType: ResponseType.bytes,
        headers: const <String, String>{
          'User-Agent': 'Mozilla/5.0 (Hibiki) Anime4K-Downloader/1.0',
          'Accept': '*/*',
        },
      ));

  final List<Anime4kShaderFile> files = preset.shaders;
  final List<String> done = <String>[];
  final List<String> failed = <String>[];

  for (int i = 0; i < files.length; i++) {
    final Anime4kShaderFile f = files[i];
    final String destPath = p.join(dir.path, f.fileName);
    // 已下载过（同名文件存在）就跳过——同一文件可能被多个预设共享，避免重复下。
    if (File(destPath).existsSync()) {
      if (!done.contains(f.fileName)) done.add(f.fileName);
      onFileProgress?.call(i, files.length, 1.0);
      continue;
    }

    bool ok = false;
    // 整组多镜像为一轮；瞬态抖动 → 退避后整组再试，最多 1 + maxRetries 轮。
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(retryBackoff * attempt);
      }
      ok = await _downloadFileViaMirrors(
        client: client,
        repoPath: f.repoPath,
        destPath: destPath,
        repo: preset.repo,
        ref: preset.ref,
        cancelToken: cancelToken,
        onProgress: (double? p) => onFileProgress?.call(i, files.length, p),
      );
      if (ok) break;
    }
    if (ok) {
      if (!done.contains(f.fileName)) done.add(f.fileName);
    } else {
      failed.add(f.fileName);
    }
  }

  return Anime4kDownloadResult(downloaded: done, failed: failed);
}
