package com.nuvio.app.features.servers.jellyfin

import com.nuvio.app.features.servers.mediabrowser.Endpoint
import com.nuvio.app.features.servers.mediabrowser.MediaBrowserProvider
import com.nuvio.app.features.servers.mediabrowser.MediaBrowserTransport
import com.nuvio.app.features.servers.mediabrowser.PlatformMediaBrowserTransport
import com.nuvio.app.features.servers.mediabrowser.pathSegment

internal class JellyfinProvider(
    transport: MediaBrowserTransport = PlatformMediaBrowserTransport,
) : MediaBrowserProvider(authorizationHeader = "Authorization", apiPath = "", transport = transport) {
    override val id: String = "jellyfin"
    override val displayName: String = "Jellyfin"
    override val minimumVersion: String = "10.9"

    override fun viewsEndpoint(userId: String) = Endpoint("/UserViews", mapOf("userId" to userId))

    override fun itemsEndpoint(userId: String) = Endpoint("/Items", mapOf("userId" to userId))

    override fun itemEndpoint(userId: String, itemId: String) =
        Endpoint("/Items/${pathSegment(itemId)}", mapOf("userId" to userId))

    override fun resumeEndpoint(userId: String) = Endpoint("/UserItems/Resume", mapOf("userId" to userId))

    override fun playedEndpoint(userId: String, itemId: String) =
        Endpoint("/UserPlayedItems/${pathSegment(itemId)}", mapOf("userId" to userId))
}
