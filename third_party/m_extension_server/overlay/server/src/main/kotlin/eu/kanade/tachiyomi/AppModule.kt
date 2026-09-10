package eu.kanade.tachiyomi

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import android.app.Application
import eu.kanade.tachiyomi.network.JavaScriptEngine
import eu.kanade.tachiyomi.network.NetworkHelper
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.json.Json
import kotlinx.serialization.protobuf.ProtoBuf
import uy.kohesive.injekt.api.InjektModule
import uy.kohesive.injekt.api.InjektRegistrar
import uy.kohesive.injekt.api.addSingleton
import uy.kohesive.injekt.api.addSingletonFactory

class AppModule(
    val app: Application,
) : InjektModule {
    @OptIn(ExperimentalSerializationApi::class)
    override fun InjektRegistrar.registerInjectables() {
        addSingleton(app)

        addSingletonFactory { NetworkHelper(app) }
        addSingletonFactory { JavaScriptEngine(app) }

        addSingletonFactory {
            Json {
                ignoreUnknownKeys = true
                explicitNulls = false
                coerceInputValues = true
            }
        }

        // Extensions talking to protobuf APIs resolve this the same way they resolve Json:
        // `Injekt.get<ProtoBuf>()` from a static initialiser. Upstream registered only Json, so
        // on this sidecar those sources died with ExceptionInInitializerError caused by
        // InjektionException, at whichever call first touched the parser -- measured on Zebrack,
        // Manga One, Corocoro Online, Zerosum Online and MangaMee, five of the installed 127.
        // The dependency was already on the classpath; only the registration was missing.
        // Mihon registers the default instance, and the extensions are built against that
        // behaviour, so this must stay unconfigured.
        //
        // The type argument is explicit on purpose: `ProtoBuf` here is the companion object, so
        // inference registers it under ProtoBuf.Default and a source asking for ProtoBuf still
        // gets InjektionException -- the same failure, now with the registration in place.
        addSingletonFactory<ProtoBuf> { ProtoBuf }
    }
}
