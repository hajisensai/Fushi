// 本机 Manga CTC 把正文短列当注音整列删掉（用户真实页《世界で一番おっぱいが好き！1》
// 第 9 页「は〜〜〜 / 癒やされる〜〜〜」只读出后一列；JMangaBench_Read 前 1,480 框里
// 这一项占全部字错的四成）。行框厚度是检测器外扩出来的，同一段正文的各列能差出
// 两三成，只看框厚分不出「窄一点的正文列」和注音。dropOcrRubyLinesByInk 对几何上
// 像注音的行再量框内墨迹：字小且贴着正文才是注音。
import 'package:test/test.dart';
import 'package:fushi_engine/ocr/ocr_line_layout.dart';
import 'package:fushi_engine/ocr/ocr_ruby_trim.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:image/image.dart' as img;

OcrRect _r(double l, double t, double r, double b) =>
    OcrRect(left: l, top: t, right: r, bottom: b);

/// 白底页；[columns] 的每项是一列「字」：x∈[left, right)、y∈[top, bottom)，
/// 每 40px 一个 20px 高的实心块（墨迹占行框面积不到一半——真实的字是稀疏的，
/// 占到一半以上会被当成反白）。
img.Image _page(List<(int, int, int, int)> columns) {
  final img.Image image = img.Image(width: 100, height: 200);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  for (final (int left, int right, int top, int bottom) in columns) {
    for (int y = top; y + 20 <= bottom; y += 40) {
      img.fillRect(
        image,
        x1: left,
        y1: y,
        x2: right - 1,
        y2: y + 19,
        color: img.ColorRgb8(0, 0, 0),
      );
    }
  }
  return image;
}

/// 正文列：墨迹 x∈[10, 40)（字宽 30），行框 40 厚。
const (int, int, int, int) _bodyInk = (10, 40, 5, 200);
final OcrRect _bodyBox = _r(5, 0, 45, 200);

void main() {
  group('ocrLineInkThickness', () {
    test('量的是字宽，不是行框厚度', () {
      final img.Image page = _page(const <(int, int, int, int)>[_bodyInk]);
      expect(ocrLineInkThickness(page, _bodyBox, vertical: true), 30);
    });

    test('字中间有一道贯通空白（「い」「り」）的列仍算一个字宽', () {
      final img.Image page = _page(const <(int, int, int, int)>[
        (10, 18, 5, 200),
        (22, 30, 5, 200),
      ]);
      expect(ocrLineInkThickness(page, _bodyBox, vertical: true), 20);
    });

    test('没有可分辨文字的行框返回 null', () {
      final img.Image page = _page(const <(int, int, int, int)>[]);
      expect(ocrLineInkThickness(page, _bodyBox, vertical: true), isNull);
    });
  });

  group('dropOcrRubyLinesByInk', () {
    test('框比邻列窄、字宽接近的正文短列留下（几何判据会删掉它）', () {
      // 右边一列短、框只有 28 厚（邻列 40）：几何判据「不到 p75 的 0.82 倍 + 贴着
      // 厚 1.25 倍以上的行」命中。字宽 22，是邻列 30 的 0.73 倍——正文。
      final img.Image page = _page(const <(int, int, int, int)>[
        _bodyInk,
        (48, 70, 5, 80),
      ]);
      final OcrRect short = _r(45, 0, 73, 80);
      final List<OcrRect> lines = <OcrRect>[_bodyBox, short];
      expect(dropOcrRubyLines(lines, vertical: true), <OcrRect>[
        _bodyBox,
      ], reason: '前提：只按行框几何会把短列删掉');
      expect(dropOcrRubyLinesByInk(page, lines, vertical: true), lines);
    });

    test('字宽不到正文一半的注音照删', () {
      final img.Image page = _page(const <(int, int, int, int)>[
        _bodyInk,
        (43, 55, 5, 60),
      ]);
      final OcrRect ruby = _r(41, 0, 57, 60);
      expect(
        dropOcrRubyLinesByInk(page, <OcrRect>[_bodyBox, ruby], vertical: true),
        <OcrRect>[_bodyBox],
      );
    });

    test('字号小一号但与邻列隔着正常列距的独立正文列留下', () {
      // 字宽 17（0.57 倍），与正文之间空 12px（0.4 个字宽）：括号里的补充说明、
      // 手写旁白这类，不是注音。
      final img.Image page = _page(const <(int, int, int, int)>[
        _bodyInk,
        (52, 69, 5, 120),
      ]);
      final OcrRect small = _r(48, 0, 73, 120);
      final List<OcrRect> lines = <OcrRect>[_bodyBox, small];
      expect(dropOcrRubyLines(lines, vertical: true), <OcrRect>[_bodyBox]);
      expect(dropOcrRubyLinesByInk(page, lines, vertical: true), lines);
    });

    test('同样字号、紧贴正文的是注音（义训注音字号偏大）', () {
      // 字宽同上 17，但与正文只隔 3px（0.1 个字宽）。
      final img.Image page = _page(const <(int, int, int, int)>[
        _bodyInk,
        (43, 60, 5, 120),
      ]);
      final OcrRect ruby = _r(41, 0, 66, 120);
      expect(
        dropOcrRubyLinesByInk(page, <OcrRect>[_bodyBox, ruby], vertical: true),
        <OcrRect>[_bodyBox],
      );
    });

    test('注音框压着正文列的边：只量它独占的那一段，不把邻列的墨迹算成字宽', () {
      // 全注音的少年漫画（用户书库《ドラえもん 第1巻》20 页里 16 个块）：注音框
      // 与它标注的那一列的框交叠，整框量墨迹是「正文边 + 注音」26px（正文的
      // 0.74 倍，会被当正文留下，读出「せいかつ / 生活」）。独占段里只有 15px。
      final img.Image page = _page(const <(int, int, int, int)>[
        _bodyInk,
        (42, 60, 5, 120),
      ]);
      final OcrRect ruby = _r(34, 0, 62, 120);
      expect(ocrLineInkThickness(page, ruby, vertical: true), 26);
      expect(
        dropOcrRubyLinesByInk(page, <OcrRect>[_bodyBox, ruby], vertical: true),
        <OcrRect>[_bodyBox],
      );
    });

    test('几何判据没删任何行时原样返回', () {
      final img.Image page = _page(const <(int, int, int, int)>[
        _bodyInk,
        (60, 90, 5, 200),
      ]);
      final List<OcrRect> lines = <OcrRect>[_bodyBox, _r(55, 0, 95, 200)];
      expect(dropOcrRubyLinesByInk(page, lines, vertical: true), lines);
    });
  });
}
