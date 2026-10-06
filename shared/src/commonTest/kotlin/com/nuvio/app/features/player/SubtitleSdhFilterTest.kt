package com.nuvio.app.features.player

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

/**
 * SDH stripping (upstream PR #1751): bracketed sound cues, parentheticals, and speaker
 * labels are removed from subtitle text; a cue that ends up empty is dropped entirely
 * (filter returns null so the caller can skip the cue).
 */
class SubtitleSdhFilterTest {

    @Test
    fun stripsBracketedSoundCues() {
        assertEquals("Hello there.", SubtitleSdhFilter.filter("[MUSIC PLAYING] Hello there."))
        // The regex consumes whitespace after the cue, not before it, so mid-line
        // cues collapse cleanly while an end-of-line cue leaves the preceding space.
        assertEquals("Hello there everyone.", SubtitleSdhFilter.filter("Hello there [DOOR SLAMS] everyone."))
        assertEquals("Hello there. ", SubtitleSdhFilter.filter("Hello there. [DOOR SLAMS]"))
    }

    @Test
    fun stripsParentheticals() {
        assertEquals("That was great.", SubtitleSdhFilter.filter("(laughs) That was great."))
        assertEquals("I knew it all along.", SubtitleSdhFilter.filter("I knew it (sighs heavily) all along."))
    }

    @Test
    fun stripsSpeakerLabels() {
        assertEquals("Where were you last night?", SubtitleSdhFilter.filter("JOHN: Where were you last night?"))
        // A dash before the label survives (dialogue dash), the label itself goes.
        assertEquals("- Where?\n- Over there.", SubtitleSdhFilter.filter("- JOHN: Where?\n- MARY: Over there."))
    }

    @Test
    fun plainDialoguePassesThroughUnchanged() {
        assertEquals("Just a normal line of dialogue.", SubtitleSdhFilter.filter("Just a normal line of dialogue."))
        assertEquals("First line\nSecond line", SubtitleSdhFilter.filter("First line\nSecond line"))
    }

    @Test
    fun cueThatBecomesEmptyReturnsNull() {
        assertNull(SubtitleSdhFilter.filter("[THUNDER RUMBLING]"))
        assertNull(SubtitleSdhFilter.filter("(dramatic music)"))
        // A line left with only whitespace/dashes is dropped too.
        assertNull(SubtitleSdhFilter.filter("- [GUNSHOT]\n- (screams)"))
    }

    @Test
    fun keepsDialogueLinesWhileDroppingCueOnlyLines() {
        assertEquals("Run!", SubtitleSdhFilter.filter("[EXPLOSION]\nRun!"))
    }

    /// PINS a KNOWN UPSTREAM BEHAVIOR, deliberately kept for parity (Codex 2026-08-20 round 1
    /// flagged it): the speaker-label regex treats ANY line-leading text before a colon as a
    /// label, so ordinary colon-bearing dialogue loses its prefix when SDH stripping is on.
    /// Upstream ships exactly this to all mobile users, the toggle is opt-in and default-OFF,
    /// and this filter only runs on the Android cue path in this fork (tvOS uses libmpv's own
    /// sub-filter-sdh). If upstream ever tightens the regex, port their change and update this
    /// test — do not diverge unilaterally.
    @Test
    fun colonPrefixedDialogueLosesItsPrefixKnownUpstreamBehavior() {
        assertEquals("8:30", SubtitleSdhFilter.filter("Time: 8:30"))
        assertEquals("the story continues", SubtitleSdhFilter.filter("Previously on: the story continues"))
    }
}
