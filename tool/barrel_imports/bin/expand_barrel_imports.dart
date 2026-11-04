// 把 `import 'package:fushi/<barrel>.dart'`（utils / models / pages / media /
// creator）换成直接 import「该文件实际用到的名字所在的库」。
//
// 为什么：barrel 把几十个库捆成一个 import，任何用到它的文件都拖进整个 app，
// `flutter test` 一个小测试也要编三千多个文件（守卫
// fushi/test/build/import_cycle_guard_test.dart）。合并别的分支后守卫报出新的
// barrel import，就在仓库根跑一次：
//
//   cd tool/barrel_imports && dart pub get
//   dart run bin/expand_barrel_imports.dart ../../fushi lib test integration_test test_driver
//   （再对改动文件 dart format）
//
// 解析用 analyzer，要先在 fushi/ 跑过 pub get 且生成过 strings.g.dart。
// 整个 app 一次约 3 分钟、峰值约 5 GB 内存。加 --dry 只统计不写。
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

const Set<String> barrels = <String>{
  'package:fushi/utils.dart',
  'package:fushi/models.dart',
  'package:fushi/pages.dart',
  'package:fushi/media.dart',
  'package:fushi/creator.dart',
};

/// Elements referenced anywhere in a unit (members map to their top-level
/// owner later).
class _Refs extends GeneralizingAstVisitor<void> {
  final Set<Element> out = <Element>{};
  void _add(Element? e) {
    if (e != null) out.add(e);
  }

  @override
  void visitComment(Comment node) {} // doc references don't need imports

  @override
  void visitDirective(Directive node) {}

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    _add(node.element);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    _add(node.element);
    super.visitNamedType(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    _add(node.element);
    super.visitBinaryExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    _add(node.element);
    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    _add(node.element);
    super.visitPostfixExpression(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    _add(node.element);
    super.visitIndexExpression(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    _add(node.element);
    _add(node.readElement);
    _add(node.writeElement);
    super.visitAssignmentExpression(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    _add(node.element);
    super.visitFunctionExpressionInvocation(node);
  }

  @override
  void visitExtensionOverride(ExtensionOverride node) {
    _add(node.element);
    super.visitExtensionOverride(node);
  }

  @override
  void visitAnnotation(Annotation node) {
    _add(node.element);
    super.visitAnnotation(node);
  }

  @override
  void visitConstructorName(ConstructorName node) {
    _add(node.element);
    super.visitConstructorName(node);
  }
}

Element _topLevel(Element e) {
  Element cur = e.baseElement;
  while (cur.enclosingElement != null &&
      cur.enclosingElement is! LibraryElement) {
    cur = cur.enclosingElement!;
  }
  return cur;
}

/// The declaration a reference needs imported: itself when top-level, its
/// extension when it is an extension member, else null (class members,
/// locals, parameters).
Element? _importable(Element e) {
  final Element base = e.baseElement;
  Element cur = base;
  while (cur.enclosingElement != null &&
      cur.enclosingElement is! LibraryElement) {
    final Element parent = cur.enclosingElement!;
    if (parent is ExtensionElement) return parent;
    cur = parent;
  }
  return identical(cur, base) ? cur : null;
}

Future<void> main(List<String> args) async {
  final bool dry = args.contains('--dry');
  final List<String> pos = args.where((a) => !a.startsWith('--')).toList();
  final String app = p.normalize(p.absolute(pos.first));
  final List<String> dirs = pos
      .skip(1)
      .map((d) => p.normalize(p.join(app, d)))
      .toList();
  final AnalysisContextCollection coll = AnalysisContextCollection(
    includedPaths: <String>[app],
  );
  final ctx = coll.contextFor(app);
  int changed = 0, skipped = 0;
  final List<String> files = <String>[];
  for (final String d in dirs) {
    for (final FileSystemEntity f in Directory(d).listSync(recursive: true)) {
      if (f is File && f.path.endsWith('.dart')) files.add(p.normalize(f.path));
    }
  }
  files.sort();
  for (final String path in files) {
    final String src = File(path).readAsStringSync();
    if (!RegExp(
      r"import\s+'package:fushi/(utils|models|pages|media|creator)\.dart'",
    ).hasMatch(src)) {
      continue;
    }
    final res = await ctx.currentSession.getResolvedLibrary(path);
    if (res is! ResolvedLibraryResult) {
      continue; // a part file: its owner carries the imports
    }
    final ResolvedUnitResult defining = res.units.firstWhere(
      (u) => p.normalize(u.path) == path,
    );
    final _Refs refs = _Refs();
    for (final ResolvedUnitResult u in res.units) {
      u.unit.accept(refs);
    }
    // Only top-level declarations and extensions need an import: members
    // reached through an instance resolve without one.
    final Set<Element> used = refs.out
        .map(_importable)
        .whereType<Element>()
        .toSet();
    final Set<String> usedNames = refs.out
        .map((Element e) => e.name)
        .whereType<String>()
        .toSet();
    final List<ImportDirective> dirsInFile = defining.unit.directives
        .whereType<ImportDirective>()
        .toList();
    final List<ImportDirective> barrelDirs = dirsInFile
        .where((d) => barrels.contains(d.uri.stringValue))
        .toList();
    // Names available from non-barrel imports, per prefix.
    final Map<String, Set<Element>> others = <String, Set<Element>>{};
    for (final ImportDirective d in dirsInFile) {
      if (barrels.contains(d.uri.stringValue)) continue;
      final LibraryImport? li = d.libraryImport;
      if (li == null) continue;
      others
          .putIfAbsent(d.prefix?.name ?? '', () => <Element>{})
          .addAll(li.namespace.definedNames2.values.map(_topLevel));
    }
    // Same-library declarations.
    final Set<Element> own = res.element.firstFragment.element.children.toSet();
    final List<_Edit> edits = <_Edit>[];
    bool bad = false;
    for (final ImportDirective d in barrelDirs) {
      final LibraryImport li = d.libraryImport!;
      final String prefix = d.prefix?.name ?? '';
      final Iterable<Element> ns = li.namespace.definedNames2.values.map(
        _topLevel,
      );
      final Set<Element> nsSet = ns.toSet();
      final Set<Element> need = used
          .where(
            (e) =>
                nsSet.contains(e) &&
                !own.contains(e) &&
                !(others[prefix]?.contains(e) ?? false),
          )
          .toSet();
      // Group by declaring library; map private external /src/ uris to the
      // public library the barrel re-exported them from.
      final Map<String, Set<Element>> byLib = <String, Set<Element>>{};
      for (final Element e in need) {
        final LibraryElement? lib = e.library;
        if (lib == null) {
          bad = true;
          continue;
        }
        String uri = lib.uri.toString();
        if (!uri.startsWith('package:fushi/') && uri.contains('/src/')) {
          final String pkg = uri.split('/').first;
          uri = '$pkg/${pkg.substring(8)}.dart';
        }
        byLib.putIfAbsent(uri, () => <Element>{}).add(e);
      }
      // Drop libraries whose needed names another chosen library re-exports.
      final List<String> uris = byLib.keys.toList()..sort();
      final Set<String> drop = <String>{};
      for (final String a in uris) {
        for (final String b in uris) {
          if (a == b || drop.contains(b)) continue;
          final LibraryElement? lb = byLib[b]!.first.library;
          if (lb == null) continue;
          final Set<Element> exp = lb.exportNamespace.definedNames2.values
              .map(_topLevel)
              .toSet();
          if (byLib[a]!.every(exp.contains) && !uris.contains('')) {
            drop.add(a);
            break;
          }
        }
      }
      final String hide = d.combinators
          .whereType<HideCombinator>()
          .expand((c) => c.hiddenNames.map((n) => n.name))
          .join(', ');
      if (d.combinators.whereType<ShowCombinator>().isNotEmpty) {
        // keep show semantics simple: names shown are the only ones used
      }
      final StringBuffer repl = StringBuffer();
      for (final String u in uris.where((u) => !drop.contains(u))) {
        repl.write("import '$u'");
        if (prefix.isNotEmpty) repl.write(' as $prefix');
        final LibraryElement? lib0 = byLib[u]!.first.library;
        final Map<String, Element> barrelNs = li.namespace.definedNames2;
        final List<String> barrelHid = lib0 == null
            ? <String>[]
            : (lib0.exportNamespace.definedNames2.entries
                  .where(
                    (MapEntry<String, Element> en) =>
                        usedNames.contains(en.key) &&
                        !identical(barrelNs[en.key], en.value),
                  )
                  .map((MapEntry<String, Element> en) => en.key)
                  .where((String n) => !n.endsWith('='))
                  .toList()
                ..sort());
        if (barrelHid.isNotEmpty && hide.isEmpty) {
          repl.write(' hide ${barrelHid.join(', ')}');
        }
        if (hide.isNotEmpty) {
          final LibraryElement? lu = byLib[u]!.first.library;
          final Set<String> names = lu == null
              ? <String>{}
              : lu.exportNamespace.definedNames2.keys.toSet();
          final List<String> h = hide
              .split(', ')
              .where(names.contains)
              .toList();
          if (h.isNotEmpty) repl.write(' hide ${h.join(', ')}');
        }
        repl.write(';\n');
      }
      String r = repl.toString();
      if (r.endsWith('\n')) r = r.substring(0, r.length - 1);
      edits.add(_Edit(d.offset, d.end, r));
    }
    if (bad) {
      skipped++;
      stderr.writeln('SKIP (element without library): $path');
      continue;
    }
    edits.sort((a, b) => b.start.compareTo(a.start));
    String out = src;
    for (final _Edit e in edits) {
      int end = e.end;
      if (e.text.isEmpty) {
        // remove the whole line
        while (end < out.length && (out[end] == '\r' || out[end] == '\n')) {
          end++;
          if (out[end - 1] == '\n') break;
        }
      }
      out = out.replaceRange(e.start, end, e.text);
    }
    if (out != src) {
      changed++;
      if (!dry) File(path).writeAsStringSync(out);
    }
  }
  stdout.writeln('changed $changed, skipped $skipped');
}

class _Edit {
  _Edit(this.start, this.end, this.text);
  final int start;
  final int end;
  final String text;
}
