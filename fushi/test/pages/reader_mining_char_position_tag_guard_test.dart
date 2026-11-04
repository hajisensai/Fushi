import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'reader_fushi_page_source_corpus.dart';

/// 源码守卫：小说阅读器制卡时注入的「制卡位置」文本（反馈 MhQHXQI-sB：写进 MiscInfo，
/// 不再是 `chars_12345` 标签；文件名沿用旧名，被设置覆盖表引用）。
///
/// 为什么只能守源码：注入点 `_prepareMiningContext` / `_miningCharPosition()` 是
/// `reader_fushi/mining.part.dart` 里 `extension _ReaderMining on
/// _ReaderFushiPageState` 的**私有**成员，读的又是页面 state 上的锚点字段
/// （`_cachedSentenceRange` / `_lastProgressCharOffset` / `_chapterCumulativeChars`）。
/// 这个页面 headless 起不来（WebView + 真 EPUB + 真 Anki），行为层拿不到这条线，
/// 只能在结构上把三条不变式钉死。
///
/// 落哪个字段（Lapis = MiscInfo / 其它类型的 MiscInfo 等价字段 / 没有不写）、怎么追加由
/// `packages/fushi_anki/test/mining_char_position_misc_info_test.dart` 的行为测试咬住；
/// 本守卫只管**阅读器这一端有没有按开关注入、按什么口径算位置、文案走不走 i18n**。
///
/// 读的是「主壳 + 全部 `reader_fushi/*.part.dart`」合并语料（见
/// `reader_fushi_page_source_corpus.dart`）：方法在 part 之间搬家不会让守卫失效，
/// 新增 part 也自动进扫描面。
void main() {
  group('reader 制卡注入制卡位置（写 MiscInfo）', () {
    test('AnkiMiningContext 的构造带 charPositionText，且经开关门控', () {
      final String src = readReaderPageSource();

      // ① 注入点确实在 AnkiMiningContext 的构造里（不是别的调用的同名参数）。
      //    撤掉 mining.part.dart 里 `charPositionText: ...` 那几行 → enclosingCallOf
      //    找不到锚点直接 fail。
      final EnclosingCall call = enclosingCallOf(src, 'charPositionText:');
      expect(
        call.name,
        'AnkiMiningContext',
        reason:
            '制卡位置必须注入进 AnkiMiningContext 的构造，'
            '否则各 backend 的 buildMinedFields 都拿不到它',
      );

      final List<String> values = namedArgumentValues(src, 'charPositionText');
      expect(
        values,
        hasLength(1),
        reason:
            '阅读器语料里只该有一处注入点（_prepareMiningContext）；'
            '多出一处说明有第二条口径不同的注入链路',
      );
      final String value = values.single;

      // ② 开关门控：撤掉 `appModel.autoAddCharPositionToTags && ... ? ... : null`，
      //    偏好开关就成了摆设（关掉照样写位置）→ 本条红。
      expect(
        value,
        contains('appModel.autoAddCharPositionToTags'),
        reason:
            '注入必须被「制卡位置写入 MiscInfo」偏好（冻结键 '
            'auto_add_char_position_to_tags）门控；开关关掉时这个值必须是 null',
      );

      // ③ 锚点取不到（快照为 null）时整个值必须是 null，不能格式化出「第 null 字」。
      expect(
        compactCode(value),
        contains('snapshotCharPosition!=null'),
        reason: '快照为 null（锚点取不到）时不写位置',
      );

      // ④ 文案走 i18n（卡上写的是用户界面语言的一句话），不在阅读器里硬拼字面量。
      expect(
        containsIdentifierCall(value, 't.anki_char_position_misc_info_value'),
        isTrue,
        reason: '位置文本必须经 t.anki_char_position_misc_info_value 格式化',
      );
      expect(value, isNot(contains('chars_')), reason: '不再产出 chars_ 标签字面量');
    });

    test('位置取的是 await 前的快照，不是构造时的当前值', () {
      final String src = readReaderPageSource();

      // 制卡链路在 `AnkiMiningContext(...)` 之前有一串 await（截图 / 句子音频 /
      // 合集反查）。悬挂期间用户可以再查一个词、甚至翻一页，把 _cachedSentenceRange
      // 与 _lastProgressCharOffset 改写。同 snapshotSentenceOffset 的既有纪律：
      // 位置必须在第一个 await 前定格。
      final String? snapshot = initializerExpression(
        src,
        'snapshotCharPosition',
      );
      expect(
        snapshot,
        isNotNull,
        reason: '_prepareMiningContext 必须在第一个 await 前把制卡位置快照下来',
      );
      expect(
        containsIdentifierCall(snapshot!, '_miningCharPosition'),
        isTrue,
        reason: '快照的来源必须是 _miningCharPosition()',
      );

      // 把构造里的 `snapshotCharPosition` 换回 `_miningCharPosition()`（await 后重算）
      // → 本条红。
      final String value = namedArgumentValues(src, 'charPositionText').single;
      expect(
        containsIdentifier(value, 'snapshotCharPosition'),
        isTrue,
        reason: '构造里必须用快照变量',
      );
      expect(
        containsIdentifierCall(value, '_miningCharPosition'),
        isFalse,
        reason: 'await 之后重新取一次锚点就等于没做快照',
      );
    });

    test('_miningCharPosition 走 absoluteCharOffsetOf 换算，不另算一套口径', () {
      final String body = methodBody(
        readReaderPageSource(),
        'int? _miningCharPosition()',
      );

      // countStudyChars 口径的「章首累计 + 章内偏移」只有这一个实现（见
      // reader_fushi_page.dart 的 absoluteCharOffsetOf，与阅读进度条分子、
      // study_segments.chars 同一根数轴）。撤掉这一行改成手写
      // `_chapterCumulativeChars[i] + offset` → 本条红，也就挡住了「卡上的数字和
      // 状态行的已读字数对不上」这类静默漂移。
      expect(
        containsCodeLine(body, 'absoluteCharOffsetOf('),
        isTrue,
        reason: '制卡位置必须与阅读账本共用 absoluteCharOffsetOf 换算',
      );

      // 两级锚都在：句锚（与制卡历史同源）+ 视口锚兜底。
      expect(
        containsIdentifier(body, '_cachedSentenceRange'),
        isTrue,
        reason: '一级锚是制卡那句话在本章的偏移',
      );
      expect(
        containsIdentifier(body, '_cachedSelectionRange'),
        isTrue,
        reason: '无句级 span 时退到选区偏移',
      );
      expect(
        containsIdentifier(body, '_lastProgressCharOffset'),
        isTrue,
        reason: '句锚取不到时退到视口锚（当前页首字符），而不是退到章首',
      );
    });

    test('取不到锚点返回 null，绝不退化成 0（不打 chars_0 冒充书首）', () {
      final String src = readReaderPageSource();
      final String body = methodBody(src, 'int? _miningCharPosition()');
      final String code = maskComments(body);

      // absoluteCharOffsetOf 的「取不到」哨兵是 -1（章号越界 / 章字数未算完 /
      // JS 拿不到 caret）。它必须映射成 null 让 buildNoteTags 不追加标签。
      // 换成 `absolute < 0 ? 0 : absolute` → 一整批卡被假标成「全书第 0 字」，
      // 用户按标签排序时看不出这些数字是编的。
      final String compact = compactCode(body);
      expect(
        compact.contains('<0?null') || compact.contains('<0)returnnull'),
        isTrue,
        reason: '负数哨兵必须落到 null（三元或 if-return 都行），不得落到 0',
      );

      // 方法体里不许出现任何「兜底成 0」的形态。两条都要禁，缺一条就漏：
      // - `?? 0` 会吃掉 `sentenceRange?.offset ?? _lastProgressCharOffset`
      //   那一级视口锚兜底，句锚取不到时直接变成「章首」；
      // - 三元退化 `absolute < 0 ? 0 : absolute` 把 0 写在 `?` 分支上——
      //   只盯 `: 0` 的正则漏得掉（实测：变异探针当场抓到），故两个分支都禁。
      expect(
        RegExp(r'\?\?\s*0(?![0-9.])').hasMatch(code),
        isFalse,
        reason: '不得用 `?? 0` 兜底：0 是合法的书首位置，不是「取不到」',
      );
      expect(
        RegExp(r'[?:]\s*0(?![0-9.])').hasMatch(code),
        isFalse,
        reason: '不得用三元把取不到的锚点退化成 0（`? 0` 与 `: 0` 两个分支都算）',
      );

      // 返回类型必须可空——写成 `int _miningCharPosition()` 就没有「不打标签」这个
      // 状态可表达了。methodBody 的签名检索本身已经钉住这一点（改成非空即 fail），
      // 这里再显式记一条，说明为什么签名不能改。
      expect(
        src,
        contains('int? _miningCharPosition()'),
        reason: '返回类型必须可空：null = 锚点取不到 = 不打标签',
      );
    });
  });
}
