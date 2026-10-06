package com.nuvio.app.features.player

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb

/** Compose `Color` ⇄ shared [SubtitleColor] adapters. Conversion happens only at the UI boundary. */
fun SubtitleColor.toComposeColor(): Color = Color(argb.toInt())

fun Color.toSubtitleColor(): SubtitleColor = SubtitleColor(toArgb().toLong() and 0xFFFFFFFFL)
