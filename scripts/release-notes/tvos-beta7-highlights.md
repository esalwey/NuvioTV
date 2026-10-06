**The profile crash is fixed — for real this time.** Thanks to u/Overall_Stuff5982's crash report, the force-close on catalog/plugin-heavy profiles finally gave up its secret: the app was storing each profile's plugin state (including plugin code) in a system store that tvOS hard-caps at 4 MB — cross the cap and tvOS kills the app on the spot, which no amount of crash-guarding could catch. Plugin data now lives in regular files with no size limit, and existing installs migrate automatically. The Home screen also builds its rows lazily now and throttles artwork loading, so heavy accounts load lighter and smoother across the board.

**Trailers on Focus (opt-in).** Hold focus on a poster for a second and it morphs into a wide card with the trailer playing, right in the row — the Fusion-style behavior u/mrStevenx3 asked for. It's **off by default**: turn it on in **Settings → Home Screen → Trailers on Focus**. Play/pause toggles the sound while a trailer is playing.

**Detail pages play the trailer automatically** after a few seconds (with a "Press Back to exit" hint), and the poster now sits as a background layer on the right — the Nuvio-style layout from the same wishlist. Both have toggles in Settings if you'd rather keep things still.

**Pick your hero sources.** Settings → Home Screen now has a Show Hero toggle plus a picker for which catalogs feed the hero carousel (up to 2).

**Collections can animate.** Collection tiles with a focus GIF configured now play it when focused.

**The tab bar gets out of the way.** It slides away as you scroll down and comes back when you scroll up or move focus to the top.

**Stream picker: file names readable at last.** The detail line (size + release name) wraps up to three lines instead of cutting off a few characters in — the last open item from u/mrStevenx3's list.

**Note for sideloaders:** the IPA no longer bundles the Top Shelf extension. Free-Apple-ID re-signing breaks extension signatures (it was crashing silently on every install, and tvOS 27 enforces harder), so removing it makes installs cleaner — and the "App ID limit" workaround in Sideloadly is no longer needed. Top Shelf still works if you build from source with a paid team.

All new UI is localized in French, Spanish, German, and Italian.
