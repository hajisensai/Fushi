package mextensionserver.controller

import java.lang.reflect.Field
import java.lang.reflect.Method
import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.fail

/**
 * Every host member a real Aniyomi extension links against must exist with the
 * exact JVM descriptor (`anime-extension-abi-refs.txt`, extracted from the dex of
 * extensions-lib 14, 16 and 17 APKs). Source-level compatibility proves nothing
 * here: a dex links by descriptor, so a reshaped data class or a moved `suspend`
 * modifier compiles fine on the host and then dies with `NoSuchMethodError` on
 * the first call from an extension (the lib-17 refusal in feedback gRSPNbJjqT was
 * the visible half of that problem; this pins the invisible half).
 */
class AnimeExtensionAbiTest {
    private val loader: ClassLoader = javaClass.classLoader

    @Test
    fun `every member real extensions link against resolves on the host`() {
        val lines =
            javaClass.getResourceAsStream("/anime-extension-abi-refs.txt")!!
                .bufferedReader()
                .readLines()
                .map(String::trim)
                .filter { it.isNotEmpty() && !it.startsWith("#") }
        assertTrue(lines.size > 100, "fixture unexpectedly small: ${lines.size}")
        val missing = lines.filterNot(::resolves)
        if (missing.isNotEmpty()) {
            fail("Host is missing ${missing.size} extension-linked member(s):\n" + missing.joinToString("\n"))
        }
    }

    private fun resolves(line: String): Boolean {
        val kind = line.substringBefore(' ')
        val ref = line.substringAfter(' ')
        val owner = classFor(ref.substringBefore("->")) ?: return false
        val member = ref.substringAfter("->")
        return when (kind) {
            "F" -> {
                val name = member.substringBefore(':')
                val type = classFor(member.substringAfter(':')) ?: return false
                hierarchy(owner).any { cls -> cls.declaredFields.any { it.matches(name, type) } }
            }
            "M" -> {
                val name = member.substringBefore('(')
                val descriptor = member.substring(name.length)
                val params = parseParams(descriptor.substring(1, descriptor.indexOf(')'))) ?: return false
                val returns = classFor(descriptor.substringAfter(')')) ?: return false
                if (name == "<init>") {
                    owner.declaredConstructors.any { it.parameterTypes.contentEquals(params) }
                } else {
                    hierarchy(owner).any { cls -> cls.declaredMethods.any { it.matches(name, params, returns) } }
                }
            }
            else -> false
        }
    }

    private fun Field.matches(
        name: String,
        type: Class<*>,
    ) = this.name == name && this.type == type

    private fun Method.matches(
        name: String,
        params: Array<Class<*>>,
        returns: Class<*>,
    ) = this.name == name && parameterTypes.contentEquals(params) && returnType == returns

    private fun hierarchy(start: Class<*>): Sequence<Class<*>> =
        sequence {
            val seen = HashSet<Class<*>>()
            val queue = ArrayDeque(listOf(start))
            while (queue.isNotEmpty()) {
                val cls = queue.removeFirst()
                if (!seen.add(cls)) continue
                yield(cls)
                cls.superclass?.let(queue::add)
                queue.addAll(cls.interfaces)
            }
        }

    private fun parseParams(spec: String): Array<Class<*>>? {
        val result = mutableListOf<Class<*>>()
        var i = 0
        while (i < spec.length) {
            var end = i
            while (spec[end] == '[') end++
            end = if (spec[end] == 'L') spec.indexOf(';', end) + 1 else end + 1
            result += classFor(spec.substring(i, end)) ?: return null
            i = end
        }
        return result.toTypedArray()
    }

    private fun classFor(descriptor: String): Class<*>? =
        when (descriptor) {
            "V" -> Void.TYPE
            "Z" -> java.lang.Boolean.TYPE
            "B" -> java.lang.Byte.TYPE
            "C" -> Character.TYPE
            "S" -> java.lang.Short.TYPE
            "I" -> Integer.TYPE
            "J" -> java.lang.Long.TYPE
            "F" -> java.lang.Float.TYPE
            "D" -> java.lang.Double.TYPE
            else ->
                try {
                    if (descriptor.startsWith("[")) {
                        Class.forName(descriptor.replace('/', '.'), false, loader)
                    } else {
                        Class.forName(descriptor.substring(1, descriptor.length - 1).replace('/', '.'), false, loader)
                    }
                } catch (_: ClassNotFoundException) {
                    null
                }
        }
}
