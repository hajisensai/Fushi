/// 模型目录（选择 + 自带包）的组装规则、本地目录识别、平台适配度，以及后台
/// isolate 那侧真的能收到同一份注册表。
///
/// 这几条错了都不会报错，只会**静默出乱码或跑错模型**，所以逐条钉死。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_asr_core/asr_core.dart';

import 'package:fushi/src/asr_host/asr_host.dart';
import 'package:fushi/src/asr_host/asr_model_catalog.dart';

void main() {
  group('buildAsrModelRegistry', () {
    test('空目录：每种内置语言的默认包与内置表逐字相同', () {
      final AsrModelRegistry registry =
          buildAsrModelRegistry(AsrModelCatalog.empty);
      final AsrModelRegistry builtin = AsrModelRegistry.builtin();
      for (final AsrLanguage language in AsrLanguage.values) {
        expect(
          registry.packForLanguage(language)?.id,
          builtin.packForLanguage(language)?.id,
          reason: '${language.tag} 的默认模型变了',
        );
      }
    });

    test('Omnilingual 扩语言版沿用同一个 id（换语言选它不会重下 4 GB）', () {
      final List<AsrModelPack> packs = fushiAsrBasePacks();
      final AsrModelPack omni = packs.firstWhere(
        (AsrModelPack p) => p.id == kAsrOmnilingualPack.id,
      );
      expect(omni.languages, contains(AsrLanguage.japanese));
      expect(omni.languages, contains(AsrLanguage.english));
      // 位置必须还在末尾：排到前面就会顶掉那 8 种语言的默认 transducer 包。
      expect(packs.last.id, kAsrOmnilingualPack.id);
    });

    test('给日语选 Omnilingual：只有日语变，英语等其余语言不受影响', () {
      final AsrModelCatalog catalog = AsrModelCatalog.empty
          .withChoice(AsrLanguage.japanese, kAsrOmnilingualPack.id);
      final AsrModelRegistry registry = buildAsrModelRegistry(catalog);

      expect(
        registry.packForLanguage(AsrLanguage.japanese)?.id,
        kAsrOmnilingualPack.id,
      );
      // 这条是整套设计的理由：多语言包被整个提到最前会顺带改掉每一种语言。
      expect(
        registry.packForLanguage(AsrLanguage.english)?.id,
        kAsrEnglishPack.id,
      );
      expect(
        registry.packForLanguage(AsrLanguage.mandarin)?.id,
        kAsrMandarinPack.id,
      );
      // 德语本来就归 Omnilingual，仍然是它。
      expect(
        registry.packForLanguage(AsrLanguage.german)?.id,
        kAsrOmnilingualPack.id,
      );
    });

    test('选择被撤销后回到默认', () {
      final AsrModelCatalog catalog = AsrModelCatalog.empty
          .withChoice(AsrLanguage.japanese, kAsrOmnilingualPack.id)
          .withChoice(AsrLanguage.japanese, null);
      expect(
        buildAsrModelRegistry(catalog)
            .packForLanguage(AsrLanguage.japanese)
            ?.id,
        kAsrJapanesePack.id,
      );
    });

    test('自带包：接进来不改默认，被选中才生效', () {
      final AsrModelPack mine = _fakePack('custom-mine', AsrLanguage.japanese);
      final AsrModelCatalog added = AsrModelCatalog.empty.withCustomPack(mine);
      expect(
        buildAsrModelRegistry(added).packForLanguage(AsrLanguage.japanese)?.id,
        kAsrJapanesePack.id,
        reason: '接入一个包不该悄悄顶掉默认模型',
      );

      final AsrModelCatalog chosen =
          added.withChoice(AsrLanguage.japanese, mine.id);
      expect(
        buildAsrModelRegistry(chosen).packForLanguage(AsrLanguage.japanese)?.id,
        mine.id,
      );
    });

    test('自带包与内置同 id：就地覆盖内容，不改谁是默认', () {
      final AsrModelPack shadow =
          _fakePack(kAsrJapanesePack.id, AsrLanguage.japanese, name: '我的日语');
      final AsrModelRegistry registry = buildAsrModelRegistry(
        AsrModelCatalog.empty.withCustomPack(shadow),
      );
      final AsrModelPack? resolved =
          registry.packForLanguage(AsrLanguage.japanese);
      expect(resolved?.id, kAsrJapanesePack.id);
      expect(resolved?.displayName, '我的日语');
      // 同 id 不能变成两个包（磁盘目录同名，设置页会画出两行同名模型）。
      expect(
        registry.packs.where((AsrModelPack p) => p.id == kAsrJapanesePack.id),
        hasLength(1),
      );
    });

    test('移除自带包时把指向它的选择一起清掉', () {
      final AsrModelPack mine = _fakePack('custom-mine', AsrLanguage.japanese);
      final AsrModelCatalog catalog = AsrModelCatalog.empty
          .withCustomPack(mine)
          .withChoice(AsrLanguage.japanese, mine.id)
          .withoutCustomPack(mine.id);
      expect(catalog.choices, isEmpty);
      expect(
        buildAsrModelRegistry(catalog)
            .packForLanguage(AsrLanguage.japanese)
            ?.id,
        kAsrJapanesePack.id,
      );
    });

    test('选中的包不服务那门语言：忽略这条选择，回落默认', () {
      final AsrModelPack enOnly = _fakePack('custom-en', AsrLanguage.english);
      final AsrModelCatalog catalog = AsrModelCatalog.empty
          .withCustomPack(enOnly)
          .withChoice(AsrLanguage.japanese, enOnly.id);
      expect(
        buildAsrModelRegistry(catalog)
            .packForLanguage(AsrLanguage.japanese)
            ?.id,
        kAsrJapanesePack.id,
      );
    });
  });

  group('asrModelChoicesFor', () {
    test('日语能选内置包与 Omnilingual，第一项是当前生效的那个', () {
      final AsrModelRegistry registry =
          buildAsrModelRegistry(AsrModelCatalog.empty);
      final List<AsrModelPack> choices =
          asrModelChoicesFor(AsrLanguage.japanese, registry);
      expect(choices.first.id, kAsrJapanesePack.id);
      expect(
        choices.map((AsrModelPack p) => p.id),
        contains(kAsrOmnilingualPack.id),
      );
    });

    test('选中后第一项就是选中的那个，且不出现重复 id', () {
      final AsrModelRegistry registry = buildAsrModelRegistry(
        AsrModelCatalog.empty
            .withChoice(AsrLanguage.japanese, kAsrOmnilingualPack.id),
      );
      final List<AsrModelPack> choices =
          asrModelChoicesFor(AsrLanguage.japanese, registry);
      expect(choices.first.id, kAsrOmnilingualPack.id);
      expect(
        choices.map((AsrModelPack p) => p.id).toSet(),
        hasLength(choices.length),
      );
    });
  });

  group('asrModelFitFor', () {
    test('内置 transducer 包全是轻量档', () {
      expect(
        asrModelFitFor(kAsrJapanesePack, mobile: true),
        AsrModelFit.light,
      );
      expect(
        asrModelFitFor(kAsrEnglishPack, mobile: false),
        AsrModelFit.light,
      );
    });

    test('Omnilingual 1B：桌面是「大模型」，手机上要明说很慢', () {
      expect(
        asrModelFitFor(kAsrOmnilingualPack, mobile: false),
        AsrModelFit.desktop,
      );
      expect(
        asrModelFitFor(kAsrOmnilingualPack, mobile: true),
        AsrModelFit.heavyOnMobile,
      );
    });
  });

  group('AsrModelCatalog JSON', () {
    test('往返：自带包与选择都原样回来', () {
      final AsrModelCatalog before = AsrModelCatalog.empty
          .withCustomPack(_fakePack('custom-mine', AsrLanguage.japanese))
          .withChoice(AsrLanguage.japanese, 'custom-mine');
      final AsrModelCatalog after = AsrModelCatalog.fromJson(
        jsonDecode(jsonEncode(before.toJson())) as Object?,
      );
      expect(after.choices, before.choices);
      expect(after.customPacks.single.id, 'custom-mine');
      expect(
        after.customPacks.single.languages.single.tag,
        AsrLanguage.japanese.tag,
      );
    });

    test('配错了当场抛，不静默跳过', () {
      expect(
        () => AsrModelCatalog.fromJson(<String, Object?>{'packs': 3}),
        throwsFormatException,
      );
    });
  });

  group('scanLocalAsrModelDirectory', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('asr_local_model_');
    });
    tearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    void write(String name) => File('${dir.path}${Platform.pathSeparator}$name')
        .writeAsBytesSync(<int>[1, 2, 3]);

    AsrLocalModelScan scan() => scanLocalAsrModelDirectory(
          dir: dir,
          displayName: '我的模型',
          languages: <AsrLanguage>[AsrLanguage.japanese],
        );

    test('transducer 三件套：认出来，两个变体角色都齐', () {
      write('tokens.txt');
      write('encoder-epoch-99-avg-1.onnx');
      write('decoder-epoch-99-avg-1.onnx');
      write('joiner-epoch-99-avg-1.onnx');
      final AsrLocalModelScan result = scan();
      expect(result, isA<AsrLocalModelFound>());
      final AsrModelPack pack = (result as AsrLocalModelFound).pack;
      expect(pack.architecture, AsrModelArchitecture.transducer);
      expect(pack.id, startsWith(kAsrCustomPackIdPrefix));
      // 两个变体都要能算出全套文件——缺一个角色 plan() 就会抛 StateError。
      for (final AsrEncoderVariant variant in AsrEncoderVariant.values) {
        expect(pack.filesFor(variant), isNotEmpty);
      }
    });

    test('只有 int8 导出：fp32 角色指向同一个文件，不会因为缺角色炸掉', () {
      write('tokens.txt');
      write('encoder-epoch-99-avg-1.int8.onnx');
      write('decoder-epoch-99-avg-1.int8.onnx');
      write('joiner-epoch-99-avg-1.int8.onnx');
      final AsrModelPack pack = (scan() as AsrLocalModelFound).pack;
      expect(
        pack.fileForRole(AsrModelRole.encoderFp32).fileName,
        pack.fileForRole(AsrModelRole.encoderInt8).fileName,
      );
      expect(pack.filesFor(AsrEncoderVariant.fp32), isNotEmpty);
    });

    test('单个 CTC 模型：按 ctc 认，blank 记号照传', () {
      write('tokens.txt');
      write('model.onnx');
      final AsrModelPack pack = (scanLocalAsrModelDirectory(
        dir: dir,
        displayName: 'ctc',
        languages: <AsrLanguage>[AsrLanguage.japanese],
        blankToken: '<s>',
      ) as AsrLocalModelFound)
          .pack;
      expect(pack.architecture, AsrModelArchitecture.ctc);
      expect(pack.blankToken, '<s>');
    });

    test('silero_vad 不在目录里时补内置那份，不算缺文件', () {
      write('tokens.txt');
      write('model.onnx');
      final AsrModelPack pack = (scan() as AsrLocalModelFound).pack;
      expect(
        pack.fileForRole(AsrModelRole.vad).fileName,
        kAsrVadFile.fileName,
      );
    });

    test('目录里有 silero_vad 时用它，且不会被当成 CTC 模型', () {
      write('tokens.txt');
      write('model.onnx');
      write('silero_vad.onnx');
      final AsrModelPack pack = (scan() as AsrLocalModelFound).pack;
      expect(pack.fileForRole(AsrModelRole.vad).url, startsWith('file:'));
      expect(
        pack.fileForRole(AsrModelRole.ctcModelFp32).fileName,
        'model.onnx',
      );
    });

    test('缺 tokens.txt / 缺模型 / 只有 encoder：各报各的原因', () {
      write('model.onnx');
      expect(
        (scan() as AsrLocalModelRejected).problem,
        AsrLocalModelProblem.missingTokens,
      );

      write('tokens.txt');
      File('${dir.path}${Platform.pathSeparator}model.onnx').deleteSync();
      expect(
        (scan() as AsrLocalModelRejected).problem,
        AsrLocalModelProblem.missingModel,
      );

      write('encoder-epoch-99-avg-1.onnx');
      expect(
        (scan() as AsrLocalModelRejected).problem,
        AsrLocalModelProblem.incompleteTransducer,
      );
    });
  });

  group('后台 isolate 装配', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('asr_bootstrap_');
    });
    tearDown(() async {
      asrModelRegistry = AsrModelRegistry.builtin();
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    File catalogFile(AsrModelCatalog catalog) =>
        File('${dir.path}${Platform.pathSeparator}asr_models.json')
          ..writeAsStringSync(jsonEncode(catalog.toJson()));

    test('bootstrap 现读目录文件装表（没有 token 也照装）', () {
      final File file = catalogFile(
        AsrModelCatalog.empty
            .withChoice(AsrLanguage.japanese, kAsrOmnilingualPack.id),
      );
      asrModelRegistry = AsrModelRegistry.builtin();

      fushiAsrIsolateBootstrap(<Object?>[null, file.path]);

      // 这条断言就是「后台不会按错模型静默解码」的全部依据：那侧的
      // asrModelPackFor(ja) 必须与主 isolate 规划时用的是同一个包。
      expect(asrModelPackFor(AsrLanguage.japanese).id, kAsrOmnilingualPack.id);
    });

    test('每次起 isolate 都现读：弹层打开后改的选择也能带过去', () {
      final File file = catalogFile(AsrModelCatalog.empty);
      fushiAsrIsolateBootstrap(<Object?>[null, file.path]);
      expect(asrModelPackFor(AsrLanguage.japanese).id, kAsrJapanesePack.id);

      // 用户在弹层里换了模型 → 先落盘。backend 的 bootstrapArg 是同一个路径，
      // 下一次起 isolate 读到的就是新的。
      catalogFile(
        AsrModelCatalog.empty
            .withChoice(AsrLanguage.japanese, kAsrOmnilingualPack.id),
      );
      fushiAsrIsolateBootstrap(<Object?>[null, file.path]);
      expect(asrModelPackFor(AsrLanguage.japanese).id, kAsrOmnilingualPack.id);
    });

    test('路径缺失 / 文件不存在时保持内置表，不清空成空表', () {
      asrModelRegistry = AsrModelRegistry.builtin();
      fushiAsrIsolateBootstrap(<Object?>[null]);
      expect(asrModelPackFor(AsrLanguage.japanese).id, kAsrJapanesePack.id);

      fushiAsrIsolateBootstrap(
        <Object?>[null, '${dir.path}${Platform.pathSeparator}nope.json'],
      );
      expect(asrModelPackFor(AsrLanguage.japanese).id, kAsrJapanesePack.id);
    });
  });

  group('本地模型的磁盘目录', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('asr_local_store_');
      for (final String name in <String>[
        'tokens.txt',
        'encoder-epoch-99-avg-1.onnx',
        'decoder-epoch-99-avg-1.onnx',
        'joiner-epoch-99-avg-1.onnx',
      ]) {
        File('${dir.path}${Platform.pathSeparator}$name')
            .writeAsBytesSync(<int>[1, 2, 3]);
      }
    });
    tearDown(() async {
      asrModelRegistry = AsrModelRegistry.builtin();
      if (dir.existsSync()) await dir.delete(recursive: true);
    });

    test('sourceUrl 是 file: 的包解析出用户那个文件夹；内置包不是', () {
      final AsrModelPack local = (scanLocalAsrModelDirectory(
        dir: dir,
        displayName: '我的模型',
        languages: <AsrLanguage>[AsrLanguage.japanese],
      ) as AsrLocalModelFound)
          .pack;
      expect(localAsrModelDirectory(local)?.path, dir.path);
      expect(localAsrModelDirectory(kAsrJapanesePack), isNull);
    });

    test('装配出的 store 指向用户文件夹，模型文件当场就位', () async {
      final AsrModelPack local = (scanLocalAsrModelDirectory(
        dir: dir,
        displayName: '我的模型',
        languages: <AsrLanguage>[AsrLanguage.japanese],
      ) as AsrLocalModelFound)
          .pack;
      final AsrModelCatalog catalog = AsrModelCatalog.empty
          .withCustomPack(local)
          .withChoice(AsrLanguage.japanese, local.id);
      asrModelRegistry = buildAsrModelRegistry(catalog);

      final AsrModelStore store = await openAsrModelStore(AsrLanguage.japanese);
      // 这条是「手动指定模型」能不能跑的全部依据：包里的 AsrModelStore.open()
      // 只按 pack.id 拼 <数据根>/asr_models/<id>，文件不在那儿就恒判未就绪、
      // 接着拿 file: URL 去发 HTTP 请求。
      expect(store.dir.path, dir.path);
      // 模型本体四个文件当场就位（未就绪的只剩 VAD——目录里没有就补下那 640 KB，
      // 见 scanLocalAsrModelDirectory 的文档）。
      for (final AsrModelRole role in <AsrModelRole>[
        AsrModelRole.encoderInt8,
        AsrModelRole.decoderInt8,
        AsrModelRole.joinerInt8,
        AsrModelRole.tokens,
      ]) {
        expect(
          store.fileFor(role).existsSync(),
          isTrue,
          reason: '$role 应该直接指到用户文件夹里的文件',
        );
      }
      expect(
        store.fileFor(AsrModelRole.vad).path,
        startsWith(dir.path),
        reason: 'VAD 也该落在用户文件夹，而不是 asr_models/<id>',
      );
    });

    test('vad 不在文件夹里时补的是内置直链，不是 file: URL', () {
      final AsrModelPack local = (scanLocalAsrModelDirectory(
        dir: dir,
        displayName: '我的模型',
        languages: <AsrLanguage>[AsrLanguage.japanese],
      ) as AsrLocalModelFound)
          .pack;
      expect(
        local.fileForRole(AsrModelRole.vad).url,
        startsWith('https://'),
      );
    });
  });

  group('接入时的 id 去重', () {
    test('同名不同目录：加后缀，先前那份与它的选择都不受影响', () {
      final AsrModelPack first = _fakeLocalPack('custom-model', '/tmp/a');
      final AsrModelPack second = _fakeLocalPack('custom-model', '/tmp/b');
      final ({AsrModelCatalog catalog, AsrModelPack pack}) added1 =
          AsrModelCatalog.empty.withLocalPack(first);
      final ({AsrModelCatalog catalog, AsrModelPack pack}) added2 =
          added1.catalog.withLocalPack(second);

      expect(added1.pack.id, 'custom-model');
      expect(added2.pack.id, 'custom-model-2');
      expect(added2.catalog.customPacks, hasLength(2));
      expect(
        added2.catalog.customPacks.map((AsrModelPack p) => p.sourceUrl).toSet(),
        <String>{'file:///tmp/a', 'file:///tmp/b'},
      );
    });

    test('同名同目录：视为重新接入，覆盖而不是加一份', () {
      final ({AsrModelCatalog catalog, AsrModelPack pack}) added =
          AsrModelCatalog.empty
              .withLocalPack(_fakeLocalPack('custom-model', '/tmp/a'))
              .catalog
              .withLocalPack(_fakeLocalPack('custom-model', '/tmp/a'));
      expect(added.pack.id, 'custom-model');
      expect(added.catalog.customPacks, hasLength(1));
    });
  });
}

/// 一个 sourceUrl 指向本地目录的假包（只用来验 id 去重规则）。
AsrModelPack _fakeLocalPack(String id, String dirPath) => AsrModelPack(
      languages: const <AsrLanguage>[AsrLanguage.japanese],
      id: id,
      displayName: id,
      sourceUrl: Uri.file(dirPath).toString(),
      files: const <AsrModelFile>[
        AsrModelFile(
          fileName: 'model.onnx',
          url: 'file:///tmp/model.onnx',
          expectedBytes: 10,
          role: AsrModelRole.ctcModelFp32,
        ),
        AsrModelFile(
          fileName: 'model.onnx',
          url: 'file:///tmp/model.onnx',
          expectedBytes: 10,
          role: AsrModelRole.ctcModelInt8,
        ),
        AsrModelFile(
          fileName: 'tokens.txt',
          url: 'file:///tmp/tokens.txt',
          expectedBytes: 10,
          role: AsrModelRole.tokens,
        ),
        kAsrVadFile,
      ],
      architecture: AsrModelArchitecture.ctc,
      blankToken: '<blk>',
    );

AsrModelPack _fakePack(
  String id,
  AsrLanguage language, {
  String name = '自带模型',
}) =>
    AsrModelPack(
      languages: <AsrLanguage>[language],
      id: id,
      displayName: name,
      sourceUrl: 'file:///tmp/$id',
      files: const <AsrModelFile>[
        AsrModelFile(
          fileName: 'encoder.onnx',
          url: 'file:///tmp/encoder.onnx',
          expectedBytes: 10,
          role: AsrModelRole.encoderFp32,
        ),
        AsrModelFile(
          fileName: 'encoder.onnx',
          url: 'file:///tmp/encoder.onnx',
          expectedBytes: 10,
          role: AsrModelRole.encoderInt8,
        ),
        AsrModelFile(
          fileName: 'decoder.onnx',
          url: 'file:///tmp/decoder.onnx',
          expectedBytes: 10,
          role: AsrModelRole.decoderFp32,
        ),
        AsrModelFile(
          fileName: 'decoder.onnx',
          url: 'file:///tmp/decoder.onnx',
          expectedBytes: 10,
          role: AsrModelRole.decoderInt8,
        ),
        AsrModelFile(
          fileName: 'joiner.onnx',
          url: 'file:///tmp/joiner.onnx',
          expectedBytes: 10,
          role: AsrModelRole.joinerFp32,
        ),
        AsrModelFile(
          fileName: 'joiner.onnx',
          url: 'file:///tmp/joiner.onnx',
          expectedBytes: 10,
          role: AsrModelRole.joinerInt8,
        ),
        AsrModelFile(
          fileName: 'tokens.txt',
          url: 'file:///tmp/tokens.txt',
          expectedBytes: 10,
          role: AsrModelRole.tokens,
        ),
        kAsrVadFile,
      ],
    );
