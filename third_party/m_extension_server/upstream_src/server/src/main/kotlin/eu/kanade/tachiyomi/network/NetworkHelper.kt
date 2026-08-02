package eu.kanade.tachiyomi.network

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import android.content.Context
import eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor
import eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor
import eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor
import okhttp3.Cache
import okhttp3.OkHttpClient
import okhttp3.brotli.BrotliInterceptor
import okhttp3.logging.HttpLoggingInterceptor
import java.nio.file.Files
import java.util.concurrent.TimeUnit

class NetworkHelper(
    val context: Context,
) {
    val cookieJar = MemoryCookieJar()

    val client by lazy {
        val builder =
            OkHttpClient
                .Builder()
                .cookieJar(cookieJar)
                .addInterceptor(UncaughtExceptionInterceptor())
                .addInterceptor(UserAgentInterceptor(::defaultUserAgentProvider))
                .addInterceptor(CloudflareInterceptor())
                .addInterceptor(HttpLoggingInterceptor().setLevel(HttpLoggingInterceptor.Level.BODY))
                .addInterceptor(BrotliInterceptor)
                .connectTimeout(30, TimeUnit.SECONDS)
                .readTimeout(30, TimeUnit.SECONDS)
                .callTimeout(2, TimeUnit.MINUTES)
                .cache(
                    Cache(
                        directory = Files.createTempDirectory("m_network_cache").toFile(),
                        maxSize = 5L * 1024 * 1024, // 5 MiB
                    ),
                )
        builder.build()
    }

    val cloudflareClient by lazy {
        client
            .newBuilder()
            .addInterceptor(CloudflareInterceptor())
            .build()
    }

    private var defaultUserAgent: String = System.getProperty("http.agent").orEmpty()

    fun setUA(ua: String) {
        defaultUserAgent = ua
    }

    fun defaultUserAgentProvider() = defaultUserAgent
}
