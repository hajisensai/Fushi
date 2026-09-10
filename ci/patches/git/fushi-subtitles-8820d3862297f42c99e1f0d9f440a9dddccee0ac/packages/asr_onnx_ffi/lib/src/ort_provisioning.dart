/// Windows 上按需装配 ONNX Runtime 动态库。
///
/// 为什么只有 Windows：macOS 走 `script/bootstrap_macos.sh`（Homebrew /
/// 官方 tgz），Linux 走发行版包管理器，两边都有既成的分发渠道。Windows 没有
/// ——用户机器上要么根本没有 onnxruntime.dll，要么只有
/// `C:\Windows\System32` 里那份随系统/显卡驱动装的旧版（实测 1.17.1，只到
/// API 17）。本文件补的就是这个缺口。
///
/// 下的是 **NuGet 上的 `Microsoft.ML.OnnxRuntime.DirectML`**，不是 GitHub
/// release 里的 `onnxruntime-win-x64-*.zip`：后者是纯 CPU 构建，装上去转录能跑
/// 但 **GPU 加速会静默消失**（DirectML EP 根本不在那个 .dll 里）。本包在
/// Windows 上的推荐路径就是 DirectML（见 `asr_engine.dart` 的 EP 决策表），
/// 所以按需下载必须下带 DML EP 的那一份，否则「装好了」和「装对了」是两回事。
///
/// `DirectML.dll` 本身不下：它是 Windows 10 1903+ 的系统组件，
/// `C:\Windows\System32` 里就有（本机实测 1.15.5，比 NuGet redist 的 1.15.4
/// 还新）。而官方 `Microsoft.AI.DirectML` 包为了塞 Xbox 与 debug 二进制有
/// **202 MB**，为取其中一个 18 MB 的 DLL 拖这么大不划算。系统版本过老的机器
/// 上 DML EP 会在探测阶段失败并回落 CPU——那条降级路径已经存在，且会把原因
/// 报给用户（`transcribe_runner.dart` 的 probeError），不是静默的。
library;

import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_asr_core/asr_core.dart'
    show
        DownloadableModelFile,
        ModelDownloadEvent,
        ModelFileDownloader,
        asrSupportRootDirectory;

import 'package:fushi_asr_onnx_ffi/src/ort_runtime.dart';

/// 按需装配的 ORT 版本。
///
/// 必须 ≥ [kOrtApiVersion] 对应的 1.22——低于它 `GetApi(22)` 返回 nullptr，
/// 装了也用不了。改这个常量记得同步改 [kOrtPackageSha256] 与 [kOrtPackageBytes]。
const String kOrtPackageVersion = '1.22.0';

/// NuGet 包 id（小写，flat container 要求）。
const String kOrtPackageId = 'microsoft.ml.onnxruntime.directml';

/// 包的 sha256。**下来的是要塞进本进程执行的机器码**，长度校验不够——
/// 长度对得上的坏包（截断后补齐、中间人替换）照样会被加载。
const String kOrtPackageSha256 =
    '29f9872d786236b79aa83f94482f3a17c14297e4833768d6d0ed4883ee732e60';

/// 包字节数（进度条总量 + 下载器的长度预校验）。
const int kOrtPackageBytes = 17898472;

/// 包内要取出来的文件（相对 `runtimes/<rid>/native/`）。
///
/// `onnxruntime_providers_shared.dll` 不是可选的：DML/CUDA 这类
/// 「共享 provider」在 EP 注册时按名字加载它，缺了就只剩 CPU。
const List<String> kOrtPackageNativeFiles = <String>[
  'onnxruntime.dll',
  'onnxruntime_providers_shared.dll',
];

/// 本平台不支持按需下载。
class OrtProvisionUnsupported implements Exception {
  OrtProvisionUnsupported(this.message);

  final String message;

  @override
  String toString() => 'OrtProvisionUnsupported: $message';
}

/// 下下来的包与预期不符（长度或摘要）。
class OrtProvisionCorrupt implements Exception {
  OrtProvisionCorrupt(this.message);

  final String message;

  @override
  String toString() => 'OrtProvisionCorrupt: $message';
}

/// NuGet flat container 直链。
String ortPackageUrl({
  String id = kOrtPackageId,
  String version = kOrtPackageVersion,
}) =>
    'https://api.nuget.org/v3-flatcontainer/$id/$version/$id.$version.nupkg';

/// Windows 架构 → NuGet runtime identifier。
///
/// 只认 Windows：其它平台由调用方在 [ensureOrtRuntime] 里挡掉，这里不额外分支。
String ortRuntimeIdentifier(Abi abi) {
  switch (abi) {
    case Abi.windowsX64:
      return 'win-x64';
    case Abi.windowsArm64:
      return 'win-arm64';
    case Abi.windowsIA32:
      return 'win-x86';
    default:
      throw OrtProvisionUnsupported('不支持的 Windows 架构：$abi');
  }
}

/// 按需下载的落地目录：`<数据根>/asr_runtime/onnxruntime-<版本>-<rid>/`。
///
/// 带版本与架构是为了**换版本不用先删旧的**：目录名不同就是两份，回退只要把
/// 常量改回去。与模型缓存同在数据根下，用户清理时看得到、删得掉。
Future<Directory> resolveOrtManagedDir({
  Directory? dataRoot,
  Abi? abi,
  String version = kOrtPackageVersion,
}) async {
  final String rid = ortRuntimeIdentifier(abi ?? Abi.current());
  final Directory root = dataRoot ?? await asrSupportRootDirectory();
  return Directory(
      p.join(root.path, 'asr_runtime', 'onnxruntime-$version-$rid'));
}

/// 当前候选里是否已经有一份**真能用**的运行时（判据与加载时逐字一致）。
///
/// 复用 [OrtRuntime.probeCandidate] 而不是另写一套「文件在不在」的判断：
/// 两套判据迟早会分叉，而分叉的结果就是这里说「有了」、加载时说「没有」。
String? findUsableOrtRuntime({List<String>? candidates}) {
  final List<String> list =
      candidates ?? OrtRuntime.resolveLibraryCandidates();
  final List<String> ignored = <String>[];
  return OrtRuntime.selectUsableCandidate<String>(
    list,
    (String candidate) {
      final (_, String? failure) = OrtRuntime.probeCandidate(candidate);
      return (failure == null ? candidate : null, failure);
    },
    ignored,
  );
}

/// 确保本机有一份可用的 ORT；缺了就下。
///
/// 进度事件与模型下载同一个契约（[ModelDownloadEvent]），调用方因此可以原样
/// 复用既有的下载进度 UI，不需要为「下运行时」再造一种展示。
///
/// 已经有可用运行时时**一个事件都不发**，直接返回——这条路径每次转录都会走，
/// 不能有网络访问。
Stream<ModelDownloadEvent> ensureOrtRuntime({
  Directory? dataRoot,
  Abi? abi,
  ModelFileDownloader? downloader,
  String url = '',
}) async* {
  // 托管目录要先登记进候选序列再判「有没有」：上一次下好的那份不在系统搜索
  // 路径里，漏了它每个新进程都会重走下载分支。登记的是**目录位置**，不代表那
  // 里已经装好——装没装好由下面的探测说了算。
  Directory? target;
  if (Platform.isWindows) {
    target = await resolveOrtManagedDir(dataRoot: dataRoot, abi: abi);
    OrtRuntime.managedRuntimeDir = target.path;
  }
  if (findUsableOrtRuntime() != null) return;
  if (!Platform.isWindows || target == null) {
    throw OrtProvisionUnsupported(
      '没有可用的 ONNX Runtime，且本平台没有按需下载：'
      '${Platform.isMacOS ? "macOS 请跑 script/bootstrap_macos.sh" : "Linux 请用发行版包管理器安装 onnxruntime"}'
      '，或用 ASR_ONNXRUNTIME_LIB 指向一份 $kOrtPackageVersion 或更新的库',
    );
  }

  // 提成 final 局部：下面的 isReady 闭包捕获它，可空局部在闭包里不参与提升。
  final Directory dir = target;
  await dir.create(recursive: true);
  final String rid = ortRuntimeIdentifier(abi ?? Abi.current());
  final _OrtPackage pkg = _OrtPackage(url.isEmpty ? ortPackageUrl() : url);

  final ModelFileDownloader effective = downloader ?? ModelFileDownloader();
  yield* effective.downloadAll(
    files: <DownloadableModelFile>[pkg],
    targetDir: dir,
    // 包只是中转，抽完就删。判据用「解出来的 DLL 在不在」而不是「包在不在」，
    // 否则删了包下次又会重下一遍。
    isReady: (File _) => File(p.join(dir.path, 'onnxruntime.dll'))
        .existsSync(),
  );

  final File archiveFile = File(p.join(dir.path, pkg.fileName));
  if (archiveFile.existsSync()) {
    final Uint8List bytes = await archiveFile.readAsBytes();
    verifyOrtPackage(bytes);
    extractOrtNative(bytes, rid: rid, target: dir);
    await archiveFile.delete();
  }

  final String dll = p.join(dir.path, 'onnxruntime.dll');
  final (_, String? failure) = OrtRuntime.probeCandidate(dll);
  if (failure != null) {
    throw OrtProvisionCorrupt('装好的运行时仍不可用（$dll）：$failure');
  }
  OrtRuntime.managedRuntimeDir = dir.path;
}

/// 把根 isolate 解析出的托管运行时目录装进后台 isolate。
///
/// [OrtRuntime.managedRuntimeDir] 是**每个 isolate 各一份**的静态字段：根
/// isolate 下好库、写好路径，后台推理 isolate 那边仍然是 null，于是重新解析
/// 候选、又撞回系统目录里的旧 ORT。真机实测就是这么炸的——下载明明成功，
/// 加载还是报「1.17.1 不支持 API 版本 22」。
///
/// 所以路径必须显式过边界，走 `AsrIsolateBackend` 的 bootstrap 通道
/// （顶层函数 + 可发送参数，闭包过不去）。
void adoptOrtManagedRuntimeDir(Object arg) {
  if (arg is! String || arg.trim().isEmpty) return;
  OrtRuntime.managedRuntimeDir = arg;
}

/// 校验下下来的包。长度先看是因为它便宜且能立刻定性「下歪了/被截断」；
/// 摘要才是真判据。
void verifyOrtPackage(
  Uint8List bytes, {
  int expectedBytes = kOrtPackageBytes,
  String expectedSha256 = kOrtPackageSha256,
}) {
  if (bytes.length != expectedBytes) {
    throw OrtProvisionCorrupt('包长度 ${bytes.length} 与预期 $expectedBytes 不符');
  }
  final String digest = sha256.convert(bytes).toString();
  if (digest != expectedSha256) {
    throw OrtProvisionCorrupt('包 sha256 $digest 与预期 $expectedSha256 不符');
  }
}

/// 把 `runtimes/<rid>/native/` 下需要的 DLL 抽到 [target]（平铺，不带目录层级）。
void extractOrtNative(
  Uint8List bytes, {
  required String rid,
  required Directory target,
}) {
  final Archive archive = ZipDecoder().decodeBytes(bytes);
  for (final String name in kOrtPackageNativeFiles) {
    final String entryPath = 'runtimes/$rid/native/$name';
    final ArchiveFile? entry = archive.findFile(entryPath);
    if (entry == null) {
      throw OrtProvisionCorrupt('包里没有 $entryPath');
    }
    File(p.join(target.path, name))
        // [Hibiki patch] `ArchiveFile.readBytes()` 是 archive 4.x 才有的 API，
        // 而本仓全仓钉 archive ^3.6.1（升 4 是一次跨 76 个文件的迁移：12+ 处
        // `package:archive/archive_io.dart` 在 4.x 已被移除，多处 `entry.content`
        // 也要改写）。3.x 的等价物是 `content`，读出来同样是 List<int>。
        // 清理条件：上游把这行换成 3/4 通吃的写法、或把 archive 约束放宽到
        // `>=3.6.1 <5.0.0` 之后，删掉本补丁目录即可（sha 一变补丁自动跳过并告警）。
        .writeAsBytesSync((entry.content as List<int>?) ?? <int>[]);
  }
}

/// 包里的一个可下载文件（给 [ModelFileDownloader] 的适配）。
class _OrtPackage implements DownloadableModelFile {
  _OrtPackage(this.url);

  @override
  final String url;

  @override
  String get fileName => p.basename(Uri.parse(url).path);

  @override
  int get expectedBytes => kOrtPackageBytes;
}
