package com.nuvio.app.features.debrid

import com.nuvio.app.features.streams.StreamClientResolve

// Requested-file selection (ported from upstream 6aa42153d "select requested episode files").
//
// The shared rules live in `selectDebridFile`: a stream that names its file wins when it matches
// exactly one playable file; otherwise the requested season/episode picks the file; a title that
// names a file or episode but matches nothing (or several files) selects NOTHING instead of
// falling back to another episode of the pack. Only a bare movie-like stream (no name, no
// episode) falls back to the torrent file index and then to the largest playable video.

class TorboxFileSelector {
    fun selectFile(
        files: List<TorboxTorrentFileDto>,
        resolve: StreamClientResolve,
        season: Int?,
        episode: Int?,
    ): TorboxTorrentFileDto? = selectDebridFile(
        files = files,
        resolve = resolve,
        season = season,
        episode = episode,
        path = { it.displayName() },
        isPlayable = {
            it.mimeType.orEmpty().startsWith("video/", ignoreCase = true) || it.displayName().hasVideoExtension()
        },
        size = { it.size ?: 0L },
    )
}

class RealDebridFileSelector {
    fun selectFile(
        files: List<RealDebridTorrentFileDto>,
        resolve: StreamClientResolve,
        season: Int?,
        episode: Int?,
    ): RealDebridTorrentFileDto? = selectDebridFile(
        files = files,
        resolve = resolve,
        season = season,
        episode = episode,
        path = { it.path.orEmpty() },
        isPlayable = { it.displayName().hasVideoExtension() },
        size = { it.bytes ?: 0L },
    )
}

class PremiumizeDirectDownloadFileSelector {
    fun selectFile(
        files: List<PremiumizeDirectDownloadFileDto>,
        resolve: StreamClientResolve,
        season: Int?,
        episode: Int?,
    ): PremiumizeDirectDownloadFileDto? = selectDebridFile(
        files = files,
        resolve = resolve,
        season = season,
        episode = episode,
        path = { it.path.orEmpty() },
        isPlayable = { !it.link.isNullOrBlank() && it.displayName().hasVideoExtension() },
        size = { it.size ?: 0L },
    )
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
    ): AllDebridFlatFile? = selectDebridFile(
        files = files,
        resolve = resolve,
        season = season,
        episode = episode,
        path = { it.name },
        isPlayable = { it.name.hasVideoExtension() },
        size = { it.size ?: 0L },
        // AllDebrid's file tree has no stable per-file index (unlike Torbox/RealDebrid), so a
        // fileIdx is never used to pick a file here: fall back to the largest playable video.
        useFileIndex = false,
    )
}

internal fun <T> selectDebridFile(
    files: List<T>,
    resolve: StreamClientResolve,
    season: Int?,
    episode: Int?,
    path: (T) -> String,
    isPlayable: (T) -> Boolean,
    size: (T) -> Long,
    useFileIndex: Boolean = true,
): T? {
    val playable = files.filter(isPlayable)
    if (playable.isEmpty()) return null

    val names = listOfNotNull(resolve.filename, resolve.stream?.raw?.filename)
        .map { it.normalizedPath() }
        .filter { it.isNotBlank() }
        .distinct()
    for (name in names) {
        val matches = playable.matchingFiles(name, path)
        if (matches.isNotEmpty()) return matches.singleOrNull()
    }

    val episodePattern = buildEpisodePattern(season ?: resolve.season, episode ?: resolve.episode)
    if (episodePattern != null) {
        val matches = playable.filter {
            episodePattern.containsMatchIn(path(it).normalizedPath().substringAfterLast('/'))
        }
        if (matches.isNotEmpty()) return matches.singleOrNull()
    }

    if (names.isNotEmpty() || episodePattern != null) return null

    if (useFileIndex) {
        resolve.fileIdx?.let { index ->
            return files.getOrNull(index)?.takeIf(isPlayable)
        }
    }

    return playable.maxByOrNull(size)
}

private fun String.normalizedPath(): String = trim().replace('\\', '/').removePrefix("/")

private fun <T> List<T>.matchingFiles(name: String, path: (T) -> String): List<T> {
    // Exact (case-sensitive) before case-insensitive, full path before bare file name.
    for (ignoreCase in listOf(false, true)) {
        val matches = filter {
            val filePath = path(it).normalizedPath()
            filePath.equals(name, ignoreCase = ignoreCase) ||
                (name.contains('/') && filePath.endsWith("/$name", ignoreCase = ignoreCase))
        }
        if (matches.isNotEmpty()) return matches
    }
    val basename = name.substringAfterLast('/')
    for (ignoreCase in listOf(false, true)) {
        val matches = filter {
            path(it).normalizedPath().substringAfterLast('/').equals(basename, ignoreCase = ignoreCase)
        }
        if (matches.isNotEmpty()) return matches
    }
    return emptyList()
}

private fun buildEpisodePattern(season: Int?, episode: Int?): Regex? {
    if (season == null || episode == null) return null
    return Regex(
        "(?<![a-z0-9])(?:s0*${season}e0*${episode}|0*${season}x0*${episode})(?![0-9])",
        RegexOption.IGNORE_CASE,
    )
}

private fun String.hasVideoExtension(): Boolean = videoExtensions.any { endsWith(it, ignoreCase = true) }

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
