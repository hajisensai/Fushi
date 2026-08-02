package android.util

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

class LruCacheTest {
    @Test
    fun `creates a missing value once and caches it`() {
        var createCalls = 0
        val cache =
            object : LruCache<String, String>(2) {
                override fun create(key: String): String {
                    createCalls++
                    return "value-$key"
                }
            }

        assertEquals("value-key", cache.get("key"))
        assertEquals("value-key", cache.get("key"))
        assertEquals(1, createCalls)
        assertEquals(1, cache.createCount())
        assertEquals(1, cache.missCount())
        assertEquals(1, cache.hitCount())
    }

    @Test
    fun `evicts the least recently used entry`() {
        val cache = LruCache<String, String>(2)
        cache.put("first", "1")
        cache.put("second", "2")

        cache.get("first")
        cache.put("third", "3")

        assertNull(cache.get("second"))
        assertEquals(listOf("first", "third"), cache.snapshot().keys.toList())
        assertEquals(1, cache.evictionCount())
    }

    @Test
    fun `resizes a weighted cache`() {
        val cache =
            object : LruCache<String, String>(5) {
                override fun sizeOf(
                    key: String,
                    value: String,
                ): Int = value.length
            }

        cache.put("first", "123")
        cache.put("second", "12")
        cache.resize(2)

        assertNull(cache.get("first"))
        assertEquals("12", cache.get("second"))
        assertEquals(2, cache.size())
        assertEquals(2, cache.maxSize())
    }

    @Test
    fun `validates size and evicts zero-sized entries`() {
        assertFailsWith<IllegalArgumentException> { LruCache<String, String>(0) }

        val cache =
            object : LruCache<String, String>(1) {
                override fun sizeOf(
                    key: String,
                    value: String,
                ): Int = 0
            }
        cache.put("key", "value")

        cache.evictAll()

        assertEquals(emptyMap(), cache.snapshot())
    }
}
