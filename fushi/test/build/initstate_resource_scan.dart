// State 生命周期裸挂外部资源扫描器（BUG-5604），守卫
// `initstate_resource_rollback_guard_test.dart` 用。
//
// 基于 package:analyzer 的语法树（只解析、不做类型解析，不是分析器插件）：
// - 根：每个类 / mixin 的 `initState`、`didChangeDependencies`、`didUpdateWidget`。
// - 顺着根里调用的本类私有方法（`_attach(x)`、`this._x()`）递归展开，按源码执行顺序
//   收集「挂资源」与「登记撤销」两类事件。
// - 挂资源：`.listen(`、`.add…Listener(` / `.add…Observer(` / `.add…Handler(`、
//   `addPostFrameCallback(`、`scheduleMicrotask(`、`Timer(` / `Timer.periodic(`、
//   `AppLifecycleListener(`，以及把回调（函数字面量 / 本类方法的 tear-off / `this`）
//   赋给别的对象的属性（`other.onX = _handle`）。
// - 算已登记：包在 `ownSubscription(` / `listenTo(` / `ownTimer(` 里；或事件序列里
//   在它**之前**已有一条与之匹配的 `onTeardown(...)`（摘除同一回调 / 取消同一字段 /
//   清掉同一属性），或紧跟它的下一条语句就是 `onTeardown(`。
// - 挂在本类自建对象上的监听不算（字段初始化或在本类里被赋成 `Ctor(...)` 的私有字段，
//   与 State 同生共死）。
import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// 一处没有登记撤销的裸挂资源。
final class RawAttachment {
  const RawAttachment({
    required this.path,
    required this.line,
    required this.owner,
    required this.root,
    required this.code,
  });

  final String path;
  final int line;

  /// 所在类 / mixin。
  final String owner;

  /// 从哪个生命周期方法走到这里（`initState` / `didChangeDependencies` /
  /// `didUpdateWidget`）。
  final String root;

  /// 挂资源那段源码（截短）。
  final String code;

  @override
  String toString() => '$path:$line $owner.$root -> $code';
}

const Set<String> _roots = <String>{
  'initState',
  'didChangeDependencies',
  'didUpdateWidget',
};
const Set<String> _wrappers = <String>{
  'ownSubscription',
  'listenTo',
  'ownTimer',
};
final RegExp _addCallback = RegExp(r'^add(\w*)(Listener|Observer|Handler)$');
final RegExp _ctorName = RegExp(r'^[A-Z]');

/// `lib/` 下所有裸挂资源（登记器本身除外）。
List<RawAttachment> scanLifecycleRawAttachments(Directory lib) {
  final List<File> files =
      lib
          .listSync(recursive: true)
          .whereType<File>()
          .where(
            (File f) =>
                f.path.endsWith('.dart') &&
                !f.path.endsWith('.g.dart') &&
                !f.path.endsWith('.freezed.dart') &&
                !f.path
                    .replaceAll(r'\', '/')
                    .endsWith('utils/state_resource_scope.dart'),
          )
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));
  return <RawAttachment>[
    for (final File f in files)
      ...rawAttachmentsInSource(
        f.readAsStringSync(),
        path: f.path.replaceAll(r'\', '/'),
      ),
  ];
}

/// 单个源文件里的裸挂资源。
List<RawAttachment> rawAttachmentsInSource(String source, {String path = ''}) {
  final CompilationUnit unit = parseString(
    content: source,
    path: path.isEmpty ? null : path,
    throwIfDiagnostics: false,
  ).unit;
  final List<RawAttachment> out = <RawAttachment>[];
  for (final CompilationUnitMember decl in unit.declarations) {
    final (String name, ClassBody body)? cls = switch (decl) {
      ClassDeclaration() => (decl.namePart.typeName.lexeme, decl.body),
      MixinDeclaration() => (decl.name.lexeme, decl.body),
      _ => null,
    };
    if (cls == null) continue;
    final _ClassScan scan = _ClassScan(cls.$1, cls.$2, unit, path);
    for (final String root in _roots) {
      final MethodDeclaration? m = scan.methods[root];
      if (m != null) out.addAll(scan.scanRoot(m));
    }
  }
  return out;
}

class _ClassScan {
  _ClassScan(this.name, ClassBody body, this.unit, this.path) {
    for (final ClassMember m in body.members) {
      if (m is MethodDeclaration && !m.isGetter && !m.isSetter) {
        methods[m.name.lexeme] = m;
      } else if (m is FieldDeclaration) {
        for (final VariableDeclaration v in m.fields.variables) {
          final Expression? init = v.initializer;
          if (init != null && _isConstruction(init)) {
            ownFields.add(v.name.lexeme);
          }
        }
      }
    }
    // 本类里任何地方 `_x = Ctor(...)` 的私有字段也是自建对象。
    body.accept(_OwnAssignmentCollector(ownFields));
  }

  final String name;
  final CompilationUnit unit;
  final String path;
  final Map<String, MethodDeclaration> methods = <String, MethodDeclaration>{};
  final Set<String> ownFields = <String>{};

  List<RawAttachment> scanRoot(MethodDeclaration root) {
    final _Walker w = _Walker(this);
    w.walkMethod(root);
    final List<RawAttachment> out = <RawAttachment>[];
    for (int i = 0; i < w.events.length; i++) {
      final _Event e = w.events[i];
      if (e is! _Attach) continue;
      if (_registeredBefore(w.events, i, e) || _nextStatementTearsDown(e)) {
        continue;
      }
      final String code = e.node.toSource().replaceAll(RegExp(r'\s+'), ' ');
      out.add(
        RawAttachment(
          path: path,
          line: unit.lineInfo.getLocation(e.node.offset).lineNumber,
          owner: name,
          root: root.name.lexeme,
          code: code.length > 120 ? '${code.substring(0, 117)}...' : code,
        ),
      );
    }
    return out;
  }

  bool _registeredBefore(List<_Event> events, int index, _Attach a) {
    if (a.matchers.isEmpty) return false;
    for (int i = 0; i < index; i++) {
      final _Event e = events[i];
      if (e is _Teardown &&
          a.matchers.every((String m) => _matches(e.source, m))) {
        return true;
      }
    }
    return false;
  }

  /// 挂资源语句的下一条是 `onTeardown(...)`，且撤销的源码对得上这次挂的东西。
  /// post-frame / 微任务没有可撤的句柄（matchers 为空），只能走 schedulePostFrame /
  /// scheduleScopedMicrotask。
  bool _nextStatementTearsDown(_Attach a) {
    if (a.matchers.isEmpty) return false;
    AstNode? stmt = a.node;
    while (stmt != null && stmt is! Statement) {
      stmt = stmt.parent;
    }
    final AstNode? block = stmt?.parent;
    if (stmt == null || block is! Block) return false;
    final int i = block.statements.indexOf(stmt as Statement);
    if (i < 0 || i + 1 >= block.statements.length) return false;
    final Statement next = block.statements[i + 1];
    if (next is! ExpressionStatement) return false;
    final Expression call = next.expression;
    if (call is! MethodInvocation || call.methodName.name != 'onTeardown') {
      return false;
    }
    final String teardown = call.argumentList.toSource();
    return a.matchers.every((String m) => _matches(teardown, m));
  }
}

/// 一个 matcher 可以是几个候选之一（[_anyOf] 拼的），命中任一即可。
const String _alt = '';

String _anyOf(List<String> candidates) => candidates.join(_alt);

bool _matches(String source, String matcher) =>
    matcher.split(_alt).any(source.contains);

bool _isConstruction(Expression e) {
  if (e is InstanceCreationExpression) return true;
  if (e is MethodInvocation) {
    final Expression? target = e.target;
    if (target == null) return _ctorName.hasMatch(e.methodName.name);
    // `Foo.named(...)`：命名构造。
    return target is SimpleIdentifier && _ctorName.hasMatch(target.name);
  }
  if (e is CascadeExpression) return _isConstruction(e.target);
  return false;
}

class _OwnAssignmentCollector extends RecursiveAstVisitor<void> {
  _OwnAssignmentCollector(this.ownFields);

  final Set<String> ownFields;

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final Expression lhs = node.leftHandSide;
    if (lhs is SimpleIdentifier &&
        lhs.name.startsWith('_') &&
        _isConstruction(node.rightHandSide)) {
      ownFields.add(lhs.name);
    }
    super.visitAssignmentExpression(node);
  }
}

sealed class _Event {}

final class _Attach extends _Event {
  _Attach(this.node, this.matchers);

  final AstNode node;

  /// 一条撤销登记要「匹配」它，源码里必须同时出现这些片段；空 = 只认包装 / 紧跟。
  final List<String> matchers;
}

final class _Teardown extends _Event {
  _Teardown(this.source);

  final String source;
}

class _Walker extends RecursiveAstVisitor<void> {
  _Walker(this.cls);

  final _ClassScan cls;
  final List<_Event> events = <_Event>[];
  final Set<String> _visited = <String>{};
  int _wrapped = 0;

  /// 每层展开的方法里第一个 `await` 的位置：之后的代码是异步续体，不在生命周期方法
  /// 的同步执行里（那是「已起跑的 Future」一类，靠 `resourcesReleased` 把关）。
  final List<int> _cutoffs = <int>[];

  void walkMethod(MethodDeclaration m) {
    if (!_visited.add(m.name.lexeme)) return;
    final _FirstAwait first = _FirstAwait();
    if (m.body.isAsynchronous) m.body.accept(first);
    _cutoffs.add(first.offset ?? m.body.end);
    m.body.accept(this);
    _cutoffs.removeLast();
  }

  bool _pastCutoff(AstNode node) =>
      _cutoffs.isNotEmpty && node.offset > _cutoffs.last;

  @override
  void visitFunctionExpression(FunctionExpression node) {
    // 闭包体不在当下执行（回调 / 延后任务），里面挂的东西不算本方法挂的。
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_pastCutoff(node)) return;
    final String name = node.methodName.name;
    // 级联段（`x..addListener(cb)`）的 target 是 null，真正的接收者在 realTarget。
    final Expression? target = node.realTarget;
    if (name == 'onTeardown' && target == null) {
      events.add(_Teardown(node.argumentList.toSource()));
      return;
    }
    if (_wrappers.contains(name) && target == null) {
      _wrapped++;
      super.visitMethodInvocation(node);
      _wrapped--;
      return;
    }
    // 本类私有方法：展开（先求参数，再进方法体，与执行顺序一致）。
    if ((target == null || target is ThisExpression) &&
        name.startsWith('_') &&
        cls.methods.containsKey(name)) {
      node.argumentList.accept(this);
      walkMethod(cls.methods[name]!);
      return;
    }
    super.visitMethodInvocation(node);
    if (_wrapped > 0) return;
    final Match? add = _addCallback.firstMatch(name);
    if (add != null && target != null) {
      if (_isOwnObject(target)) return;
      final String arg = node.argumentList.arguments.isEmpty
          ? ''
          : node.argumentList.arguments.first.toSource();
      // 撤销登记要摘的是同一个接收者上的同一个回调。
      events.add(
        _Attach(node, <String>[
          // `_x = make()..addListener(cb)`：撤销按存下来的字段或原表达式摘都算。
          _anyOf(<String>[
            target.toSource(),
            if (_cascadeHolder(node) case final String holder) holder,
          ]),
          'remove${add.group(1)}${add.group(2)}(',
          arg,
        ]),
      );
      return;
    }
    if (name == 'addPostFrameCallback' ||
        (name == 'scheduleMicrotask' && target == null)) {
      events.add(_Attach(node, const <String>[]));
      return;
    }
    if (name == 'listen' && target != null) {
      events.add(_Attach(node, _holderMatchers(node, 'cancel')));
      return;
    }
    if (_isTimerOrLifecycleCtor(node)) {
      events.add(_Attach(node, _holderMatchers(node, '')));
    }
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (_pastCutoff(node)) return;
    super.visitInstanceCreationExpression(node);
    if (_wrapped > 0) return;
    final String type = node.constructorName.type.name.lexeme;
    if (type == 'Timer' || type == 'AppLifecycleListener') {
      events.add(_Attach(node, _holderMatchers(node, '')));
    }
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    if (_pastCutoff(node)) return;
    super.visitAssignmentExpression(node);
    if (_wrapped > 0) return;
    final Expression lhs = node.leftHandSide;
    final (Expression? target, String? prop) = switch (lhs) {
      PropertyAccess() => (lhs.target, lhs.propertyName.name),
      PrefixedIdentifier() => (lhs.prefix, lhs.identifier.name),
      _ => (null, null),
    };
    if (target == null || prop == null) return;
    if (target is ThisExpression || _isOwnObject(target)) return;
    if (!_isCallback(node.rightHandSide)) return;
    events.add(_Attach(node, <String>[prop]));
  }

  bool _isCallback(Expression e) {
    if (e is FunctionExpression || e is ThisExpression) return true;
    if (e is SimpleIdentifier) return cls.methods.containsKey(e.name);
    return false;
  }

  bool _isOwnObject(Expression target) {
    Expression t = target;
    while (t is ParenthesizedExpression) {
      t = t.expression;
    }
    // `Ctor(...)..addListener(cb)`：挂在刚建出来的对象上。
    if (_isConstruction(t)) return true;
    if (t is SimpleIdentifier) return cls.ownFields.contains(t.name);
    if (t is PrefixedIdentifier && t.prefix.name == 'this') {
      return cls.ownFields.contains(t.identifier.name);
    }
    return false;
  }

  bool _isTimerOrLifecycleCtor(MethodInvocation node) {
    final Expression? target = node.target;
    final String name = node.methodName.name;
    if (target == null) {
      return name == 'Timer' || name == 'AppLifecycleListener';
    }
    return target is SimpleIdentifier &&
        target.name == 'Timer' &&
        name == 'periodic';
  }

  /// 资源被存进哪个变量 / 字段：撤销登记里要出现它（以及 [verb]）才算匹配。没存
  /// （直接丢弃的返回值）就只认包装 / 紧跟。
  String? _cascadeHolder(MethodInvocation node) {
    if (node.parent is! CascadeExpression) return null;
    final List<String> h = _holderMatchers(node, '');
    return h.isEmpty ? null : h.first;
  }

  List<String> _holderMatchers(AstNode node, String verb) {
    AstNode n = node;
    while (n.parent is CascadeExpression ||
        n.parent is ParenthesizedExpression) {
      n = n.parent!;
    }
    final AstNode? parent = n.parent;
    String? holder;
    if (parent is AssignmentExpression && parent.rightHandSide == n) {
      holder = parent.leftHandSide.toSource();
    } else if (parent is VariableDeclaration && parent.initializer == n) {
      holder = parent.name.lexeme;
    }
    if (holder == null) return const <String>[];
    return <String>[holder, if (verb.isNotEmpty) verb];
  }
}

/// 方法体里第一个挂起点（`await` 的操作数之后 / `await for`；不进闭包）。
class _FirstAwait extends RecursiveAstVisitor<void> {
  int? offset;

  // `await f()` 里的 `f()` 本身是同步调用的，挂起点在操作数求值之后。
  void _hit(int at) {
    if (offset == null || at < offset!) offset = at;
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {}

  @override
  void visitAwaitExpression(AwaitExpression node) {
    _hit(node.expression.end);
    super.visitAwaitExpression(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    if (node.awaitKeyword != null) _hit(node.offset);
    super.visitForStatement(node);
  }
}
