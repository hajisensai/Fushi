package mextensionserver.util

import com.googlecode.d2j.Method
import com.googlecode.d2j.dex.Dex2jar
import com.googlecode.d2j.dex.writer.DexFileWriter
import com.googlecode.d2j.reader.MultiDexFileReader
import com.googlecode.d2j.reader.Op
import org.objectweb.asm.Opcodes
import java.net.URLClassLoader
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class DexConcreteAllocationTest {
    @Test
    fun `real dex conversion preserves concrete item type for typed collection arrays`() {
        withFixture { dex, jar ->
            // Comic Days shape: R8 erases Item's constructor, then the filter
            // constructor materializes List<Item> using Collection.toArray(Item[]).
            assertFailsWith<ArrayStoreException> { invoke(jar) }
            DexAllocationRepair.restore(dex, jar)
            DexAllocationRepair.restore(dex, jar)
            val items = invoke(jar) as Array<*>
            assertEquals("ErasedItem", items.single()!!.javaClass.name)
            assertEquals("Japanese option", items.single().toString())
            assertEquals(
                1,
                items
                    .single()!!
                    .javaClass.declaredConstructors.size,
            )
        }
    }

    @Test
    fun `allocation counts alone cannot rewrite a concrete Object allocation`() {
        withFixture(existingConstructor = true) { _, jar ->
            DexAllocationRepair.restoreWithAllocations(
                jar,
                mapOf("ItemFactory#create#()[LErasedItem;" to listOf("ErasedItem")),
            )
            assertFailsWith<ArrayStoreException> { invoke(jar) }
        }
    }

    @Test
    fun `retains real Object allocation even when another subclass allocation was erased`() {
        withFixture(realObject = true) { dex, jar ->
            DexAllocationRepair.restore(dex, jar)
            assertEquals("java.lang.Object", invoke(jar)!!.javaClass.name)
        }
    }

    @Test
    fun `does not choose between multiple erased concrete subclasses`() {
        withFixture(ambiguous = true) { dex, jar ->
            DexAllocationRepair.restore(dex, jar)
            assertFailsWith<ArrayStoreException> { invoke(jar) }
        }
    }

    private fun invoke(jar: Path): Any? =
        URLClassLoader(arrayOf(jar.toUri().toURL()), javaClass.classLoader).use { loader ->
            try {
                loader.loadClass("ItemFactory").getMethod("create").invoke(null)
            } catch (wrapped: java.lang.reflect.InvocationTargetException) {
                throw wrapped.cause!!
            }
        }

    private fun withFixture(
        realObject: Boolean = false,
        ambiguous: Boolean = false,
        existingConstructor: Boolean = false,
        verify: (Path, Path) -> Unit,
    ) {
        val dex = Files.createTempFile("concrete-allocation", ".dex")
        val jar = Files.createTempFile("concrete-allocation", ".jar")
        try {
            val writer = DexFileWriter()
            val item = writer.visit(Opcodes.ACC_PUBLIC or Opcodes.ACC_FINAL, "LErasedItem;", "Ljava/lang/Object;", null)
            if (existingConstructor) {
                val initializer = item.visitMethod(Opcodes.ACC_PUBLIC, Method("LErasedItem;", "<init>", emptyArray(), "V"))
                initializer.visitCode().apply {
                    visitRegister(1)
                    visitMethodStmt(Op.INVOKE_DIRECT, intArrayOf(0), Method("Ljava/lang/Object;", "<init>", emptyArray(), "V"))
                    visitStmt0R(Op.RETURN_VOID)
                    visitEnd()
                }
                initializer.visitEnd()
            }
            val toString = item.visitMethod(Opcodes.ACC_PUBLIC, Method("LErasedItem;", "toString", emptyArray(), "Ljava/lang/String;"))
            toString.visitCode().apply {
                visitRegister(2)
                visitConstStmt(Op.CONST_STRING, 0, "Japanese option")
                visitStmt1R(Op.RETURN_OBJECT, 0)
                visitEnd()
            }
            toString.visitEnd()
            item.visitEnd()
            if (ambiguous) writer.visit(Opcodes.ACC_PUBLIC, "LOtherItem;", "Ljava/lang/Object;", null).visitEnd()
            val factory = writer.visit(Opcodes.ACC_PUBLIC, "LItemFactory;", "Ljava/lang/Object;", null)
            val method =
                factory.visitMethod(
                    Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC,
                    Method("LItemFactory;", "create", emptyArray(), if (realObject) "Ljava/lang/Object;" else "[LErasedItem;"),
                )
            method.visitCode().apply {
                visitRegister(4)
                visitTypeStmt(Op.NEW_INSTANCE, 0, -1, "LErasedItem;")
                visitMethodStmt(Op.INVOKE_DIRECT, intArrayOf(0), Method("Ljava/lang/Object;", "<init>", emptyArray(), "V"))
                if (realObject || ambiguous) {
                    visitTypeStmt(Op.NEW_INSTANCE, 1, -1, if (realObject) "Ljava/lang/Object;" else "LOtherItem;")
                    visitMethodStmt(Op.INVOKE_DIRECT, intArrayOf(1), Method("Ljava/lang/Object;", "<init>", emptyArray(), "V"))
                    // Make both allocations observable so converter optimization
                    // cannot drop the evidence whose ambiguity we are testing.
                    visitMethodStmt(
                        Op.INVOKE_STATIC,
                        intArrayOf(0, 1),
                        Method("Ljava/util/Objects;", "equals", arrayOf("Ljava/lang/Object;", "Ljava/lang/Object;"), "Z"),
                    )
                }
                if (realObject) {
                    visitStmt1R(Op.RETURN_OBJECT, 1)
                } else {
                    visitMethodStmt(
                        Op.INVOKE_STATIC,
                        intArrayOf(0),
                        Method("Ljava/util/Collections;", "singletonList", arrayOf("Ljava/lang/Object;"), "Ljava/util/List;"),
                    )
                    visitStmt1R(Op.MOVE_RESULT_OBJECT, 1)
                    visitConstStmt(Op.CONST_4, 2, 0)
                    visitTypeStmt(Op.NEW_ARRAY, 2, 2, "[LErasedItem;")
                    visitMethodStmt(
                        Op.INVOKE_INTERFACE,
                        intArrayOf(1, 2),
                        Method("Ljava/util/List;", "toArray", arrayOf("[Ljava/lang/Object;"), "[Ljava/lang/Object;"),
                    )
                    visitStmt1R(Op.MOVE_RESULT_OBJECT, 3)
                    visitTypeStmt(Op.CHECK_CAST, 3, -1, "[LErasedItem;")
                    visitStmt1R(Op.RETURN_OBJECT, 3)
                }
                visitEnd()
            }
            method.visitEnd()
            factory.visitEnd()
            writer.visitEnd()
            Files.write(dex, writer.toByteArray())
            Dex2jar.from(MultiDexFileReader.open(Files.readAllBytes(dex))).to(jar)
            BytecodeEditor.fixAndroidClasses(jar)
            verify(dex, jar)
        } finally {
            Files.deleteIfExists(dex)
            Files.deleteIfExists(jar)
        }
    }
}
