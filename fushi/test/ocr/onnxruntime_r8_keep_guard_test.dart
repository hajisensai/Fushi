import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1780 守卫：Android release 的 R8 规则必须以**原名**保住 ONNX Runtime 的
/// JNI 反查类。
///
/// 为什么需要这条守卫：`libonnxruntime4j_jni.so` 不是靠 Java 侧持有引用找类的，
/// 它在 native 里按**类名字符串** `FindClass`。R8 一旦把这些类改名，`FindClass`
/// 返回 null，于是「建会话 / 建张量 / 抛异常」三条路径上随便哪条都会在运行时炸。
///
/// 这类回归**在 debug 构建上永远复现不了**（debug `minifyEnabled false`，类名全在），
/// 只在 release APK 上必现——与 BUG-1702 里 `kotlin.Lazy` 被 R8 改成 `W4.f` 导致每个
/// Mihon 扩展加载即崩，是同一个形状。
///
/// 尤其不能指望 AGP 的默认规则兜底：`proguard-android-optimize.txt` 里那条
/// `-keepclasseswithmembernames,includedescriptorclasses class * { native <methods>; }`
/// 只覆盖「自己声明了 native 方法」或「出现在 native 方法**描述符**里」的类。
/// [_jniLookedUpTypes] 里的 `TensorInfo` / `OrtException` / `MapInfo` / `SequenceInfo` /
/// `ValueInfo` 都落在它外面——`throws` 子句不属于方法描述符，所以 `OrtException`
/// 这条路根本够不着。
///
/// 清单来源（可复现）：解包
/// `com.microsoft.onnxruntime:onnxruntime-android:1.23.0` 的 AAR，对
/// `jni/arm64-v8a/libonnxruntime4j_jni.so` 取 `ai/onnxruntime/...` 字符串：
///
///     unzip -p onnxruntime-android-1.23.0.aar jni/arm64-v8a/libonnxruntime4j_jni.so \
///       | grep -aoE "ai/onnxruntime/[A-Za-z0-9_/]+" | sort -u
///
/// 同一次解包还确认了：**该 AAR 里只有 `classes.jar`，没有 `proguard.txt`**，
/// 也就是说上游不带 consumer 规则，我们不写就没有人写。
void main() {
  group('ONNX Runtime 的 R8 keep 覆盖', () {
    final File rules = File('android/app/proguard-rules.pro');

    test('proguard-rules.pro 存在（路径变了要同步改本守卫）', () {
      expect(
        rules.existsSync(),
        isTrue,
        reason: '找不到 ${rules.path}；R8 规则文件挪位置了就必须同步更新这条守卫。',
      );
    });

    test('每个被 JNI 按名查找的 ORT 类都被一条不可改名的 keep 覆盖', () {
      final List<_KeepRule> keeps = _parseKeepRules(rules.readAsStringSync());
      expect(
        keeps,
        isNotEmpty,
        reason: 'proguard-rules.pro 里一条 -keep class 都没解析出来',
      );

      final List<String> uncovered = <String>[
        for (final String type in _jniLookedUpTypes)
          if (!keeps.any((_KeepRule rule) => rule.covers(type))) type,
      ];

      expect(
        uncovered,
        isEmpty,
        reason:
            '这些类 ORT 的 native 侧要按原名 FindClass，release APK 上会当场崩：\n'
            '${uncovered.join('\n')}\n'
            '修法：在 android/app/proguard-rules.pro 的「ONNX Runtime」区块补 keep。',
      );
    });
  });
}

/// `libonnxruntime4j_jni.so` 里硬编码的全部 `ai.onnxruntime` 类描述符。
const List<String> _jniLookedUpTypes = <String>[
  'ai.onnxruntime.MapInfo',
  'ai.onnxruntime.NodeInfo',
  'ai.onnxruntime.OnnxMap',
  'ai.onnxruntime.OnnxModelMetadata',
  'ai.onnxruntime.OnnxSequence',
  'ai.onnxruntime.OnnxSparseTensor',
  'ai.onnxruntime.OnnxTensor',
  'ai.onnxruntime.OnnxValue',
  'ai.onnxruntime.OrtException',
  'ai.onnxruntime.SequenceInfo',
  'ai.onnxruntime.TensorInfo',
  'ai.onnxruntime.ValueInfo',
];

/// 一条 `-keep class <pattern>` 规则。
///
/// 只认**不带 `allowobfuscation`** 的 keep：带上它就等于放行改名，对按名
/// `FindClass` 而言与没写无异。
class _KeepRule {
  const _KeepRule(this.pattern);

  final String pattern;

  bool covers(String type) {
    if (pattern.endsWith('.**')) {
      final String prefix = pattern.substring(0, pattern.length - 2);
      return type.startsWith(prefix);
    }
    if (pattern.endsWith('.*')) {
      final String prefix = pattern.substring(0, pattern.length - 1);
      if (!type.startsWith(prefix)) return false;
      // 单星只覆盖同一层，不跨包。
      return !type.substring(prefix.length).contains('.');
    }
    return pattern == type;
  }
}

List<_KeepRule> _parseKeepRules(String source) {
  final RegExp keepLine = RegExp(
    r'^\s*-keep(?<modifiers>[a-z,]*)\s+class\s+(?<pattern>[\w.*$]+)',
    multiLine: true,
  );
  return <_KeepRule>[
    for (final RegExpMatch m in keepLine.allMatches(source))
      if (!(m.namedGroup('modifiers') ?? '').contains('allowobfuscation'))
        _KeepRule(m.namedGroup('pattern')!),
  ];
}
