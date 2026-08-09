package app.fushi.reader.mihon

import dalvik.system.PathClassLoader
import java.io.IOException
import java.io.InputStream
import java.net.URL
import java.util.Enumeration

/**
 * Mirrors Mihon's private-extension loader order: boot/system classes first,
 * then extension classes, then Hibiki's host API. This lets an extension carry
 * its multisrc implementation while keeping the source/network ABI unified.
 */
internal class ChildFirstPathClassLoader(
    dexPath: String,
    parent: ClassLoader,
) : PathClassLoader(dexPath, null, parent) {
    private val system = getSystemClassLoader()

    override fun loadClass(name: String?, resolve: Boolean): Class<*> {
        var loaded = findLoadedClass(name)
        if (loaded == null) {
            try {
                loaded = system?.loadClass(name)
            } catch (_: ClassNotFoundException) {
                // Continue with extension dex.
            }
        }
        if (loaded == null) {
            loaded = try {
                findClass(name)
            } catch (_: ClassNotFoundException) {
                super.loadClass(name, resolve)
            }
        }
        if (resolve) resolveClass(loaded)
        return loaded
    }

    override fun getResource(name: String?): URL? =
        system?.getResource(name) ?: findResource(name) ?: super.getResource(name)

    override fun getResources(name: String?): Enumeration<URL> {
        val values = buildList {
            listOf(system?.getResources(name), findResources(name), parent?.getResources(name))
                .forEach { resources ->
                    while (resources?.hasMoreElements() == true) add(resources.nextElement())
                }
        }
        return object : Enumeration<URL> {
            private val iterator = values.iterator()
            override fun hasMoreElements(): Boolean = iterator.hasNext()
            override fun nextElement(): URL = iterator.next()
        }
    }

    override fun getResourceAsStream(name: String?): InputStream? =
        try {
            getResource(name)?.openStream()
        } catch (_: IOException) {
            null
        }
}
