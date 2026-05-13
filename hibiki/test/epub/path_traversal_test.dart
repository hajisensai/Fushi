import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('p.isWithin rejects sibling prefix collisions', () {
    test('sibling directory with same prefix is rejected', () {
      final String base = p.join('C:', 'data', 'books', '12');
      final String evil =
          p.join('C:', 'data', 'books', '12_evil', 'payload.txt');
      expect(p.isWithin(base, evil), isFalse);
    });

    test('legitimate child path is accepted', () {
      final String base = p.join('C:', 'data', 'books', '12');
      final String child = p.join('C:', 'data', 'books', '12', 'chapter1.html');
      expect(p.isWithin(base, child), isTrue);
    });

    test('parent traversal via .. is rejected', () {
      final String base = p.join('C:', 'data', 'books', '12');
      final String traversal =
          p.canonicalize(p.join(base, '..', '13', 'secret.txt'));
      expect(p.isWithin(base, traversal), isFalse);
    });

    test('base path itself is not "within" (equals case)', () {
      final String base = p.join('C:', 'data', 'books', '12');
      expect(p.isWithin(base, base), isFalse);
    });
  });
}
