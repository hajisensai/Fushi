package mextensionserver.util

import com.googlecode.d2j.node.DexFileNode
import com.googlecode.d2j.node.insn.TypeStmtNode
import com.googlecode.d2j.reader.MultiDexFileReader
import com.googlecode.d2j.reader.Op
import io.github.oshai.kotlinlogging.KotlinLogging
import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.Opcodes
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
 * 用原始 dex 里携带的精确分配类型，修回 dex2jar 泛化掉的 `NEW`。
 *
 * ## 这个 pass 修的是什么
 *
 * dex 的 `new-instance` 指令自带精确类型，但 dex2jar 在把寄存器式 dex 翻成栈式
 * JVM 字节码时要做类型推断；当同一个分配点在控制流上与别的分支合并，它会把类型
 * 取成两者的**公共父类**。如果那个父类是抽象类，产出的字节码就变成 `NEW <抽象类>`
 * ——JVM 规范明令禁止，运行到那条指令必然 `InstantiationError`。
 *
 * 实测（keiyoushi koharu 扩展，`Lp;.getFilterList`）：
 *
 *   dex : new-instance Lp0;                      (p0 = public final, extends Filter$Group)
 *   jar : NEW eu/kanade/tachiyomi/source/model/Filter$Group
 *         INVOKESPECIAL eu/kanade/tachiyomi/source/model/Filter$Group.<init>(String, List)
 *
 * 同一个方法里另外 8 个 `Lb1;`（同样 extends Filter$Group、构造器签名同为
 * `(String, List)`）却完好无损——所以这不是「宿主少了什么类」，而是单个分配点被
 * 泛化。症状是打开该源的搜索页直接 500：
 *
 *   java.lang.InstantiationError: eu.kanade.tachiyomi.source.model.Filter$Group
 *       at p.getFilterList(Unknown Source)
 *       at mextensionserver.impl.MihonInvoker.invokeFiltersManga(MihonInvoker.kt:178)
 *
 * `NEW` 与配对的 `INVOKESPECIAL <init>` **两处 owner 都被改写**，所以没法只看字节码
 * 本地恢复，必须回到原始 dex 取真值。
 *
 * ## 判据（可判定，不猜）
 *
 * - 只碰 `NEW T` 且 T 是抽象类或接口。这类指令**一定**是转换 bug——合法字节码不可能
 *   实例化抽象类，所以不存在「本来就对、被我改坏」的情况。
 * - 候选只从**同一方法的原始 dex 分配集合**里取，不从全 jar 猜。
 * - 必须能唯一对账：dex 里有、jar 里少掉的具体子类恰好一个，且缺口数正好等于
 *   `NEW T` 的条数。有歧义就原样放过——宁可继续报 `InstantiationError`
 *   （错误明确、可追）也不写进一个语义错误的 filter 类型。
 *
 * 与上游 [BytecodeEditor] 的 `repairAllocation` 不重叠：那条走的是「按期望类型在全
 * jar 里挑兼容候选」，兜底甚至会任选一个未认领的无参构造类；这里只用原始 dex 的真值
 * 对账，且只处理抽象类分配。
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
        val allocations =
            runCatching { readDexAllocations(dexFile) }
                .onFailure { logger.warn(it) { "Unable to read dex allocations from $dexFile" } }
                .getOrNull()
                ?: return
        restoreWithAllocations(jarFile, allocations)
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
    private fun readDexAllocations(dexFile: Path): Map<String, List<String>> {
        val reader = MultiDexFileReader.open(Files.readAllBytes(dexFile))
        val fileNode = DexFileNode()
        reader.accept(fileNode)

        val allocations = mutableMapOf<String, MutableList<String>>()
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
            }
        }
        return allocations
    }

    private fun rewriteJar(
        jarFile: Path,
        allocations: Map<String, List<String>>,
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
                    )
            }

            // 扩展把宿主的 source-api 当 compileOnly，`Filter$Group` 这类基类**不在扩展
            // jar 里**，只存在于 sidecar 自己的 classpath（运行期由 parent-first 的
            // URLClassLoader 解析过去）。只看 jar 内的类会把它们当成「查不到」而整条放过，
            // 于是这个 pass 一个分配点都修不到。查不到就回落到宿主 classpath 反射，
            // 与运行期的解析路径一致。
            val shapes = ClassShapeResolver(info)

            nodes.forEach { (path, node) ->
                var changed = false
                node.methods.forEach { method ->
                    if (repairMethod(node.name, method, allocations, shapes)) changed = true
                }
                if (!changed) return@forEach
                val writer = ClassWriter(0)
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

            // 只改 owner 是不够的：dex2jar 有时把整个构造**内联**掉，连描述符一起换成父类
            // 的（实测 koharu 的 `Lp0;`——它在 dex 里是 `<init>(Lp;)V` 的 Kotlin 内部类，
            // 却被转成了 `Filter$Group.<init>(String, List)`，栈上的实参也跟着变了）。
            // 那种情况下光把 owner 改回 p0 只会把 InstantiationError 换成
            // NoSuchMethodError——同样不可用，还更难查。候选类必须真的有这个签名的构造器
            // 才动手；否则原样留着那个语义明确的 InstantiationError。
            val constructorDescriptors = constructorDescriptorsFor(method, abstractType)
            if (constructorDescriptors.any { it !in replacementShape.constructors }) {
                logger.warn {
                    "Skipping abstract allocation in $owner.${method.name}: " +
                        "$replacement has no constructor matching $constructorDescriptors " +
                        "(dex2jar likely inlined the constructor) — left as-is"
                }
                return@forEach
            }

            if (rewriteAllocations(method, abstractType, replacement)) {
                changed = true
                logger.info {
                    "Restored dex allocation in $owner.${method.name}: " +
                        "NEW $abstractType → NEW $replacement (×$missing)"
                }
            }
        }
        return changed
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
                    isAbstract = java.lang.reflect.Modifier.isAbstract(loaded.modifiers),
                    isInterface = loaded.isInterface,
                    constructors =
                        loaded.declaredConstructors
                            .map { org.objectweb.asm.Type.getConstructorDescriptor(it) }
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
    ) {
        val isInstantiable: Boolean get() = !isAbstract && !isInterface
    }
}
