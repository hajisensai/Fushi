package mextensionserver.util

import com.googlecode.d2j.Method
import com.googlecode.d2j.dex.writer.DexFileWriter
import com.googlecode.d2j.reader.Op
import org.objectweb.asm.Opcodes
import java.net.URLClassLoader
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * BUG-2826: R8 inlines the trivial constructor of every suspend function's
 * continuation class, so the DEX allocates `ContB` and invokes
 * `ContinuationImpl.<init>` on it directly. dex2jar generalizes that NEW to the
 * abstract `ContinuationImpl`; several constructor-less continuation classes then
 * match every such allocation and BytecodeEditor hands out "the first unclaimed
 * candidate", so the allocations of two methods were swapped (mokuro 1.6.6:
 * `ClassCastException: w1 cannot be cast to y1` on every getPageList).
 * [DexAllocationRepair.exactAllocationReader] restores the type before dex2jar runs.
 */
class DexContinuationAllocationTest {
    private val continuationImpl = "Lkotlin/coroutines/jvm/internal/ContinuationImpl;"
    private val continuation = "Lkotlin/coroutines/Continuation;"

    @Test
    fun `every method keeps its own constructor-less continuation class`() {
        // Method order deliberately differs from class order: `a` allocates ContB,
        // `b` allocates ContA, `c` allocates ContC.
        val allocations = linkedMapOf("a" to "ContB", "b" to "ContA", "c" to "ContC")
        val dex = Files.createTempFile("continuation-allocation", ".dex")
        val jar = Files.createTempFile("continuation-allocation", ".jar")
        try {
            Files.write(dex, continuationDex(allocations))
            PackageTools.dex2jar(dex.toFile(), jar.toFile())
            URLClassLoader(arrayOf(jar.toUri().toURL()), javaClass.classLoader).use { loader ->
                val factory = loader.loadClass("Factory")
                val continuationType = loader.loadClass("kotlin.coroutines.Continuation")
                allocations.forEach { (method, expected) ->
                    val value = factory.getMethod(method, continuationType).invoke(null, null)
                    assertEquals(expected, value.javaClass.name, "allocation in Factory.$method")
                }
            }
        } finally {
            Files.deleteIfExists(dex)
            Files.deleteIfExists(jar)
        }
    }

    private fun continuationDex(allocations: Map<String, String>): ByteArray {
        val writer = DexFileWriter()
        allocations.values.sorted().forEach { name ->
            writer.visit(Opcodes.ACC_PUBLIC or Opcodes.ACC_FINAL, "L$name;", continuationImpl, null).visitEnd()
        }
        val factory = writer.visit(Opcodes.ACC_PUBLIC, "LFactory;", "Ljava/lang/Object;", null)
        val keep = Method("LFactory;", "keep", arrayOf(continuationImpl), "V")
        factory.visitMethod(Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC, keep).apply {
            visitCode().apply {
                visitRegister(1)
                visitStmt0R(Op.RETURN_VOID)
                visitEnd()
            }
            visitEnd()
        }
        allocations.forEach { (name, type) ->
            factory
                .visitMethod(
                    Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC,
                    Method("LFactory;", name, arrayOf(continuation), "Ljava/lang/Object;"),
                ).apply {
                    visitCode().apply {
                        visitRegister(2)
                        visitTypeStmt(Op.NEW_INSTANCE, 0, -1, "L$type;")
                        visitMethodStmt(
                            Op.INVOKE_DIRECT,
                            intArrayOf(0, 1),
                            Method(continuationImpl, "<init>", arrayOf(continuation), "V"),
                        )
                        // An abstract-typed use site is where BytecodeEditor guessed.
                        visitMethodStmt(Op.INVOKE_STATIC, intArrayOf(0), keep)
                        visitStmt1R(Op.RETURN_OBJECT, 0)
                        visitEnd()
                    }
                    visitEnd()
                }
        }
        factory.visitEnd()
        writer.visitEnd()
        return writer.toByteArray()
    }
}
