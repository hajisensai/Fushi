import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:fushi/src/media/manga/ocr/system_ocr_manga_service.dart';
import 'package:fushi/src/ocr/manga_ocr_folder_job.dart';
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart';
import 'package:path/path.dart' as p;

/// 系统 OCR 的可测面分两层：
/// 1. **平台契约**（parseSystemOcrPayload）——原生侧改一个字段名，这里立刻红。
///    否则那种失败在真机上看起来和「这页真没字」一模一样，没人查得出来。
/// 2. **整卷编排**——当前页优先、逐页落盘、缓存复用。这层与识别质量无关，
///    四个平台共用，因此值得用 fake platform 钉死。
class _FakePlatform implements SystemOcrPlatform {
  _FakePlatform({
    this.available = true,
    Map<String, List<SystemOcrTextLine>>? byPage,
  }) : _byPage = byPage ?? <String, List<SystemOcrTextLine>>{};

  final bool available;
  final Map<String, List<SystemOcrTextLine>> _byPage;
  final List<int> requestSizes = <int>[];

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<SystemOcrPageResult> recognize(
    Uint8List imageBytes, {
    required String language,
  }) async {
    requestSizes.add(imageBytes.length);
    // fake 图片字节的首字节当页号用，让每页拿到不同结果。
    final String key = String.fromCharCode(imageBytes.first);
    return SystemOcrPageResult(
      lines: _byPage[key] ?? const <SystemOcrTextLine>[],
      imageWidth: 1000,
      imageHeight: 1600,
    );
  }
}

void main() {
  group('平台契约 parseSystemOcrPayload', () {
    test('正常载荷：字段名与坐标原样落地', () {
      final SystemOcrPageResult result =
          parseSystemOcrPayload(<Object?, Object?>{
        'width': 800,
        'height': 1200,
        'lines': <Object?>[
          <Object?, Object?>{
            'text': 'こんにちは',
            'left': 10,
            'top': 20,
            'right': 60,
            'bottom': 200,
            'vertical': true,
          },
        ],
      });
      expect(result.imageWidth, 800);
      expect(result.imageHeight, 1200);
      expect(result.lines.single.text, 'こんにちは');
      expect(result.lines.single.rect, const Rect.fromLTRB(10, 20, 60, 200));
      expect(result.lines.single.isVertical, isTrue);
    });

    test('平台不表态竖排时按包围盒推断（错了也只影响 writing-mode）', () {
      final SystemOcrPageResult result =
          parseSystemOcrPayload(<Object?, Object?>{
        'width': 800,
        'height': 1200,
        'lines': <Object?>[
          <Object?, Object?>{
            'text': 'たて',
            'left': 0,
            'top': 0,
            'right': 20,
            'bottom': 200,
          },
          <Object?, Object?>{
            'text': 'よこ',
            'left': 0,
            'top': 0,
            'right': 200,
            'bottom': 20,
          },
        ],
      });
      expect(result.lines[0].isVertical, isTrue);
      expect(result.lines[1].isVertical, isFalse);
    });

    test('空文本、退化矩形一律丢弃，不产出点不中的透明框', () {
      final SystemOcrPageResult result =
          parseSystemOcrPayload(<Object?, Object?>{
        'width': 800,
        'height': 1200,
        'lines': <Object?>[
          <Object?, Object?>{
            'text': '   ',
            'left': 0,
            'top': 0,
            'right': 10,
            'bottom': 10,
          },
          <Object?, Object?>{
            'text': 'ok',
            'left': 10,
            'top': 10,
            'right': 10,
            'bottom': 40,
          },
        ],
      });
      expect(result.lines, isEmpty);
    });

    test('图片尺寸缺失即报错：没有分母就没法映射回页图', () {
      expect(
        () => parseSystemOcrPayload(<Object?, Object?>{'width': 0, 'height': 0}),
        throwsA(isA<SystemOcrUnavailableException>()),
      );
    });

    // 模型由 Google Play 服务保管（unbundled ML Kit），可能还在下、或本机没有 GMS。
    // 这跟「这张图识别失败」是两回事：前者该提示等待或换引擎，后者才该怀疑图片。
    // 两者塌成同一个错误码的话，用户看到「识别失败」会去查错方向。
    test('模型未就绪单独成一类，不冒充识别失败', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const MethodChannel channel =
          MethodChannel('test.fushi/system_ocr_unavailable');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(
          code: 'MODEL_UNAVAILABLE',
          message: 'Waiting for the text recognition model to be downloaded',
        );
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      const MethodChannelSystemOcr platform =
          MethodChannelSystemOcr(channel: channel);
      await expectLater(
        () => platform.recognize(Uint8List(0), language: 'ja'),
        throwsA(isA<SystemOcrUnavailableException>()),
        reason: '模型未就绪必须报成「不可用」，让上层去提示等待/换引擎',
      );
    });

    test('真正的识别失败不被冒充成「不可用」', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const MethodChannel channel =
          MethodChannel('test.fushi/system_ocr_failed');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(code: 'RECOGNIZE_FAILED', message: 'boom');
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      const MethodChannelSystemOcr platform =
          MethodChannelSystemOcr(channel: channel);
      await expectLater(
        () => platform.recognize(Uint8List(0), language: 'ja'),
        throwsA(isA<PlatformException>()),
        reason: '识别失败原样上抛；被吞成 Unavailable 就等于把两类失败又合回一类',
      );
    });

    test('数字用字符串回传也能吃下（平台侧 JSON 化的常见走样）', () {
      final SystemOcrPageResult result =
          parseSystemOcrPayload(<Object?, Object?>{
        'width': '800',
        'height': '1200',
        'lines': <Object?>[
          <Object?, Object?>{
            'text': 'あ',
            'left': '1',
            'top': '2',
            'right': '30',
            'bottom': '40',
          },
        ],
      });
      expect(result.imageWidth, 800);
      expect(result.lines.single.rect.right, 30);
    });
  });

  group('buildSystemOcrPage', () {
    test('一行一个 block，坐标 clamp 进页内', () {
      final MokuroImage page = buildSystemOcrPage(
        'p001.jpg',
        SystemOcrPageResult(
          imageWidth: 100,
          imageHeight: 200,
          lines: <SystemOcrTextLine>[
            const SystemOcrTextLine(
              text: 'あい',
              // 右下越界：平台偶尔给出超出图边的框。
              rect: Rect.fromLTRB(10, 20, 500, 900),
              isVertical: true,
            ),
          ],
        ),
      );
      expect(page.blocks.length, 1);
      expect(page.blocks.single.rectangle.right, 100);
      expect(page.blocks.single.rectangle.bottom, 200);
      expect(page.blocks.single.isVertical, isTrue);
      expect(page.blocks.single.lines, <String>['あい']);
      expect(page.blocks.single.fontSize, greaterThan(0),
          reason: 'font_size 为 0 会让透明文字层塌缩、整框点不中');
    });

    test('页尺寸原样透传（覆盖层按比例定位，尺寸错则全盘错位）', () {
      final MokuroImage page = buildSystemOcrPage(
        'p001.jpg',
        const SystemOcrPageResult(
          imageWidth: 1234,
          imageHeight: 5678,
          lines: <SystemOcrTextLine>[],
        ),
      );
      expect(page.size.width, 1234);
      expect(page.size.height, 5678);
      expect(page.url, 'p001.jpg');
    });
  });

  group('整卷编排', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('system_ocr_');
      for (int i = 0; i < 3; i++) {
        File(p.join(dir.path, 'p00$i.jpg'))
            .writeAsBytesSync(<int>[0x30 + i, 1, 2, 3]);
      }
    });

    // Windows 上后台任务当前页的 IO 未必在订阅取消的同一刻放手，临时目录会短暂
    // 被占用。重试删除，不让清理竞态伪装成被测行为的失败。
    tearDown(() async {
      for (int attempt = 0; attempt < 20 && dir.existsSync(); attempt++) {
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });

    _FakePlatform platformWithText() => _FakePlatform(
          byPage: <String, List<SystemOcrTextLine>>{
            '0': <SystemOcrTextLine>[
              const SystemOcrTextLine(
                text: 'ページ0',
                rect: Rect.fromLTRB(0, 0, 50, 200),
                isVertical: true,
              ),
            ],
            '1': <SystemOcrTextLine>[
              const SystemOcrTextLine(
                text: 'ページ1',
                rect: Rect.fromLTRB(0, 0, 50, 200),
                isVertical: true,
              ),
            ],
            '2': <SystemOcrTextLine>[
              const SystemOcrTextLine(
                text: 'ページ2',
                rect: Rect.fromLTRB(0, 0, 50, 200),
                isVertical: true,
              ),
            ],
          },
        );

    test('产出 manga.json：三页齐全、引擎标记为 system_ocr', () async {
      final SystemOcrMangaService service =
          SystemOcrMangaService(platform: platformWithText());
      final List<MangaOcrVolumeEvent> events = await service
          .ocrFolder(imageDirPath: dir.path, language: 'ja')
          .toList();

      final MangaOcrVolumeEvent last = events.last;
      expect(last.finished, isTrue);
      final MokuroPayload payload =
          parseMangaJson(File(last.mangaJsonPath!).readAsStringSync());
      expect(payload.images.length, 3);
      expect(payload.ocr?.engine, 'system_ocr');
      expect(
        payload.images.map((MokuroImage i) => i.blocks.single.lines.single),
        <String>['ページ0', 'ページ1', 'ページ2'],
      );
    });

    test('当前页优先：从 startPage 开始扫，绕回补前面的页', () async {
      final _FakePlatform platform = platformWithText();
      final SystemOcrMangaService service =
          SystemOcrMangaService(platform: platform);
      await service
          .ocrFolder(imageDirPath: dir.path, startPage: 2, language: 'ja')
          .toList();

      // 「点一下就查词」能成立全靠这条顺序：用户点的那一页必须最先识别。
      final String first = File(p.join(dir.path, 'p002.jpg'))
          .readAsBytesSync()
          .first
          .toString();
      expect(platform.requestSizes.length, 3);
      expect(first, isNotEmpty);
      final MokuroPayload payload = parseMangaJson(
        File(p.join(dir.path, kMangaOcrOutDirName, kMangaOcrOutputFileName))
            .readAsStringSync(),
      );
      expect(payload.images.length, 3, reason: '绕回后三页都要补齐');
    });

    test('第二次跑命中缓存，不再打平台一次', () async {
      final _FakePlatform first = platformWithText();
      await SystemOcrMangaService(platform: first)
          .ocrFolder(imageDirPath: dir.path, language: 'ja')
          .toList();
      expect(first.requestSizes.length, 3);

      final _FakePlatform second = platformWithText();
      await SystemOcrMangaService(platform: second)
          .ocrFolder(imageDirPath: dir.path, language: 'ja')
          .toList();
      expect(second.requestSizes, isEmpty,
          reason: '识别结果有 per-page 缓存，重跑不该再问平台一遍');
    });

    test('换语言不复用旧缓存（签名带语言）', () async {
      await SystemOcrMangaService(platform: platformWithText())
          .ocrFolder(imageDirPath: dir.path, language: 'ja')
          .toList();
      final _FakePlatform english = platformWithText();
      await SystemOcrMangaService(platform: english)
          .ocrFolder(imageDirPath: dir.path, language: 'en')
          .toList();
      expect(english.requestSizes.length, 3);
      expect(systemOcrEngineSignature('ja'),
          isNot(systemOcrEngineSignature('en')));
    });

    test('中途取消：已识别的页留在 per-page 缓存里，重跑只补没跑过的', () async {
      final _FakePlatform interrupted = platformWithText();
      final Stream<MangaOcrVolumeEvent> stream =
          SystemOcrMangaService(platform: interrupted)
              .ocrFolder(imageDirPath: dir.path, language: 'ja');
      // 收第一页进度后立刻断开订阅，模拟用户中途取消。
      final Completer<MangaOcrVolumeEvent> firstSeen =
          Completer<MangaOcrVolumeEvent>();
      final StreamSubscription<MangaOcrVolumeEvent> sub =
          stream.listen((MangaOcrVolumeEvent event) {
        if (!firstSeen.isCompleted) firstSeen.complete(event);
      });
      final MangaOcrVolumeEvent first = await firstSeen.future;
      expect(first.finished, isFalse);
      await sub.cancel();
      // 让后台把当前页的收尾跑完再断言——否则断的是一个还在动的状态。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final int beforeCancel = interrupted.requestSizes.length;
      expect(beforeCancel, greaterThan(0));
      expect(beforeCancel, lessThan(3), reason: '取消要真的止住后面的页');

      final _FakePlatform resumed = platformWithText();
      await SystemOcrMangaService(platform: resumed)
          .ocrFolder(imageDirPath: dir.path, language: 'ja')
          .toList();

      // 两次加起来正好识别三页：取消掉的那部分成果留在 per-page 缓存里，
      // 重跑只补没跑过的，没有一页被白识别两次。
      expect(beforeCancel + resumed.requestSizes.length, 3);
      final File output =
          File(p.join(dir.path, kMangaOcrOutDirName, kMangaOcrOutputFileName));
      expect(output.existsSync(), isTrue);
      final Map<String, Object?> decoded =
          jsonDecode(output.readAsStringSync()) as Map<String, Object?>;
      expect(decoded['pages'], isA<List<Object?>>());
    });

    test('空图片目录报错，而不是产出一份空 manga.json', () async {
      final Directory empty =
          Directory.systemTemp.createTempSync('system_ocr_empty_');
      addTearDown(() => empty.deleteSync(recursive: true));
      await expectLater(
        SystemOcrMangaService(platform: _FakePlatform())
            .ocrFolder(imageDirPath: empty.path, language: 'ja')
            .toList(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('可用性', () {
    test('平台说不可用就是不可用——引擎选项据此置灰，不能假装能跑', () async {
      expect(
        await SystemOcrMangaService(platform: _FakePlatform(available: false))
            .isAvailable(),
        isFalse,
      );
      expect(
        await SystemOcrMangaService(platform: _FakePlatform()).isAvailable(),
        isTrue,
      );
    });
  });

  group('auto 回退链', () {
    MangaOcrEngineCapability cap(MangaOcrEngineId id, bool ready) =>
        MangaOcrEngineCapability(
          id: id,
          supported: true,
          ready: ready,
          requiresNetwork: false,
          uploadsImages: false,
          supportsIncremental: true,
        );

    test('本地模型就绪时优先本地（系统 OCR 识别竖排明显更弱）', () {
      expect(
        resolveMangaOcrEngine(
          preference: MangaOcrEnginePreference.auto,
          hasExistingMetadata: false,
          capabilities: <MangaOcrEngineCapability>[
            cap(MangaOcrEngineId.localOnnx, true),
            cap(MangaOcrEngineId.systemOcr, true),
          ],
        ),
        MangaOcrEngineId.localOnnx,
      );
    });

    test('本地模型没下但设备自带可用 → 选系统 OCR，而不是干等用户去下 470MB', () {
      expect(
        resolveMangaOcrEngine(
          preference: MangaOcrEnginePreference.auto,
          hasExistingMetadata: false,
          capabilities: <MangaOcrEngineCapability>[
            cap(MangaOcrEngineId.localOnnx, false),
            cap(MangaOcrEngineId.systemOcr, true),
            cap(MangaOcrEngineId.externalMokuro, true),
          ],
        ),
        MangaOcrEngineId.systemOcr,
      );
    });

    test('auto 依旧绝不选 Google Lens（不自作主张上传）', () {
      expect(
        resolveMangaOcrEngine(
          preference: MangaOcrEnginePreference.auto,
          hasExistingMetadata: false,
          capabilities: <MangaOcrEngineCapability>[
            cap(MangaOcrEngineId.localOnnx, false),
            cap(MangaOcrEngineId.systemOcr, false),
            cap(MangaOcrEngineId.googleLens, true),
          ],
        ),
        isNull,
      );
    });

    test('偏好键与枚举双向一致（存量偏好不能因新引擎而错位）', () {
      for (final MangaOcrEnginePreference preference
          in MangaOcrEnginePreference.values) {
        expect(
          MangaOcrEnginePreferenceKey.fromKey(preference.key),
          preference,
          reason: '${preference.key} 的往返解析必须回到自己',
        );
      }
      expect(
        MangaOcrEnginePreferenceKey.fromKey('system_ocr'),
        MangaOcrEnginePreference.systemOcr,
      );
    });
  });
}
