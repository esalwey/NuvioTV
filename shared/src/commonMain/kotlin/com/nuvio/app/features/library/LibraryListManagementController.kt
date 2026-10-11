package com.nuvio.app.features.library

import com.nuvio.app.features.tracking.LibraryListPrivacy
import com.nuvio.app.features.tracking.TrackingLibraryTab
import com.nuvio.app.features.tracking.TrackingListManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Which library a list edit belongs to. A draft is only ever applied while the active profile and
 * source are still the ones it was started against.
 */
data class LibraryManagementContext(val profileId: Int, val source: LibrarySourceMode)

enum class LibraryListDialogMode { MANAGE, EDIT, DELETE }

data class LibraryListDialogState(
    val context: LibraryManagementContext,
    val instance: Long,
    val mode: LibraryListDialogMode = LibraryListDialogMode.MANAGE,
    val key: String? = null,
    val name: String = "",
    val description: String = "",
    val privacy: LibraryListPrivacy = LibraryListPrivacy.PRIVATE,
    val isPending: Boolean = false,
    val error: Exception? = null,
)

/**
 * State machine behind the "manage lists" flow: open the manager, create or edit a list, confirm
 * a delete. Port of the mobile app's controller; the UI only renders [state] and forwards input.
 *
 * Guarantees: a second [submit] while one is in flight is ignored, a completion that arrives for a
 * superseded editor never overwrites the newer one, a failed save keeps the draft (with [error])
 * so it can be retried, and a profile or source change dismisses the dialog.
 */
class LibraryListManagementController(
    private val currentContext: () -> LibraryManagementContext?,
    private val manager: (LibraryManagementContext) -> TrackingListManager,
) {
    private var sequence = 0L
    private val mutableState = MutableStateFlow<LibraryListDialogState?>(null)
    val state: StateFlow<LibraryListDialogState?> = mutableState.asStateFlow()

    fun open() {
        mutableState.value = currentContext()?.let { LibraryListDialogState(it, ++sequence) }
    }

    /** Dismisses the dialog when the library it was opened for is no longer the active one. */
    fun reconcileContext() {
        if (mutableState.value?.context != currentContext()) dismiss()
    }

    fun dismiss() {
        mutableState.value = null
    }

    fun create() = edit(null)

    /** Opens the editor on [tab], or a blank editor for a new list when [tab] is null. */
    fun edit(tab: TrackingLibraryTab?) {
        val context = currentContext() ?: return dismiss()
        val capabilities = manager(context).capabilities
        mutableState.value = LibraryListDialogState(
            context = context,
            instance = ++sequence,
            mode = LibraryListDialogMode.EDIT,
            key = tab?.key,
            name = tab?.title.orEmpty(),
            description = if (capabilities.supportsDescription) tab?.description.orEmpty() else "",
            privacy = tab?.privacy?.takeIf { it in capabilities.privacyOptions }
                ?: capabilities.privacyOptions.first(),
        )
    }

    fun requestDelete(tab: TrackingLibraryTab) {
        val context = currentContext() ?: return dismiss()
        mutableState.value = LibraryListDialogState(
            context = context,
            instance = ++sequence,
            mode = LibraryListDialogMode.DELETE,
            key = tab.key,
            name = tab.title,
        )
    }

    fun setName(value: String) = editDraft { it.copy(name = value) }

    fun setDescription(value: String) = editDraft { it.copy(description = value) }

    fun setPrivacy(value: LibraryListPrivacy) = editDraft { it.copy(privacy = value) }

    /** Saves the open draft (or performs the confirmed delete). Failures land in [state]. */
    @Throws(CancellationException::class)
    suspend fun submit() {
        val draft = mutableState.value ?: return
        if (draft.isPending || draft.mode == LibraryListDialogMode.MANAGE) return
        if (draft.mode == LibraryListDialogMode.EDIT && draft.name.isBlank()) return
        if (currentContext() != draft.context) return dismiss()
        mutableState.value = draft.copy(isPending = true, error = null)
        try {
            val target = manager(draft.context)
            when {
                draft.mode == LibraryListDialogMode.DELETE -> target.deleteList(requireNotNull(draft.key))
                draft.key == null -> target.createList(
                    draft.name,
                    draft.description.takeIf(String::isNotBlank),
                    draft.privacy,
                )
                else -> target.updateList(
                    draft.key,
                    draft.name,
                    draft.description.takeIf(String::isNotBlank),
                    draft.privacy,
                )
            }
            if (isCurrent(draft)) mutableState.value = LibraryListDialogState(draft.context, ++sequence)
        } catch (error: CancellationException) {
            if (isCurrent(draft)) mutableState.value = draft
            throw error
        } catch (error: Exception) {
            if (isCurrent(draft)) mutableState.value = draft.copy(error = error)
        } finally {
            if (mutableState.value?.instance == draft.instance && currentContext() != draft.context) dismiss()
        }
    }

    private fun isCurrent(draft: LibraryListDialogState) =
        mutableState.value?.instance == draft.instance && currentContext() == draft.context

    private fun editDraft(update: (LibraryListDialogState) -> LibraryListDialogState) {
        val draft = mutableState.value ?: return
        if (!draft.isPending && draft.mode == LibraryListDialogMode.EDIT) {
            mutableState.value = update(draft).copy(error = null)
        }
    }
}
