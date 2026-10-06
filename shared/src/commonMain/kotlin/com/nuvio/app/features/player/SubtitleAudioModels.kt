package com.nuvio.app.features.player

data class AudioTrack(
    val index: Int,
    val id: String,
    val label: String,
    val language: String? = null,
    val isSelected: Boolean = false,
)

data class SubtitleTrack(
    val index: Int,
    val id: String,
    val label: String,
    val language: String? = null,
    val isSelected: Boolean = false,
    val isForced: Boolean = false,
)

data class AddonSubtitle(
    val id: String,
    val url: String,
    val language: String,
    val display: String,
    val addonName: String? = null,
    val isSelected: Boolean = false,
)

const val SUBTITLE_DELAY_MIN_MS = -60_000
const val SUBTITLE_DELAY_MAX_MS = 60_000
const val SUBTITLE_DELAY_STEP_MS = 100
const val SUBTITLE_AUTO_SYNC_REACTION_COMPENSATION_MS = 300L

data class SubtitleSyncCue(
    val startTimeMs: Long,
    val endTimeMs: Long = startTimeMs + 5_000L,
    val text: String,
)

data class SubtitleAutoSyncUiState(
    val capturedPositionMs: Long? = null,
    val cues: List<SubtitleSyncCue> = emptyList(),
    val isLoading: Boolean = false,
    val errorMessage: String? = null,
)

data class SubtitleStyleState(
    val textColor: SubtitleColor = SubtitleColor.White,
    val backgroundColor: SubtitleColor = SubtitleColor.Transparent,
    val outlineColor: SubtitleColor = SubtitleColor.Black,
    val outlineEnabled: Boolean = true,
    val outlineWidth: Int = 2,
    val bold: Boolean = false,
    val fontSizeSp: Int = 18,
    val bottomOffset: Int = 20,
    val stripSdh: Boolean = false,
    val useForcedSubtitles: Boolean = false,
    val showOnlyPreferredLanguages: Boolean = false,
) {
    companion object {
        val DEFAULT = SubtitleStyleState()
    }
}

data class SubtitleAudioUiState(
    val audioTracks: List<AudioTrack> = emptyList(),
    val subtitleTracks: List<SubtitleTrack> = emptyList(),
    val addonSubtitles: List<AddonSubtitle> = emptyList(),
    val isLoadingAddonSubtitles: Boolean = false,
    val addonSubtitleError: String? = null,
    val selectedAudioIndex: Int = -1,
    val selectedSubtitleIndex: Int = -1,
    val selectedAddonSubtitleId: String? = null,
    val useCustomSubtitles: Boolean = false,
    val subtitleStyle: SubtitleStyleState = SubtitleStyleState.DEFAULT,
    val showAudioModal: Boolean = false,
    val showSubtitleModal: Boolean = false,
)
