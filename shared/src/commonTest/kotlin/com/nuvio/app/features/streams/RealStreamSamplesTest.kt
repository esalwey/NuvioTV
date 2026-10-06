package com.nuvio.app.features.streams

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * Regression net over ~400 real add-on stream texts with hand-checked language labels
 * ([RealStreamSamples]). Every labeled sample must parse to exactly its audio and subtitle tags,
 * except the few documented in [KNOWN_MISSES].
 */
class RealStreamSamplesTest {

    private val spanishTags = setOf("ES", "CAST", "LAT")

    private fun labelSet(label: String): Set<String> = label.split(' ').filter { it.isNotBlank() }.toSet()

    /** "ES*" in a label accepts any one Spanish tag: collapse Spanish tags on both sides. */
    private fun normalize(predicted: Set<String>, expected: Set<String>): Pair<Set<String>, Set<String>> {
        if ("ES*" !in expected) return predicted to expected
        val collapsed = predicted.filterNot { it in spanishTags }.toSet() +
            (if (predicted.any { it in spanishTags }) setOf("ES*") else emptySet())
        return collapsed to expected
    }

    private fun parse(sample: RealStreamSample): StreamInsight = StreamInsightParser.parse(
        StreamInsightInput(
            name = sample.name,
            title = sample.title,
            description = sample.description,
            filename = sample.filename,
        ),
    )

    @Test
    fun everyLabeledSampleParsesToItsLabels() {
        val labeled = RealStreamSamples.all.filter { it.audio != "SKIP" }
        assertTrue(labeled.size >= 380, "fixture shrank: ${labeled.size}")
        val failures = mutableListOf<String>()
        var exact = 0
        for (sample in labeled) {
            val insight = parse(sample)
            val (audio, expectedAudio) = normalize(insight.audioLanguages.map { it.tag }.toSet(), labelSet(sample.audio))
            val (subs, expectedSubs) = normalize(insight.subtitleLanguages.map { it.tag }.toSet(), labelSet(sample.subs))
            val matches = audio == expectedAudio && subs == expectedSubs
            if (matches) exact++
            if (matches == (sample.id in KNOWN_MISSES)) {
                failures += "${sample.id} [${sample.source}] audio=$audio want=$expectedAudio subs=$subs want=$expectedSubs" +
                    (if (matches) " (known miss now passes: remove it from KNOWN_MISSES)" else "")
            }
        }
        assertTrue(failures.isEmpty(), "exact=$exact/${labeled.size}\n" + failures.joinToString("\n"))
        assertEquals(labeled.size - KNOWN_MISSES.size, exact)
    }

    private companion object {
        /**
         * S031: languages written in Devanagari / Thai / Vietnamese script are not read.
         * S258, S263: Brazilian "[DUAL]" Spanish series — Torrentio's 🇬🇧 is noise, kept as audio.
         * S324: Torrentio cut the title ("… URBiN4HD Eng S"), so "Eng" reads as an audio track.
         */
        val KNOWN_MISSES = setOf("S031", "S258", "S263", "S324")
    }
}
