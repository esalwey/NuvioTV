#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IOS_PROJECT="$ROOT_DIR/iosApp/iosApp.xcodeproj"
TVOS_SCHEME="NuvioTV"
DERIVED_DATA="$ROOT_DIR/iosApp/build/tvos-ipa"
PRODUCTS_DIR="$DERIVED_DATA/Build/Products/Release-appletvos"
APP_NAME="NuvioTV.app"
IPA_NAME="NuvioTV.ipa"
GH_REPO="youngchris29-art/NuvioMobile"
MIRROR_REPO="youngchris29-art/NuvioTV"   # public-facing fork repo; its releases/latest is the published download link
MIRROR_DIR="$(cd "$ROOT_DIR/.." && pwd)"
VERSION_XCCONFIG="$ROOT_DIR/iosApp/Configuration/Version.xcconfig"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/release-beta.sh [options]

Builds an unsigned tvOS IPA of NuvioTV and publishes it as a GitHub
prerelease tagged tvos-v<version>-beta.<n> (n auto-increments) on BOTH
youngchris29-art/NuvioMobile and youngchris29-art/NuvioTV (the public
download link points at NuvioTV's releases/latest).

The release notes always include a "What's new" changelog: commit subjects
(first-parent, so an upstream catch-up merge shows as one line) since the
previous tvos-v* tag, plus a compare link. Pass --changelog to prepend
hand-written highlights above the generated list.

The generated list is sanitized for the public: internal tracker IDs
(BUG-xx/FEAT-xx/UX-x), Codex review rounds, wave/gate markers, and
process-only commits (docs/ci/tests/harness/diagnostics/release plumbing)
never appear in the published notes — testers only read what was added or
fixed. Check the sanitized output with --dry-run before publishing.

Before building, the script checks that the public repo's README.md (or
design/screenshots/) has been touched since the previous tvos-v* release —
every beta must update the README's feature list + screenshots for whatever
it ships. Update the README first, or pass --skip-readme-check for a
hotfix/rebuild that genuinely adds nothing user-facing.

Options:
  --tag <tag>          Use an explicit release tag instead of auto-incrementing
  --changelog <file>   Markdown file with hand-written highlights for the notes
  --reddit-changelog <file>
                       After publishing, swap the "Latest build" block in the
                       r/Nuvio beta thread's post body for this file's contents,
                       so the post always describes what releases/latest serves.
                       Shows a diff and asks before touching the live post; pass
                       --yes to skip the prompt. Needs REDDIT_CLIENT_ID and
                       REDDIT_REFRESH_TOKEN in the environment (plus
                       REDDIT_CLIENT_SECRET for a "web app"); get the token once
                       via scripts/update-reddit-beta-post.py --authorize.
                       Write this file by hand: it is public prose for testers,
                       not generated commit subjects.
  --reddit-post <id>   Override the post id (default: the beta thread)
  --yes                Do not prompt before editing the Reddit post
  --skip-build         Reuse the existing build products (repackage + publish only)
  --skip-readme-check  Allow releasing without a README update (hotfixes/rebuilds)
  --dry-run            Build and package, print the notes + what would be published, skip publish
  -h, --help           Show this help
EOF
}

TAG=""
SKIP_BUILD=0
SKIP_README_CHECK=0
DRY_RUN=0
CHANGELOG_FILE=""
REDDIT_CHANGELOG_FILE=""
REDDIT_POST_ID=""
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --changelog) CHANGELOG_FILE="$2"; shift 2 ;;
    --reddit-changelog) REDDIT_CHANGELOG_FILE="$2"; shift 2 ;;
    --reddit-post) REDDIT_POST_ID="$2"; shift 2 ;;
    --yes) ASSUME_YES=1; shift ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --skip-readme-check) SKIP_README_CHECK=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -n "$CHANGELOG_FILE" ]]; then
  if [[ ! -r "$CHANGELOG_FILE" ]]; then
    echo "error: changelog file not readable: $CHANGELOG_FILE" >&2
    exit 1
  fi
  # Resolve now — the script cd's to ROOT_DIR below, which would break a relative path.
  CHANGELOG_FILE="$(cd "$(dirname "$CHANGELOG_FILE")" && pwd)/$(basename "$CHANGELOG_FILE")"
fi

# Validate the Reddit step up front. It runs after publishing, and discovering a
# typo'd path or a missing credential at that point would leave the release out
# and the thread stale — the one state this is meant to prevent.
REDDIT_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/update-reddit-beta-post.py"
if [[ -n "$REDDIT_CHANGELOG_FILE" ]]; then
  if [[ ! -r "$REDDIT_CHANGELOG_FILE" ]]; then
    echo "error: reddit changelog file not readable: $REDDIT_CHANGELOG_FILE" >&2
    exit 1
  fi
  REDDIT_CHANGELOG_FILE="$(cd "$(dirname "$REDDIT_CHANGELOG_FILE")" && pwd)/$(basename "$REDDIT_CHANGELOG_FILE")"
  if [[ ! -x "$REDDIT_SCRIPT" ]]; then
    echo "error: $REDDIT_SCRIPT missing or not executable" >&2
    exit 1
  fi
  # REDDIT_CLIENT_SECRET is intentionally not required: an "installed app" is a
  # public client and has none. The refresh token is scoped to "read edit", so it
  # cannot post or touch the account even if it leaks.
  missing_reddit_env=()
  for v in REDDIT_CLIENT_ID REDDIT_REFRESH_TOKEN; do
    [[ -n "${!v:-}" ]] || missing_reddit_env+=("$v")
  done
  if [[ ${#missing_reddit_env[@]} -gt 0 ]]; then
    echo "error: --reddit-changelog needs these in the environment: ${missing_reddit_env[*]}" >&2
    echo "       One-time setup: create an app at https://www.reddit.com/prefs/apps as the" >&2
    echo "       post author, then run:" >&2
    echo "         $REDDIT_SCRIPT --authorize" >&2
    exit 1
  fi
  echo "==> Reddit post update armed ($(basename "$REDDIT_CHANGELOG_FILE"))"
fi

cd "$ROOT_DIR"

MARKETING_VERSION="$(sed -n 's/^MARKETING_VERSION=//p' "$VERSION_XCCONFIG" | tr -d '[:space:]')"
BUILD_NUMBER="$(sed -n 's/^CURRENT_PROJECT_VERSION=//p' "$VERSION_XCCONFIG" | tr -d '[:space:]')"
[[ -n "$MARKETING_VERSION" ]] || { echo "error: MARKETING_VERSION not found in $VERSION_XCCONFIG" >&2; exit 1; }

HEAD_SHA="$(git rev-parse HEAD)"
BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo detached)"

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "warning: working tree has uncommitted changes; the release tag will point at $HEAD_SHA which may not match what you build." >&2
fi

if ! git branch -r --contains "$HEAD_SHA" | grep -q 'origin/'; then
  echo "error: HEAD ($HEAD_SHA) is not pushed to origin — push first so the release tag has a valid target." >&2
  exit 1
fi

# gh release create --target rejects commit SHAs with HTTP 422 since ~2026-08-03
# (beta.10 hit it on both repos with pushed 40-char SHAs), so releases target
# branch names. The tag then lands on the branch's tip on GitHub — verify that
# tip is exactly the commit we're building, not merely an ancestor.
if [[ "$BRANCH" == "detached" ]]; then
  echo "error: HEAD is detached — releases target a branch name (GitHub 422s SHA targets). Check out a branch first." >&2
  exit 1
fi
REMOTE_TIP="$(git ls-remote origin "refs/heads/$BRANCH" | cut -f1)"
if [[ "$REMOTE_TIP" != "$HEAD_SHA" ]]; then
  echo "error: origin/$BRANCH is at ${REMOTE_TIP:-<missing>} but HEAD is $HEAD_SHA — the release tag targets the branch tip, so they must match. Push/sync first." >&2
  exit 1
fi

# The mirror release targets the outer NuvioTV checkout's HEAD; verify it is
# actually that repo (someone may have cloned NuvioMobile standalone).
MIRROR_SHA=""
MIRROR_BRANCH=""
if git -C "$MIRROR_DIR" remote get-url origin 2>/dev/null | grep -q "NuvioTV"; then
  MIRROR_SHA="$(git -C "$MIRROR_DIR" rev-parse HEAD)"
  if ! git -C "$MIRROR_DIR" branch -r --contains "$MIRROR_SHA" | grep -q 'origin/'; then
    echo "error: NuvioTV repo HEAD ($MIRROR_SHA) is not pushed to origin — push it first (the public download link lives on that repo)." >&2
    exit 1
  fi
  MIRROR_BRANCH="$(git -C "$MIRROR_DIR" symbolic-ref --short HEAD 2>/dev/null || echo detached)"
  if [[ "$MIRROR_BRANCH" == "detached" ]]; then
    echo "error: NuvioTV repo HEAD is detached — releases target a branch name (GitHub 422s SHA targets). Check out a branch in $MIRROR_DIR first." >&2
    exit 1
  fi
  MIRROR_TIP="$(git -C "$MIRROR_DIR" ls-remote origin "refs/heads/$MIRROR_BRANCH" | cut -f1)"
  if [[ "$MIRROR_TIP" != "$MIRROR_SHA" ]]; then
    echo "error: NuvioTV origin/$MIRROR_BRANCH is at ${MIRROR_TIP:-<missing>} but its HEAD is $MIRROR_SHA — the release tag targets the branch tip, so they must match. Push/sync first." >&2
    exit 1
  fi
else
  echo "warning: no NuvioTV checkout at $MIRROR_DIR — publishing to $GH_REPO only. The public releases/latest link on $MIRROR_REPO will go stale!" >&2
fi

latest_beta_n() { # latest_beta_n <repo> <prefix>
  gh release list --repo "$1" --limit 100 --json tagName -q '.[].tagName' \
    | { grep -F "$2" || true; } \
    | sed "s|^$2||" | sort -n | tail -1
}

if [[ -z "$TAG" ]]; then
  PREFIX="tvos-v${MARKETING_VERSION}-beta."
  LAST_N="$(latest_beta_n "$GH_REPO" "$PREFIX")"
  if [[ -n "$MIRROR_SHA" ]]; then
    MIRROR_LAST_N="$(latest_beta_n "$MIRROR_REPO" "$PREFIX")"
    [[ "${MIRROR_LAST_N:-0}" -gt "${LAST_N:-0}" ]] && LAST_N="$MIRROR_LAST_N"
  fi
  NEXT_N=$(( ${LAST_N:-0} + 1 ))
  TAG="${PREFIX}${NEXT_N}"
fi

echo "==> Release tag: $TAG (version $MARKETING_VERSION build $BUILD_NUMBER, commit ${HEAD_SHA:0:8} on $BRANCH)"

# The commit list is published to testers — strip the internal tracker/process
# vocabulary before it goes anywhere public. Two passes:
#   1) drop commits that are pure process (docs/ci/tests/harness/diagnostics/
#      release plumbing) — nothing user-facing to say about them;
#   2) scrub surviving subjects: BUG-xx/FEAT-xx/UX-x IDs, "round N" suffixes,
#      §-section refs, conventional-commit type prefixes, "Merge " lead-ins,
#      and parentheticals that reference internal process (Codex rounds, wave/
#      gate numbers, device-pass notes, upstream SHAs, test/harness ids).
# Best-effort by design: --changelog highlights remain the curated channel, and
# --dry-run shows exactly what would be published.
sanitize_changelog() {
  perl -CSD -ne '
    next if /^-\s*(?:docs?|ci|tests?|test\d+|chore|comms|readme|harness|diagnostics|release[ -]?notes?)\s*[:(]/i;
    next if /^-\s*beta\.[\d.]+\s*:\s*build\b/i;
    next if /^-\s*beta\.[\d.]+\s+batch\s+\d+\s*:/i;
    next if /^-\s*Merge (?:branch|remote-tracking)/;
    s/^(-\s*)Merge\s+/$1/;
    s/^(-\s*)(?:feat|fix|perf|refactor|style|l10n)(?:\([^)]*\))?!?:\s*/$1/i;
    s/\b(?:BUG|FEAT|UX)-\d+(?:\s*\/\s*(?:BUG|FEAT|UX)-\d+)*(?:\s+round\s+\S+)?\s*[:\x{2014}\x{2013}-]?\s*/ /gi;
    s/\x{00A7}\s*\d+\s*[:\x{2014}\x{2013}-]?\s*/ /g;
    s/\s*\((?=[^)]*(?:codex|wave\s*\d|gate\s*r?\d|harness|device[- ]pass|upstream|info-panel|test\s*\d|beta\.\d|\br\d+\b|W\d))[^)]*\)//gi;
    s/\s+into\s+beta[\w.\/-]*\s*$//i;
    s{/(?=\s)}{}g;
    s/^(-\s*)[\x{2014}\x{2013}:;,-]+\s*/$1/;
    s/\s{2,}/ /g;
    s/\s+$//;
    next if /^-?\s*$/;
    # ucfirst only all-lowercase first words (leave tvOS, ALL-CAPS, snake_case
    # identifiers alone). Copy $1 first: the inner match would clobber it.
    s/^- (\S+)/($w = $1) =~ m{[A-Z_]} ? "- $w" : "- " . ucfirst($w)/e;
    print "$_\n";
  '
}

# Changelog: commit subjects since the previous tvos-v* tag. --first-parent so an
# upstream catch-up merge collapses to its single merge-commit line instead of
# spraying hundreds of upstream subjects into the notes. gh-created tags only
# exist on GitHub until fetched.
git fetch --tags --quiet origin \
  || echo "warning: could not fetch tags from origin; changelog range may be stale." >&2
PREV_TAG="$(git tag --list 'tvos-v*' --sort=-v:refname | grep -Fxv "$TAG" | head -1)"
CHANGELOG_BODY=""
if [[ -n "$PREV_TAG" ]]; then
  RAW_CHANGELOG="$(git log --first-parent --pretty='- %s' "$PREV_TAG..$HEAD_SHA" \
    | grep -iv '^- bump version$' || true)"
  CHANGELOG_BODY="$(printf '%s\n' "$RAW_CHANGELOG" | sanitize_changelog || true)"
  if [[ -n "$RAW_CHANGELOG" && -z "$CHANGELOG_BODY" ]]; then
    # Every commit since the previous tag was internal-only. Saying "no code
    # changes" would be false — say what a tester needs to know instead.
    CHANGELOG_BODY="- Internal maintenance and stability work (no user-visible changes)."
  fi
  echo "==> Changelog: $(printf '%s\n' "$CHANGELOG_BODY" | grep -c '^- ' || true) public line(s) from $(printf '%s\n' "${RAW_CHANGELOG:-}" | grep -c '^- ' || true) commit(s) since $PREV_TAG"
else
  echo "==> Changelog: no previous tvos-v* tag found — treating as first beta of v${MARKETING_VERSION}"
fi

# Release step: every beta must refresh the public README's feature list and
# screenshots for whatever it ships. Enforced cheaply by timestamp — README.md or
# design/screenshots/ in the outer NuvioTV repo needs a commit newer than the
# previous tvos-v* release's tagged commit. Runs before the build so a miss fails
# in seconds, not after a 10-minute xcodebuild.
if [[ "$SKIP_README_CHECK" -eq 0 && -n "$PREV_TAG" && -n "$MIRROR_SHA" ]]; then
  PREV_TAG_TIME="$(git log -1 --format=%ct "$PREV_TAG" 2>/dev/null || echo 0)"
  README_TIME="$(git -C "$MIRROR_DIR" log -1 --format=%ct -- README.md design/screenshots 2>/dev/null || echo 0)"
  if [[ "${README_TIME:-0}" -le "${PREV_TAG_TIME:-0}" ]]; then
    echo "error: README.md / design/screenshots in $MIRROR_DIR have not been touched since $PREV_TAG." >&2
    echo "       Every beta updates the public README's feature list + screenshots before publishing." >&2
    echo "       Update and commit the README (and screenshots for new features), or pass" >&2
    echo "       --skip-readme-check for a hotfix/rebuild with nothing user-facing." >&2
    exit 1
  fi
  echo "==> README check: README/screenshots updated since $PREV_TAG"
fi

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  echo "==> Building $TVOS_SCHEME (Release, unsigned, tvOS device)"
  xcodebuild -project "$IOS_PROJECT" -scheme "$TVOS_SCHEME" -configuration Release \
    -destination "generic/platform=tvOS" -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
    NUVIO_BETA_TAG="$TAG" \
    | tail -5
else
  echo "==> Skipping build, reusing $PRODUCTS_DIR"
fi

[[ -d "$PRODUCTS_DIR/$APP_NAME" ]] || { echo "error: $PRODUCTS_DIR/$APP_NAME not found" >&2; exit 1; }

# Regression guard: the NuvioTV target used to hardcode its own
# MARKETING_VERSION/CURRENT_PROJECT_VERSION, silently overriding
# Version.xcconfig (FEAT-13). Verify the built product's Info.plist actually
# reflects Version.xcconfig before we ship it.
BUILT_PLIST="$PRODUCTS_DIR/$APP_NAME/Info.plist"
if [[ -f "$BUILT_PLIST" ]]; then
  BUILT_MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_PLIST" 2>/dev/null || echo "")"
  BUILT_BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT_PLIST" 2>/dev/null || echo "")"
  if [[ "$BUILT_MARKETING_VERSION" != "$MARKETING_VERSION" || "$BUILT_BUILD_NUMBER" != "$BUILD_NUMBER" ]]; then
    echo "error: pbxproj target-level version override is back (FEAT-13): product reports ${BUILT_MARKETING_VERSION} (${BUILT_BUILD_NUMBER}), Version.xcconfig says ${MARKETING_VERSION} (${BUILD_NUMBER})" >&2
    exit 1
  fi

  # Regression guard: the Stamp Build Metadata phase once ran before
  # ProcessInfoPlistFile in clean Release builds, which clobbered both keys
  # (beta.9's IPA had to be stamped by hand). The About pane must never ship
  # blank again: the stamped tag has to match the tag being published, and the
  # commit SHA has to be present.
  BUILT_BETA_TAG="$(/usr/libexec/PlistBuddy -c 'Print :NuvioBetaTag' "$BUILT_PLIST" 2>/dev/null || echo "")"
  BUILT_COMMIT_SHA="$(/usr/libexec/PlistBuddy -c 'Print :NuvioCommitSHA' "$BUILT_PLIST" 2>/dev/null || echo "")"
  if [[ "$BUILT_BETA_TAG" != "$TAG" ]]; then
    echo "error: stamp guard (FEAT-13): product's NuvioBetaTag is '${BUILT_BETA_TAG}', publishing as '${TAG}'." >&2
    echo "       The Stamp Build Metadata phase did not run (or ran before plist processing)," >&2
    echo "       or --skip-build is reusing a product stamped for a different tag. Rebuild." >&2
    exit 1
  fi
  if [[ -z "$BUILT_COMMIT_SHA" ]]; then
    echo "error: stamp guard (FEAT-13): product's NuvioCommitSHA is empty — the Stamp Build Metadata phase did not survive the build. Rebuild." >&2
    exit 1
  fi
  HEAD_SHA="$(git -C "$ROOT_DIR" rev-parse --short=8 HEAD 2>/dev/null || echo "")"
  if [[ "$SKIP_BUILD" -eq 0 && "$BUILT_COMMIT_SHA" != "$HEAD_SHA" ]]; then
    echo "error: stamp guard (FEAT-13): product's NuvioCommitSHA is ${BUILT_COMMIT_SHA} but HEAD is ${HEAD_SHA} — fresh build stamped a stale SHA." >&2
    exit 1
  elif [[ "$BUILT_COMMIT_SHA" != "$HEAD_SHA" ]]; then
    echo "warning: reused product was built at ${BUILT_COMMIT_SHA}; HEAD is now ${HEAD_SHA}." >&2
  fi
  echo "==> Stamp check: NuvioBetaTag=${BUILT_BETA_TAG} NuvioCommitSHA=${BUILT_COMMIT_SHA}"
else
  echo "error: $BUILT_PLIST not found; cannot verify version/stamp keys." >&2
  exit 1
fi

echo "==> Packaging $IPA_NAME"
cd "$PRODUCTS_DIR"
rm -rf Payload "$IPA_NAME"
mkdir Payload
cp -R "$APP_NAME" Payload/
# Free-Apple-ID re-signers (Sideloadly/atvloadly) mangle the appex signature —
# tvOS 27's code-signing monitor then kills it on launch (CODESIGNING Invalid Page).
rm -rf "Payload/$APP_NAME/PlugIns"
zip -qry "$IPA_NAME" Payload
rm -rf Payload
echo "    $(du -h "$IPA_NAME" | cut -f1 | tr -d ' ') $PRODUCTS_DIR/$IPA_NAME"

NOTES_FILE="$(mktemp)"
trap 'rm -f "$NOTES_FILE"' EXIT
cat > "$NOTES_FILE" <<EOF
# NuvioTV for Apple TV: Beta (v${MARKETING_VERSION})

Unsigned tvOS IPA for beta testing. This is a **fresh build**, with no account and no addons. Sign in with your own Nuvio account and install your own addons after installing.

## What's new in this build

EOF

# Hand-written highlights first (if provided), then the generated commit list.
# printf/cat, NOT an expanding heredoc: commit subjects and external markdown
# must never go through shell expansion.
if [[ -n "$CHANGELOG_FILE" ]]; then
  cat "$CHANGELOG_FILE" >> "$NOTES_FILE"
  printf '\n' >> "$NOTES_FILE"
fi
if [[ -n "$CHANGELOG_BODY" ]]; then
  printf '%s\n' "$CHANGELOG_BODY" >> "$NOTES_FILE"
  printf '\nFull diff: https://github.com/%s/compare/%s...%s\n' "$GH_REPO" "$PREV_TAG" "$TAG" >> "$NOTES_FILE"
elif [[ -z "$CHANGELOG_FILE" ]]; then
  if [[ -n "$PREV_TAG" ]]; then
    printf 'No code changes since %s (rebuild of the same code).\n' "$PREV_TAG" >> "$NOTES_FILE"
  else
    printf 'First beta build of v%s.\n' "$MARKETING_VERSION" >> "$NOTES_FILE"
  fi
fi

cat >> "$NOTES_FILE" <<EOF

## How to install (no paid Apple Developer account needed)

You sideload this yourself with a **free Apple ID**. The signature is created on your machine at install time.

### Option A: Sideloadly (Mac/Windows)
1. Download \`NuvioTV.ipa\` from the assets below.
2. Install [Sideloadly](https://sideloadly.io/).
3. Make sure your computer and Apple TV are on the same network. Pair the Apple TV if prompted (on the Apple TV: Settings → Remotes and Devices → Remote App and Devices shows the pairing code).
4. Select your Apple TV as the target device in Sideloadly, drag \`NuvioTV.ipa\` in, enter your Apple ID, and hit **Start**.

### Option B: atvloadly (self-hosted / Docker)
[atvloadly](https://github.com/bitxeno/atvloadly) is a web UI for sideloading to Apple TV over the network, with automatic re-signing.

### First launch
Trust the developer certificate on the Apple TV when prompted (Settings → General → Privacy & Security).

## Free Apple ID limits (normal, not bugs)
- The app signature expires after **7 days**, so just re-sideload (Sideloadly's background daemon or atvloadly can auto-refresh).
- Max **3 sideloaded apps** per free Apple ID at once.

## Build info
- Version ${MARKETING_VERSION} (build ${BUILD_NUMBER}), built from \`${HEAD_SHA:0:8}\` on \`${BRANCH}\`
- Includes MPV-based player (MPVKit). The Top Shelf extension is not bundled in the sideload IPA, because free-Apple-ID re-signing breaks extension signatures (crashes on tvOS 27), so it ships only in from-source builds.
EOF

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> Dry run: release notes that would be published:"
  sed 's/^/    /' "$NOTES_FILE"
  echo "==> Dry run: would publish $TAG to $GH_REPO targeting branch $BRANCH (tip $HEAD_SHA) with asset $PRODUCTS_DIR/$IPA_NAME"
  [[ -n "$MIRROR_SHA" ]] && echo "==> Dry run: would publish $TAG to $MIRROR_REPO targeting branch $MIRROR_BRANCH (tip $MIRROR_SHA)"
  if [[ -n "$REDDIT_CHANGELOG_FILE" ]]; then
    echo "==> Dry run: Reddit post diff that would be applied:"
    reddit_args=(--changelog "$REDDIT_CHANGELOG_FILE" --dry-run)
    [[ -n "$REDDIT_POST_ID" ]] && reddit_args+=(--post-id "$REDDIT_POST_ID")
    "$REDDIT_SCRIPT" "${reddit_args[@]}" || echo "==> Dry run: reddit preview failed (see above)"
  fi
  exit 0
fi

publish_release() { # publish_release <repo> <target_branch>
  echo "==> Publishing prerelease $TAG to $1 (target branch: $2)"
  gh release create "$TAG" \
    --repo "$1" \
    --target "$2" \
    --title "NuvioTV (Apple TV) v${MARKETING_VERSION} ${TAG##*-}" \
    --notes-file "$NOTES_FILE" \
    --prerelease \
    "$PRODUCTS_DIR/$IPA_NAME#NuvioTV.ipa (unsigned tvOS IPA)"

  # Move the repo's "Latest" pointer to this build.
  #
  # Every announcement links <repo>/releases/latest. While EVERY release was
  # flagged prerelease that link 302'd to the /releases list page and the API
  # endpoint 404'd, because GitHub never treats a prerelease as Latest — found
  # and fixed by hand on 2026-08-22 (beta.14.5), see docs/beta-feedback-*.
  #
  # GitHub will not let a release be both prerelease and Latest, so promoting
  # necessarily drops this build's prerelease badge. The badge stays on every
  # OLDER release, which is the point: the newest beta is the one testers are
  # meant to land on, and the rest stay visibly archival. Done as an explicit
  # post-publish flip rather than by omitting --prerelease above so the pointer
  # is SET, not inferred from publish order — re-runs and the mirror repo would
  # otherwise be at the mercy of GitHub's implicit "newest non-prerelease wins".
  echo "==> Marking $TAG as Latest on $1 (drops its prerelease badge; older releases keep theirs)"
  gh release edit "$TAG" --repo "$1" --prerelease=false --latest
}

publish_release "$GH_REPO" "$BRANCH"
if [[ -n "$MIRROR_SHA" ]]; then
  publish_release "$MIRROR_REPO" "$MIRROR_BRANCH"
fi

# Post-publish: point the beta thread at the build that is now live. Deliberately
# last — the release is the thing that matters, and a Reddit failure here must not
# fail the release that already succeeded. It exits non-zero on its own if the post
# is not in the shape it knows how to edit, rather than mangling it.
if [[ -n "$REDDIT_CHANGELOG_FILE" ]]; then
  echo "==> Updating the r/Nuvio beta thread's post body"
  reddit_args=(--changelog "$REDDIT_CHANGELOG_FILE")
  [[ -n "$REDDIT_POST_ID" ]] && reddit_args+=(--post-id "$REDDIT_POST_ID")
  [[ "$ASSUME_YES" -eq 1 ]] && reddit_args+=(--yes)
  if ! "$REDDIT_SCRIPT" "${reddit_args[@]}"; then
    echo "warning: $TAG published successfully, but the Reddit post was NOT updated." >&2
    echo "         Re-run just that step once fixed:" >&2
    echo "         $REDDIT_SCRIPT --changelog $REDDIT_CHANGELOG_FILE" >&2
  fi
fi
