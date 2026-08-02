package mextensionserver.util

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import io.github.oshai.kotlinlogging.KotlinLogging
import org.objectweb.asm.ClassReader
import org.objectweb.asm.ClassVisitor
import org.objectweb.asm.ClassWriter
import org.objectweb.asm.FieldVisitor
import org.objectweb.asm.Handle
import org.objectweb.asm.MethodVisitor
import org.objectweb.asm.Opcodes
import org.objectweb.asm.Type
import org.objectweb.asm.tree.ClassNode
import org.objectweb.asm.tree.FieldInsnNode
import org.objectweb.asm.tree.MethodInsnNode
import org.objectweb.asm.tree.TypeInsnNode
import org.objectweb.asm.tree.analysis.Analyzer
import org.objectweb.asm.tree.analysis.SourceInterpreter
import org.objectweb.asm.tree.analysis.SourceValue
import java.nio.file.FileSystems
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardOpenOption
import java.util.ArrayDeque
import kotlin.streams.asSequence

object BytecodeEditor {
    private val logger = KotlinLogging.logger {}

    /**
     * Replace some java class references inside a jar with new ones that behave like Androids
     *
     * @param jarFile The JarFile to replace class references in
     */
    fun fixAndroidClasses(jarFile: Path) {
        FileSystems.newFileSystem(jarFile, null as ClassLoader?)?.use {
            val classes =
                Files
                    .walk(it.getPath("/"))
                    .asSequence()
                    .filterNotNull()
                    .filterNot(Files::isDirectory)
                    .mapNotNull(::getClassBytes)
                    .toList()
            val hierarchy = ClassHierarchy(classes.map(Pair<Path, ByteArray>::second))
            val repairedClasses =
                classes.map { (path, bytes) ->
                    path to hierarchy.repairDexAllocations(bytes)
                }
            hierarchy.findSyntheticConstructors(repairedClasses.map(Pair<Path, ByteArray>::second))
            repairedClasses
                .asSequence()
                .map { classFile -> transform(classFile, hierarchy) }
                .forEach(::write)
        }
    }

    /**
     * Get class bytes from a [Path]
     *
     * @param path The path entry to get the class bytes from
     *
     * @return [Pair] of the [Path] plus the class [ByteArray], or null if it's not a valid class
     */
    private fun getClassBytes(path: Path): Pair<Path, ByteArray>? {
        return try {
            if (path.toString().endsWith(".class")) {
                val bytes = Files.readAllBytes(path)
                if (bytes.size < 4) {
                    // Invalid class size
                    return null
                }
                val cafebabe =
                    String.format(
                        "%02X%02X%02X%02X",
                        bytes[0],
                        bytes[1],
                        bytes[2],
                        bytes[3],
                    )
                if (cafebabe.lowercase() != "cafebabe") {
                    // Corrupted class
                    return null
                }

                path to bytes
            } else {
                null
            }
        } catch (e: Exception) {
            logger.error(e) { "Error loading class from Path: $path" }
            null
        }
    }

    /**
     * The path where replacement classes will reside
     */
    private const val REPLACEMENT_PATH = "xyz/nulldev/androidcompat/replace"

    /**
     * List of classes that will be replaced
     */
    private val classesToReplace =
        listOf(
            "java/text/SimpleDateFormat",
        )

    /**
     * Replace direct references to the class, used on places
     * that don't have any other text then the class
     *
     * @return [String] of class or null if [String] was null
     */
    private fun String?.replaceDirectly() =
        when (this) {
            null -> null
            in classesToReplace -> "$REPLACEMENT_PATH/$this"
            else -> this
        }

    /**
     * Replace references to the class, used in places that have
     * other text around the class references
     *
     * @return [String] with class references replaced, or null if [String] was null
     */
    private fun String?.replaceIndirectly(): String? {
        if (this == null) return null
        var classReference: String = this
        classesToReplace.forEach {
            classReference = classReference.replace(it, "$REPLACEMENT_PATH/$it")
        }
        return classReference
    }

    /**
     * Replace all references to certain classes inside the class file
     * with ones that behave more like Androids
     *
     * @param pair Class bytecode to load into ASM for ease of modification
     *
     * @return [ByteArray] with modified bytecode
     */
    private fun transform(
        pair: Pair<Path, ByteArray>,
        hierarchy: ClassHierarchy,
    ): Pair<Path, ByteArray> {
        // Read the class and prepare to modify it
        val cr = ClassReader(pair.second)
        // dex2jar output can have missing or stale StackMapTable entries. Rebuild
        // them using actual class hierarchy metadata. Returning Object for every
        // merge corrupts uninitialized constructor values in obfuscated classes.
        val cw =
            object : ClassWriter(ClassWriter.COMPUTE_FRAMES or ClassWriter.COMPUTE_MAXS) {
                override fun getCommonSuperClass(
                    type1: String,
                    type2: String,
                ): String = hierarchy.commonSuperClass(type1, type2)
            }
        val syntheticConstructors = hierarchy.syntheticConstructors(cr.className)
        // Modify the class
        cr.accept(
            object : ClassVisitor(Opcodes.ASM9, cw) {
                // Modify field descriptor, for example
                // class MangaYes {
                //     val format = SimpleDateFormat("YYYY-MM-dd")
                // }
                override fun visitField(
                    access: Int,
                    name: String?,
                    desc: String?,
                    signature: String?,
                    cst: Any?,
                ): FieldVisitor? {
                    logger.trace { "CLass Field" to "${desc.replaceIndirectly()}: ${cst?.let { it::class.java.simpleName }}: $cst" }
                    return super.visitField(access, name, desc.replaceIndirectly(), signature, cst)
                }

                override fun visit(
                    version: Int,
                    access: Int,
                    name: String?,
                    signature: String?,
                    superName: String?,
                    interfaces: Array<out String>?,
                ) {
                    logger.trace { "Visiting $name: $signature: $superName" }
                    super.visit(version, access, name, signature, superName, interfaces)
                }

                // Modify method bytecode, for example
                // class MangaYes {
                //     fun fetchChapterList() {
                //         SimpleDateFormat("YYYY-MM-dd")
                //     }
                // }
                override fun visitMethod(
                    access: Int,
                    name: String,
                    desc: String,
                    signature: String?,
                    exceptions: Array<String?>?,
                ): MethodVisitor {
                    logger.trace { "Processing method $name: ${desc.replaceIndirectly()}: $signature" }
                    val mv: MethodVisitor? =
                        super.visitMethod(
                            access,
                            name,
                            desc.replaceIndirectly(),
                            signature,
                            exceptions,
                        )
                    val methodName = name
                    return object : MethodVisitor(Opcodes.ASM9, mv) {
                        private val pendingConstructions = ArrayDeque<String>()

                        override fun visitLdcInsn(cst: Any?) {
                            logger.trace { "Ldc" to "${cst?.let { "${it::class.java.simpleName}: $it" }}" }
                            super.visitLdcInsn(cst)
                        }

                        // Replace method type, for example
                        // val format = DateFormat()
                        // fun fetchChapterList() {
                        //     if (format is SimpleDateFormat)
                        // }
                        override fun visitTypeInsn(
                            opcode: Int,
                            type: String?,
                        ) {
                            val replacementType = type.replaceDirectly()
                            logger.trace {
                                "Type" to "$opcode: $replacementType"
                            }
                            if (opcode == Opcodes.NEW && replacementType != null) {
                                pendingConstructions.addLast(replacementType)
                            }
                            super.visitTypeInsn(
                                opcode,
                                replacementType,
                            )
                        }

                        // Replace method field, for example
                        // fun fetchChapterList() {
                        //     val format = SimpleDateFormat("YYYY-MM-dd")
                        // }
                        override fun visitMethodInsn(
                            opcode: Int,
                            owner: String?,
                            name: String?,
                            desc: String?,
                            itf: Boolean,
                        ) {
                            var replacementOwner = owner.replaceDirectly()
                            if (
                                methodName == "<init>" &&
                                name == "<init>" &&
                                desc != null &&
                                pendingConstructions.isEmpty() &&
                                hierarchy.needsSuperConstructorRedirect(cr.className, desc) &&
                                replacementOwner != cr.className &&
                                replacementOwner != cr.superName
                            ) {
                                replacementOwner = cr.superName
                            }
                            if (opcode == Opcodes.INVOKESPECIAL && name == "<init>" && pendingConstructions.isNotEmpty()) {
                                val constructedType = pendingConstructions.last()
                                if (replacementOwner == constructedType) {
                                    pendingConstructions.removeLast()
                                } else if (
                                    desc != null &&
                                    hierarchy.needsConstructorRedirect(constructedType, desc) &&
                                    replacementOwner != null &&
                                    hierarchy.isAncestor(replacementOwner, constructedType)
                                ) {
                                    // dex2jar can emit `new Child` followed by
                                    // `Object.<init>` and omit Child's trivial
                                    // constructor. That is legal in DEX but not
                                    // in JVM bytecode.
                                    replacementOwner = constructedType
                                    pendingConstructions.removeLast()
                                }
                            }
                            logger.trace {
                                "Method" to "$opcode: $replacementOwner: $name: ${desc.replaceIndirectly()}"
                            }
                            super.visitMethodInsn(
                                opcode,
                                replacementOwner,
                                name,
                                desc.replaceIndirectly(),
                                itf,
                            )
                        }

                        // Replace class field call from method, for example
                        // val format = SimpleDateFormat("YYYY-MM-dd")
                        // fun fetchChapterList() {
                        //     format.format(Date())
                        // }
                        override fun visitFieldInsn(
                            opcode: Int,
                            owner: String?,
                            name: String?,
                            desc: String?,
                        ) {
                            logger.trace { "Field" to "$opcode: $owner: $name: ${desc.replaceIndirectly()}" }
                            super.visitFieldInsn(opcode, owner, name, desc.replaceIndirectly())
                        }

                        override fun visitInvokeDynamicInsn(
                            name: String?,
                            desc: String?,
                            bsm: Handle?,
                            vararg bsmArgs: Any?,
                        ) {
                            logger.trace { "InvokeDynamic" to "$name: $desc" }
                            super.visitInvokeDynamicInsn(name, desc, bsm, *bsmArgs)
                        }
                    }
                }

                override fun visitEnd() {
                    syntheticConstructors.forEach { descriptor ->
                        visitMethod(Opcodes.ACC_PUBLIC, "<init>", descriptor, null, null)?.apply {
                            visitCode()
                            visitVarInsn(Opcodes.ALOAD, 0)
                            var localIndex = 1
                            Type.getArgumentTypes(descriptor).forEach { argument ->
                                visitVarInsn(argument.getOpcode(Opcodes.ILOAD), localIndex)
                                localIndex += argument.size
                            }
                            visitMethodInsn(
                                Opcodes.INVOKESPECIAL,
                                hierarchy.superName(cr.className),
                                "<init>",
                                descriptor,
                                false,
                            )
                            visitInsn(Opcodes.RETURN)
                            visitMaxs(0, 0)
                            visitEnd()
                        }
                    }
                    super.visitEnd()
                }
            },
            ClassReader.SKIP_FRAMES,
        )
        return pair.first to cw.toByteArray()
    }

    private fun write(pair: Pair<Path, ByteArray>) {
        Files.write(
            pair.first,
            pair.second,
            StandardOpenOption.CREATE,
            StandardOpenOption.TRUNCATE_EXISTING,
        )
    }

    private data class ClassInfo(
        val superName: String?,
        val interfaces: List<String>,
        val isInterface: Boolean,
        val isAbstract: Boolean,
        val constructors: Set<String>,
    )

    /**
     * Resolves hierarchy information from class bytes instead of loading classes.
     * Loading dex2jar output would itself trigger verification before it is fixed.
     */
    private class ClassHierarchy(
        classBytes: List<ByteArray>,
    ) {
        private val classes = mutableMapOf<String, ClassInfo?>()
        private val bytecode = mutableMapOf<String, ByteArray>()
        private val lazyValueTypes = mutableMapOf<String, String>()
        private val functionReturnTypes = mutableMapOf<String, String?>()
        private val methodDescriptorRedirects = mutableMapOf<String, String>()
        private val syntheticConstructors = mutableMapOf<String, MutableSet<String>>()
        private val constructorRedirects = mutableMapOf<String, MutableSet<String>>()
        private val superConstructorRedirects = mutableMapOf<String, MutableSet<String>>()
        private val claimedErasedCandidates = mutableSetOf<String>()
        private val classLoader = BytecodeEditor::class.java.classLoader

        init {
            classBytes.forEach { bytes ->
                val reader = ClassReader(bytes)
                classes[reader.className] = reader.toClassInfo()
                bytecode[reader.className] = bytes
            }
            classBytes.forEach(::findReturnTypeRedirects)
            repeat(3) {
                classBytes.forEach(::findArgumentTypeRedirects)
            }
            classBytes.forEach(::collectLazyValueTypes)
        }

        fun findSyntheticConstructors(classBytes: List<ByteArray>) {
            classBytes.forEach(::findSyntheticConstructors)
        }

        fun commonSuperClass(
            type1: String,
            type2: String,
        ): String {
            if (type1 == type2) return type1
            if (type1.startsWith("[") || type2.startsWith("[")) {
                return commonArrayType(type1, type2)
            }
            if (isAssignableFrom(type1, type2)) return type1
            if (isAssignableFrom(type2, type1)) return type2
            if (classInfo(type1)?.isInterface == true || classInfo(type2)?.isInterface == true) {
                return OBJECT
            }

            var current = classInfo(type1)?.superName
            while (current != null) {
                if (isAssignableFrom(current, type2)) return current
                current = classInfo(current)?.superName
            }
            return OBJECT
        }

        fun superName(name: String): String? = classInfo(name)?.superName

        fun syntheticConstructors(name: String): Set<String> = syntheticConstructors[name].orEmpty()

        fun needsConstructorRedirect(
            name: String,
            descriptor: String,
        ): Boolean = descriptor in constructorRedirects[name].orEmpty()

        fun needsSuperConstructorRedirect(
            name: String,
            descriptor: String,
        ): Boolean = descriptor in superConstructorRedirects[name].orEmpty()

        fun isAncestor(
            target: String,
            source: String,
        ): Boolean = isAssignableFrom(target, source)

        private fun commonArrayType(
            type1: String,
            type2: String,
        ): String {
            if (!type1.startsWith("[") || !type2.startsWith("[")) return OBJECT
            if (type1 == type2) return type1

            val element1 = type1.removePrefix("[")
            val element2 = type2.removePrefix("[")
            if (!element1.startsWith("L") || !element2.startsWith("L")) return OBJECT

            val common =
                commonSuperClass(
                    element1.removeSurrounding("L", ";"),
                    element2.removeSurrounding("L", ";"),
                )
            return "[L$common;"
        }

        private fun isAssignableFrom(
            target: String,
            source: String,
            visited: MutableSet<String> = mutableSetOf(),
        ): Boolean {
            if (target == source || target == OBJECT) return true
            if (!visited.add(source)) return false
            val sourceInfo = classInfo(source) ?: return false
            return sourceInfo.superName?.let { isAssignableFrom(target, it, visited) } == true ||
                sourceInfo.interfaces.any { isAssignableFrom(target, it, visited) }
        }

        private fun classInfo(name: String): ClassInfo? {
            if (classes.containsKey(name)) return classes[name]
            val info =
                classLoader
                    .getResourceAsStream("$name.class")
                    ?.use { ClassReader(it).toClassInfo() }
            classes[name] = info
            return info
        }

        fun repairDexAllocations(bytes: ByteArray): ByteArray {
            val node = ClassNode(Opcodes.ASM9)
            ClassReader(bytes).accept(node, 0)
            var changed = false

            node.methods.forEach { method ->
                methodDescriptorRedirects[methodKey(node.name, method.name, method.desc)]?.let {
                    method.desc = it
                    changed = true
                }
                method.instructions
                    .toArray()
                    .filterIsInstance<MethodInsnNode>()
                    .forEach { invocation ->
                        methodDescriptorRedirects[
                            methodKey(invocation.owner, invocation.name, invocation.desc),
                        ]?.let {
                            invocation.desc = it
                            changed = true
                        }
                    }
            }

            node.methods.forEach { method ->
                val narrowedTypes =
                    method.instructions
                        .toArray()
                        .filterIsInstance<TypeInsnNode>()
                        .filter { it.opcode == Opcodes.INSTANCEOF }
                        .map(TypeInsnNode::desc)
                        .toSet()
                method.instructions
                    .toArray()
                    .filterIsInstance<FieldInsnNode>()
                    .filter { it.opcode == Opcodes.GETFIELD && it.owner in narrowedTypes }
                    .forEach { field ->
                        method.instructions.insertBefore(field, TypeInsnNode(Opcodes.CHECKCAST, field.owner))
                        changed = true
                    }

                if (narrowedTypes.isNotEmpty()) {
                    method.instructions
                        .toArray()
                        .filterIsInstance<FieldInsnNode>()
                        .filter { it.opcode == Opcodes.PUTFIELD && it.owner in narrowedTypes }
                        .forEach { field ->
                            val valueType = Type.getType(field.desc)
                            val valueLocal = method.maxLocals
                            method.maxLocals += valueType.size
                            val castReceiver =
                                org.objectweb.asm.tree.InsnList().apply {
                                    add(
                                        org.objectweb.asm.tree.VarInsnNode(
                                            valueType.getOpcode(Opcodes.ISTORE),
                                            valueLocal,
                                        ),
                                    )
                                    add(TypeInsnNode(Opcodes.CHECKCAST, field.owner))
                                    add(
                                        org.objectweb.asm.tree.VarInsnNode(
                                            valueType.getOpcode(Opcodes.ILOAD),
                                            valueLocal,
                                        ),
                                    )
                                }
                            method.instructions.insertBefore(field, castReceiver)
                            changed = true
                        }
                }

                val frames =
                    runCatching {
                        Analyzer(
                            object : SourceInterpreter(Opcodes.ASM9) {
                                override fun copyOperation(
                                    instruction: org.objectweb.asm.tree.AbstractInsnNode,
                                    value: SourceValue,
                                ): SourceValue = value
                            },
                        ).analyze(node.name, method)
                    }.getOrNull() ?: return@forEach

                repairAbstractArrayAllocations(method.instructions.toArray(), frames).also {
                    changed = changed || it
                }

                method.instructions.toArray().forEachIndexed { index, instruction ->
                    val frame = frames[index] ?: return@forEachIndexed
                    when (instruction) {
                        is FieldInsnNode ->
                            when (instruction.opcode) {
                                Opcodes.PUTFIELD -> {
                                    repairAllocation(
                                        frame.getStack(frame.stackSize - 2),
                                        instruction.owner,
                                    ).also {
                                        changed = changed || it
                                    }
                                    val expectedType = Type.getType(instruction.desc)
                                    if (expectedType.sort == Type.OBJECT) {
                                        repairAllocation(
                                            frame.getStack(frame.stackSize - 1),
                                            expectedType.internalName,
                                        ).also {
                                            changed = changed || it
                                        }
                                    }
                                }
                                Opcodes.PUTSTATIC -> {
                                    val expectedType = Type.getType(instruction.desc)
                                    if (expectedType.sort == Type.OBJECT) {
                                        repairAllocation(
                                            frame.getStack(frame.stackSize - 1),
                                            expectedType.internalName,
                                        ).also {
                                            changed = changed || it
                                        }
                                    }
                                }
                            }

                        is MethodInsnNode -> {
                            var stackIndex = frame.stackSize
                            Type.getArgumentTypes(instruction.desc).reversed().forEach { argument ->
                                stackIndex--
                                if (argument.sort == Type.OBJECT) {
                                    val expectedReturnType =
                                        if (
                                            argument.internalName == "kotlin/jvm/functions/Function0" &&
                                            instruction.owner == "kotlin/LazyKt"
                                        ) {
                                            instruction.lazyDestination()?.let(lazyValueTypes::get)
                                        } else {
                                            null
                                        }
                                    repairAllocation(
                                        frame.getStack(stackIndex),
                                        argument.internalName,
                                        expectedReturnType,
                                    ).also {
                                        changed = changed || it
                                    }
                                }
                            }
                            if (instruction.opcode != Opcodes.INVOKESTATIC) {
                                stackIndex--
                                repairAllocation(frame.getStack(stackIndex), instruction.owner).also {
                                    changed = changed || it
                                }
                            }
                        }

                        else -> {
                            if (instruction.opcode == Opcodes.AASTORE) {
                                val arrayValue = frame.getStack(frame.stackSize - 3)
                                val elementType =
                                    arrayValue.insns
                                        .filterIsInstance<TypeInsnNode>()
                                        .singleOrNull { it.opcode == Opcodes.ANEWARRAY }
                                        ?.desc
                                if (elementType != null) {
                                    repairAllocation(
                                        frame.getStack(frame.stackSize - 1),
                                        elementType,
                                    ).also {
                                        changed = changed || it
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if (!changed) return bytes
            return ClassWriter(0).also(node::accept).toByteArray()
        }

        private fun repairAbstractArrayAllocations(
            instructions: Array<org.objectweb.asm.tree.AbstractInsnNode>,
            frames: Array<org.objectweb.asm.tree.analysis.Frame<SourceValue>?>,
        ): Boolean {
            data class ArrayAllocations(
                val elementType: String,
                val allocations: MutableList<TypeInsnNode> = mutableListOf(),
            )

            val arrays = linkedMapOf<TypeInsnNode, ArrayAllocations>()
            instructions.forEachIndexed { index, instruction ->
                if (instruction.opcode != Opcodes.AASTORE) return@forEachIndexed
                val frame = frames[index] ?: return@forEachIndexed
                val array =
                    frame
                        .getStack(frame.stackSize - 3)
                        .insns
                        .filterIsInstance<TypeInsnNode>()
                        .singleOrNull { it.opcode == Opcodes.ANEWARRAY }
                        ?: return@forEachIndexed
                val allocation =
                    frame
                        .getStack(frame.stackSize - 1)
                        .insns
                        .filterIsInstance<TypeInsnNode>()
                        .singleOrNull { it.opcode == Opcodes.NEW && it.desc == array.desc }
                        ?: return@forEachIndexed
                arrays.getOrPut(array) { ArrayAllocations(array.desc) }.allocations.add(allocation)
            }

            var changed = false
            arrays.values.forEach { array ->
                val elementInfo = classInfo(array.elementType) ?: return@forEach
                if (!elementInfo.isInterface && !elementInfo.isAbstract) return@forEach

                val allocations = array.allocations.distinct()
                val candidates =
                    classes
                        .mapNotNull { (name, info) ->
                            name.takeIf {
                                info != null &&
                                    !info.isInterface &&
                                    !info.isAbstract &&
                                    info.superName == array.elementType &&
                                    isAssignableFrom(array.elementType, name)
                            }
                        }
                // Multi-source extension factories may be translated as an array
                // containing repeated allocations of their abstract source base.
                // Only restore the concrete types when the factory has a complete
                // one-to-one set, so no ambiguous allocation is guessed.
                if (allocations.size > 1 && allocations.size == candidates.size) {
                    allocations.zip(candidates).forEach { (allocation, candidate) ->
                        allocation.desc = candidate
                    }
                    changed = true
                }
            }
            return changed
        }

        private fun repairAllocation(
            value: SourceValue,
            expectedType: String,
            expectedReturnType: String? = null,
        ): Boolean {
            val expectedInfo = classInfo(expectedType) ?: return false

            var changed = false
            val allocations =
                value.insns
                    .filterIsInstance<TypeInsnNode>()
                    .filter { it.opcode == Opcodes.NEW }
                    .distinct()
            // A merged source value can represent different allocations from
            // separate control-flow branches. Mutating all of them to the type
            // required by just one branch swaps otherwise valid concrete types.
            if (allocations.size != 1) return false
            allocations.forEach { allocation ->
                val replacementType =
                    if (!expectedInfo.isInterface && !expectedInfo.isAbstract) {
                        expectedType.takeIf {
                            allocation.desc == expectedInfo.superName ||
                                (
                                    allocation.desc != expectedType &&
                                        classInfo(allocation.desc)?.superName == expectedInfo.superName
                                )
                        }
                    } else {
                        val candidates =
                            classes
                                .toList()
                                .asSequence()
                                .mapNotNull { (name, info) -> name to (info ?: return@mapNotNull null) }
                                .filter { (_, info) ->
                                    !info.isInterface &&
                                        !info.isAbstract
                                }.map { (name, _) -> name }
                                .filter { candidate -> isAssignableFrom(allocation.desc, candidate) }
                                .filter { candidate -> isAssignableFrom(expectedType, candidate) }
                                .toList()
                        val descriptor = allocation.constructorDescriptor()
                        val compatibleCandidates =
                            descriptor
                                ?.let {
                                    candidates.filter { candidate ->
                                        classInfo(candidate)?.constructors.orEmpty().let { constructors ->
                                            constructors.isEmpty() || descriptor in constructors
                                        }
                                    }
                                }.orEmpty()
                        val returnCompatibleCandidates =
                            expectedReturnType
                                ?.let { returnType ->
                                    compatibleCandidates.filter { candidate ->
                                        inferredFunctionReturnType(candidate)?.let {
                                            isAssignableFrom(returnType, it)
                                        } == true
                                    }
                                }.orEmpty()
                        (
                            candidates.singleOrNull()
                                ?: compatibleCandidates.singleOrNull()
                                ?: returnCompatibleCandidates.singleOrNull()
                                ?: compatibleCandidates
                                    .takeIf {
                                        it.isNotEmpty() &&
                                            !isAssignableFrom("java/lang/Enum", expectedType) &&
                                            it.all { candidate -> classInfo(candidate)?.constructors?.isEmpty() == true }
                                    }?.firstOrNull { it !in claimedErasedCandidates }
                        )?.also(claimedErasedCandidates::add)
                    }
                if (replacementType != null) {
                    allocation.desc = replacementType
                    changed = true
                }
            }
            return changed
        }

        private fun MethodInsnNode.lazyDestination(): String? {
            var instruction = next
            while (instruction != null) {
                if (instruction is FieldInsnNode && instruction.opcode in listOf(Opcodes.PUTFIELD, Opcodes.PUTSTATIC)) {
                    return "${instruction.owner}.${instruction.name}"
                }
                if (
                    instruction is MethodInsnNode ||
                    instruction.opcode in listOf(Opcodes.ARETURN, Opcodes.RETURN)
                ) {
                    return null
                }
                instruction = instruction.next
            }
            return null
        }

        private fun collectLazyValueTypes(bytes: ByteArray) {
            val node = ClassNode(Opcodes.ASM9)
            ClassReader(bytes).accept(node, 0)
            node.methods.forEach { method ->
                val frames =
                    runCatching {
                        Analyzer(sourceInterpreter()).analyze(node.name, method)
                    }.getOrNull() ?: return@forEach
                method.instructions.toArray().forEachIndexed { index, instruction ->
                    if (
                        instruction !is MethodInsnNode ||
                        instruction.owner != "kotlin/Lazy" ||
                        instruction.name != "getValue"
                    ) {
                        return@forEachIndexed
                    }
                    val frame = frames[index] ?: return@forEachIndexed
                    val field =
                        frame
                            .getStack(frame.stackSize - 1)
                            .insns
                            .filterIsInstance<FieldInsnNode>()
                            .singleOrNull()
                            ?: return@forEachIndexed
                    var next = instruction.next
                    while (next != null && next.opcode < 0) next = next.next
                    val cast = next as? TypeInsnNode
                    if (cast?.opcode == Opcodes.CHECKCAST) {
                        lazyValueTypes["${field.owner}.${field.name}"] = cast.desc
                    }
                }
            }
        }

        private fun findReturnTypeRedirects(bytes: ByteArray) {
            val node = ClassNode(Opcodes.ASM9)
            ClassReader(bytes).accept(node, 0)
            node.methods.forEach { method ->
                val declaredReturn = Type.getReturnType(method.desc)
                if (declaredReturn.sort != Type.OBJECT) return@forEach
                val frames =
                    runCatching {
                        Analyzer(sourceInterpreter()).analyze(node.name, method)
                    }.getOrNull() ?: return@forEach
                val actualTypes =
                    method.instructions
                        .toArray()
                        .mapIndexedNotNull { index, instruction ->
                            if (instruction.opcode != Opcodes.ARETURN) return@mapIndexedNotNull null
                            val frame = frames[index] ?: return@mapIndexedNotNull null
                            inferredSourceType(frame.getStack(frame.stackSize - 1))
                        }.distinct()
                if (
                    actualTypes.isEmpty() ||
                    actualTypes.all { isAssignableFrom(declaredReturn.internalName, it) }
                ) {
                    return@forEach
                }
                val commonType = actualTypes.reduce(::commonSuperClass)
                if (commonType == OBJECT && declaredReturn.internalName != OBJECT) return@forEach
                val redirectedDescriptor =
                    Type.getMethodDescriptor(
                        Type.getObjectType(commonType),
                        *Type.getArgumentTypes(method.desc),
                    )
                methodDescriptorRedirects[methodKey(node.name, method.name, method.desc)] = redirectedDescriptor
            }
        }

        private fun findArgumentTypeRedirects(bytes: ByteArray) {
            val node = ClassNode(Opcodes.ASM9)
            ClassReader(bytes).accept(node, 0)
            node.methods.forEach { method ->
                val frames =
                    runCatching {
                        Analyzer(sourceInterpreter()).analyze(node.name, method)
                    }.getOrNull() ?: return@forEach
                method.instructions.toArray().forEachIndexed { index, instruction ->
                    val invocation = instruction as? MethodInsnNode ?: return@forEachIndexed
                    if (!classes.containsKey(invocation.owner)) return@forEachIndexed
                    val originalKey = methodKey(invocation.owner, invocation.name, invocation.desc)
                    val currentDescriptor = methodDescriptorRedirects[originalKey] ?: invocation.desc
                    val arguments = Type.getArgumentTypes(currentDescriptor)
                    val frame = frames[index] ?: return@forEachIndexed
                    var stackIndex = frame.stackSize
                    var changed = false
                    val widenedArguments = arguments.copyOf()
                    arguments.indices.reversed().forEach { argumentIndex ->
                        stackIndex--
                        val expected = arguments[argumentIndex]
                        if (expected.sort != Type.OBJECT) return@forEach
                        val actual = inferredSourceType(frame.getStack(stackIndex)) ?: return@forEach
                        if (!isAssignableFrom(expected.internalName, actual)) {
                            val common = commonSuperClass(expected.internalName, actual)
                            if (common != OBJECT) {
                                widenedArguments[argumentIndex] = Type.getObjectType(common)
                                changed = true
                            }
                        }
                    }
                    if (changed) {
                        methodDescriptorRedirects[originalKey] =
                            Type.getMethodDescriptor(
                                Type.getReturnType(currentDescriptor),
                                *widenedArguments,
                            )
                    }
                }
            }
        }

        private fun inferredSourceType(value: SourceValue): String? =
            value.insns
                .mapNotNull { producer ->
                    when (producer) {
                        is TypeInsnNode ->
                            producer.desc.takeIf { producer.opcode == Opcodes.NEW }
                        is MethodInsnNode ->
                            Type
                                .getReturnType(
                                    methodDescriptorRedirects[
                                        methodKey(producer.owner, producer.name, producer.desc),
                                    ] ?: producer.desc,
                                ).takeIf { it.sort == Type.OBJECT }
                                ?.internalName
                        is FieldInsnNode ->
                            Type
                                .getType(producer.desc)
                                .takeIf { it.sort == Type.OBJECT }
                                ?.internalName
                        else -> null
                    }
                }.distinct()
                .reduceOrNull(::commonSuperClass)

        private fun methodKey(
            owner: String,
            name: String,
            descriptor: String,
        ): String = "$owner.$name$descriptor"

        private fun inferredFunctionReturnType(className: String): String? =
            functionReturnTypes.getOrPut(className) {
                val bytes = bytecode[className] ?: return@getOrPut null
                val node = ClassNode(Opcodes.ASM9)
                ClassReader(bytes).accept(node, 0)
                val method =
                    node.methods.singleOrNull {
                        it.name == "invoke" && it.desc == "()Ljava/lang/Object;"
                    } ?: return@getOrPut null
                val frames =
                    runCatching {
                        Analyzer(sourceInterpreter()).analyze(node.name, method)
                    }.getOrNull() ?: return@getOrPut null
                val returnTypes =
                    method.instructions
                        .toArray()
                        .mapIndexedNotNull { index, instruction ->
                            if (instruction.opcode != Opcodes.ARETURN) return@mapIndexedNotNull null
                            val frame = frames[index] ?: return@mapIndexedNotNull null
                            frame
                                .getStack(frame.stackSize - 1)
                                .insns
                                .mapNotNull { producer ->
                                    when (producer) {
                                        is TypeInsnNode ->
                                            producer.desc.takeIf { producer.opcode == Opcodes.NEW }
                                        is MethodInsnNode ->
                                            Type
                                                .getReturnType(producer.desc)
                                                .takeIf { it.sort == Type.OBJECT }
                                                ?.internalName
                                        is FieldInsnNode ->
                                            Type
                                                .getType(producer.desc)
                                                .takeIf { it.sort == Type.OBJECT }
                                                ?.internalName
                                        else -> null
                                    }
                                }.singleOrNull()
                        }.distinct()
                returnTypes.singleOrNull()
            }

        private fun sourceInterpreter() =
            object : SourceInterpreter(Opcodes.ASM9) {
                override fun copyOperation(
                    instruction: org.objectweb.asm.tree.AbstractInsnNode,
                    value: SourceValue,
                ): SourceValue = value
            }

        private fun TypeInsnNode.constructorDescriptor(): String? {
            var instruction = next
            while (instruction != null) {
                if (
                    instruction is MethodInsnNode &&
                    instruction.opcode == Opcodes.INVOKESPECIAL &&
                    instruction.name == "<init>" &&
                    instruction.owner == desc
                ) {
                    return instruction.desc
                }
                instruction = instruction.next
            }
            return null
        }

        private fun findSyntheticConstructors(bytes: ByteArray) {
            val reader = ClassReader(bytes)
            val currentClass = reader.className
            reader.accept(
                object : ClassVisitor(Opcodes.ASM9) {
                    override fun visitMethod(
                        access: Int,
                        name: String?,
                        descriptor: String?,
                        signature: String?,
                        exceptions: Array<out String>?,
                    ): MethodVisitor {
                        val methodName = name
                        return object : MethodVisitor(Opcodes.ASM9) {
                            private val pendingConstructions = ArrayDeque<String>()

                            override fun visitTypeInsn(
                                opcode: Int,
                                type: String?,
                            ) {
                                if (opcode == Opcodes.NEW && type != null) {
                                    pendingConstructions.addLast(type.replaceDirectly())
                                }
                            }

                            override fun visitMethodInsn(
                                opcode: Int,
                                owner: String?,
                                name: String?,
                                descriptor: String?,
                                isInterface: Boolean,
                            ) {
                                if (
                                    methodName == "<init>" &&
                                    name == "<init>" &&
                                    descriptor != null &&
                                    pendingConstructions.isEmpty()
                                ) {
                                    val directSuper = classInfo(currentClass)?.superName
                                    if (
                                        directSuper != null &&
                                        owner != currentClass &&
                                        owner != directSuper
                                    ) {
                                        superConstructorRedirects
                                            .getOrPut(currentClass, ::mutableSetOf)
                                            .add(descriptor)
                                        val superInfo = classInfo(directSuper)
                                        if (superInfo != null && descriptor !in superInfo.constructors) {
                                            syntheticConstructors
                                                .getOrPut(directSuper, ::mutableSetOf)
                                                .add(descriptor)
                                        }
                                    }
                                }
                                if (
                                    opcode != Opcodes.INVOKESPECIAL ||
                                    name != "<init>" ||
                                    descriptor == null ||
                                    pendingConstructions.isEmpty()
                                ) {
                                    return
                                }

                                val constructedType = pendingConstructions.last()
                                val replacementOwner = owner.replaceDirectly() ?: return
                                if (replacementOwner == constructedType) {
                                    pendingConstructions.removeLast()
                                    return
                                }

                                val info = classInfo(constructedType) ?: return
                                if (
                                    !info.isInterface &&
                                    isAssignableFrom(replacementOwner, constructedType)
                                ) {
                                    constructorRedirects
                                        .getOrPut(constructedType, ::mutableSetOf)
                                        .add(descriptor)
                                    addForwardingConstructors(constructedType, replacementOwner, descriptor)
                                    pendingConstructions.removeLast()
                                }
                            }
                        }
                    }
                },
                ClassReader.SKIP_DEBUG or ClassReader.SKIP_FRAMES,
            )
        }

        private fun addForwardingConstructors(
            constructedType: String,
            originalOwner: String,
            descriptor: String,
        ) {
            var current: String? = constructedType
            while (current != null && current != originalOwner) {
                val info = classInfo(current) ?: return
                if (descriptor !in info.constructors) {
                    syntheticConstructors
                        .getOrPut(current, ::mutableSetOf)
                        .add(descriptor)
                }
                current = info.superName
            }
        }

        private fun ClassReader.toClassInfo(): ClassInfo {
            val constructors = mutableSetOf<String>()
            accept(
                object : ClassVisitor(Opcodes.ASM9) {
                    override fun visitMethod(
                        access: Int,
                        name: String?,
                        descriptor: String?,
                        signature: String?,
                        exceptions: Array<out String>?,
                    ): MethodVisitor? {
                        if (name == "<init>" && descriptor != null) constructors.add(descriptor)
                        return null
                    }
                },
                ClassReader.SKIP_CODE or ClassReader.SKIP_DEBUG or ClassReader.SKIP_FRAMES,
            )
            return ClassInfo(
                superName = superName,
                interfaces = interfaces.toList(),
                isInterface = access and Opcodes.ACC_INTERFACE != 0,
                isAbstract = access and Opcodes.ACC_ABSTRACT != 0,
                constructors = constructors,
            )
        }

        private companion object {
            const val OBJECT = "java/lang/Object"
        }
    }
}
