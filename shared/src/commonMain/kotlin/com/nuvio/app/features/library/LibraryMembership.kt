package com.nuvio.app.features.library

import com.nuvio.app.core.tracking.ensureTrackingProvidersRegistered
import com.nuvio.app.features.tracking.TrackingLibraryTab
import com.nuvio.app.features.tracking.TrackingMembershipApplyResult
import com.nuvio.app.features.tracking.TrackingMembershipRemovalConfirmation
import com.nuvio.app.features.tracking.TrackingMembershipRemovalImpact
import com.nuvio.app.features.tracking.TrackingMembershipResolution
import com.nuvio.app.features.tracking.TrackingProviderId
import com.nuvio.app.features.tracking.TrackingProviderRegistry
import com.nuvio.app.features.tracking.toggleTrackingLibraryMembership
import com.nuvio.app.features.tracking.trackingMembershipDestinations

/**
 * Swift-facing "which lists is this title on" flow (the Detail page's Add to Lists and the "+"
 * button). Everything the UI needs is a plain class or string, and every suspending entry point
 * is `@Throws`, so a failure reaches Swift as an `NSError` instead of aborting the process.
 */
object LibraryMembership {
    /** True when a connected tracking account offers lists to put a title on besides the local library. */
    fun hasProviderLists(): Boolean {
        ensureTrackingProvidersRegistered()
        return TrackingProviderRegistry.connectedLibraryProviders().isNotEmpty()
    }

    /** Loads the lists [item] can be added to and which of them it is on now. */
    @Throws(Throwable::class)
    suspend fun editor(item: LibraryItem): LibraryMembershipEditor {
        val snapshot = LibraryRepository.getMembershipSnapshot(item)
        val tabs = LibraryRepository.libraryListTabs(item)
        return LibraryMembershipEditor(item, tabs, tabs.associate { tab -> tab.key to (snapshot[tab.key] == true) })
    }

    /**
     * The "+" button: adds the title to, or removes it from, the active library's default list.
     * A provider that would also clear watched history or a rating asks first (see
     * [LibraryMembershipOutcome.requiresConfirmation]).
     */
    @Throws(Throwable::class)
    suspend fun toggleSaved(item: LibraryItem): LibraryMembershipOutcome =
        toggleSavedOutcome(item, emptySet())

    private suspend fun toggleSavedOutcome(
        item: LibraryItem,
        confirmed: Set<TrackingProviderId>,
    ): LibraryMembershipOutcome {
        val result = LibraryRepository.toggleSavedConfirmable(item, confirmed)
        return result.toOutcome(item.name) { providers -> toggleSavedOutcome(item, providers) }
    }
}

/** One row of the Add to Lists checklist. [groupTitle] is the provider's name; null is the local library. */
class LibraryMembershipOption(
    val key: String,
    val title: String,
    val groupTitle: String?,
    val isSelected: Boolean,
)

/**
 * The editable list membership of one title. [toggle] flips a row (picking a Simkl status clears
 * the others), [save] writes the difference.
 */
class LibraryMembershipEditor internal constructor(
    private val item: LibraryItem,
    tabs: List<TrackingLibraryTab>,
    private val initialMembership: Map<String, Boolean>,
) {
    private val destinations = trackingMembershipDestinations(tabs)
    private var membership: Map<String, Boolean> = initialMembership

    val itemTitle: String get() = item.name

    fun options(): List<LibraryMembershipOption> = destinations.map { tab ->
        LibraryMembershipOption(
            key = tab.key,
            title = tab.title,
            groupTitle = tab.providerId?.let(::trackingProviderDisplayName),
            isSelected = membership[tab.key] == true,
        )
    }

    fun toggle(key: String) {
        membership = toggleTrackingLibraryMembership(destinations, membership, key)
    }

    val hasChanges: Boolean
        get() = destinations.any { tab -> (membership[tab.key] == true) != (initialMembership[tab.key] == true) }

    @Throws(Throwable::class)
    suspend fun save(): LibraryMembershipOutcome = saveConfirming(emptySet())

    private suspend fun saveConfirming(confirmed: Set<TrackingProviderId>): LibraryMembershipOutcome {
        val result = LibraryRepository.applyMembershipChangesConfirmable(
            item = item,
            desiredMembership = membership,
            confirmedRemovalProviders = confirmed,
        )
        return result.toOutcome(item.name, destinations) { providers -> saveConfirming(providers) }
    }
}

enum class LibraryRemovalImpact { WATCHED_HISTORY, RATING, WATCHED_HISTORY_AND_RATING }

/** A provider put the title on a different list than the one asked for. */
class LibraryMembershipRewrite(
    val providerName: String,
    val requestedTitle: String,
    val resolvedTitle: String,
)

/**
 * What a membership write did. When [requiresConfirmation] is true nothing was written yet:
 * ask the user, then call [confirmRemoval]. Otherwise [rewrites] lists any list the provider
 * substituted, for the "moved to ..." message.
 */
class LibraryMembershipOutcome internal constructor(
    val itemTitle: String,
    val providerNames: List<String>,
    val removalImpact: LibraryRemovalImpact?,
    val rewrites: List<LibraryMembershipRewrite>,
    private val confirmedProviders: Set<TrackingProviderId>,
    private val retry: (suspend (Set<TrackingProviderId>) -> LibraryMembershipOutcome)?,
) {
    val requiresConfirmation: Boolean get() = retry != null

    @Throws(Throwable::class)
    suspend fun confirmRemoval(): LibraryMembershipOutcome = retry?.invoke(confirmedProviders) ?: this
}

internal fun trackingProviderDisplayName(id: TrackingProviderId): String =
    TrackingProviderRegistry.authProvider(id)?.descriptor?.displayName
        ?: id.storageId.replaceFirstChar { char -> char.titlecase() }

internal fun TrackingMembershipApplyResult.toOutcome(
    itemTitle: String,
    tabs: List<TrackingLibraryTab> = emptyList(),
    retry: suspend (Set<TrackingProviderId>) -> LibraryMembershipOutcome,
): LibraryMembershipOutcome {
    if (requiresRemovalConfirmation) {
        return LibraryMembershipOutcome(
            itemTitle = itemTitle,
            providerNames = requiredRemovalConfirmations
                .map { confirmation -> trackingProviderDisplayName(confirmation.providerId) }
                .distinct(),
            removalImpact = removalImpact(requiredRemovalConfirmations),
            rewrites = emptyList(),
            confirmedProviders = requiredRemovalConfirmations.mapTo(linkedSetOf()) { it.providerId },
            retry = retry,
        )
    }
    return LibraryMembershipOutcome(
        itemTitle = itemTitle,
        providerNames = emptyList(),
        removalImpact = null,
        rewrites = rewrites.map { resolution -> resolution.toRewrite(tabs) },
        confirmedProviders = emptySet(),
        retry = null,
    )
}

/** Collapses the impacts of every provider asking for confirmation into one sentence's worth. */
internal fun removalImpact(confirmations: List<TrackingMembershipRemovalConfirmation>): LibraryRemovalImpact {
    val impacts = confirmations.flatMapTo(linkedSetOf()) { confirmation -> confirmation.impacts }
    return when (impacts) {
        setOf(TrackingMembershipRemovalImpact.WATCHED_HISTORY) -> LibraryRemovalImpact.WATCHED_HISTORY
        setOf(TrackingMembershipRemovalImpact.RATING) -> LibraryRemovalImpact.RATING
        else -> LibraryRemovalImpact.WATCHED_HISTORY_AND_RATING
    }
}

private fun TrackingMembershipResolution.toRewrite(tabs: List<TrackingLibraryTab>): LibraryMembershipRewrite {
    val providerName = trackingProviderDisplayName(providerId)
    val known = tabs.ifEmpty {
        TrackingProviderRegistry.libraryProvider(providerId)?.snapshot()?.tabs.orEmpty()
    }
    return LibraryMembershipRewrite(
        providerName = providerName,
        requestedTitle = known.rewriteTitle(requestedListKey, providerName),
        resolvedTitle = known.rewriteTitle(resolvedListKey, providerName),
    )
}

/** A list's display name without the provider prefix, falling back to the key's last segment. */
internal fun List<TrackingLibraryTab>.rewriteTitle(key: String, providerName: String): String =
    firstOrNull { tab -> tab.key == key }
        ?.title
        ?.removePrefix("$providerName ")
        ?: key.substringAfterLast(':')
