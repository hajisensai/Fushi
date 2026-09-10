package mextensionserver.util

import com.googlecode.d2j.node.DexCodeNode
import com.googlecode.d2j.node.DexFileNode
import com.googlecode.d2j.node.insn.AbstractMethodStmtNode
import com.googlecode.d2j.node.insn.BaseSwitchStmtNode
import com.googlecode.d2j.node.insn.ConstStmtNode
import com.googlecode.d2j.node.insn.DexLabelStmtNode
import com.googlecode.d2j.node.insn.DexStmtNode
import com.googlecode.d2j.node.insn.FieldStmtNode
import com.googlecode.d2j.node.insn.FillArrayDataStmtNode
import com.googlecode.d2j.node.insn.FilledNewArrayStmtNode
import com.googlecode.d2j.node.insn.JumpStmtNode
import com.googlecode.d2j.node.insn.MethodStmtNode
import com.googlecode.d2j.node.insn.Stmt0RNode
import com.googlecode.d2j.node.insn.Stmt1RNode
import com.googlecode.d2j.node.insn.Stmt2R1NNode
import com.googlecode.d2j.node.insn.Stmt2RNode
import com.googlecode.d2j.node.insn.Stmt3RNode
import com.googlecode.d2j.node.insn.TypeStmtNode
import com.googlecode.d2j.reader.MultiDexFileReader
import com.googlecode.d2j.reader.Op
import io.github.oshai.kotlinlogging.KotlinLogging
import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.Opcodes
import org.objectweb.asm.Type
import org.objectweb.asm.tree.AbstractInsnNode
import org.objectweb.asm.tree.ClassNode
import org.objectweb.asm.tree.MethodInsnNode
import org.objectweb.asm.tree.MethodNode
import org.objectweb.asm.tree.TypeInsnNode
import java.nio.file.FileSystems
import java.nio.file.Files
import java.nio.file.Path
import kotlin.streams.asSequence

/**
 * Restore exact DEX allocation types lost by dex2jar. R8 can inline a concrete
 * subclass constructor and invoke its superclass constructor on the original
 * new-instance register. DEX permits this, but JVM NEW and <init> owners must
 * match. The converter can instead emit NEW of that abstract superclass.
 *
 * BUG-2406: SchaleNetwork's original p0 is a concrete Filter.Group subclass
 * with no methods or fields. getFilterList allocates p0, builds arguments in a
 * loop, then invokes Group.<init>(String,List) directly. This is not a missing
 * host API and must not be repaired by making the abstract API concrete.
 *
 * Exact allocation counts identify a unique missing subclass. Existing matching
 * constructors are reused. A missing forwarding constructor is emitted only
 * when original DEX proves the allocation register invokes the accessible direct
 * superclass constructor with that descriptor. Ambiguity remains untouched.
 */
object DexAllocationRepair {
    private val logger = KotlinLogging.logger {}

    /**
     * @param dexFile 原始 APK/dex（[MultiDexFileReader] 能读的任意形态）
     * @param jarFile dex2jar 产出、且已过 [BytecodeEditor.fixAndroidClasses] 的 jar，原地修改
     */
    fun restore(
        dexFile: Path,
        jarFile: Path,
    ) {
        val evidence =
            runCatching { readDexAllocations(dexFile) }
                .onFailure { logger.warn(it) { "Unable to read dex allocations from $dexFile" } }
                .getOrNull()
                ?: return
        runCatching { rewriteJar(jarFile, evidence.first, evidence.second) }
            .onFailure { logger.warn(it) { "Unable to repair abstract allocations in $jarFile" } }
    }

    /**
     * 只做改写那一半，[allocations] 直接给定（`owner#name#desc` → `new-instance` 的
     * internal name 列表）。分出来是为了让判据可以单测，不必现造一个 dex。
     */
    internal fun restoreWithAllocations(
        jarFile: Path,
        allocations: Map<String, List<String>>,
    ) {
        if (allocations.isEmpty()) return
        runCatching { rewriteJar(jarFile, allocations) }
            .onFailure { logger.warn(it) { "Unable to repair abstract allocations in $jarFile" } }
    }

    /** `owner#name#desc` → 该方法里 `new-instance` 的 internal name 列表（可重复）。 */
    private fun readDexAllocations(dexFile: Path): Pair<Map<String, List<String>>, Map<String, List<ConstructorEvidence>>> {
        val reader = MultiDexFileReader.open(Files.readAllBytes(dexFile))
        val fileNode = DexFileNode()
        reader.accept(fileNode)

        val allocations = mutableMapOf<String, MutableList<String>>()
        val constructors = mutableMapOf<String, List<ConstructorEvidence>>()
        fileNode.clzs.forEach { classNode ->
            classNode.methods?.forEach { methodNode ->
                val code = methodNode.codeNode ?: return@forEach
                val news =
                    code.stmts
                        .asSequence()
                        .filterIsInstance<TypeStmtNode>()
                        .filter { it.op == Op.NEW_INSTANCE }
                        .mapNotNull { it.type?.let(::internalName) }
                        .toMutableList()
                if (news.isEmpty()) return@forEach
                val key =
                    methodKey(
                        internalName(methodNode.method.owner),
                        methodNode.method.name,
                        methodNode.method.desc,
                    )
                allocations.getOrPut(key) { mutableListOf() }.addAll(news)
                constructors[key] = readConstructorEvidence(code)
            }
        }
        return allocations to constructors
    }

    internal data class ConstructorEvidence(
        val type: String,
        val owner: String,
        val descriptor: String,
    )

    /**
     * R8 may erase a constructor in DEX and call its superclass on the allocated
     * register directly. Prove that register still denotes this allocation:
     * no overwrite or alias escapes, and no outside jump/handler enters the
     * interval. Internal loops (for example building constructor arguments) are
     * permitted. Debug labels are not control-flow entries.
     */
    internal fun readConstructorEvidence(code: DexCodeNode): List<ConstructorEvidence> {
        val statements = code.stmts
        val labels =
            statements
                .withIndex()
                .mapNotNull { (index, statement) ->
                    (statement as? DexLabelStmtNode)?.let { it.label to index }
                }.toMap()
        val edges =
            statements.withIndex().flatMap { (index, statement) ->
                val targets =
                    when (statement) {
                        is JumpStmtNode -> listOf(statement.label)
                        is BaseSwitchStmtNode -> statement.labels.toList()
                        else -> emptyList()
                    }
                targets.mapNotNull { labels[it]?.let { target -> index to target } }
            }
        val handlers =
            code.tryStmts
                .orEmpty()
                .flatMap { it.handler.toList() }
                .mapNotNull(labels::get)
        return statements.withIndex().mapNotNull { (start, statement) ->
            val allocation = statement as? TypeStmtNode ?: return@mapNotNull null
            if (allocation.op != Op.NEW_INSTANCE) return@mapNotNull null
            val register = allocation.a
            for (end in start + 1 until statements.size) {
                val current = statements[end]
                if (current is MethodStmtNode && register in current.args) {
                    if (current.op !in setOf(Op.INVOKE_DIRECT, Op.INVOKE_DIRECT_RANGE) ||
                        current.method.name != "<init>" ||
                        current.args.firstOrNull() != register ||
                        current.args.drop(1).contains(register)
                    ) {
                        break
                    }
                    if (edges.any { (source, target) -> target in start + 1..end && source !in start..end } ||
                        handlers.any { it in start + 1..end }
                    ) {
                        break
                    }
                    return@mapNotNull ConstructorEvidence(
                        internalName(allocation.type),
                        internalName(current.method.owner),
                        current.method.desc,
                    )
                }
                if (touchesRegister(current, register)) break
            }
            null
        }
    }

    /** Unknown instruction shapes invalidate the proof instead of guessing. */
    private fun touchesRegister(
        statement: DexStmtNode,
        register: Int,
    ): Boolean {
        val op = statement.op ?: return statement !is DexLabelStmtNode
        val operands =
            when (statement) {
                is ConstStmtNode -> listOf(statement.a)
                is TypeStmtNode -> listOf(statement.a, statement.b)
                is Stmt1RNode -> listOf(statement.a)
                is Stmt2RNode -> listOf(statement.a, statement.b)
                is Stmt2R1NNode -> listOf(statement.distReg, statement.srcReg)
                is Stmt3RNode -> listOf(statement.a, statement.b, statement.c)
                is FieldStmtNode -> listOf(statement.a, statement.b)
                is AbstractMethodStmtNode -> statement.args.toList()
                is JumpStmtNode -> listOf(statement.a, statement.b)
                is BaseSwitchStmtNode -> listOf(statement.a)
                is FilledNewArrayStmtNode -> statement.args.toList()
                is FillArrayDataStmtNode -> listOf(statement.ra)
                is Stmt0RNode -> emptyList()
                else -> return true
            }
        if (register in operands) return true
        val destination =
            when (statement) {
                is ConstStmtNode -> statement.a
                is TypeStmtNode -> if (op == Op.CHECK_CAST) -1 else statement.a
                is Stmt1RNode -> if (op.name.startsWith("MOVE_")) statement.a else -1
                is Stmt2RNode -> statement.a
                is Stmt2R1NNode -> statement.distReg
                is Stmt3RNode -> if (op.name.startsWith("APUT")) -1 else statement.a
                is FieldStmtNode -> if (op.name.startsWith("IGET") || op.name.startsWith("SGET")) statement.a else -1
                is AbstractMethodStmtNode, is JumpStmtNode, is BaseSwitchStmtNode,
                is FilledNewArrayStmtNode, is FillArrayDataStmtNode, is Stmt0RNode,
                -> -1
                else -> return true
            }
        if (destination < 0) return false
        val wide =
            op.name.contains("WIDE") ||
                op.name.substringBefore("_2ADDR").endsWith("_LONG") ||
                op.name.substringBefore("_2ADDR").endsWith("_DOUBLE")
        return register == destination || (wide && register == destination + 1)
    }

    private fun rewriteJar(
        jarFile: Path,
        allocations: Map<String, List<String>>,
        constructors: Map<String, List<ConstructorEvidence>> = emptyMap(),
    ) {
        FileSystems.newFileSystem(jarFile, null as ClassLoader?)?.use { fs ->
            val classFiles =
                Files
                    .walk(fs.getPath("/"))
                    .asSequence()
                    .filterNot(Files::isDirectory)
                    .filter { it.toString().endsWith(".class") }
                    .toList()

            val nodes = mutableListOf<Pair<Path, ClassNode>>()
            val info = mutableMapOf<String, ClassShape>()
            classFiles.forEach { path ->
                val node =
                    runCatching {
                        ClassNode(Opcodes.ASM9).also {
                            ClassReader(Files.readAllBytes(path)).accept(it, 0)
                        }
                    }.getOrNull() ?: return@forEach
                nodes += path to node
                info[node.name] =
                    ClassShape(
                        superName = node.superName,
                        isAbstract = node.access and Opcodes.ACC_ABSTRACT != 0,
                        isInterface = node.access and Opcodes.ACC_INTERFACE != 0,
                        constructors =
                            node.methods
                                .filter { it.name == "<init>" }
                                .map(MethodNode::desc)
                                .toSet(),
                        accessibleConstructors =
                            node.methods
                                .filter {
                                    it.name == "<init>" && it.access and (Opcodes.ACC_PUBLIC or Opcodes.ACC_PROTECTED) != 0
                                }.map(MethodNode::desc)
                                .toSet(),
                    )
            }

            // 扩展把宿主的 source-api 当 compileOnly，`Filter$Group` 这类基类**不在扩展
            // jar 里**，只存在于 sidecar 自己的 classpath（运行期由 parent-first 的
            // URLClassLoader 解析过去）。只看 jar 内的类会把它们当成「查不到」而整条放过，
            // 于是这个 pass 一个分配点都修不到。查不到就回落到宿主 classpath 反射，
            // 与运行期的解析路径一致。
            val shapes = ClassShapeResolver(info)
            val changedClasses = mutableSetOf<String>()
            val byName = nodes.associate { it.second.name to it.second }

            nodes.forEach { (path, node) ->
                var changed = false
                node.methods.toList().forEach { method ->
                    if (repairMethod(node.name, method, allocations, shapes, constructors, byName, changedClasses)) changed = true
                }
                if (changed) changedClasses += node.name
            }
            nodes.forEach { (path, node) ->
                if (node.name !in changedClasses) return@forEach
                val writer = ClassWriter(ClassWriter.COMPUTE_MAXS)
                node.accept(writer)
                Files.write(path, writer.toByteArray())
            }
        }
    }

    private fun repairMethod(
        owner: String,
        method: MethodNode,
        allocations: Map<String, List<String>>,
        shapes: ClassShapeResolver,
        constructors: Map<String, List<ConstructorEvidence>>,
        classes: Map<String, ClassNode>,
        changedClasses: MutableSet<String>,
    ): Boolean {
        val instructions = method.instructions.toArray()
        val abstractNews =
            instructions
                .filterIsInstance<TypeInsnNode>()
                .filter { it.opcode == Opcodes.NEW && shapes[it.desc]?.isInstantiable == false }
        if (abstractNews.isEmpty()) return false

        val dexNews = allocations[methodKey(owner, method.name, method.desc)] ?: return false
        val jarCounts =
            instructions
                .filterIsInstance<TypeInsnNode>()
                .filter { it.opcode == Opcodes.NEW }
                .groupingBy(TypeInsnNode::desc)
                .eachCount()
        val dexCounts = dexNews.groupingBy { it }.eachCount()

        var changed = false
        abstractNews.map(TypeInsnNode::desc).distinct().forEach { abstractType ->
            // dex 里本来就分配过这个类型 → 不是泛化造成的，交给别的 pass，别动。
            if ((dexCounts[abstractType] ?: 0) != 0) return@forEach
            val missing = jarCounts[abstractType] ?: return@forEach

            val candidates =
                dexCounts
                    .filterKeys { it != abstractType && isSubclassOf(it, abstractType, shapes) }
                    .filter { (type, dexCount) -> dexCount - (jarCounts[type] ?: 0) == missing }
                    .keys
            val replacement =
                candidates.singleOrNull() ?: run {
                    logger.warn {
                        "Ambiguous abstract allocation in $owner.${method.name}: " +
                            "NEW $abstractType ×$missing, candidates=$candidates — left as-is"
                    }
                    return@forEach
                }
            val replacementShape = shapes[replacement] ?: return@forEach
            if (!replacementShape.isInstantiable) return@forEach

            // A descriptor mismatch alone is not evidence of inlining. Only
            // the original DEX receiver proof can authorize a forwarding ctor.
            val constructorDescriptors = constructorDescriptorsFor(method, abstractType)
            val missingDescriptors = constructorDescriptors - replacementShape.constructors
            val evidence = constructors[methodKey(owner, method.name, method.desc)].orEmpty()
            val replacementNode = classes[replacement]
            val canForward =
                replacementNode != null &&
                    replacementNode.superName == abstractType &&
                    missingDescriptors.all { descriptor ->
                        evidence.count { it == ConstructorEvidence(replacement, abstractType, descriptor) } ==
                            method.instructions.toArray().filterIsInstance<MethodInsnNode>().count {
                                it.opcode == Opcodes.INVOKESPECIAL &&
                                    it.name == "<init>" &&
                                    it.owner == abstractType &&
                                    it.desc == descriptor
                            } &&
                            descriptor in shapes[abstractType]?.accessibleConstructors.orEmpty()
                    }
            if (missingDescriptors.isNotEmpty() && !canForward) {
                logger.warn {
                    "Skipping abstract allocation in $owner.${method.name}: " +
                        "$replacement has no constructor matching $constructorDescriptors " +
                        "(dex2jar likely inlined the constructor) — left as-is"
                }
                return@forEach
            }

            if (rewriteAllocations(method, abstractType, replacement)) {
                missingDescriptors.forEach { descriptor ->
                    if (replacementNode!!.methods.none { it.name == "<init>" && it.desc == descriptor }) {
                        replacementNode.methods.add(forwardingConstructor(abstractType, descriptor))
                        changedClasses += replacement
                    }
                }
                changed = true
                logger.info {
                    "Restored dex allocation in $owner.${method.name}: " +
                        "NEW $abstractType → NEW $replacement (×$missing)"
                }
            }
        }
        return changed
    }

    private fun forwardingConstructor(
        parent: String,
        descriptor: String,
    ): MethodNode =
        MethodNode(Opcodes.ACC_PUBLIC or Opcodes.ACC_SYNTHETIC, "<init>", descriptor, null, null).apply {
            visitCode()
            visitVarInsn(Opcodes.ALOAD, 0)
            var local = 1
            Type.getArgumentTypes(descriptor).forEach { argument ->
                visitVarInsn(argument.getOpcode(Opcodes.ILOAD), local)
                local += argument.size
            }
            visitMethodInsn(Opcodes.INVOKESPECIAL, parent, "<init>", descriptor, false)
            visitInsn(Opcodes.RETURN)
            visitMaxs(local, local)
            visitEnd()
        }

    /** 该方法里所有以 [abstractType] 为 owner 的构造调用描述符。 */
    private fun constructorDescriptorsFor(
        method: MethodNode,
        abstractType: String,
    ): Set<String> =
        method.instructions
            .toArray()
            .filterIsInstance<MethodInsnNode>()
            .filter {
                it.opcode == Opcodes.INVOKESPECIAL &&
                    it.name == "<init>" &&
                    it.owner == abstractType
            }.map(MethodInsnNode::desc)
            .toSet()

    /**
     * 把 `NEW abstractType` 及与之配对的 `INVOKESPECIAL abstractType.<init>` 换成
     * [replacement]。
     *
     * 按栈序配对：只有紧跟其后、尚未认领的那条 `<init>` 才算这次分配的构造调用。子类
     * `<init>` 里调 `super.<init>`（owner 同样是抽象基类）不会被误伤——那种方法里
     * 没有对应的 `NEW`。
     */
    private fun rewriteAllocations(
        method: MethodNode,
        abstractType: String,
        replacement: String,
    ): Boolean {
        val pending = ArrayDeque<TypeInsnNode>()
        val rewrites = mutableListOf<AbstractInsnNode>()
        method.instructions.toArray().forEach { insn ->
            when {
                insn is TypeInsnNode &&
                    insn.opcode == Opcodes.NEW &&
                    insn.desc == abstractType -> pending.addLast(insn)

                insn is MethodInsnNode &&
                    insn.opcode == Opcodes.INVOKESPECIAL &&
                    insn.name == "<init>" &&
                    insn.owner == abstractType &&
                    pending.isNotEmpty() -> {
                    rewrites += pending.removeLast()
                    rewrites += insn
                }
            }
        }
        // 配不上对的分配点原样留着：宁可保留一个明确的 InstantiationError，也不要
        // 制造出 NEW 与 <init> 类型不一致的、过不了校验器的字节码。
        if (rewrites.isEmpty() || pending.isNotEmpty()) return false
        rewrites.forEach { insn ->
            when (insn) {
                is TypeInsnNode -> insn.desc = replacement
                is MethodInsnNode -> insn.owner = replacement
                else -> Unit
            }
        }
        return true
    }

    private fun isSubclassOf(
        type: String,
        ancestor: String,
        shapes: ClassShapeResolver,
    ): Boolean {
        var current: String? = type
        var hops = 0
        while (current != null && hops < 64) {
            if (current == ancestor) return true
            current = shapes[current]?.superName
            hops++
        }
        return false
    }

    /**
     * 先查扩展 jar 内的类，查不到就走宿主 classpath。
     *
     * 运行期扩展类由 parent-first 的 `URLClassLoader` 加载（[PackageTools] 里那个），
     * 宿主提供的 `eu.kanade.tachiyomi.**` 会解析到 sidecar 自己这份，所以这里的两级查找
     * 与真实解析路径一致。查不到的类返回 null，调用方一律保守放过。
     */
    private class ClassShapeResolver(
        private val inJar: Map<String, ClassShape>,
    ) {
        private val hostCache = mutableMapOf<String, ClassShape?>()

        operator fun get(internalName: String): ClassShape? =
            inJar[internalName] ?: hostCache.getOrPut(internalName) { resolveFromHost(internalName) }

        private fun resolveFromHost(internalName: String): ClassShape? =
            runCatching {
                val loaded =
                    Class.forName(
                        internalName.replace('/', '.'),
                        false,
                        DexAllocationRepair::class.java.classLoader,
                    )
                ClassShape(
                    superName = loaded.superclass?.name?.replace('.', '/'),
                    isAbstract =
                        java.lang.reflect.Modifier
                            .isAbstract(loaded.modifiers),
                    isInterface = loaded.isInterface,
                    constructors =
                        loaded.declaredConstructors
                            .map {
                                org.objectweb.asm.Type
                                    .getConstructorDescriptor(it)
                            }.toSet(),
                    accessibleConstructors =
                        loaded.declaredConstructors
                            .filter {
                                java.lang.reflect.Modifier
                                    .isPublic(it.modifiers) ||
                                    java.lang.reflect.Modifier
                                        .isProtected(it.modifiers)
                            }.map { Type.getConstructorDescriptor(it) }
                            .toSet(),
                )
            }.getOrNull()
    }

    private fun methodKey(
        owner: String,
        name: String,
        desc: String,
    ): String = "$owner#$name#$desc"

    /** `Lfoo/Bar;` → `foo/Bar`；已经是 internal name 的原样返回。 */
    private fun internalName(descriptor: String): String =
        if (descriptor.length > 2 && descriptor.startsWith("L") && descriptor.endsWith(";")) {
            descriptor.substring(1, descriptor.length - 1)
        } else {
            descriptor
        }

    private data class ClassShape(
        val superName: String?,
        val isAbstract: Boolean,
        val isInterface: Boolean,
        val constructors: Set<String> = emptySet(),
        val accessibleConstructors: Set<String> = emptySet(),
    ) {
        val isInstantiable: Boolean get() = !isAbstract && !isInterface
    }
}
