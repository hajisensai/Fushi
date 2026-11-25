import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_anki/src/fushi_card_template_history.dart';

/// 内置 Fushi 卡片模板历史登记（A1，反馈 O5YDP27Xko）：内置模板一有修改记录就冻成那一版
/// 全文，之后内置模板升级，冻住的旧版必须仍被认作「内置」，否则原生卡面整张回退 WebView。
///
/// 改了模板数据（templates/fushi_card/ + gen_fushi_card_template.dart）却没跑
/// `dart run tool/gen_fushi_card_template_history.dart` 追加新版本时这里红。
void main() {
  FushiCardSideSpec specOf(String template) => FushiCardSideSpec.markers(
    fushiCardSha256(fushiCardMarkedSkeletonOf(template)!),
  );

  test('当前内置样式与正背面骨架都在登记表里', () {
    final String css = fushiCardSha256(
      fushiCardNormalizeCss(kFushiCardStylingCss),
    );
    final String front = specOf(kFushiCardFrontTemplate).sha256;
    final String back = specOf(kFushiCardBackTemplate).sha256;
    expect(
      kFushiCardTemplateHistory.any(
        (FushiCardTemplateVersion v) =>
            v.cssSha256 == css &&
            v.front.kind == FushiCardSideSpecKind.markers &&
            v.front.sha256 == front &&
            v.back.kind == FushiCardSideSpecKind.markers &&
            v.back.sha256 == back,
      ),
      isTrue,
      reason:
          '模板数据改了没登记：在 packages/fushi_anki 下跑 '
          'dart run tool/gen_fushi_card_template_history.dart',
    );
    expect(fushiCardCssIsBuiltin(kFushiCardStylingCss), isTrue);
  });

  test('登记表只追加：已登记的历史版本不许删改', () {
    // 头尾几版的哈希钉死（生成器只往末尾追加）。
    expect(kFushiCardTemplateHistory.length, greaterThanOrEqualTo(11));
    final FushiCardTemplateVersion first = kFushiCardTemplateHistory.first;
    expect(first.commit, 'ed82de1394');
    expect(
      first.cssSha256,
      '4903dce117a42d9b77b887aed2a80647487ffba16e8fae3998e56522df585e6b',
    );
    final FushiCardTemplateVersion premarker = kFushiCardTemplateHistory
        .firstWhere((FushiCardTemplateVersion v) => v.commit == 'f5ab1a649d');
    expect(premarker.back.kind, FushiCardSideSpecKind.snippets);
    expect(premarker.back.snippets, hasLength(FushiCardBlock.values.length));
    final Set<String> keys = <String>{
      for (final FushiCardTemplateVersion v in kFushiCardTemplateHistory)
        '${v.cssSha256}|${v.front.sha256}|${v.back.sha256}',
    };
    expect(keys, hasLength(kFushiCardTemplateHistory.length), reason: '无重复版本');
  });
}
