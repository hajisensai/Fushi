import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/custom_fonts_page.dart';
import 'package:fushi/src/utils/net/github_mirrors.dart';

/// 反馈 f4ybrMM0mP（iOS 中国大陆网络「无法获取推荐字体」）：推荐字体的下载源以前
/// 每款只手写 jsDelivr 主域 + raw + Google 打包接口三条——raw 直连被重置、Google
/// 接口只回网页 HTML（必败），等于只靠 jsDelivr 一个节点。这里钉住：每款都有
/// GitHub 加速镜像与 raw 兜底，能走 jsDelivr 的都挂满四个独立节点，失效的 Google
/// 接口不再出现。
void main() {
  test(
    'every recommended font has mirror + raw fallbacks, no dead Google API',
    () {
      final List<RecommendedFont> catalog = recommendedFontsCatalog;
      expect(catalog, isNotEmpty);
      for (final RecommendedFont font in catalog) {
        expect(
          font.urls.where((String u) => u.contains('fonts.google.com')),
          isEmpty,
          reason: '${font.name}: Google 打包接口只回 HTML，不能当下载源',
        );
        for (final String prefix in kGitHubMirrorPrefixes) {
          expect(
            font.urls.where((String u) => u.startsWith(prefix)),
            hasLength(1),
            reason: '${font.name}: 缺 GitHub 镜像 $prefix',
          );
        }
        expect(
          font.urls.last,
          startsWith('https://raw.githubusercontent.com/google/fonts/main/'),
          reason: '${font.name}: raw 直连兜底排在最后',
        );
        expect(font.urls.toSet(), hasLength(font.urls.length));
      }
    },
  );

  test('jsDelivr nodes come first, except the >50MB notoserifsc dir', () {
    for (final RecommendedFont font in recommendedFontsCatalog) {
      final List<String> jsDelivr = font.urls
          .where((String u) => u.contains('jsdelivr.net'))
          .toList();
      if (font.name == 'Noto Serif SC') {
        expect(jsDelivr, isEmpty, reason: 'jsDelivr 对该目录整目录 403');
        continue;
      }
      expect(jsDelivr, hasLength(kJsDelivrHosts.length), reason: font.name);
      expect(
        font.urls.take(kJsDelivrHosts.length).toList(),
        jsDelivr,
        reason: '${font.name}: jsDelivr 节点排在镜像之前',
      );
    }
  });

  test('gitHubRepoFileUrls keeps jsDelivr → mirrors → raw order', () {
    final List<String> urls = gitHubRepoFileUrls(
      'ofl/a/A.ttf',
      repo: 'google/fonts',
      ref: 'main',
    );
    expect(
      urls.first,
      'https://cdn.jsdelivr.net/gh/google/fonts@main/ofl/a/A.ttf',
    );
    expect(
      urls.last,
      'https://raw.githubusercontent.com/google/fonts/main/ofl/a/A.ttf',
    );
    expect(
      urls,
      hasLength(kJsDelivrHosts.length + kGitHubMirrorPrefixes.length + 1),
    );
    expect(
      gitHubRepoFileUrls(
        'ofl/a/A.ttf',
        repo: 'google/fonts',
        ref: 'main',
        viaJsDelivr: false,
      ).where((String u) => u.contains('jsdelivr')),
      isEmpty,
    );
  });
}
