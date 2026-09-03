package mextensionserver.util

import org.objectweb.asm.ClassWriter
import org.objectweb.asm.Opcodes
import java.net.URI
import java.net.URLClassLoader
import java.nio.file.FileSystems
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

/**
 * BUG-2045 根因 B 的守卫。
 *
 * 复刻 dex2jar 的实际产出形状：`NEW <抽象基类>` + `INVOKESPECIAL <抽象基类>.<init>`
 * （两处 owner 一起被泛化），原始 dex 里那条其实是 `new-instance <具体子类>`。
 * 不修就是运行到即 `InstantiationError`。
 */
class DexAllocationRepairTest {
    @Test
    fun `restores the concrete subclass recorded in the dex`() {
        val jar = buildFixture()
        try {
            DexAllocationRepair.restoreWithAllocations(
                jar,
                mapOf("Factory#create#()LAbstractGroup;" to listOf("ConcreteGroup")),
            )
            URLClassLoader(arrayOf(jar.toUri().toURL()), javaClass.classLoader).use { loader ->
                val created =
                    Class
                        .forName("Factory", true, loader)
                        .getMethod("create")
                        .invoke(null)
                assertEquals("ConcreteGroup", created.javaClass.name)
            }
        } finally {
            Files.deleteIfExists(jar)
        }
    }

    @Test
    fun `leaves the allocation alone when two subclasses are equally plausible`() {
        val jar = buildFixture(extraConcrete = "OtherGroup")
        try {
            // dex 里两个子类各缺一个，无法唯一对账 → 必须原样放过。
            DexAllocationRepair.restoreWithAllocations(
                jar,
                mapOf("Factory#create#()LAbstractGroup;" to listOf("ConcreteGroup", "OtherGroup")),
            )
            URLClassLoader(arrayOf(jar.toUri().toURL()), javaClass.classLoader).use { loader ->
                val factory = Class.forName("Factory", true, loader)
                assertFailsWith<InstantiationError> {
                    try {
                        factory.getMethod("create").invoke(null)
                    } catch (wrapped: java.lang.reflect.InvocationTargetException) {
                        throw wrapped.cause!!
                    }
                }
            }
        } finally {
            Files.deleteIfExists(jar)
        }
    }

    @Test
    fun `leaves the allocation alone when the dex really allocated that type`() {
        val jar = buildFixture()
        try {
            // dex 里就写着分配抽象类型（不该发生，但真发生时不是本 pass 该管的），不动。
            DexAllocationRepair.restoreWithAllocations(
                jar,
                mapOf("Factory#create#()LAbstractGroup;" to listOf("AbstractGroup")),
            )
            URLClassLoader(arrayOf(jar.toUri().toURL()), javaClass.classLoader).use { loader ->
                val factory = Class.forName("Factory", true, loader)
                assertFailsWith<InstantiationError> {
                    try {
                        factory.getMethod("create").invoke(null)
                    } catch (wrapped: java.lang.reflect.InvocationTargetException) {
                        throw wrapped.cause!!
                    }
                }
            }
        } finally {
            Files.deleteIfExists(jar)
        }
    }

    @Test
    fun `leaves the allocation alone when the candidate has no matching constructor`() {
        // dex2jar 有时把构造整个内联掉，连描述符一起换成父类的（koharu 的 Lp0; 在 dex 里
        // 是 `<init>(Lp;)V` 的 Kotlin 内部类，却被转成了父类的 `(String, List)`）。这时
        // 光把 owner 改回去只会把 InstantiationError 换成 NoSuchMethodError——一样不可用、
        // 还更难查。必须原样放过。
        val jar = buildFixture(concreteCtorDesc = "(Ljava/lang/String;)V")
        try {
            DexAllocationRepair.restoreWithAllocations(
                jar,
                mapOf("Factory#create#()LAbstractGroup;" to listOf("ConcreteGroup")),
            )
            URLClassLoader(arrayOf(jar.toUri().toURL()), javaClass.classLoader).use { loader ->
                val factory = Class.forName("Factory", true, loader)
                assertFailsWith<InstantiationError> {
                    try {
                        factory.getMethod("create").invoke(null)
                    } catch (wrapped: java.lang.reflect.InvocationTargetException) {
                        throw wrapped.cause!!
                    }
                }
            }
        } finally {
            Files.deleteIfExists(jar)
        }
    }

    private fun buildFixture(
        extraConcrete: String? = null,
        concreteCtorDesc: String = "()V",
    ): Path {
        val jar = Files.createTempFile("dex-allocation-repair-test", ".jar")
        Files.delete(jar)
        FileSystems
            .newFileSystem(URI.create("jar:${jar.toUri()}"), mapOf("create" to "true"))
            .use { zip ->
                Files.write(zip.getPath("/AbstractGroup.class"), abstractGroup())
                Files.write(
                    zip.getPath("/ConcreteGroup.class"),
                    concreteGroup("ConcreteGroup", concreteCtorDesc),
                )
                if (extraConcrete != null) {
                    Files.write(zip.getPath("/$extraConcrete.class"), concreteGroup(extraConcrete))
                }
                Files.write(zip.getPath("/Factory.class"), factoryAllocatingAbstract())
            }
        return jar
    }

    /** `abstract class AbstractGroup { protected AbstractGroup() {} }` */
    private fun abstractGroup(): ByteArray {
        val writer = ClassWriter(ClassWriter.COMPUTE_FRAMES or ClassWriter.COMPUTE_MAXS)
        writer.visit(
            Opcodes.V1_8,
            Opcodes.ACC_PUBLIC or Opcodes.ACC_ABSTRACT,
            "AbstractGroup",
            null,
            "java/lang/Object",
            null,
        )
        writer.visitMethod(Opcodes.ACC_PUBLIC, "<init>", "()V", null, null).apply {
            visitCode()
            visitVarInsn(Opcodes.ALOAD, 0)
            visitMethodInsn(Opcodes.INVOKESPECIAL, "java/lang/Object", "<init>", "()V", false)
            visitInsn(Opcodes.RETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        writer.visitEnd()
        return writer.toByteArray()
    }

    /** `final class <name> extends AbstractGroup`，构造器描述符可指定。 */
    private fun concreteGroup(
        name: String,
        ctorDesc: String = "()V",
    ): ByteArray {
        val writer = ClassWriter(ClassWriter.COMPUTE_FRAMES or ClassWriter.COMPUTE_MAXS)
        writer.visit(
            Opcodes.V1_8,
            Opcodes.ACC_PUBLIC or Opcodes.ACC_FINAL,
            name,
            null,
            "AbstractGroup",
            null,
        )
        writer.visitMethod(Opcodes.ACC_PUBLIC, "<init>", ctorDesc, null, null).apply {
            visitCode()
            visitVarInsn(Opcodes.ALOAD, 0)
            visitMethodInsn(Opcodes.INVOKESPECIAL, "AbstractGroup", "<init>", "()V", false)
            visitInsn(Opcodes.RETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        writer.visitEnd()
        return writer.toByteArray()
    }

    /**
     * dex2jar 的错误产出：`NEW AbstractGroup` + `INVOKESPECIAL AbstractGroup.<init>`。
     * 字节码本身能过校验器，只是运行到 `NEW` 抽象类就抛 `InstantiationError`。
     */
    private fun factoryAllocatingAbstract(): ByteArray {
        val writer = ClassWriter(ClassWriter.COMPUTE_FRAMES or ClassWriter.COMPUTE_MAXS)
        writer.visit(Opcodes.V1_8, Opcodes.ACC_PUBLIC, "Factory", null, "java/lang/Object", null)
        writer
            .visitMethod(
                Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC,
                "create",
                "()LAbstractGroup;",
                null,
                null,
            ).apply {
                visitCode()
                visitTypeInsn(Opcodes.NEW, "AbstractGroup")
                visitInsn(Opcodes.DUP)
                visitMethodInsn(Opcodes.INVOKESPECIAL, "AbstractGroup", "<init>", "()V", false)
                visitInsn(Opcodes.ARETURN)
                visitMaxs(0, 0)
                visitEnd()
            }
        writer.visitEnd()
        return writer.toByteArray()
    }
}
