package mextensionserver

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */

import android.os.Looper
import eu.kanade.tachiyomi.App
import io.github.oshai.kotlinlogging.KotlinLogging
import mextensionserver.controller.MExtensionServerController
import mextensionserver.ui.ServerWindow
import org.kodein.di.DI
import org.kodein.di.conf.global
import xyz.nulldev.androidcompat.AndroidCompat
import xyz.nulldev.androidcompat.AndroidCompatInitializer
import xyz.nulldev.ts.config.ConfigKodeinModule
import java.net.CookieHandler
import java.net.CookieManager
import java.util.concurrent.CompletableFuture
import javax.swing.SwingUtilities

private val logger = KotlinLogging.logger {}
private val androidCompat by lazy { AndroidCompat() }

@Suppress("BlockingMethodInNonBlockingContext")
fun main(args: Array<String>) {
    val useUI = "--ui" in args
    val filteredArgs = args.filter { it != "--ui" }
    val port = filteredArgs.getOrNull(0)?.toIntOrNull() ?: 0
    val appDir = filteredArgs.getOrNull(1)

    if (useUI) {
        // Must be set before any AWT/Swing initialisation
        System.setProperty("apple.awt.application.name", "MExtension Server")
        System.setProperty("apple.laf.useScreenMenuBar", "true")
    }

    CookieHandler.setDefault(CookieManager())
    initApplication(appDir)

    if (useUI) {
        // Show the Swing window; the AWT event-dispatch thread (non-daemon)
        // keeps the JVM alive until the window is closed.
        SwingUtilities.invokeLater { ServerWindow().show() }
    } else {
        val controller = MExtensionServerController()
        controller.start(port)
        Runtime.getRuntime().addShutdownHook(Thread { controller.stop() })
        // Keep running
        while (controller.isRunning()) {
            Thread.sleep(1000)
        }
    }
}

private fun initApplication(appDir: String?) {
    logger.info("Running MExtensionServer ${BuildConfig.VERSION} revision ${BuildConfig.REVISION}")

    // Set custom app directory if provided
    appDir?.let { System.setProperty("ts.server.rootDir", it) }

    startMainLooper()

    // Load config API
    DI.global.addImport(ConfigKodeinModule().create())
    // Load Android compatibility dependencies
    AndroidCompatInitializer().init()
    // start app
    androidCompat.startApp(App())
}

private fun startMainLooper() {
    if (Looper.getMainLooper() != null) return

    val ready = CompletableFuture<Unit>()
    Thread(
        {
            try {
                Looper.prepareMainLooper()
                ready.complete(Unit)
                Looper.loop()
            } catch (error: Throwable) {
                ready.completeExceptionally(error)
                logger.error(error) { "Android main looper stopped" }
            }
        },
        "Android main looper",
    ).apply {
        isDaemon = true
        start()
    }
    ready.join()
}
