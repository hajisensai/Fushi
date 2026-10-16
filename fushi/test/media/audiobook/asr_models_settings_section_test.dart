import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi/src/asr_host/asr_model_downloads.dart';
import 'package:fushi/src/media/audiobook/asr_models_settings_section.dart';
import 'package:fushi/utils.dart';
import 'package:path/path.dart' as p;

/// 假服务：每种语言的就绪状态可编程；模型目录落在临时目录里，`deleteAll` 走真
/// 删除以拿到真实的释放字节数。
class _FakeService extends AsrTranscriptionService {
  _FakeService({required this.root, required this.readyByLanguage})
    : super(
        audioProfile: AsrAudioProfile.cleanSpeech,
        backend: const AsrIsolateBackend(buildFactory: _unusedOnnxFactory),

        openStore: (AsrLanguage l) async => AsrModelStore(
          Directory(p.join(root.path, asrModelPackFor(l).id)),
          asrModelPackFor(l),
        ),
        jobsRoot: () async => root,
      );

  final Directory root;
  final Map<AsrLanguage, bool> readyByLanguage;
  final List<AsrLanguage> downloadLanguages = <AsrLanguage>[];

  @override
  Future<AsrTranscribePlan> plan({
    required AsrLanguage language,
    required AsrAccelerationPreference preference,
  }) async {
    final bool ready = readyByLanguage[language] ?? false;
    return AsrTranscribePlan(
      language: language,
      variant: AsrEncoderVariant.int8,
      expectedProvider: OnnxExecutionProvider.cpu,
      modelStatus: AsrModelStatus(
        ready: ready,
        diskBytes: ready ? 4096 : 0,
        totalBytes: 4096,
        obtainedBytes: ready ? 4096 : 0,
      ),
    );
  }

  @override
  Stream<ModelDownloadEvent> downloadModel({
    required AsrLanguage language,
    required AsrEncoderVariant variant,
  }) async* {
    downloadLanguages.add(language);
    yield const ModelDownloadEvent(
      fileName: 'encoder.onnx',
      receivedBytes: 4096,
      totalBytes: 4096,
      done: true,
    );
    readyByLanguage[language] = true;
  }
}

/// 这几组用例都走进程内路径（`runInIsolate: false`）或只碰 UI，不会真起后台
/// isolate。真被调到说明用例走错了路径，直接炸比默默建个真后端好。
/// 假模型目录：就绪状态按**包 id** 编程（同一语言的几行互不串）；下载只记账
/// 并把该包置为就绪，`deleteAll` 继承真删除。
class _FakeStore extends AsrModelStore {
  _FakeStore(super.dir, super.pack, this.readyByPack, this.downloads);

  final Map<String, bool> readyByPack;
  final List<String> downloads;

  @override
  Future<AsrModelStatus> status(AsrEncoderVariant variant) async {
    final bool ready = readyByPack[pack.id] ?? false;
    return AsrModelStatus(
      ready: ready,
      diskBytes: ready ? 4096 : 0,
      totalBytes: 4096,
      obtainedBytes: ready ? 4096 : 0,
    );
  }

  @override
  Stream<ModelDownloadEvent> download(
    AsrEncoderVariant variant, {
    ModelFileDownloader? downloader,
  }) async* {
    downloads.add(pack.id);
    yield const ModelDownloadEvent(
      fileName: 'encoder.onnx',
      receivedBytes: 4096,
      totalBytes: 4096,
      done: true,
    );
    readyByPack[pack.id] = true;
  }
}

OnnxSessionFactory _unusedOnnxFactory() =>
    throw UnimplementedError('本用例不该在 isolate 里建 ONNX 后端');

void main() {
  late Directory tmp;
  Map<String, bool> readyByPack = <String, bool>{};
  List<String> downloads = <String>[];
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('asr_models_section_test_');
    readyByPack = <String, bool>{kAsrJapanesePack.id: true};
    downloads = <String>[];
  });
  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<AsrModelStore> openPackStore(AsrModelPack pack) async => _FakeStore(
    Directory(p.join(tmp.path, pack.id)),
    pack,
    readyByPack,
    downloads,
  );

  // 独立登记表：按包开假目录、不带 GPU 环境（不碰插件 / 数据根）。
  Widget section(AsrTranscriptionService service) => AsrModelsSettingsSection(
    service: service,
    showGpuRuntime: false,
    downloads: AsrModelDownloads(
      openPackStore: openPackStore,
      gpuRuntimeToDownload: () async => null,
    ),
  );

  Widget wrap(Widget child) {
    return ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      ),
    );
  }

  testWidgets('每个语言包一行：未下载的给下载按钮、已下载的给删除按钮', (WidgetTester tester) async {
    final _FakeService service = _FakeService(
      root: tmp,
      readyByLanguage: <AsrLanguage, bool>{
        AsrLanguage.japanese: true,
        AsrLanguage.english: false,
      },
    );
    await tester.pumpWidget(wrap(section(service)));
    await tester.pumpAndSettle();

    for (final AsrModelPack pack in kAsrModelPacks) {
      expect(find.text(pack.displayName), findsOneWidget);
    }
    // 可选包能直接点下载：非宽松许可必须写在行名里，下载前看得见。
    for (final AsrModelPack pack in kAsrOptionalModelPacks) {
      if (pack.license == null) continue;
      expect(
        find.text('${pack.displayName} · ${pack.license}'),
        findsOneWidget,
      );
    }
    // 日语已下载：副标题报占用，只有删除。
    expect(
      find.textContaining(
        t.asr_models_status_ready(size: FushiByteFormat.bytes(4096)),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(ValueKey<String>('asr-models-delete-${kAsrJapanesePack.id}')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        ValueKey<String>('asr-models-download-${kAsrJapanesePack.id}'),
      ),
      findsNothing,
    );
    // 日语之外的包都未下载：副标题各报需要多少，给下载。可选包（Kitsune）
    // 也是日语，但它是另一个包，不能照抄默认日语包的「已下载」。
    expect(
      find.textContaining(
        t.asr_models_status_missing(size: FushiByteFormat.bytes(4096)),
      ),
      findsNWidgets(kAsrModelPacks.length + kAsrOptionalModelPacks.length - 1),
    );
    for (final AsrModelPack pack in kAsrOptionalModelPacks) {
      expect(
        find.byKey(ValueKey<String>('asr-models-download-${pack.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey<String>('asr-models-delete-${pack.id}')),
        findsNothing,
      );
    }
    expect(
      find.byKey(ValueKey<String>('asr-models-download-${kAsrEnglishPack.id}')),
      findsOneWidget,
    );

    // 点英语的下载：service 收到英语，下载完变成已下载态。
    await tester.tap(
      find.byKey(ValueKey<String>('asr-models-download-${kAsrEnglishPack.id}')),
    );
    await tester.pumpAndSettle();
    expect(downloads, <String>[kAsrEnglishPack.id]);
    expect(
      find.byKey(ValueKey<String>('asr-models-delete-${kAsrEnglishPack.id}')),
      findsOneWidget,
    );
  });

  testWidgets('删除先弹二次确认；确认后真删目录并回报释放字节', (WidgetTester tester) async {
    final _FakeService service = _FakeService(
      root: tmp,
      readyByLanguage: <AsrLanguage, bool>{
        AsrLanguage.japanese: true,
        AsrLanguage.english: false,
      },
    );
    final Directory jaDir = Directory(p.join(tmp.path, kAsrJapanesePack.id))
      ..createSync(recursive: true);
    File(p.join(jaDir.path, 'tokens.txt')).writeAsStringSync('x' * 100);

    await tester.pumpWidget(wrap(section(service)));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey<String>('asr-models-delete-${kAsrJapanesePack.id}')),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.asr_models_delete_confirm_title), findsOneWidget);
    expect(jaDir.existsSync(), isTrue);

    // 取消：目录还在。
    await tester.tap(find.widgetWithText(TextButton, t.dialog_cancel));
    await tester.pumpAndSettle();
    expect(jaDir.existsSync(), isTrue);

    // 确认：目录被删。
    await tester.tap(
      find.byKey(ValueKey<String>('asr-models-delete-${kAsrJapanesePack.id}')),
    );
    await tester.pumpAndSettle();
    // deleteAll 有真实目录 IO（量目录 + 递归删），要在 runAsync 里让真事件循环跑完。
    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(
          ValueKey<String>('asr-models-delete-confirm-${kAsrJapanesePack.id}'),
        ),
      );
      for (int i = 0; i < 50 && jaDir.existsSync(); i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(jaDir.existsSync(), isFalse);
  });
}
