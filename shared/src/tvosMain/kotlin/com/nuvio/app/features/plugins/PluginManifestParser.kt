package com.nuvio.app.features.plugins

import kotlinx.serialization.json.Json

internal object PluginManifestParser {
    private val json = Json {
        ignoreUnknownKeys = true
    }

    fun parse(payload: String): PluginManifest {
        val manifest = json.decodeFromString<PluginManifest>(payload)
        require(manifest.name.isNotBlank()) {
            "Plugin manifest is missing a name."
        }
        require(manifest.version.isNotBlank()) {
            "Plugin manifest is missing a version."
        }
        require(manifest.scrapers.isNotEmpty()) {
            "Plugin manifest contains no providers."
        }
        return manifest
    }
}
