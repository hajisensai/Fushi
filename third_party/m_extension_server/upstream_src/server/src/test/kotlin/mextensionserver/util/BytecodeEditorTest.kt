package mextensionserver.util

import org.objectweb.asm.ClassWriter
import org.objectweb.asm.Opcodes
import java.net.URI
import java.net.URLClassLoader
import java.nio.file.FileSystems
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class BytecodeEditorTest {
    @Test
    fun `repairs missing frames and dex constructors`() {
        val jar = Files.createTempFile("bytecode-editor-test", ".jar")
        Files.delete(jar)
        try {
            FileSystems
                .newFileSystem(
                    URI.create("jar:${jar.toUri()}"),
                    mapOf("create" to "true"),
                ).use { zip ->
                    Files.write(zip.getPath("/a.class"), dexStyleFunction())
                    Files.write(zip.getPath("/b.class"), dexStyleUnaryFunction())
                    Files.write(zip.getPath("/b2.class"), dexStyleUnaryFunctionWithArgument())
                    Files.write(zip.getPath("/h.class"), dexStyleLambda())
                    Files.write(zip.getPath("/j.class"), dexStyleHolder())
                    Files.write(zip.getPath("/SourceBase.class"), sourceBase())
                    Files.write(zip.getPath("/SourceOne.class"), concreteSource("SourceOne"))
                    Files.write(zip.getPath("/SourceTwo.class"), concreteSource("SourceTwo"))
                    Files.write(zip.getPath("/VerifierFixture.class"), verifierFixture())
                }

            BytecodeEditor.fixAndroidClasses(jar)

            URLClassLoader(arrayOf(jar.toUri().toURL()), javaClass.classLoader).use { loader ->
                val fixture = Class.forName("VerifierFixture", true, loader)
                val result = fixture.getMethod("create", Boolean::class.javaPrimitiveType).invoke(null, false)
                assertEquals("a", result.javaClass.name)
                assertEquals(
                    "j",
                    fixture
                        .getMethod("createHolder")
                        .invoke(null)
                        .javaClass.name,
                )
                assertEquals(
                    "h",
                    Class
                        .forName("h", true, loader)
                        .getField("INSTANCE")
                        .get(null)
                        .javaClass.name,
                )
                assertNull(fixture.getMethod("callFunction").invoke(null))
                val sources = fixture.getMethod("createSources").invoke(null) as Array<*>
                assertEquals(2, sources.size)
                assertTrue(
                    sources.map { it?.javaClass?.name }.toSet() == setOf("SourceOne", "SourceTwo"),
                )
            }
        } finally {
            Files.deleteIfExists(jar)
        }
    }

    private fun dexStyleUnaryFunction(): ByteArray {
        val writer = ClassWriter(0)
        writer.visit(
            Opcodes.V1_8,
            Opcodes.ACC_PUBLIC or Opcodes.ACC_FINAL,
            "b",
            null,
            "java/lang/Object",
            arrayOf("kotlin/jvm/functions/Function1"),
        )
        writer
            .visitMethod(
                Opcodes.ACC_PUBLIC,
                "invoke",
                "(Ljava/lang/Object;)Ljava/lang/Object;",
                null,
                null,
            ).apply {
                visitCode()
                visitInsn(Opcodes.ACONST_NULL)
                visitInsn(Opcodes.ARETURN)
                visitMaxs(1, 2)
                visitEnd()
            }
        writer.visitEnd()
        return writer.toByteArray()
    }

    private fun dexStyleUnaryFunctionWithArgument(): ByteArray {
        val writer = ClassWriter(0)
        writer.visit(
            Opcodes.V1_8,
            Opcodes.ACC_PUBLIC or Opcodes.ACC_FINAL,
            "b2",
            null,
            "java/lang/Object",
            arrayOf("kotlin/jvm/functions/Function1"),
        )
        writer
            .visitMethod(Opcodes.ACC_PUBLIC, "<init>", "(Ljava/lang/String;)V", null, null)
            .apply {
                visitCode()
                visitVarInsn(Opcodes.ALOAD, 0)
                visitMethodInsn(Opcodes.INVOKESPECIAL, "java/lang/Object", "<init>", "()V", false)
                visitInsn(Opcodes.RETURN)
                visitMaxs(1, 2)
                visitEnd()
            }
        writer
            .visitMethod(
                Opcodes.ACC_PUBLIC,
                "invoke",
                "(Ljava/lang/Object;)Ljava/lang/Object;",
                null,
                null,
            ).apply {
                visitCode()
                visitInsn(Opcodes.ACONST_NULL)
                visitInsn(Opcodes.ARETURN)
                visitMaxs(1, 2)
                visitEnd()
            }
        writer.visitEnd()
        return writer.toByteArray()
    }

    private fun dexStyleLambda(): ByteArray {
        val writer = ClassWriter(0)
        writer.visit(
            Opcodes.V1_8,
            Opcodes.ACC_PUBLIC or Opcodes.ACC_FINAL,
            "h",
            null,
            "kotlin/jvm/internal/Lambda",
            arrayOf("kotlin/jvm/functions/Function0"),
        )
        writer
            .visitField(
                Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC or Opcodes.ACC_FINAL,
                "INSTANCE",
                "Lh;",
                null,
                null,
            ).visitEnd()
        writer
            .visitMethod(Opcodes.ACC_STATIC, "<clinit>", "()V", null, null)
            .apply {
                visitCode()
                visitTypeInsn(Opcodes.NEW, "kotlin/jvm/internal/Lambda")
                visitInsn(Opcodes.DUP)
                visitInsn(Opcodes.ICONST_0)
                visitMethodInsn(Opcodes.INVOKESPECIAL, "kotlin/jvm/internal/Lambda", "<init>", "(I)V", false)
                visitFieldInsn(Opcodes.PUTSTATIC, "h", "INSTANCE", "Lh;")
                visitInsn(Opcodes.RETURN)
                visitMaxs(3, 0)
                visitEnd()
            }
        writer
            .visitMethod(Opcodes.ACC_PUBLIC, "invoke", "()Ljava/lang/Object;", null, null)
            .apply {
                visitCode()
                visitInsn(Opcodes.ACONST_NULL)
                visitInsn(Opcodes.ARETURN)
                visitMaxs(1, 1)
                visitEnd()
            }
        writer.visitEnd()
        return writer.toByteArray()
    }

    private fun dexStyleHolder(): ByteArray {
        val writer = ClassWriter(0)
        writer.visit(Opcodes.V1_8, Opcodes.ACC_PUBLIC or Opcodes.ACC_FINAL, "j", null, "java/lang/Object", null)
        writer.visitField(Opcodes.ACC_PUBLIC, "value", "I", null, null).visitEnd()
        writer.visitEnd()
        return writer.toByteArray()
    }

    private fun sourceBase(): ByteArray {
        val writer = ClassWriter(0)
        writer.visit(
            Opcodes.V1_8,
            Opcodes.ACC_PUBLIC or Opcodes.ACC_ABSTRACT,
            "SourceBase",
            null,
            "java/lang/Object",
            null,
        )
        writer
            .visitMethod(Opcodes.ACC_PUBLIC, "<init>", "()V", null, null)
            .apply {
                visitCode()
                visitVarInsn(Opcodes.ALOAD, 0)
                visitMethodInsn(Opcodes.INVOKESPECIAL, "java/lang/Object", "<init>", "()V", false)
                visitInsn(Opcodes.RETURN)
                visitMaxs(1, 1)
                visitEnd()
            }
        writer.visitEnd()
        return writer.toByteArray()
    }

    private fun concreteSource(name: String): ByteArray {
        val writer = ClassWriter(0)
        writer.visit(Opcodes.V1_8, Opcodes.ACC_PUBLIC or Opcodes.ACC_FINAL, name, null, "SourceBase", null)
        writer
            .visitMethod(Opcodes.ACC_PUBLIC, "<init>", "()V", null, null)
            .apply {
                visitCode()
                visitVarInsn(Opcodes.ALOAD, 0)
                visitMethodInsn(Opcodes.INVOKESPECIAL, "SourceBase", "<init>", "()V", false)
                visitInsn(Opcodes.RETURN)
                visitMaxs(1, 1)
                visitEnd()
            }
        writer.visitEnd()
        return writer.toByteArray()
    }

    private fun dexStyleFunction(): ByteArray {
        val writer = ClassWriter(0)
        writer.visit(
            Opcodes.V1_8,
            Opcodes.ACC_PUBLIC or Opcodes.ACC_FINAL,
            "a",
            null,
            "java/lang/Object",
            arrayOf("kotlin/jvm/functions/Function2"),
        )
        writer
            .visitMethod(
                Opcodes.ACC_PUBLIC,
                "invoke",
                "(Ljava/lang/Object;Ljava/lang/Object;)Ljava/lang/Object;",
                null,
                null,
            ).apply {
                visitCode()
                visitInsn(Opcodes.ACONST_NULL)
                visitInsn(Opcodes.ARETURN)
                visitMaxs(1, 3)
                visitEnd()
            }
        writer.visitEnd()
        return writer.toByteArray()
    }

    private fun verifierFixture(): ByteArray {
        val writer = ClassWriter(0)
        writer.visit(
            Opcodes.V1_8,
            Opcodes.ACC_PUBLIC or Opcodes.ACC_FINAL,
            "VerifierFixture",
            null,
            "java/lang/Object",
            null,
        )
        writer
            .visitMethod(
                Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC,
                "create",
                "(Z)Ljava/lang/Object;",
                null,
                null,
            ).apply {
                val construct = org.objectweb.asm.Label()
                visitCode()
                visitVarInsn(Opcodes.ILOAD, 0)
                visitJumpInsn(Opcodes.IFEQ, construct)
                visitInsn(Opcodes.ACONST_NULL)
                visitInsn(Opcodes.ARETURN)
                visitLabel(construct)
                visitTypeInsn(Opcodes.NEW, "a")
                visitVarInsn(Opcodes.ASTORE, 1)
                visitVarInsn(Opcodes.ALOAD, 1)
                visitMethodInsn(Opcodes.INVOKESPECIAL, "java/lang/Object", "<init>", "()V", false)
                visitVarInsn(Opcodes.ALOAD, 1)
                visitInsn(Opcodes.ARETURN)
                visitMaxs(1, 2)
                visitEnd()
            }
        writer
            .visitMethod(
                Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC,
                "createHolder",
                "()Ljava/lang/Object;",
                null,
                null,
            ).apply {
                visitCode()
                visitTypeInsn(Opcodes.NEW, "java/lang/Object")
                visitInsn(Opcodes.DUP)
                visitMethodInsn(Opcodes.INVOKESPECIAL, "java/lang/Object", "<init>", "()V", false)
                visitVarInsn(Opcodes.ASTORE, 0)
                visitVarInsn(Opcodes.ALOAD, 0)
                visitInsn(Opcodes.ICONST_1)
                visitFieldInsn(Opcodes.PUTFIELD, "j", "value", "I")
                visitVarInsn(Opcodes.ALOAD, 0)
                visitInsn(Opcodes.ARETURN)
                visitMaxs(2, 1)
                visitEnd()
            }
        writer
            .visitMethod(
                Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC,
                "callFunction",
                "()Ljava/lang/Object;",
                null,
                null,
            ).apply {
                visitCode()
                visitTypeInsn(Opcodes.NEW, "java/lang/Object")
                visitInsn(Opcodes.DUP)
                visitMethodInsn(Opcodes.INVOKESPECIAL, "java/lang/Object", "<init>", "()V", false)
                visitInsn(Opcodes.ACONST_NULL)
                visitMethodInsn(
                    Opcodes.INVOKEINTERFACE,
                    "kotlin/jvm/functions/Function1",
                    "invoke",
                    "(Ljava/lang/Object;)Ljava/lang/Object;",
                    true,
                )
                visitInsn(Opcodes.ARETURN)
                visitMaxs(2, 0)
                visitEnd()
            }
        writer
            .visitMethod(
                Opcodes.ACC_PUBLIC or Opcodes.ACC_STATIC,
                "createSources",
                "()[LSourceBase;",
                null,
                null,
            ).apply {
                visitCode()
                visitInsn(Opcodes.ICONST_2)
                visitTypeInsn(Opcodes.ANEWARRAY, "SourceBase")
                repeat(2) { index ->
                    visitInsn(Opcodes.DUP)
                    visitInsn(if (index == 0) Opcodes.ICONST_0 else Opcodes.ICONST_1)
                    visitTypeInsn(Opcodes.NEW, "SourceBase")
                    visitInsn(Opcodes.DUP)
                    visitMethodInsn(Opcodes.INVOKESPECIAL, "SourceBase", "<init>", "()V", false)
                    visitInsn(Opcodes.AASTORE)
                }
                visitInsn(Opcodes.ARETURN)
                visitMaxs(5, 0)
                visitEnd()
            }
        writer.visitEnd()
        return writer.toByteArray()
    }
}
