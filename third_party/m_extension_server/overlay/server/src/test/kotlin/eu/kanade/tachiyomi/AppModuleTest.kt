package eu.kanade.tachiyomi

import android.app.Application
import kotlinx.serialization.json.Json
import kotlinx.serialization.protobuf.ProtoBuf
import uy.kohesive.injekt.api.InjektScope
import uy.kohesive.injekt.api.get
import uy.kohesive.injekt.registry.default.DefaultRegistrar
import kotlin.test.Test
import kotlin.test.assertNotNull

/**
 * Extensions resolve their parsers out of Injekt from static initialisers, so a missing
 * registration is not a nice error: the class fails to initialise and every later call on that
 * source reports ExceptionInInitializerError / NoClassDefFoundError with the real
 * InjektionException already swallowed. Measured on five of the 127 installed extensions while
 * only Json was registered.
 */
class AppModuleTest {
    private fun scope(): InjektScope =
        InjektScope(DefaultRegistrar()).apply { importModule(AppModule(Application())) }

    @Test
    fun serializationParsersUsedByExtensionsAreResolvable() {
        val injekt = scope()
        assertNotNull(injekt.get<Json>())
        assertNotNull(injekt.get<ProtoBuf>())
    }
}
