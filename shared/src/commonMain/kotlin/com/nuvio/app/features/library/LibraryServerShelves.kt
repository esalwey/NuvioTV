package com.nuvio.app.features.library

import com.nuvio.app.features.home.HomeCatalogSection
import com.nuvio.app.features.servers.ServerCatalog
import com.nuvio.app.features.servers.ServerFailure
import com.nuvio.app.features.servers.ServerLibraryRef
import com.nuvio.app.features.servers.serverFailure
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope

/**
 * One server library as the Library screen shows it: a row of its newest titles, or the reason it
 * could not load. Ported from upstream's `LibraryServerContent` minus the Compose rendering, which
 * the tvOS Library screen does natively.
 */
data class LibraryServerShelf(
    val ref: ServerLibraryRef,
    val section: HomeCatalogSection? = null,
    val failure: ServerFailure? = null,
)

/** Loads a shelf for every selected library of every enabled server; one failing library never hides the others. */
suspend fun loadServerShelves(): List<LibraryServerShelf> = coroutineScope {
    ServerCatalog.libraries().map { ref ->
        async {
            try {
                LibraryServerShelf(ref, section = ServerCatalog.librarySection(ref, SERVER_SHELF_LIMIT))
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                LibraryServerShelf(ref, failure = error.serverFailure())
            }
        }
    }.awaitAll()
}

const val SERVER_SHELF_LIMIT = 18
