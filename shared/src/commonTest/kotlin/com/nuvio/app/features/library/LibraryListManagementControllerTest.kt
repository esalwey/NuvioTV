package com.nuvio.app.features.library

import com.nuvio.app.features.tracking.LibraryListPrivacy
import com.nuvio.app.features.tracking.TrackingLibraryTab
import com.nuvio.app.features.tracking.TrackingLibraryTabKind
import com.nuvio.app.features.tracking.TrackingListManagementCapabilities
import com.nuvio.app.features.tracking.TrackingListManager
import com.nuvio.app.features.tracking.TrackingProviderId
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LibraryListManagementControllerTest {
    private val context = LibraryManagementContext(1, LibrarySourceMode.TRAKT)

    @Test
    fun `duplicate submission is suppressed and an old completion keeps the new editor`() = runBlocking {
        val manager = TestListManager()
        val waiting = CompletableDeferred<Unit>()
        manager.action = { waiting.await() }
        val controller = LibraryListManagementController({ context }, { manager })
        controller.open()
        controller.create()
        controller.setName("First")
        val first = launch { controller.submit() }
        yield()
        controller.submit()
        assertEquals(listOf("create:First:PRIVATE"), manager.calls)
        controller.open()
        controller.create()
        controller.setName("Second")
        waiting.complete(Unit)
        first.join()
        assertEquals("Second", controller.state.value?.name)
        assertEquals(LibraryListDialogMode.EDIT, controller.state.value?.mode)
    }

    @Test
    fun `profile or source change rejects a pending draft`() = runBlocking {
        for (replacement in listOf(context.copy(profileId = 2), context.copy(source = LibrarySourceMode.SIMKL))) {
            var current = context
            val manager = TestListManager()
            val controller = LibraryListManagementController({ current }, { manager })
            controller.create()
            controller.setName("Draft")
            current = replacement
            controller.submit()
            assertTrue(manager.calls.isEmpty())
            assertNull(controller.state.value)
        }
    }

    @Test
    fun `failed save keeps the draft and can be retried`() = runBlocking {
        val manager = TestListManager().apply { action = { error("Unavailable") } }
        val controller = LibraryListManagementController({ context }, { manager })
        controller.create()
        controller.setName("Movies")
        controller.setPrivacy(LibraryListPrivacy.PUBLIC)
        controller.submit()
        assertEquals("Unavailable", controller.state.value?.error?.message)
        assertEquals("Movies", controller.state.value?.name)
        manager.action = {}
        controller.submit()
        assertEquals(LibraryListDialogMode.MANAGE, controller.state.value?.mode)
        assertEquals(listOf("create:Movies:PUBLIC", "create:Movies:PUBLIC"), manager.calls)
    }

    @Test
    fun `a blank name is not submitted`() = runBlocking {
        val manager = TestListManager()
        val controller = LibraryListManagementController({ context }, { manager })
        controller.create()
        controller.setName("   ")
        controller.submit()
        assertTrue(manager.calls.isEmpty())
        assertEquals(LibraryListDialogMode.EDIT, controller.state.value?.mode)
    }

    @Test
    fun `editing an existing list starts from its values and updates by key`() = runBlocking {
        val manager = TestListManager()
        val controller = LibraryListManagementController({ context }, { manager })
        controller.edit(
            TrackingLibraryTab(
                key = "trakt:list:7",
                title = "Horror",
                providerId = TrackingProviderId.TRAKT,
                kind = TrackingLibraryTabKind.PERSONAL,
                description = "Scary ones",
                privacy = LibraryListPrivacy.PUBLIC,
            ),
        )
        assertEquals("Horror", controller.state.value?.name)
        assertEquals("Scary ones", controller.state.value?.description)
        assertEquals(LibraryListPrivacy.PUBLIC, controller.state.value?.privacy)

        controller.setName("Horror Night")
        controller.submit()

        assertEquals(listOf("update:trakt:list:7:Horror Night"), manager.calls)
        assertEquals(LibraryListDialogMode.MANAGE, controller.state.value?.mode)
    }

    @Test
    fun `delete needs the confirmation step and deletes by key`() = runBlocking {
        val manager = TestListManager()
        val controller = LibraryListManagementController({ context }, { manager })
        controller.requestDelete(
            TrackingLibraryTab("trakt:list:7", "Horror", TrackingProviderId.TRAKT, TrackingLibraryTabKind.PERSONAL),
        )
        assertEquals(LibraryListDialogMode.DELETE, controller.state.value?.mode)
        assertTrue(manager.calls.isEmpty())

        controller.submit()

        assertEquals(listOf("delete:trakt:list:7"), manager.calls)
        assertEquals(LibraryListDialogMode.MANAGE, controller.state.value?.mode)
    }

    @Test
    fun `reconcileContext dismisses a dialog opened for another library`() {
        var current: LibraryManagementContext? = context
        val controller = LibraryListManagementController({ current }, { TestListManager() })
        controller.open()
        controller.reconcileContext()
        assertEquals(LibraryListDialogMode.MANAGE, controller.state.value?.mode)

        current = null
        controller.reconcileContext()
        assertNull(controller.state.value)
    }

    private class TestListManager : TrackingListManager {
        override val capabilities = TrackingListManagementCapabilities(
            privacyOptions = listOf(LibraryListPrivacy.PRIVATE, LibraryListPrivacy.PUBLIC),
            supportsDescription = true,
        )
        val calls = mutableListOf<String>()
        var action: suspend () -> Unit = {}

        override suspend fun createList(name: String, description: String?, privacy: LibraryListPrivacy) {
            calls += "create:$name:$privacy"
            action()
        }

        override suspend fun updateList(key: String, name: String, description: String?, privacy: LibraryListPrivacy) {
            calls += "update:$key:$name"
            action()
        }

        override suspend fun deleteList(key: String) {
            calls += "delete:$key"
            action()
        }
    }
}
