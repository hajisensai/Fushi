// BUG-5508（反馈 U9mp42sAAL / GkWWJ02V3S / 2ML9ck1-Kj）：Android 3.4.0 连环
// `java.lang.OutOfMemoryError`（Java 堆 256 MB 用尽）。vendored flutter_onnxruntime
// 的 Android 端原先经 StandardMessageCodec 搬张量：输入解码成 FloatArray、ORT 再拷进
// Android 上算 Java 堆的 direct buffer（存活到张量释放），每次读输出是
// getFloatBuffer 拷贝 + FloatArray + 成倍扩容的 ByteArrayOutputStream + 回包 buffer，
// 每个张量在 Java 堆里存 2～5 份。崩溃栈落在 `OrtUtil.prepareBuffer` 与
// `StandardMessageCodec.writeFloat`。
//
// 修法（PATCHES.md delta 19）：Android 上数值张量只过地址——输入在 Dart 侧 malloc，
// 插件用 JNI NewDirectByteBuffer 包成 ORT 零拷贝读的 direct buffer；输出由插件给出 ORT
// 张量内存的地址，Dart 直接拷进 typed list。这里走真实的 method channel 路径（mock 的
// 是 native 回包），钉住：Android 上大张量一个元素都不经过 channel 的 list 编码；内存在
// releaseOrtValue 之前一直有效；其它平台不变。Kotlin / JNI / gradle 那半由源码守卫钉住。
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/onnx/onnx_inference_ort.dart';
import 'package:fushi_asr_core/asr_core.dart'
    show OnnxExecutionProvider, OnnxSession, OnnxTensor;

const MethodChannel _channel = MethodChannel('flutter_onnxruntime');

/// 模拟 Android 插件：按地址收发张量、记下每次调用。
class _FakeAndroidPlugin {
  final List<MethodCall> calls = <MethodCall>[];

  /// valueId -> 插件侧那份张量（输入：Dart 给的地址；输出：插件自己的内存）。
  final Map<
    String,
    ({int address, int byteLength, String type, List<int> shape})
  >
  values =
      <String, ({int address, int byteLength, String type, List<int> shape})>{};

  /// releaseOrtValue 那一刻读到的输入内容（证明释放前 Dart 没先 free）。
  final Map<String, Uint8List> bytesAtRelease = <String, Uint8List>{};

  /// 插件自己持有的输出内存（测试结束时释放）。
  final List<Pointer<Uint8>> ownedOutputs = <Pointer<Uint8>>[];

  int _next = 0;

  String addOutput(TypedData data, String type, List<int> shape) {
    final Pointer<Uint8> p = malloc<Uint8>(data.lengthInBytes);
    p.asTypedList(data.lengthInBytes).setAll(0, data.buffer.asUint8List());
    ownedOutputs.add(p);
    final String id = 'out${_next++}';
    values[id] = (
      address: p.address,
      byteLength: data.lengthInBytes,
      type: type,
      shape: shape,
    );
    return id;
  }

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    final Map<Object?, Object?> args =
        (call.arguments as Map<Object?, Object?>?) ?? <Object?, Object?>{};
    switch (call.method) {
      case 'createOrtValueFromAddress':
        final String id = 'in${_next++}';
        values[id] = (
          address: args['address']! as int,
          byteLength: args['byteLength']! as int,
          type: args['sourceType']! as String,
          shape: List<int>.from(args['shape']! as List<Object?>),
        );
        return <String, Object?>{
          'valueId': id,
          'dataType': args['sourceType'],
          'shape': args['shape'],
        };
      case 'getOrtValueAddress':
        final v = values[args['valueId']]!;
        if (v.type == 'float16') return null;
        return <String, Object?>{
          'address': v.address,
          'byteLength': v.byteLength,
          'dataType': v.type,
          'shape': v.shape,
        };
      case 'getOrtValueData':
        return <String, Object?>{
          'data': Float32List.fromList(<double>[0.5, 1.5]),
          'shape': <int>[2],
        };
      case 'releaseOrtValue':
        final String id = args['valueId']! as String;
        final v = values.remove(id);
        if (v != null && id.startsWith('in')) {
          bytesAtRelease[id] = Uint8List.fromList(
            Pointer<Uint8>.fromAddress(v.address).asTypedList(v.byteLength),
          );
        }
        return null;
      case 'createSession':
        return <String, Object?>{
          'sessionId': 's1',
          'inputNames': <String>['x'],
          'outputNames': <String>['y', 'len'],
        };
      case 'runInference':
        final String y = addOutput(
          Float32List.fromList(List<double>.generate(6, (int i) => i * 0.25)),
          'float32',
          <int>[1, 6],
        );
        final String len = addOutput(
          Int64List.fromList(<int>[6]),
          'int64',
          <int>[1],
        );
        return <String, Object?>{
          'y': <Object?>[
            y,
            'float32',
            <int>[1, 6],
          ],
          'len': <Object?>[
            len,
            'int64',
            <int>[1],
          ],
        };
      case 'createOrtValue':
        final String id = 'list${_next++}';
        return <String, Object?>{
          'valueId': id,
          'dataType': args['sourceType'],
          'shape': args['shape'],
        };
    }
    throw MissingPluginException(call.method);
  }

  Iterable<String> get methods => calls.map((MethodCall c) => c.method);

  void dispose() {
    for (final Pointer<Uint8> p in ownedOutputs) {
      malloc.free(p);
    }
  }
}

String _repoFile(String relative) {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    final File f = File('${dir.path}/$relative');
    if (f.existsSync()) return f.readAsStringSync();
    dir = dir.parent;
  }
  fail('找不到 $relative（从 ${Directory.current.path} 向上）');
}

const String _plugin = 'third_party/flutter_onnxruntime/android';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAndroidPlugin plugin;

  setUp(() {
    plugin = _FakeAndroidPlugin();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, plugin.handle);
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    plugin.dispose();
  });

  group('Android：张量只过地址', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);

    test('float32 输入按地址交给插件，channel 上没有数据列表', () async {
      final Float32List data = Float32List.fromList(<double>[1, 2.5, -3, 4]);
      final OrtValue value = await OrtValue.fromList(data, <int>[2, 2]);

      expect(plugin.methods, <String>['createOrtValueFromAddress']);
      final Map<Object?, Object?> args =
          plugin.calls.single.arguments as Map<Object?, Object?>;
      expect(args.containsKey('data'), isFalse);
      expect(args['byteLength'], 16);
      expect(args['shape'], <int>[2, 2]);
      final Float32List seen = Pointer<Float>.fromAddress(
        args['address']! as int,
      ).asTypedList(4);
      expect(seen, data, reason: '插件按地址读到的必须就是这份输入');

      await value.dispose();
      expect(
        plugin.bytesAtRelease[value.id],
        data.buffer.asUint8List(),
        reason: 'releaseOrtValue 之前那块内存必须还活着（ORT 张量直接读它）',
      );
    });

    test('int64 / int32 / uint8 输入也走地址', () async {
      final List<OrtValue> values = <OrtValue>[
        await OrtValue.fromList(Int64List.fromList(<int>[1 << 40, 7]), <int>[
          2,
        ]),
        await OrtValue.fromList(Int32List.fromList(<int>[3, 4, 5]), <int>[3]),
        await OrtValue.fromList(Uint8List.fromList(<int>[9, 8]), <int>[2]),
      ];
      expect(plugin.methods, everyElement('createOrtValueFromAddress'));
      final List<int> lengths = plugin.calls
          .map(
            (MethodCall c) =>
                (c.arguments as Map<Object?, Object?>)['byteLength']! as int,
          )
          .toList();
      expect(lengths, <int>[16, 12, 2]);
      for (final OrtValue v in values) {
        await v.dispose();
      }
    });

    test('插件拒绝建张量时异常照常抛出', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (MethodCall call) async {
            throw PlatformException(
              code: 'TENSOR_CREATION_ERROR',
              message: 'bad shape',
            );
          });
      await expectLater(
        OrtValue.fromList(Float32List(4), <int>[4]),
        throwsA(isA<PlatformException>()),
      );
    });

    test('OnnxSession.run：输入输出都不经 list 编码，结果正确且全部释放', () async {
      final OnnxSession session = await OrtOnnxSessionFactory().createSession(
        'model.onnx',
        providers: const <OnnxExecutionProvider>[OnnxExecutionProvider.cpu],
      );
      final Map<String, OnnxTensor> out = await session.run(
        <String, OnnxTensor>{
          'x': OnnxTensor.float32(
            Float32List.fromList(<double>[1, 2, 3]),
            <int>[1, 3],
          ),
        },
      );

      expect(
        plugin.methods.where(
          (String m) => m == 'createOrtValue' || m == 'getOrtValueData',
        ),
        isEmpty,
        reason: '数值张量在 Android 上不允许再走 StandardMessageCodec 搬数据',
      );
      expect(
        out['y']!.floatData,
        List<double>.generate(6, (int i) => i * 0.25),
      );
      expect(out['y']!.shape, <int>[1, 6]);
      expect(out['len']!.floatData, <double>[6]);
      expect(plugin.values, isEmpty, reason: '输入与输出张量都必须 release');
    });

    test('不能按原始字节读的类型（float16）回落到 getOrtValueData', () async {
      final String id = plugin.addOutput(Uint16List(2), 'float16', <int>[2]);
      final OrtValue value = OrtValue.fromMap(<String, dynamic>{
        'valueId': id,
        'dataType': 'float16',
        'shape': <int>[2],
      });
      expect(await value.asFlattenedList(), <double>[0.5, 1.5]);
      expect(plugin.methods, <String>['getOrtValueData']);
    });

    test('多维输出 asList 按 shape 重排', () async {
      final String id = plugin.addOutput(
        Int32List.fromList(<int>[1, 2, 3, 4, 5, 6]),
        'int32',
        <int>[2, 3],
      );
      final OrtValue value = OrtValue.fromMap(<String, dynamic>{
        'valueId': id,
        'dataType': 'int32',
        'shape': <int>[2, 3],
      });
      expect(await value.asList(), <List<int>>[
        <int>[1, 2, 3],
        <int>[4, 5, 6],
      ]);
      expect(plugin.methods, <String>['getOrtValueAddress']);
    });
  });

  test('非 Android 平台照旧走 list 路径', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final Float32List data = Float32List.fromList(<double>[1, 2]);
    await OrtValue.fromList(data, <int>[2]);
    expect(plugin.methods, <String>['createOrtValue']);
    expect(
      (plugin.calls.single.arguments as Map<Object?, Object?>)['data'],
      data,
    );
  });

  group('源码守卫：Android 原生那半', () {
    test('插件实现了按地址建 / 读张量，且走 NativeTensorMemory', () {
      final String kt = _repoFile(
        '$_plugin/src/main/kotlin/com/masicai/flutteronnxruntime/FlutterOnnxruntimePlugin.kt',
      );
      expect(kt, contains('"createOrtValueFromAddress" ->'));
      expect(kt, contains('"getOrtValueAddress" ->'));
      expect(kt, contains('NativeTensorMemory.wrapInput('));
      expect(kt, contains('NativeTensorMemory.dataAddress('));
    });

    test('NativeTensorMemory 零拷贝：JNI 包地址、读 ORT 自己的内存', () {
      final String kt = _repoFile(
        '$_plugin/src/main/kotlin/com/masicai/flutteronnxruntime/NativeTensorMemory.kt',
      );
      expect(kt, contains('System.loadLibrary("flutter_onnxruntime_jni")'));
      expect(kt, contains('getDeclaredMethod("getBuffer")'));
      expect(
        kt,
        isNot(contains('allocateDirect(')),
        reason: 'Android 上 allocateDirect 就是 Java 堆',
      );
      final String c = _repoFile(
        '$_plugin/src/main/cpp/native_tensor_memory.c',
      );
      expect(c, contains('NewDirectByteBuffer'));
      expect(c, contains('GetDirectBufferAddress'));
      expect(
        c,
        contains('Java_com_masicai_flutteronnxruntime_NativeTensorMemory_wrap'),
      );
      expect(
        c,
        contains(
          'Java_com_masicai_flutteronnxruntime_NativeTensorMemory_addressOf',
        ),
      );
    });

    test('gradle 编 JNI 库，R8 保住 JNI 名与反射的 getBuffer', () {
      final String gradle = _repoFile('$_plugin/build.gradle');
      expect(gradle, contains('path = "src/main/cpp/CMakeLists.txt"'));
      expect(gradle, contains('consumerProguardFiles "consumer-rules.pro"'));
      final String cmake = _repoFile('$_plugin/src/main/cpp/CMakeLists.txt');
      expect(cmake, contains('add_library(flutter_onnxruntime_jni SHARED'));
      final String rules = _repoFile('$_plugin/consumer-rules.pro');
      expect(rules, contains('NativeTensorMemory { native <methods>; }'));
      expect(rules, contains('private java.nio.ByteBuffer getBuffer();'));
    });
  });
}
