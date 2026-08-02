package mextensionserver.impl

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/. */

import android.content.pm.PackageInfo
import io.github.oshai.kotlinlogging.KotlinLogging
import mextensionserver.util.Extension
import mextensionserver.util.PackageTools.dex2jar
import mextensionserver.util.PackageTools.getPackageInfo
import mextensionserver.util.PackageTools.loadExtensionSources
import java.io.File
import java.net.URLClassLoader
import java.nio.file.Files
import java.security.MessageDigest
import java.util.Base64
import java.util.UUID

object MExtensionServerLoader {
    private val logger = KotlinLogging.logger {}
    private val tempDir = Files.createTempDirectory("mextensionserver").toFile()

    // Extensions retain pagination iterators and other request state. Keep one
    // instance per APK for the server lifetime instead of decoding it per call.
    private val loadedExtensions =
        ExtensionInstanceCache(
            keyOf = ::sha256,
            load = ::loadExtension,
            dispose = LoadedExtension::close,
        )

    private const val MANGA_PACKAGE = "tachiyomi.extension"
    private const val ANIME_PACKAGE = "tachiyomi.animeextension"
    private const val METADATA_SOURCE_CLASS_SUFFIX = ".class"

    init {
        // Close classloaders before deleting their JARs, including on JVM exit.
        try {
            Runtime.getRuntime().addShutdownHook(
                Thread {
                    cleanupTempFiles()
                },
            )
        } catch (e: IllegalStateException) {
            // Shutdown already in progress, ignore
        }
    }

    class LoadedExtension(
        val sources: List<Any>,
        val packageInfo: PackageInfo,
        val jarFile: File,
        private val classLoader: URLClassLoader,
    ) : AutoCloseable {
        override fun close() {
            try {
                sources
                    .filterIsInstance<eu.kanade.tachiyomi.source.Source>()
                    .forEach(MihonMetadataCache::remove)
                classLoader.close()
            } finally {
                if (jarFile.exists() && !jarFile.delete()) {
                    logger.warn { "Failed to delete cached extension JAR ${jarFile.absolutePath}" }
                }
            }
        }
    }

    fun <T> invokeWithExtension(
        base64Data: String,
        block: (LoadedExtension) -> T,
    ): T = loadedExtensions.use(Base64.getDecoder().decode(base64Data), block)

    private fun loadExtension(apkData: ByteArray): LoadedExtension {
        val tempApkFile = File(tempDir, "extension-${UUID.randomUUID()}.apk")
        val jarFile = File(tempDir, "extension-${UUID.randomUUID()}.jar")
        var classLoader: URLClassLoader? = null
        try {
            // Write APK data to temp file
            tempApkFile.writeBytes(apkData)

            // Get package info
            val packageInfo = getPackageInfo(tempApkFile.absolutePath)

            // Extract class name
            val metaData = packageInfo.applicationInfo.metaData
            var classNameSuffix = metaData.getString(MANGA_PACKAGE + METADATA_SOURCE_CLASS_SUFFIX)
            if (classNameSuffix == null) {
                classNameSuffix = metaData.getString(ANIME_PACKAGE + METADATA_SOURCE_CLASS_SUFFIX)
            }
            if (classNameSuffix == null) {
                throw IllegalArgumentException("No source class found in extension metadata")
            }
            val className =
                if (classNameSuffix.startsWith(".")) {
                    packageInfo.packageName + classNameSuffix
                } else {
                    classNameSuffix
                }
            logger.debug { "Main class for extension is $className" }

            // Convert to JAR
            val dexFile = File(tempApkFile.absolutePath)

            dex2jar(dexFile, jarFile)

            // Extract assets and resources from APK
            Extension.extractAssetsFromApk(tempApkFile, jarFile)

            // Load extension sources
            val loadedSource = loadExtensionSources(jarFile, className, tempApkFile)
            val extensionMainClassInstance = loadedSource.instance
            classLoader = loadedSource.classLoader
            val sources: List<Any> =
                when (extensionMainClassInstance) {
                    is eu.kanade.tachiyomi.source.Source -> listOf(extensionMainClassInstance)
                    is eu.kanade.tachiyomi.source.SourceFactory -> extensionMainClassInstance.createSources()
                    is eu.kanade.tachiyomi.animesource.AnimeSource -> listOf(extensionMainClassInstance)
                    is eu.kanade.tachiyomi.animesource.AnimeSourceFactory -> extensionMainClassInstance.createSources()
                    else -> throw RuntimeException("Unknown source class type! ${extensionMainClassInstance.javaClass}")
                }

            return LoadedExtension(sources, packageInfo, jarFile, loadedSource.classLoader)
        } catch (error: Throwable) {
            try {
                classLoader?.close()
            } finally {
                jarFile.delete()
            }
            logger.error(error) { "Failed to load extension from base64 data" }
            throw error
        } finally {
            // Clean up APK file
            if (tempApkFile.exists()) {
                tempApkFile.delete()
            }
        }
    }

    private fun sha256(data: ByteArray): String =
        MessageDigest
            .getInstance("SHA-256")
            .digest(data)
            .joinToString(separator = "") { byte -> "%02x".format(byte) }

    fun cleanupTempFiles() {
        MihonImageProxy.clear()
        MihonMetadataCache.clear()
        try {
            loadedExtensions.close()
        } catch (e: Exception) {
            logger.warn(e) { "Failed to close cached extensions" }
        } finally {
            try {
                tempDir.listFiles()?.forEach { file ->
                    if (file.isFile) {
                        file.delete()
                    }
                }
            } catch (e: Exception) {
                logger.warn(e) { "Failed to cleanup temp files" }
            }
        }
    }
}
