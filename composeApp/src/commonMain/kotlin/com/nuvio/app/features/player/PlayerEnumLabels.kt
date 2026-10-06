package com.nuvio.app.features.player

import androidx.compose.runtime.Composable
import nuvio.composeapp.generated.resources.Res
import nuvio.composeapp.generated.resources.player_ios_hardware_decoder_off
import nuvio.composeapp.generated.resources.player_ios_preset_compatibility_desc
import nuvio.composeapp.generated.resources.player_ios_preset_compatibility_label
import nuvio.composeapp.generated.resources.player_ios_preset_custom_desc
import nuvio.composeapp.generated.resources.player_ios_preset_custom_label
import nuvio.composeapp.generated.resources.player_ios_preset_native_edr_desc
import nuvio.composeapp.generated.resources.player_ios_preset_native_edr_label
import nuvio.composeapp.generated.resources.player_ios_preset_sdr_tone_mapped_desc
import nuvio.composeapp.generated.resources.player_ios_preset_sdr_tone_mapped_label
import org.jetbrains.compose.resources.stringResource

@Composable
fun IosVideoOutputPreset.localizedLabel(): String = when (this) {
    IosVideoOutputPreset.NativeEdr -> stringResource(Res.string.player_ios_preset_native_edr_label)
    IosVideoOutputPreset.SdrToneMapped -> stringResource(Res.string.player_ios_preset_sdr_tone_mapped_label)
    IosVideoOutputPreset.Compatibility -> stringResource(Res.string.player_ios_preset_compatibility_label)
    IosVideoOutputPreset.Custom -> stringResource(Res.string.player_ios_preset_custom_label)
}

@Composable
fun IosVideoOutputPreset.localizedDescription(): String = when (this) {
    IosVideoOutputPreset.NativeEdr -> stringResource(Res.string.player_ios_preset_native_edr_desc)
    IosVideoOutputPreset.SdrToneMapped -> stringResource(Res.string.player_ios_preset_sdr_tone_mapped_desc)
    IosVideoOutputPreset.Compatibility -> stringResource(Res.string.player_ios_preset_compatibility_desc)
    IosVideoOutputPreset.Custom -> stringResource(Res.string.player_ios_preset_custom_desc)
}

@Composable
fun IosHardwareDecoderMode.localizedLabel(): String = when (this) {
    IosHardwareDecoderMode.Off -> stringResource(Res.string.player_ios_hardware_decoder_off)
    else -> label
}
