import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_system.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/utils.dart';

/// TODO-2525：TMDB 署名 = **合约义务**（Terms of Use 第 3 节），署名文字 + 官方标识
/// 缺一不可，且标识不得改色 / 改比例 / 翻转 / 旋转 / 裁剪。
///
/// 本守卫钉住四件事：
/// 1. 矢量原图与 TMDB 下发的**逐字节相同**——TMDB 资产 URL 用内容摘要命名（Rails
///    asset digest），所以「文件 sha256 == 直链文件名里那串」既证明来源是官方原图，
///    也证明零加工（改色/改比例/重导出都会让哈希变）。
/// 2. 实际打包的 PNG 是那张原图的忠实栅格化：宽高比与 viewBox 一致、背景透明、
///    **全部不透明像素落在 TMDB 官方渐变三色的端点区间内**（零越界）。这条是真检查
///    ——最初的实现用 flutter_svg 直接渲染 SVG，因为它不支持 CSS（原图唯一填充写在
///    `<style>.cls-1{fill:url(#linear-gradient)}` 里），整个标识渲染成纯黑 9397 px；
///    黑色 TMDB 标识本身就是改色，比不放更违反条款。像素色域断言就是为了拦这类退化。
/// 3. 展示尺寸克制：不得比应用自身 logo 更显眼。
/// 4. 文字与标识的耦合：设置行同时引用 `about_tmdb_attribution` 与 logo 资源，
///    pubspec 也登记了该资源——删一半就红。
void main() {
  // TMDB 官方直链（来源页 https://www.themoviedb.org/about/logos-attribution）：
  //   /assets/2/v4/logos/v2/blue_square_1-<digest>.svg   （Primary short (blue)）
  const String officialDigest =
      '5bdc75aaebeb75dc7ae79426ddd9be3b2be1e342510f8202baf6bffa71d7f5c4';
  const String svgPath = 'assets/attribution/tmdb/blue_square_1.svg';
  const String pngPath = 'assets/attribution/tmdb/logo_tmdb.png';
  // 原图 viewBox：`0 0 190.24 81.52`。
  const double officialAspect = 190.24 / 81.52;
  // TMDB 品牌渐变三色（来源页 Brand guidelines）：
  //   #90cea1 (144,206,161) → #3cbec9 (60,190,201) → #00b3e5 (0,179,229)
  // 整张标识只有这一条线性渐变填充，故任何不透明像素都必须落在各通道端点闭区间内。
  const int maxR = 144;
  const int minG = 179;
  const int maxG = 206;
  const int minB = 161;
  const int maxB = 229;

  test('矢量原图与 TMDB 官方下发文件逐字节相同（未做任何加工）', () {
    final File svg = File(svgPath);
    expect(svg.existsSync(), isTrue, reason: '$svgPath 必须存在（provenance 真相源）');
    expect(
      sha256.convert(svg.readAsBytesSync()).toString(),
      officialDigest,
      reason: 'sha256 必须等于 TMDB 直链文件名里的摘要串——不等就说明原图被改色/改'
          '比例/翻转/裁剪/重新导出过（含「为绕开 flutter_svg 的 CSS 限制而把 fill '
          '内联进 path」），或换成了非官方来源。要换变体请从 '
          'themoviedb.org/about/logos-attribution 重新下载原图并同步更新本守卫。',
    );

    // provenance 台账必须与实际入库文件一致。
    final String readme =
        File('assets/attribution/tmdb/README.md').readAsStringSync();
    expect(readme, contains(officialDigest));
    expect(readme, contains('themoviedb.org/about/logos-attribution'));
    // 栅格化配方必须可复现（换人/换机重跑得到同一张图）。
    expect(File('assets/attribution/tmdb/rasterize.html').existsSync(), isTrue);
  });

  test('pubspec 只打包 PNG，原图与说明留在仓库不进包', () {
    final String pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, contains('- $pngPath'));
    expect(pubspec, isNot(contains('- $svgPath')),
        reason: 'SVG 是 provenance 存证，Flutter 也渲染不了它，不该进包');
    expect(pubspec, isNot(contains('- assets/attribution/tmdb/\n')),
        reason: '整目录登记会把 README/配方一起打进包');
  });

  test('设置行同时挂着署名文字与 logo，且展示尺寸克制（删一半即红）', () {
    final String schema =
        File('lib/src/settings/settings_schema_system.dart').readAsStringSync();
    expect(schema, contains("id: 'system.tmdb_attribution'"));
    expect(schema, contains('t.about_tmdb_attribution'),
        reason: '条款原句免责声明不得移除');
    expect(schema, contains("const String kTmdbLogoAsset = '$pngPath'"),
        reason: 'logo 资源路径不得移除或指向别的文件');
    expect(schema, contains('Image.asset(\n        kTmdbLogoAsset'),
        reason: 'logo 必须真的被渲染，而不是只留常量');
    // 比例锁：宽度由原图 viewBox 算死 + BoxFit.contain，杜绝拉伸变形。
    expect(schema, contains('_kTmdbLogoHeight * 190.24 / 81.52'));
    expect(schema, contains('fit: BoxFit.contain'));
    // 显眼度上限：24dp 与设置行图标徽标（`FushiBadge` 18+6*2 = 30dp）同量级；
    // 应用自身图标在 Flutter 里唯一的渲染点是设置 › 外观 › 应用图标的预设瓦片
    // （62×62dp），逐条依据见 `_kTmdbLogoHeight` 的文档注释。
    final RegExp height = RegExp(r'_kTmdbLogoHeight = (\d+(?:\.\d+)?)');
    final RegExpMatch? m = height.firstMatch(schema);
    expect(m, isNotNull);
    expect(double.parse(m!.group(1)!), lessThanOrEqualTo(32),
        reason: 'TMDB 标识不得比应用自身 logo 更显眼');
  });

  test('免责声明正文进设置搜索索引（搜条款里的词也能命中这一行）', () {
    final SettingsDestination system = buildSystemDestination();
    final SettingsItem tmdb = <SettingsItem>[
      for (final SettingsSection s in system.sections) ...s.items,
    ].firstWhere((SettingsItem i) => i.id == 'system.tmdb_attribution');

    // custom 行 title 恒空，靠 searchTitle opt-in 才进索引。
    expect(settingsItemSearchTitle(tmdb), 'TMDB');
    // 声明正文必须挂在 schema 的 subtitle 上：filterSettingsEntries 的 haystack
    // 取 item.subtitle。行改成 SettingsCustomItem 时曾漏掉它，导致只剩 'TMDB'
    // 可搜、声明正文里的词全搜不到（复核残项②）。
    expect(tmdb.subtitle, t.about_tmdb_attribution);

    // 端到端：用只存在于声明正文、不存在于 searchTitle 的词检索，必须命中本行
    // ——命中只可能经 subtitle 通道，故本断言直接钉住上面的接线真的生效。
    const String needle = 'otherwise approved';
    expect(t.about_tmdb_attribution, contains(needle),
        reason: '条款原句须逐字保留（TMDB Terms of Use 第 3 节）');
    expect(needle.toLowerCase(), isNot(contains('tmdb')),
        reason: '检索词若含 TMDB 就会经 searchTitle 命中，测不到 subtitle 通道');
    expect(
      filterSettingsEntries(
        <SettingsSearchEntry>[
          SettingsSearchEntry(destination: system, item: tmdb),
        ],
        needle,
      ).map((SettingsSearchEntry e) => e.item.id),
      contains('system.tmdb_attribution'),
    );
  });

  testWidgets('打包的 PNG 是原图的忠实栅格化：比例一致、背景透明、配色零越界', (WidgetTester tester) async {
    final Uint8List bytes = File(pngPath).readAsBytesSync();
    late ui.Image image;
    late ByteData raw;
    await tester.runAsync(() async {
      final ui.Codec codec = await ui.instantiateImageCodec(bytes);
      image = (await codec.getNextFrame()).image;
      raw = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    });
    addTearDown(image.dispose);

    final int w = image.width;
    final int h = image.height;
    // 宽高比必须与原图 viewBox 一致（0.5% 容差只留给栅格化取整，不留给改比例）。
    expect(w / h, closeTo(officialAspect, officialAspect * 0.005),
        reason: 'PNG 宽高比偏离原图 viewBox = 改比例/裁剪');
    // 覆盖到 DPR 4（24dp × 4 = 96 px）1:1，低于此会在高密度屏上糊。
    expect(h, greaterThanOrEqualTo(96));

    final Uint8List rgba = raw.buffer.asUint8List();
    int opaque = 0;
    int transparent = 0;
    int offPalette = 0;
    for (int i = 0; i < rgba.length; i += 4) {
      final int a = rgba[i + 3];
      if (a == 0) {
        transparent++;
        continue;
      }
      // 只判完全不透明的像素：rawRgba 是**预乘 alpha**，半透明抗锯齿边缘的通道值
      // 被 a/255 缩过，拿去和原始色域端点比会假阳（实测 a=252 的边缘像素 G 179→176）。
      if (a < 255) continue;
      opaque++;
      final int r = rgba[i];
      final int g = rgba[i + 1];
      final int b = rgba[i + 2];
      if (r > maxR || g < minG || g > maxG || b < minB || b > maxB) {
        offPalette++;
      }
    }
    expect(opaque, greaterThan(w * h ~/ 10), reason: '不透明像素太少：标识基本没画出来');
    expect(transparent, greaterThan(w * h ~/ 10),
        reason: '几乎没有透明像素：背景被填成了实色（= 加底色/加边框）');
    expect(offPalette, 0,
        reason: '出现了不属于 TMDB 官方渐变色域的实心像素。典型成因：渲染器丢了 '
            '<style> 里的渐变填充、路径退化成黑色（flutter_svg 就是这样），或有人'
            '把标识改了色。此时展示的已不是 TMDB 官方配色，违反条款。');
  });
}
