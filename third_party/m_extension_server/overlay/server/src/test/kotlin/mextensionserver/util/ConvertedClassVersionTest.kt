package mextensionserver.util

import org.objectweb.asm.ClassWriter
import org.objectweb.asm.Label
import org.objectweb.asm.Opcodes
import java.net.URI
import java.net.URLClassLoader
import java.nio.file.FileSystems
import java.nio.file.Files
import java.nio.file.Path
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

/**
 * dex2jar writes Java 6 class files. A Java 6 class must not reach an
 * interface method with invokestatic / invokespecial, which is exactly what an
 * extension compiled against current kotlinx-coroutines does
 * (`Job.cancel$default`, an interface static method): keiyoushi Komga 1.6.73
 * died in `Komga.r(...)` with "Illegal type at constant pool entry" and the
 * whole extension failed to install. The converter has to emit Java 8.
 */
class ConvertedClassVersionTest {
    @Test
    fun `java 6 fixtures reproduce the verifier rejection`() {
        // Guards the fixtures themselves: if HotSpot ever accepted them the
        // tests below would pass without proving anything.
        val loader = BytesClassLoader(mapOf(STATIC_CALLER to interfaceStaticCaller()))
        assertFailsWith<VerifyError> { Class.forName(STATIC_CALLER, false, loader).declaredMethods }
        val superLoader = BytesClassLoader(mapOf(SUPER_CALLER to interfaceSuperCaller()))
        assertFailsWith<VerifyError> { Class.forName(SUPER_CALLER, false, superLoader).declaredMethods }
    }

    @Test
    fun `converted classes may call interface static and default methods`() {
        withConvertedJar(
            mapOf(
                STATIC_CALLER to interfaceStaticCaller(),
                SUPER_CALLER to interfaceSuperCaller(),
            ),
        ) { jar, loader ->
            assertEquals(Opcodes.V1_8, majorVersion(jar, STATIC_CALLER))
            assertEquals(Opcodes.V1_8, majorVersion(jar, SUPER_CALLER))

            val staticCaller = Class.forName(STATIC_CALLER, true, loader)
            val pick = staticCaller.getMethod("pick", Boolean::class.javaPrimitiveType)
            assertEquals(Comparator.naturalOrder<String>(), pick.invoke(null, true))
            assertEquals(Comparator.reverseOrder<String>(), pick.invoke(null, false))

            val superCaller = Class.forName(SUPER_CALLER, true, loader)
            val instance = superCaller.getConstructor().newInstance()
            val spliterator = superCaller.getMethod("superSpliterator").invoke(instance)
            assertTrue(spliterator is java.util.Spliterator<*>)
        }
    }

    @Test
    fun `converted classes stay below the java 9 final field rule`() {
        // DEX code may assign a final field outside <init>. That is legal up to
        // class file 52 and an IllegalAccessError from 53 on, so the version
        // bump must stop at Java 8.
        withConvertedJar(mapOf(FINAL_WRITER to finalFieldWriter())) { jar, loader ->
            assertEquals(Opcodes.V1_8, majorVersion(jar, FINAL_WRITER))
            val writer = Class.forName(FINAL_WRITER, true, loader)
            val instance = writer.getConstructor().newInstance()
            assertEquals(42, writer.getMethod("assign", Int::class.javaPrimitiveType).invoke(instance, 42))
        }
    }

    @Test
    fun `class versions are raised to java 8 and never lowered`() {
        assertEquals(Opcodes.V1_8, BytecodeEditor.convertedClassVersion(Opcodes.V1_6))
        assertEquals(Opcodes.V1_8, BytecodeEditor.convertedClassVersion(Opcodes.V1_7))
        assertEquals(Opcodes.V1_8, BytecodeEditor.convertedClassVersion(Opcodes.V1_8))
        assertEquals(Opcodes.V11, BytecodeEditor.convertedClassVersion(Opcodes.V11))
    }

    private fun withConvertedJar(
        classes: Map<String, ByteArray>,
        block: (Path, URLClassLoader) -> Unit,
    ) {
        val jar = Files.createTempFile("converted-class-version", ".jar")
        Files.delete(jar)
        try {
            FileSystems.newFileSystem(URI.create("jar:${jar.toUri()}"), mapOf("create" to "true")).use { zip ->
                classes.forEach { (name, bytes) -> Files.write(zip.getPath("/$name.class"), bytes) }
            }
            BytecodeEditor.fixAndroidClasses(jar)
            URLClassLoader(arrayOf(jar.toUri().toURL()), javaClass.classLoader).use { loader -> block(jar, loader) }
        } finally {
            Files.deleteIfExists(jar)
        }
    }

    private fun majorVersion(
        jar: Path,
        className: String,
    ): Int =
        FileSystems.newFileSystem(jar, null as ClassLoader?).use { zip ->
            val bytes = Files.readAllBytes(zip.getPath("/$className.class"))
            ((bytes[6].toInt() and 0xFF) shl 8) or (bytes[7].toInt() and 0xFF)
        }

    /** `static Object pick(boolean)`: naturalOrder / reverseOrder, both interface statics, behind a branch. */
    private fun interfaceStaticCaller(): ByteArray {
        val writer = ClassWriter(ClassWriter.COMPUTE_MAXS)
        writer.visit(Opcodes.V1_6, Opcodes.ACC_PUBLIC or Opcodes.ACC_SUPER, STATIC_CALLER, null, OBJECT, null)
        writer.defaultConstructor()
        writer.visitMethod(Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC, "pick", "(Z)Ljava/lang/Object;", null, null).apply {
            visitCode()
            val reverse = Label()
            visitVarInsn(Opcodes.ILOAD, 0)
            visitJumpInsn(Opcodes.IFEQ, reverse)
            visitMethodInsn(Opcodes.INVOKESTATIC, COMPARATOR, "naturalOrder", "()L$COMPARATOR;", true)
            visitInsn(Opcodes.ARETURN)
            visitLabel(reverse)
            visitMethodInsn(Opcodes.INVOKESTATIC, COMPARATOR, "reverseOrder", "()L$COMPARATOR;", true)
            visitInsn(Opcodes.ARETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        writer.visitEnd()
        return writer.toByteArray()
    }

    /** An empty Iterable whose `superSpliterator()` is `Iterable.super.spliterator()`. */
    private fun interfaceSuperCaller(): ByteArray {
        val writer = ClassWriter(ClassWriter.COMPUTE_MAXS)
        writer.visit(
            Opcodes.V1_6,
            Opcodes.ACC_PUBLIC or Opcodes.ACC_SUPER,
            SUPER_CALLER,
            null,
            OBJECT,
            arrayOf("java/lang/Iterable"),
        )
        writer.defaultConstructor()
        writer.visitMethod(Opcodes.ACC_PUBLIC, "iterator", "()Ljava/util/Iterator;", null, null).apply {
            visitCode()
            visitMethodInsn(Opcodes.INVOKESTATIC, "java/util/Collections", "emptyIterator", "()Ljava/util/Iterator;", false)
            visitInsn(Opcodes.ARETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        writer.visitMethod(Opcodes.ACC_PUBLIC, "superSpliterator", "()Ljava/lang/Object;", null, null).apply {
            visitCode()
            visitVarInsn(Opcodes.ALOAD, 0)
            visitMethodInsn(Opcodes.INVOKESPECIAL, "java/lang/Iterable", "spliterator", "()Ljava/util/Spliterator;", true)
            visitInsn(Opcodes.ARETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        writer.visitEnd()
        return writer.toByteArray()
    }

    /** `int assign(int)` writes the final field `value` outside the constructor, as DEX code may. */
    private fun finalFieldWriter(): ByteArray {
        val writer = ClassWriter(ClassWriter.COMPUTE_MAXS)
        writer.visit(Opcodes.V1_6, Opcodes.ACC_PUBLIC or Opcodes.ACC_SUPER, FINAL_WRITER, null, OBJECT, null)
        writer.visitField(Opcodes.ACC_PRIVATE or Opcodes.ACC_FINAL, "value", "I", null, null).visitEnd()
        writer.defaultConstructor()
        writer.visitMethod(Opcodes.ACC_PUBLIC, "assign", "(I)I", null, null).apply {
            visitCode()
            visitVarInsn(Opcodes.ALOAD, 0)
            visitVarInsn(Opcodes.ILOAD, 1)
            visitFieldInsn(Opcodes.PUTFIELD, FINAL_WRITER, "value", "I")
            visitVarInsn(Opcodes.ALOAD, 0)
            visitFieldInsn(Opcodes.GETFIELD, FINAL_WRITER, "value", "I")
            visitInsn(Opcodes.IRETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
        writer.visitEnd()
        return writer.toByteArray()
    }

    private fun ClassWriter.defaultConstructor() {
        visitMethod(Opcodes.ACC_PUBLIC, "<init>", "()V", null, null).apply {
            visitCode()
            visitVarInsn(Opcodes.ALOAD, 0)
            visitMethodInsn(Opcodes.INVOKESPECIAL, OBJECT, "<init>", "()V", false)
            visitInsn(Opcodes.RETURN)
            visitMaxs(0, 0)
            visitEnd()
        }
    }

    private class BytesClassLoader(
        private val classes: Map<String, ByteArray>,
    ) : ClassLoader(ConvertedClassVersionTest::class.java.classLoader) {
        override fun findClass(name: String): Class<*> {
            val bytes = classes[name] ?: throw ClassNotFoundException(name)
            return defineClass(name, bytes, 0, bytes.size)
        }
    }

    private companion object {
        const val OBJECT = "java/lang/Object"
        const val COMPARATOR = "java/util/Comparator"
        const val STATIC_CALLER = "LegacyInterfaceStaticCaller"
        const val SUPER_CALLER = "LegacyInterfaceSuperCaller"
        const val FINAL_WRITER = "LegacyFinalFieldWriter"
    }
}
