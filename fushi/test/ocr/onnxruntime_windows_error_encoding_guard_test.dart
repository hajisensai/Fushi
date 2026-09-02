import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Directory _findRepositoryRoot() {
  Directory current = Directory.current.absolute;
  while (true) {
    if (File(
      '${current.path}/third_party/flutter_onnxruntime/PATCHES.md',
    ).existsSync()) {
      return current;
    }
    final Directory parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('找不到 Hibiki 仓库根目录');
    }
    current = parent;
  }
}

/// 去掉 `//` 行注释与 `/* */` 块注释。
///
/// 本文件的判据是「源码里出现了什么调用」，而注释里照抄一份被禁的写法是完全正当
/// 的——这个文件自己的说明就照抄了。不剥注释的话，守卫会被自己的说明文字命中，
/// 从此恒红或恒绿，取决于谁先被 indexOf 撞上。
String _stripComments(String source) {
  final StringBuffer out = StringBuffer();
  bool inLine = false;
  bool inBlock = false;
  for (int i = 0; i < source.length; i++) {
    final String ch = source[i];
    final String next = i + 1 < source.length ? source[i + 1] : '';
    if (inLine) {
      if (ch == '\n') {
        inLine = false;
        out.write(ch);
      }
      continue;
    }
    if (inBlock) {
      if (ch == '*' && next == '/') {
        inBlock = false;
        i++;
      }
      continue;
    }
    if (ch == '/' && next == '/') {
      inLine = true;
      i++;
      continue;
    }
    if (ch == '/' && next == '*') {
      inBlock = true;
      i++;
      continue;
    }
    out.write(ch);
  }
  return out.toString();
}

void main() {
  final Directory root = _findRepositoryRoot();
  final String pluginRoot =
      '${root.path}/third_party/flutter_onnxruntime/windows';
  final String plugin = _stripComments(
    File('$pluginRoot/flutter_onnxruntime_plugin.cpp').readAsStringSync(),
  );
  final String utilsHeader = File(
    '$pluginRoot/src/windows_utils.h',
  ).readAsStringSync();
  final String utilsSource = _stripComments(
    File('$pluginRoot/src/windows_utils.cc').readAsStringSync(),
  );

  group('Windows ONNX Runtime 错误消息编码', () {
    // BUG-2034：method channel 的 String 契约是 UTF-8，Dart 侧解码是严格的。ORT 在
    // Windows 上把系统错误文本按机器的 ANSI 代码页拼进消息（中文机器就是 GBK），
    // 原样送过去的后果不是「文字乱码」而是「整个回复解不出来」——用户拿到的是
    // FormatException 和一个字节偏移量，真正的失败原因彻底消失。
    test('错误消息只有一个出口，且那个出口做了 UTF-8 归一', () {
      final int rawCalls = 'result->Error('.allMatches(plugin).length;
      expect(
        rawCalls,
        1,
        reason:
            '整个插件只允许保留一处 result->Error——FailWith 内部那一处。'
            '新增错误分支必须走 FailWith，否则又是一条能把回复变成乱码的通道',
      );
      expect(
        plugin,
        contains('result->Error(code, WindowsUtils::toUtf8Message(message)'),
        reason: '唯一那处出口必须真的过 toUtf8Message；只是收口而不归一等于没修',
      );
      expect(plugin, contains('void FailWith('), reason: '收口函数不在了，说明有人把统一出口拆了');
    });

    test('归一函数存在且对合法 UTF-8 免转换', () {
      expect(utilsHeader, contains('static std::string toUtf8Message('));
      expect(utilsSource, contains('isWellFormedUtf8'));
      expect(
        utilsSource,
        contains('CP_ACP'),
        reason: '非 UTF-8 的那半必须按 ANSI 代码页读回来，那正是 ORT 写进去的编码',
      );
      expect(
        utilsSource,
        contains('CP_UTF8'),
        reason: '读回来之后要再编成 UTF-8，否则等于什么都没做',
      );
    });

    // 合法 UTF-8 直接放行这条不是优化，是正确性：模型路径里的中文是 ORT 用
    // ToUTF8String 写进去的真 UTF-8，无条件按 ANSI 再解一遍会把它转成乱码。
    test('合法 UTF-8 必须原样返回而不是无条件重编码', () {
      expect(
        utilsSource,
        contains('if (message.empty() || isWellFormedUtf8(message)) {'),
        reason: '缺了这道短路，本来正确的 UTF-8 会被当成 ANSI 二次转换毁掉',
      );
    });

    // 严格性判据：Dart 的 utf8.decode 会拒绝 overlong、代理项和超 U+10FFFF 的编码。
    // 本地校验只要比它宽一点点，就会出现「这里判合法、过了 channel 仍然炸」——
    // 那种漏网正是这个 bug 最初的形态，不能再来一次。
    test('UTF-8 校验至少和 Dart 的严格解码器一样严', () {
      expect(
        utilsSource,
        contains('0xC2'),
        reason: '0xC0/0xC1 是 overlong 前导，必须判非法',
      );
      expect(utilsSource, contains('0xED'), reason: '必须挡住 UTF-16 代理项区');
      expect(utilsSource, contains('0xF4'), reason: '必须挡住超过 U+10FFFF 的 4 字节序列');
    });
  });
}
