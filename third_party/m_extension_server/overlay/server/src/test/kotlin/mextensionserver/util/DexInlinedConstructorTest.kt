package mextensionserver.util

import com.googlecode.d2j.DexLabel
import com.googlecode.d2j.Field
import com.googlecode.d2j.Method
import com.googlecode.d2j.dex.Dex2jar
import com.googlecode.d2j.dex.writer.DexFileWriter
import com.googlecode.d2j.node.DexCodeNode
import com.googlecode.d2j.reader.MultiDexFileReader
import com.googlecode.d2j.reader.Op
import eu.kanade.tachiyomi.source.model.Filter
import org.objectweb.asm.Opcodes
import java.net.URLClassLoader
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

class DexInlinedConstructorTest {
    abstract class WideParent(
        val count: Long,
        val ratio: Double,
    )

    abstract class PrivateParent private constructor(
        val unused: Int,
    )

    private val parent = "Leu/kanade/tachiyomi/source/model/Filter\$Group;"
    private val constructor = Method(parent, "<init>", arrayOf("Ljava/lang/String;", "Ljava/util/List;"), "V")

    @Test
    fun `forwarding constructor preserves wide arguments and local slots`() {
        withHostParent(WideParent::class.java, arrayOf("J", "D")) { loader ->
            val value = loader.loadClass("HostParentFactory").getMethod("create").invoke(null) as WideParent
            assertEquals(9876543210L, value.count)
            assertEquals(2.5, value.ratio)
            assertEquals("HostParentChild", value.javaClass.name)
        }
    }

    @Test
    fun `does not synthesize a call to inaccessible superclass constructor`() {
        withHostParent(PrivateParent::class.java, arrayOf("I")) { loader ->
            assertFailsWith<InstantiationError> {
                try {
                    loader.loadClass("HostParentFactory").getMethod("create").invoke(null)
                } catch (wrapped: java.lang.reflect.InvocationTargetException) {
                    throw wrapped.cause!!
                }
            }
        }
    }

    private fun withHostParent(
        parentClass: Class<*>,
        arguments: Array<String>,
        verify: (URLClassLoader) -> Unit,
    ) {
        val dex = Files.createTempFile("host-parent-constructor", ".dex")
        val jar = Files.createTempFile("host-parent-constructor", ".jar")
        try {
            val descriptor = "L${parentClass.name.replace('.', '/')};"
            val writer = DexFileWriter()
            writer.visit(Opcodes.ACC_PUBLIC, "LHostParentChild;", descriptor, null).visitEnd()
            val factory = writer.visit(Opcodes.ACC_PUBLIC, "LHostParentFactory;", "Ljava/lang/Object;", null)
            val method =
                factory.visitMethod(
                    Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC,
                    Method("LHostParentFactory;", "create", emptyArray(), descriptor),
                )
            method.visitCode().apply {
                visitRegister(5)
                visitTypeStmt(Op.NEW_INSTANCE, 0, -1, "LHostParentChild;")
                if (arguments.contentEquals(arrayOf("I"))) {
                    visitConstStmt(Op.CONST_4, 1, 1)
                } else if (arguments.isNotEmpty()) {
                    visitConstStmt(Op.CONST_WIDE, 1, 9876543210L)
                    visitConstStmt(Op.CONST_WIDE, 3, java.lang.Double.doubleToRawLongBits(2.5))
                }
                visitMethodStmt(
                    Op.INVOKE_DIRECT_RANGE,
                    if (arguments.size == 1) intArrayOf(0, 1) else intArrayOf(0, 1, 2, 3, 4),
                    Method(descriptor, "<init>", arguments, "V"),
                )
                visitStmt1R(Op.RETURN_OBJECT, 0)
                visitEnd()
            }
            method.visitEnd()
            factory.visitEnd()
            writer.visitEnd()
            Files.write(dex, writer.toByteArray())
            // Isolate this pass: BytecodeEditor has a separate constructor
            // redirect pass, which would mask the inaccessible-parent boundary.
            Dex2jar.from(MultiDexFileReader.open(Files.readAllBytes(dex))).to(jar)
            DexAllocationRepair.restore(dex, jar)
            URLClassLoader(arrayOf(jar.toUri().toURL()), javaClass.classLoader).use(verify)
        } finally {
            Files.deleteIfExists(dex)
            Files.deleteIfExists(jar)
        }
    }

    @Test
    fun `real dex conversion preserves erased subclass and superclass arguments through a loop`() {
        val dex = Files.createTempFile("inlined-constructor", ".dex")
        val jar = Files.createTempFile("inlined-constructor", ".jar")
        try {
            val writer = DexFileWriter()
            writer.visit(Opcodes.ACC_PUBLIC or Opcodes.ACC_FINAL, "LErasedGroup;", parent, null).visitEnd()
            val factory = writer.visit(Opcodes.ACC_PUBLIC, "LInlinedFactory;", "Ljava/lang/Object;", null)
            val method =
                factory.visitMethod(
                    Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC,
                    Method("LInlinedFactory;", "create", emptyArray(), parent),
                )
            method.visitCode().apply {
                visitRegister(4)
                visitTypeStmt(Op.NEW_INSTANCE, 0, -1, "LErasedGroup;")
                visitConstStmt(Op.CONST_STRING, 1, "Japanese filters")
                visitMethodStmt(
                    Op.INVOKE_STATIC,
                    intArrayOf(),
                    Method("Ljava/util/Collections;", "emptyList", emptyArray(), "Ljava/util/List;"),
                )
                visitStmt1R(Op.MOVE_RESULT_OBJECT, 2)
                visitConstStmt(Op.CONST_4, 3, 1)
                val loop = DexLabel()
                visitLabel(loop)
                visitStmt2R1N(Op.ADD_INT_LIT8, 3, 3, -1)
                visitJumpStmt(Op.IF_NEZ, 3, -1, loop)
                visitMethodStmt(Op.INVOKE_DIRECT, intArrayOf(0, 1, 2), constructor)
                visitStmt1R(Op.RETURN_OBJECT, 0)
                visitEnd()
            }
            method.visitEnd()
            factory.visitEnd()
            writer.visitEnd()
            Files.write(dex, writer.toByteArray())
            PackageTools.dex2jar(dex.toFile(), jar.toFile())
            // A repeated repair must not duplicate the generated constructor.
            DexAllocationRepair.restore(dex, jar)
            URLClassLoader(arrayOf(jar.toUri().toURL()), javaClass.classLoader).use { loader ->
                val value = loader.loadClass("InlinedFactory").getMethod("create").invoke(null) as Filter.Group<*>
                assertEquals("ErasedGroup", value.javaClass.name)
                assertEquals("Japanese filters", value.name)
                assertTrue(value.state.isEmpty())
                assertEquals(1, value.javaClass.declaredConstructors.size)
            }
        } finally {
            Files.deleteIfExists(dex)
            Files.deleteIfExists(jar)
        }
    }

    @Test
    fun `proof rejects every register overwrite and alias escape`() {
        val operations: List<DexCodeNode.() -> Unit> =
            listOf(
                { visitConstStmt(Op.CONST_4, 3, 0) },
                { visitConstStmt(Op.CONST_WIDE, 2, 0L) },
                { visitStmt1R(Op.MOVE_RESULT_WIDE, 2) },
                { visitStmt2R(Op.MOVE_WIDE, 2, 7) },
                { visitStmt2R(Op.INT_TO_LONG, 2, 7) },
                { visitStmt2R(Op.MOVE_OBJECT, 4, 3) },
                { visitStmt2R1N(Op.ADD_INT_LIT8, 3, 7, 1) },
                { visitStmt3R(Op.ADD_DOUBLE, 2, 6, 8) },
                { visitStmt3R(Op.AGET_WIDE, 2, 6, 8) },
                { visitFieldStmt(Op.SGET_WIDE, 2, -1, Field("LHolder;", "wide", "J")) },
                { visitFieldStmt(Op.IPUT_OBJECT, 3, 5, Field("LHolder;", "value", "Ljava/lang/Object;")) },
                { visitStmt3R(Op.APUT_OBJECT, 3, 5, 6) },
                { visitFilledNewArrayStmt(Op.FILLED_NEW_ARRAY, intArrayOf(3), "[Ljava/lang/Object;") },
                { visitTypeStmt(Op.CHECK_CAST, 3, -1, parent) },
                { visitMethodStmt(Op.INVOKE_STATIC, intArrayOf(3), Method("LHolder;", "escape", arrayOf(parent), "V")) },
            )
        operations.forEachIndexed { index, operation ->
            val code = allocationCode(operation)
            assertTrue(DexAllocationRepair.readConstructorEvidence(code).isEmpty(), "unsafe operation $index")
        }
    }

    @Test
    fun `proof rejects control flow entering after allocation`() {
        val entry = DexLabel()
        val code = DexCodeNode()
        code.visitJumpStmt(Op.IF_EQZ, 7, -1, entry)
        code.visitTypeStmt(Op.NEW_INSTANCE, 3, -1, "LErasedGroup;")
        code.visitLabel(entry)
        code.visitMethodStmt(Op.INVOKE_DIRECT, intArrayOf(3, 4, 5), constructor)
        assertTrue(DexAllocationRepair.readConstructorEvidence(code).isEmpty())
    }

    @Test
    fun `proof rejects exception handler entering after allocation`() {
        val start = DexLabel()
        val end = DexLabel()
        val handler = DexLabel()
        val code = allocationCode { visitLabel(handler) }
        code.visitTryCatch(start, end, arrayOf(handler), arrayOf("Ljava/lang/Throwable;"))
        assertTrue(DexAllocationRepair.readConstructorEvidence(code).isEmpty())
    }

    private fun allocationCode(intervening: DexCodeNode.() -> Unit): DexCodeNode =
        DexCodeNode().apply {
            visitTypeStmt(Op.NEW_INSTANCE, 3, -1, "LErasedGroup;")
            intervening()
            visitMethodStmt(Op.INVOKE_DIRECT, intArrayOf(3, 4, 5), constructor)
        }
}
