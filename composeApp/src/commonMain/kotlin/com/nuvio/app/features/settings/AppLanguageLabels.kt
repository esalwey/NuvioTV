package com.nuvio.app.features.settings

import nuvio.composeapp.generated.resources.Res
import nuvio.composeapp.generated.resources.lang_arabic
import nuvio.composeapp.generated.resources.lang_bulgarian
import nuvio.composeapp.generated.resources.lang_czech
import nuvio.composeapp.generated.resources.lang_english
import nuvio.composeapp.generated.resources.lang_french
import nuvio.composeapp.generated.resources.lang_german
import nuvio.composeapp.generated.resources.lang_greek
import nuvio.composeapp.generated.resources.lang_hebrew
import nuvio.composeapp.generated.resources.lang_hungarian
import nuvio.composeapp.generated.resources.lang_indonesian
import nuvio.composeapp.generated.resources.lang_italian
import nuvio.composeapp.generated.resources.lang_polish
import nuvio.composeapp.generated.resources.lang_portuguese_brazil
import nuvio.composeapp.generated.resources.lang_portuguese_portugal
import nuvio.composeapp.generated.resources.lang_romanian
import nuvio.composeapp.generated.resources.lang_slovak
import nuvio.composeapp.generated.resources.lang_spanish
import nuvio.composeapp.generated.resources.lang_turkish
import nuvio.composeapp.generated.resources.lang_norwegian
import nuvio.composeapp.generated.resources.lang_dutch
import nuvio.composeapp.generated.resources.lang_japanese
import nuvio.composeapp.generated.resources.lang_vietnamese
import nuvio.composeapp.generated.resources.settings_appearance_app_language_device
import org.jetbrains.compose.resources.StringResource

val AppLanguage.labelRes: StringResource
    get() = when (this) {
        AppLanguage.DEVICE -> Res.string.settings_appearance_app_language_device
        AppLanguage.ARABIC -> Res.string.lang_arabic
        AppLanguage.BULGARIAN -> Res.string.lang_bulgarian
        AppLanguage.CZECH -> Res.string.lang_czech
        AppLanguage.ENGLISH -> Res.string.lang_english
        AppLanguage.FRENCH -> Res.string.lang_french
        AppLanguage.GERMAN -> Res.string.lang_german
        AppLanguage.GREEK -> Res.string.lang_greek
        AppLanguage.HEBREW -> Res.string.lang_hebrew
        AppLanguage.HUNGARIAN -> Res.string.lang_hungarian
        AppLanguage.INDONESIAN -> Res.string.lang_indonesian
        AppLanguage.ITALIAN -> Res.string.lang_italian
        AppLanguage.POLISH -> Res.string.lang_polish
        AppLanguage.PORTUGUESE_BRAZIL -> Res.string.lang_portuguese_brazil
        AppLanguage.PORTUGUESE -> Res.string.lang_portuguese_portugal
        AppLanguage.ROMANIAN -> Res.string.lang_romanian
        AppLanguage.SLOVAK -> Res.string.lang_slovak
        AppLanguage.SPANISH -> Res.string.lang_spanish
        AppLanguage.TURKISH -> Res.string.lang_turkish
        AppLanguage.NORWEGIAN -> Res.string.lang_norwegian
        AppLanguage.DUTCH -> Res.string.lang_dutch
        AppLanguage.JAPANESE -> Res.string.lang_japanese
        AppLanguage.VIETNAMESE -> Res.string.lang_vietnamese
    }
