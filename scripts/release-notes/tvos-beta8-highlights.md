**The native redesign beta.** This one touches nearly every screen — and closes out the whole beta.7 feedback batch.

- **A full native-tvOS design pass.** Liquid Glass surfaces, real system focus everywhere (posters now track your thumb on the Siri Remote touch surface — u/mrStevenx3, this is the swipe-reactive effect you described back on beta.6), and Settings reorganized into proper panes.
- **New: Nuvio-Style Hero** (opt-in — Settings → Home Screen → *Nuvio-Style Hero*): title and description on the left, artwork blending in from the right, just like Nuvio's modern home screen. Requested twice, so here it is. The hero also gained a **Go to Movie / Go to Show** button — the title itself is no longer the focus target.
- **Trailer fixes across the board:**
  - The full-screen trailer **no longer black-screens with Match Content Frame Rate enabled** — the app simply doesn't request a display-mode switch for short clips anymore, so no Apple TV settings change needed.
  - Trailers now play **up to 1080p** (previously they were quietly capped much lower).
  - The **detail-page background trailer has its own toggle** now (Settings → Appearance), separate from auto-play.
  - Trailers on Focus: the poster now **keeps its height and just widens** into the playing card, so the row doesn't shrink around it.
- **Collections with focus GIFs scroll smoothly** — GIF frames are decoded off the main thread and downsampled to tile size.
- **Sharing an account with Nuvio on another TV?** NuvioTV now keeps its synced settings in its own slot, so the two apps can no longer flip each other's options back and forth on every launch. Your settings migrate over automatically.
- **Stream picker:** focus a source row and it expands to show the **full release name**, however long.
- **The screensaver can no longer kick in mid-movie.**

Thanks to u/mrStevenx3 for the detailed beta.7 review that drove most of this list, and again to u/Overall_Stuff5982 — whose crash reports cracked the big profile crash fixed in beta.7, now confirmed fixed on their setup.
