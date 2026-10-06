package com.nuvio.app.core.network

import androidx.compose.runtime.Composable
import nuvio.composeapp.generated.resources.Res
import nuvio.composeapp.generated.resources.details_check_connection
import nuvio.composeapp.generated.resources.details_servers_unreachable
import nuvio.composeapp.generated.resources.network_cannot_reach_servers
import nuvio.composeapp.generated.resources.network_connection_issue
import nuvio.composeapp.generated.resources.network_no_internet_connection
import nuvio.composeapp.generated.resources.network_please_check_connection
import org.jetbrains.compose.resources.stringResource

@Composable
fun NetworkCondition.titleForEmptyState(): String =
    when (this) {
        NetworkCondition.ServersUnreachable -> stringResource(Res.string.network_cannot_reach_servers)
        NetworkCondition.NoInternet -> stringResource(Res.string.network_no_internet_connection)
        else -> stringResource(Res.string.network_connection_issue)
    }

@Composable
fun NetworkCondition.messageForEmptyState(): String =
    when (this) {
        NetworkCondition.ServersUnreachable -> stringResource(Res.string.details_servers_unreachable)
        NetworkCondition.NoInternet -> stringResource(Res.string.details_check_connection)
        else -> stringResource(Res.string.network_please_check_connection)
    }
