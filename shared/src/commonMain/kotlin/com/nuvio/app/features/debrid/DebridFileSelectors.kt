package com.nuvio.app.features.debrid

import com.nuvio.app.features.streams.StreamClientResolve

class TorboxFileSelector {
    fun selectFile(
        files: List<TorboxTorrentFileDto>,
        resolve: StreamClientResolve,
        season: Int?,
        episode: Int?,
    ): TorboxTorrentFileDto? {
        val playable = files.filter { it.isPlayableVideo() }
        if (playable.isEmpty()) return null

        val episodePatterns = buildEpisodePatterns(
            season = season ?: resolve.season,
            episode = episode ?: resolve.episode,
        )
        val names = resolve.specificFileNames(episodePatterns)
        if (names.isNotEmpty()) {
            playable.firstNameMatch(names) { it.displayName() }?.let {
                return it
            }
        }

        if (episodePatterns.isNotEmpty()) {
            playable.firstOrNull { file ->
                val fileName = file.displayName().lowercase()
                episodePatterns.any { pattern -> fileName.contains(pattern) }
            }?.let {
                return it
            }
        }

        resolve.fileIdx?.let { fileIdx ->
            files.getOrNull(fileIdx)?.takeIf { it.isPlayableVideo() }?.let {
                return it
            }
            if (fileIdx > 0) {
                files.getOrNull(fileIdx - 1)?.takeIf { it.isPlayableVideo() }?.let {
                    return it
                }
            }
            playable.firstOrNull { it.id == fileIdx }?.let {
                return it
            }
        }

        return playable.maxByOrNull { it.size ?: 0L }
    }

    private fun TorboxTorrentFileDto.isPlayableVideo(): Boolean {
        val mime = mimeType.orEmpty().lowercase()
        if (mime.startsWith("video/")) return true
        return displayName().lowercase().hasVideoExtension()
    }
}

class RealDebridFileSelector {
    fun selectFile(
        files: List<RealDebridTorrentFileDto>,
        resolve: StreamClientResolve,
        season: Int?,
        episode: Int?,
    ): RealDebridTorrentFileDto? {
        val playable = files.filter { it.isPlayableVideo() }
        if (playable.isEmpty()) return null

        val episodePatterns = buildEpisodePatterns(
            season = season ?: resolve.season,
            episode = episode ?: resolve.episode,
        )
        val names = resolve.specificFileNames(episodePatterns)
        if (names.isNotEmpty()) {
            playable.firstNameMatch(names) { it.displayName() }?.let {
                return it
            }
        }

        if (episodePatterns.isNotEmpty()) {
            playable.firstOrNull { file ->
                val fileName = file.displayName().lowercase()
                episodePatterns.any { pattern -> fileName.contains(pattern) }
            }?.let {
                return it
            }
        }

        resolve.fileIdx?.let { fileIdx ->
            files.getOrNull(fileIdx)?.takeIf { it.isPlayableVideo() }?.let {
                return it
            }
            if (fileIdx > 0) {
                files.getOrNull(fileIdx - 1)?.takeIf { it.isPlayableVideo() }?.let {
                    return it
                }
            }
            playable.firstOrNull { it.id == fileIdx }?.let {
                return it
            }
        }

        return playable.maxByOrNull { it.bytes ?: 0L }
    }

    private fun RealDebridTorrentFileDto.isPlayableVideo(): Boolean =
        displayName().lowercase().hasVideoExtension()
}

class PremiumizeDirectDownloadFileSelector {
    fun selectFile(
        files: List<PremiumizeDirectDownloadFileDto>,
        resolve: StreamClientResolve,
        season: Int?,
        episode: Int?,
    ): PremiumizeDirectDownloadFileDto? {
        val playable = files.filter { it.isPlayableVideo() }
        if (playable.isEmpty()) return null

        val episodePatterns = buildEpisodePatterns(
            season = season ?: resolve.season,
            episode = episode ?: resolve.episode,
        )
        val names = resolve.specificFileNames(episodePatterns)
        if (names.isNotEmpty()) {
            playable.firstNameMatch(names) { it.displayName() }?.let {
                return it
            }
        }

        if (episodePatterns.isNotEmpty()) {
            playable.firstOrNull { file ->
                val fileName = file.displayName().lowercase()
                episodePatterns.any { pattern -> fileName.contains(pattern) }
            }?.let {
                return it
            }
        }

        resolve.fileIdx?.let { fileIdx ->
            files.getOrNull(fileIdx)?.takeIf { it.isPlayableVideo() }?.let {
                return it
            }
            if (fileIdx > 0) {
                files.getOrNull(fileIdx - 1)?.takeIf { it.isPlayableVideo() }?.let {
                    return it
                }
            }
        }

        return playable.maxByOrNull { it.size ?: 0L }
    }

    private fun PremiumizeDirectDownloadFileDto.isPlayableVideo(): Boolean =
        !link.isNullOrBlank() && displayName().lowercase().hasVideoExtension()
}

fun PremiumizeDirectDownloadFileDto.displayName(): String =
    path.orEmpty().substringAfterLast('/').substringAfterLast('\\').ifBlank { path.orEmpty() }

/**
 * A leaf file flattened out of AllDebrid's `magnet/files` folder tree. Public (like the other
 * provider file DTOs in this file) since `AllDebridFileSelector.selectFile` — also public —
 * exposes it in its signature.
 */
data class AllDebridFlatFile(
    val name: String,
    val size: Long?,
    val link: String,
)

fun AllDebridFlatFile.displayName(): String = name

/**
 * AllDebrid's `magnet/files` response is a tree: file nodes carry `n`/`s`/`l`, folder nodes carry
 * `n`/`e` (children) instead. Flatten it to the leaf files only, since selection only cares about
 * filenames and sizes, not folder structure.
 */
internal fun List<AllDebridFileNodeDto>.flattenAllDebridFiles(): List<AllDebridFlatFile> {
    val result = mutableListOf<AllDebridFlatFile>()
    fun visit(nodes: List<AllDebridFileNodeDto>) {
        nodes.forEach { node ->
            val children = node.e
            if (!children.isNullOrEmpty()) {
                visit(children)
            } else {
                val link = node.l?.takeIf { it.isNotBlank() } ?: return@forEach
                result.add(AllDebridFlatFile(name = node.n.orEmpty(), size = node.s, link = link))
            }
        }
    }
    visit(this)
    return result
}

class AllDebridFileSelector {
    fun selectFile(
        files: List<AllDebridFlatFile>,
        resolve: StreamClientResolve,
        season: Int?,
        episode: Int?,
    ): AllDebridFlatFile? {
        val playable = files.filter { it.isPlayableVideo() }
        if (playable.isEmpty()) return null

        val episodePatterns = buildEpisodePatterns(
            season = season ?: resolve.season,
            episode = episode ?: resolve.episode,
        )
        val names = resolve.specificFileNames(episodePatterns)
        if (names.isNotEmpty()) {
            playable.firstNameMatch(names) { it.displayName() }?.let {
                return it
            }
        }

        if (episodePatterns.isNotEmpty()) {
            playable.firstOrNull { file ->
                val fileName = file.displayName().lowercase()
                episodePatterns.any { pattern -> fileName.contains(pattern) }
            }?.let {
                return it
            }
        }

        // AllDebrid's file tree has no stable per-file index (unlike Torbox/RealDebrid), so there
        // is no fileIdx-based lookup here — just fall back to the largest playable video.
        return playable.maxByOrNull { it.size ?: 0L }
    }

    private fun AllDebridFlatFile.isPlayableVideo(): Boolean =
        name.lowercase().hasVideoExtension()
}

private fun String.normalizedName(): String =
    substringAfterLast('/')
        .substringBeforeLast('.')
        .lowercase()
        .replace(Regex("[^a-z0-9]+"), " ")
        .trim()

private fun StreamClientResolve.specificFileNames(episodePatterns: List<String>): List<String> {
    val raw = stream?.raw
    return listOfNotNull(
        filename,
        raw?.filename,
        raw?.parsed?.rawTitle?.takeIf { it.looksSpecificForSelection(episodePatterns) },
        torrentName?.takeIf { it.looksSpecificForSelection(episodePatterns) },
    )
        .map { it.normalizedName() }
        .filter { it.isNotBlank() }
        .distinct()
}

private fun String.looksSpecificForSelection(episodePatterns: List<String>): Boolean {
    val lower = lowercase()
    return lower.hasVideoExtension() || episodePatterns.any { pattern -> lower.contains(pattern) }
}

private fun <T> List<T>.firstNameMatch(
    names: List<String>,
    displayName: (T) -> String,
): T? =
    firstOrNull { item ->
        val fileName = displayName(item).normalizedName()
        names.any { name -> fileName.contains(name) || name.contains(fileName) }
    }

private fun buildEpisodePatterns(season: Int?, episode: Int?): List<String> {
    if (season == null || episode == null) return emptyList()
    val seasonTwo = season.toString().padStart(2, '0')
    val episodeTwo = episode.toString().padStart(2, '0')
    return listOf(
        "s${seasonTwo}e$episodeTwo",
        "${season}x$episodeTwo",
        "${season}x$episode",
    )
}

private fun String.hasVideoExtension(): Boolean =
    videoExtensions.any { endsWith(it) }

private val videoExtensions = setOf(
    ".mp4",
    ".mkv",
    ".webm",
    ".avi",
    ".mov",
    ".m4v",
    ".ts",
    ".m2ts",
    ".wmv",
    ".flv",
)
