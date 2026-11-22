// 符号索引的 Dart 部分：用 analyzer 完整解析仓库里的 Dart 包，导出「定义」和
// 「引用」两张表（TSV），由 tool/symindex/build.py 装进 SQLite。
//
//   cd tool/symindex && dart pub get
//   dart run bin/dart_index.dart <仓库根> <输出.tsv> <包目录>...
//
// 输出行格式（路径都相对仓库根，行号从 1 开始）：
//   D <符号id> <名字> <种类> <所属> <文件> <行>
//   R <符号id> <文件> <行>
// 只收仓库内声明的符号；局部变量、参数、类型参数、标签、import 前缀不收（跨文件
// 查找用不上，还会把引用表撑大好几倍）。生成文件（*.g.dart 等）里的声明不收。
// 要求各包已 pub get、fushi/ 已生成 strings.g.dart。全仓一次约 5 分钟、峰值约 6 GB。
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

const Set<ElementKind> _skipKinds = <ElementKind>{
  ElementKind.LOCAL_VARIABLE,
  ElementKind.PARAMETER,
  ElementKind.TYPE_PARAMETER,
  ElementKind.LABEL,
  ElementKind.PREFIX,
  ElementKind.LIBRARY,
  ElementKind.DYNAMIC,
  ElementKind.NEVER,
  ElementKind.ERROR,
  ElementKind.FUNCTION_TYPE_ALIAS,
};

final RegExp _generated = RegExp(r'\.(g|freezed|mocks|gr|config)\.dart$');

/// 一个声明的位置：仓库相对路径 + 名字偏移。
class _Loc {
  _Loc(this.file, this.offset, this.line);
  final String file;
  final int offset;
  final int line;
}

class _Index {
  _Index(this.root, this.out);

  final String root;
  final IOSink out;
  final Map<String, int> _ids = <String, int>{};
  int _refs = 0;

  String? _rel(String abs) {
    final String r = p
        .relative(p.normalize(abs), from: root)
        .replaceAll('\\', '/');
    if (r.startsWith('..') || r.contains('.dart_tool/')) return null;
    return r;
  }

  /// 把合成的 getter / setter、隐式构造函数等映射到用户写出来的那个声明。
  Element? canonical(Element? e) {
    if (e == null) return null;
    Element cur = e.baseElement;
    if (cur is PropertyAccessorElement && cur.isOriginVariable)
      cur = cur.variable;
    if (cur is ConstructorElement && cur.isOriginImplicitDefault)
      cur = cur.enclosingElement;
    if (_skipKinds.contains(cur.kind) || cur.name == null || cur.name!.isEmpty)
      return null;
    if (cur.enclosingElement is ExecutableElement) return null; // 局部函数
    return cur;
  }

  _Loc? locOf(Element e) {
    final Fragment f = e.firstFragment;
    final int? off = f.nameOffset;
    final LibraryFragment? lf = f.libraryFragment;
    if (off == null || lf == null) return null;
    final String? rel = _rel(lf.source.fullName);
    if (rel == null || _generated.hasMatch(rel)) return null;
    return _Loc(rel, off, lf.lineInfo.getLocation(off).lineNumber);
  }

  /// 返回符号 id；首次见到时写一行 D。仓库外 / 不收的符号返回 null。
  int? idOf(Element e) {
    final _Loc? loc = locOf(e);
    if (loc == null) return null;
    final String key = '${loc.file}:${loc.offset}';
    final int? have = _ids[key];
    if (have != null) return have;
    final int id = _ids.length + 1;
    _ids[key] = id;
    final Element? enc = e.enclosingElement;
    final String container = (enc == null || enc is LibraryElement)
        ? ''
        : (enc.name ?? '');
    out.writeln(
      'D\t$id\t${e.name}\t${e.kind.name.toLowerCase()}\t$container\t${loc.file}\t${loc.line}',
    );
    return id;
  }

  void ref(Element? raw, String file, int line) {
    final Element? e = canonical(raw);
    if (e == null) return;
    final int? id = idOf(e);
    if (id == null) return;
    _refs++;
    out.writeln('R\t$id\t$file\t$line');
  }

  /// 把一个库里所有声明（递归到类成员）登记成 D，没人引用的也要能按名字查到。
  void declarations(Element e) {
    for (final Element c in e.children) {
      final Element? k = canonical(c);
      if (k != null && identical(k, c.baseElement)) idOf(k);
      if (c is InstanceElement || c is ExtensionElement) declarations(c);
    }
  }

  int get symbols => _ids.length;
  int get refs => _refs;
}

class _RefVisitor extends GeneralizingAstVisitor<void> {
  _RefVisitor(this.ix, this.file, this.unit);

  final _Index ix;
  final String file;
  final CompilationUnit unit;

  void _add(Element? e, int offset) =>
      ix.ref(e, file, unit.lineInfo.getLocation(offset).lineNumber);

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    _add(node.element, node.offset);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    _add(node.element, node.name.offset);
    super.visitNamedType(node);
  }

  @override
  void visitConstructorName(ConstructorName node) {
    _add(node.element, node.offset);
    super.visitConstructorName(node);
  }

  @override
  void visitSuperConstructorInvocation(SuperConstructorInvocation node) {
    _add(node.element, node.offset);
    super.visitSuperConstructorInvocation(node);
  }

  @override
  void visitRedirectingConstructorInvocation(
    RedirectingConstructorInvocation node,
  ) {
    _add(node.element, node.offset);
    super.visitRedirectingConstructorInvocation(node);
  }
}

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('用法: dart run bin/dart_index.dart <仓库根> <输出.tsv> <包目录>...');
    exit(64);
  }
  final String root = p.normalize(p.absolute(args[0]));
  final IOSink out = File(args[1]).openWrite();
  final List<String> pkgs = args
      .skip(2)
      .map((String d) => p.normalize(p.absolute(root, d)))
      .toList();
  final _Index ix = _Index(root, out);
  final Stopwatch sw = Stopwatch()..start();
  final AnalysisContextCollection coll = AnalysisContextCollection(
    includedPaths: pkgs,
  );
  final Set<String> seenLibs = <String>{};
  int files = 0;
  int failed = 0;
  for (final ctx in coll.contexts) {
    final List<String> paths =
        ctx.contextRoot
            .analyzedFiles()
            .where((String f) => f.endsWith('.dart'))
            .toList()
          ..sort();
    for (final String path in paths) {
      final String? rel = ix._rel(path);
      if (rel == null || _generated.hasMatch(rel)) continue;
      final SomeResolvedUnitResult res = await ctx.currentSession
          .getResolvedUnit(path);
      if (res is! ResolvedUnitResult) {
        failed++;
        continue;
      }
      files++;
      final LibraryElement lib = res.libraryElement;
      if (seenLibs.add(lib.uri.toString())) ix.declarations(lib);
      res.unit.accept(_RefVisitor(ix, rel, res.unit));
      if (files % 1000 == 0)
        stderr.writeln(
          '  $files files, ${ix.symbols} symbols, ${ix.refs} refs, ${sw.elapsed.inSeconds}s',
        );
    }
  }
  await out.close();
  stderr.writeln(
    'dart_index: $files files ($failed unresolved), ${ix.symbols} symbols, ${ix.refs} refs, ${sw.elapsed.inSeconds}s',
  );
}
