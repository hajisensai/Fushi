import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_hook_code_profile.dart';

/// BUG-1909：用户拿到的 galgame 特殊码只是一串字符，而 Fushi 唯一能吃下自定义
/// H-code 的入口是「导入一个七列 TSV 文件」，首列还必须是游戏 exe 的 SHA-256
/// （用户原话：「特殊码确实是可以用在 fushi 上的，不过要稍微转换一下，因为 fushi 只接受
/// tsv 合适的，一般特殊码只是一串字符。优化一下」）。
///
/// 中间那层转换分两半：洗噪声（[normalizeGalHookCode]）+ 补身份列拼成 profile 行
/// （由 texthooker 页的「粘贴特殊码」入口完成，那里能拿到当前运行游戏的 exe）。
///
/// 归一化的红线是**不碰码本身的结构**：Hibiki 从头到尾把 hook code 当不透明字符串
/// 搬运，真正的词法解析在 LunaHost DLL 里（本仓 third_party 只有二进制，没有源码
/// 可复用）。在 Dart 侧替 native 猜格式 = 开第二个真相源。
void main() {
  group('normalizeGalHookCode', () {
    test('原样保留一条干净的码（不补/不删开头的斜杠、不改大小写）', () {
      const String code = '/HQN4@4CE90:nine_kokoiro.exe';
      expect(normalizeGalHookCode(code), code);
      // 不带斜杠的写法同样原样保留 —— 两种写法都是上游生态里的合法形式。
      expect(normalizeGalHookCode('HQN4@4CE90:nine_kokoiro.exe'),
          'HQN4@4CE90:nine_kokoiro.exe');
      // 大小写是有意义的（H/Q/N/S/W 是数据类型标志），绝不能规整。
      expect(normalizeGalHookCode('EXHVXN0@2198:x.exe'), 'EXHVXN0@2198:x.exe');
    });

    test('去掉首尾空白与包裹引号（从网页/聊天复制的常态）', () {
      expect(
          normalizeGalHookCode('  /HQN4@4CE90:a.exe  '), '/HQN4@4CE90:a.exe');
      expect(normalizeGalHookCode('"/HQN4@4CE90:a.exe"'), '/HQN4@4CE90:a.exe');
      expect(normalizeGalHookCode("'/HQN4@4CE90:a.exe'"), '/HQN4@4CE90:a.exe');
      expect(normalizeGalHookCode('「/HQN4@4CE90:a.exe」'), '/HQN4@4CE90:a.exe');
      // 嵌套引号也剥干净。
      expect(
          normalizeGalHookCode('"「/HQN4@4CE90:a.exe」"'), '/HQN4@4CE90:a.exe');
    });

    test('去掉内部空白与换行（复制时的软折行）', () {
      expect(normalizeGalHookCode('/HQN4@4CE90\n:a.exe'), '/HQN4@4CE90:a.exe');
      expect(normalizeGalHookCode('/HQN4 @4CE90:a.exe'), '/HQN4@4CE90:a.exe');
      expect(
          normalizeGalHookCode('/HQN4@4CE90:a.exe\r\n'), '/HQN4@4CE90:a.exe');
      // 全角空格（U+3000）不在 FF01..FF5E 区间里，必须单独处理。
      expect(normalizeGalHookCode('/HQN4　@4CE90:a.exe'), '/HQN4@4CE90:a.exe');
    });

    test('全角 ASCII → 半角（中日文 IME 下粘出来的码 native 一个字都认不出）', () {
      // ／ＨＱＮ４＠４ＣＥ９０：ａ．ｅｘｅ
      const String fullWidth = '／ＨＱＮ４＠'
          '４ＣＥ９０：ａ．ｅｘｅ';
      expect(normalizeGalHookCode(fullWidth), '/HQN4@4CE90:a.exe');
    });

    test('空输入/纯噪声归一成空串（调用方据此拒绝入库）', () {
      expect(normalizeGalHookCode(''), '');
      expect(normalizeGalHookCode('   \n\t  '), '');
      expect(normalizeGalHookCode('""'), '');
    });
  });

  test('归一化后的码能通过 profile 校验并写成合法 TSV 行（BUG-1909）', () {
    final LunaHookCodeProfile profile = LunaHookCodeProfile(
      // 归一化只管码本身；身份列由「粘贴特殊码」入口用当前运行游戏的 exe 算出来
      // ——这正是用户手工拼 TSV 时最过不去的一关。
      executableSha256: 'a' * 64,
      moduleName: '',
      moduleSha256: '',
      codepage: 932,
      hookCode: normalizeGalHookCode('  "／ＨＱＮ４＠４ＣＥ９０：a.exe"  '),
      label: 'nine_kokoiro.exe',
    );
    // validate() 不抛 = 这一行 native 认得。
    profile.validate();
    expect(profile.hookCode, '/HQN4@4CE90:a.exe');
  });

  test('粘贴入口用 upsert 而不是 replaceFrom（不清掉用户既有 profile）', () {
    final String page = File(
      'lib/src/pages/implementations/texthooker_page.dart',
    ).readAsStringSync();
    final int start = page.indexOf('Future<void> _pasteLunaHookCode(');
    expect(start, greaterThanOrEqualTo(0), reason: '粘贴入口必须存在');
    final int end = page.indexOf('Future<void> _saveSelectedLunaHookCode(');
    expect(end, greaterThan(start));
    final String body = page.substring(start, end);
    expect(body.contains('store.upsert('), isTrue,
        reason: '粘一条码不该把用户其它 profile 全部清掉');
    expect(body.contains('replaceFrom('), isFalse,
        reason: 'replaceFrom 是整表替换，那是导入文件那条路的语义');
    expect(body.contains('normalizeGalHookCode('), isTrue, reason: '必须先洗噪声再入库');
    expect(body.contains('sha256File('), isTrue,
        reason: '必须补上 exe 身份哈希 —— 否则这条 profile 永远匹配不上');
  });
}
