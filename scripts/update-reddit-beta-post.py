#!/usr/bin/env python3
"""Update the "Latest build" changelog block in the r/Nuvio beta thread's post body.

The beta thread (https://www.reddit.com/r/Nuvio/comments/1v26ebw/) carries a
"Latest build: beta N (build M)" section right under the download link, so the
post body always describes what releases/latest actually serves. This script
swaps that block for a new one at release time.

It deliberately does NOT write the changelog for you. The Reddit changelog is
hand-written prose with its own constraints (no em dashes, straight quotes, and
wording that avoids the Automod rules that have tripped this sub before); text
generated from commit subjects would read badly and risk removal. Pass a file
you wrote, the same way scripts/release-beta.sh takes --changelog.

Auth is a refresh token, not the account password. The token is scoped to
"read edit" (fetch the post, edit own posts) and nothing else, so a leak cannot
post, delete, message, or touch the account. Credentials come from the
environment, never from the repo:

    REDDIT_CLIENT_ID, REDDIT_REFRESH_TOKEN, and REDDIT_CLIENT_SECRET
    (secret is required for a "web app", omitted for an "installed app")

One-time setup:
  1. https://www.reddit.com/prefs/apps as the post author -> create an app.
     "installed app" needs no secret; "web app" issues one. Set the redirect
     URI to anything you control, e.g. http://localhost:8080 (nothing has to
     listen there; you just copy the code out of the URL bar).
  2. export REDDIT_CLIENT_ID=... [REDDIT_CLIENT_SECRET=...]
  3. ./update-reddit-beta-post.py --authorize --redirect-uri http://localhost:8080
     Open the printed URL, approve, then paste the URL you land on. It prints a
     refresh token; export it as REDDIT_REFRESH_TOKEN. It does not expire, so
     this is done once.

Usage:
    update-reddit-beta-post.py --changelog notes.md [--post-id 1v26ebw]
                               [--dry-run] [--yes]
    update-reddit-beta-post.py --authorize [--redirect-uri URI]
    update-reddit-beta-post.py --self-test

    --dry-run    Fetch and show the diff, write nothing. Needs credentials
                 (Reddit returns 403 for unauthenticated reads).
    --yes        Skip the confirmation prompt. For non-interactive release runs.
    --authorize  One-time flow that turns an approval into a refresh token.
    --self-test  Run the block-replacement logic against fixtures and exit.
                 Needs no credentials and no network.
"""

from __future__ import annotations

import argparse
import difflib
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_POST_ID = "1v26ebw"
USER_AGENT = "nuviotv-release/1.0 (beta thread changelog updater)"

# The block runs from the "Latest build:" heading through the build-number line
# that closes it. Both anchors are part of the published format, so a post that
# has drifted from it fails loudly below rather than being silently mangled.
BLOCK_START = re.compile(r"^\*\*Latest build:.*$", re.MULTILINE)
BLOCK_END = re.compile(r"^Settings -> About should read.*$", re.MULTILINE)
# Where the block goes when the post does not have one yet. The live post writes
# this line bold ("**Download the beta IPA:** <url>"), so the leading asterisks
# are optional here rather than assumed away.
ANCHOR = re.compile(r"^\**Download the beta IPA:.*$", re.MULTILINE)


class BlockError(RuntimeError):
    """The post body is not in the shape this script knows how to edit."""


def replace_block(body: str, new_block: str) -> tuple[str, str]:
    """Return (new_body, action). Pure: no network, no globals. See --self-test.

    action is "replaced" when an existing block was swapped, "inserted" when the
    block was added after the download link for the first time.
    """
    new_block = new_block.strip()
    if not new_block:
        raise BlockError("changelog is empty")

    starts = list(BLOCK_START.finditer(body))
    if len(starts) > 1:
        raise BlockError(
            f"found {len(starts)} 'Latest build:' headings; expected at most 1. "
            "Fix the post by hand so there is exactly one."
        )

    if starts:
        start = starts[0]
        ends = [m for m in BLOCK_END.finditer(body) if m.start() > start.start()]
        if not ends:
            raise BlockError(
                "found a 'Latest build:' heading but no closing "
                "'Settings -> About should read ...' line after it"
            )
        end = ends[0]
        return body[: start.start()] + new_block + body[end.end() :], "replaced"

    anchors = list(ANCHOR.finditer(body))
    if len(anchors) != 1:
        raise BlockError(
            f"no existing block, and found {len(anchors)} 'Download the beta IPA:' "
            "lines to anchor to; expected exactly 1"
        )
    at = anchors[0].end()
    return body[:at] + "\n\n" + new_block + body[at:], "inserted"


def _api(method: str, url: str, token: str | None = None, data: dict | None = None,
         auth: tuple[str, str] | None = None) -> dict:
    body = urllib.parse.urlencode(data).encode() if data else None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("User-Agent", USER_AGENT)
    if token:
        req.add_header("Authorization", f"bearer {token}")
    if auth:
        import base64
        raw = base64.b64encode(f"{auth[0]}:{auth[1]}".encode()).decode()
        req.add_header("Authorization", f"Basic {raw}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")[:400]
        raise SystemExit(f"error: {method} {url} -> HTTP {exc.code}\n{detail}") from exc


# Only what the job needs: read the post, edit our own post. Not submit, not
# modify account settings, not send messages.
OAUTH_SCOPE = "read edit"


def _client() -> tuple[str, str]:
    """(client_id, client_secret). Secret is "" for an installed (public) app."""
    cid = os.environ.get("REDDIT_CLIENT_ID")
    if not cid:
        raise SystemExit(
            "error: REDDIT_CLIENT_ID is not set.\n"
            "       Create an app at https://www.reddit.com/prefs/apps as the post author,\n"
            "       then see --help for the one-time --authorize step."
        )
    return cid, os.environ.get("REDDIT_CLIENT_SECRET", "")


def get_token() -> str:
    cid, csec = _client()
    refresh = os.environ.get("REDDIT_REFRESH_TOKEN")
    if not refresh:
        raise SystemExit(
            "error: REDDIT_REFRESH_TOKEN is not set.\n"
            "       Run once:  ./update-reddit-beta-post.py --authorize\n"
            "       then export the token it prints. It does not expire."
        )
    out = _api("POST", "https://www.reddit.com/api/v1/access_token",
               auth=(cid, csec),
               data={"grant_type": "refresh_token", "refresh_token": refresh})
    if "access_token" not in out:
        raise SystemExit(f"error: no access_token in refresh response: {out}")
    return out["access_token"]


def authorize(redirect_uri: str) -> int:
    """One-time: turn a browser approval into a long-lived refresh token."""
    import secrets
    cid, csec = _client()
    state = secrets.token_urlsafe(16)
    url = "https://www.reddit.com/api/v1/authorize?" + urllib.parse.urlencode({
        "client_id": cid, "response_type": "code", "state": state,
        "redirect_uri": redirect_uri, "duration": "permanent",
        "scope": OAUTH_SCOPE,
    })
    print("1. Open this URL as the post author and approve:\n")
    print("   " + url + "\n")
    print(f"2. You will land on {redirect_uri}?... (nothing needs to be listening there).")
    try:
        pasted = input("   Paste that full URL, or just the code: ").strip()
    except EOFError:
        raise SystemExit("\nerror: --authorize needs a terminal to paste the code into") from None

    if "code=" in pasted:
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(pasted).query)
        if qs.get("error"):
            raise SystemExit(f"error: reddit returned {qs['error'][0]}")
        got_state = (qs.get("state") or [None])[0]
        if got_state and got_state != state:
            raise SystemExit("error: state mismatch, discarding (possible mix-up or tampering)")
        code = (qs.get("code") or [""])[0]
    else:
        code = pasted
    # Reddit appends #_ to the redirect fragment; strip anything trailing.
    code = code.split("#")[0].strip()
    if not code:
        raise SystemExit("error: no authorization code found in that input")

    out = _api("POST", "https://www.reddit.com/api/v1/access_token",
               auth=(cid, csec),
               data={"grant_type": "authorization_code", "code": code,
                     "redirect_uri": redirect_uri})
    token = out.get("refresh_token")
    if not token:
        raise SystemExit(
            f"error: no refresh_token in response: {out}\n"
            "       Make sure the authorize URL had duration=permanent and that the\n"
            "       redirect URI matches the app's exactly."
        )
    print("\n==> Add this to your shell profile (scope: " + OAUTH_SCOPE + "):\n")
    print(f'export REDDIT_REFRESH_TOKEN="{token}"\n')
    print("It does not expire. Treat it like a password: it can read and edit as you.")
    return 0


def fetch_post(token: str, post_id: str) -> dict:
    out = _api("GET", f"https://oauth.reddit.com/api/info?id=t3_{post_id}", token=token)
    children = out.get("data", {}).get("children", [])
    if not children:
        raise SystemExit(f"error: post t3_{post_id} not found (or not visible to this account)")
    return children[0]["data"]


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True, description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--changelog", help="file holding the new 'Latest build' block")
    ap.add_argument("--post-id", default=DEFAULT_POST_ID)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--yes", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--authorize", action="store_true",
                    help="one-time: exchange a browser approval for a refresh token")
    ap.add_argument("--redirect-uri", default="http://localhost:8080",
                    help="must match the app's redirect URI exactly (default: %(default)s)")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    if args.authorize:
        return authorize(args.redirect_uri)

    if not args.changelog:
        ap.error("--changelog is required (or use --self-test)")
    try:
        with open(args.changelog, encoding="utf-8") as fh:
            new_block = fh.read()
    except OSError as exc:
        raise SystemExit(f"error: cannot read changelog: {exc}") from exc

    token = get_token()
    post = fetch_post(token, args.post_id)
    old_body = post.get("selftext", "")
    print(f"==> post t3_{args.post_id} by u/{post.get('author')}: "
          f"{len(old_body)} chars")

    try:
        new_body, action = replace_block(old_body, new_block)
    except BlockError as exc:
        raise SystemExit(
            f"error: {exc}\n"
            "       Refusing to edit a post whose shape I do not recognise. "
            "Fix it by hand, then re-run."
        ) from exc

    if new_body == old_body:
        print("==> post body already matches this changelog, nothing to do")
        return 0

    diff = difflib.unified_diff(old_body.splitlines(), new_body.splitlines(),
                                fromfile="post (current)", tofile="post (new)",
                                lineterm="", n=2)
    print(f"==> block will be {action}\n")
    print("\n".join(diff))
    print(f"\n==> {len(old_body)} chars -> {len(new_body)} chars")

    if args.dry_run:
        print("==> dry run, post not modified")
        return 0

    if not args.yes:
        if not sys.stdin.isatty():
            raise SystemExit("error: refusing to edit a live post non-interactively "
                             "without --yes")
        if input("\nApply this edit to the live post? [y/N] ").strip().lower() != "y":
            print("==> aborted, post not modified")
            return 1

    out = _api("POST", "https://oauth.reddit.com/api/editusertext", token=token,
               data={"thing_id": f"t3_{args.post_id}", "text": new_body,
                     "api_type": "json"})
    errors = out.get("json", {}).get("errors") or []
    if errors:
        raise SystemExit(f"error: reddit rejected the edit: {errors}")
    print("==> post updated")
    return 0


def self_test() -> int:
    """Exercise replace_block without credentials or network."""
    # Mirrors the live post, which writes these two lines bold. An earlier version
    # of ANCHOR only matched the unbolded form and would have refused to insert.
    base = (
        "Hey everyone,\n\n"
        "**Repo:** https://example.invalid/repo\n"
        "**Download the beta IPA:** https://example.invalid/releases/latest\n\n"
        "So what does it do?\n\nStuff.\n"
    )
    base_plain = base.replace("**", "")
    block10 = ("**Latest build: beta 10 (build 106)**\n\nHero follows focus.\n\n"
               "Settings -> About should read 0.3.0 (106).")
    block11 = ("**Latest build: beta 11 (build 107)**\n\nSimkl.\n\n"
               "Settings -> About should read 0.3.0 (107).")
    failures = []

    def check(name, cond):
        print(("  ok   " if cond else "  FAIL ") + name)
        if not cond:
            failures.append(name)

    inserted, action = replace_block(base, block10)
    check("inserts when absent (bold anchor, as the live post writes it)",
          action == "inserted")
    check("inserts when absent (plain anchor)",
          replace_block(base_plain, block10)[1] == "inserted")
    check("insert lands after the download line",
          inserted.index("Latest build") > inserted.index("Download the beta IPA"))
    check("insert lands before the body", inserted.index("Latest build") < inserted.index("So what does it do?"))
    check("insert keeps intro", inserted.startswith("Hey everyone,"))
    check("insert keeps outro", inserted.rstrip().endswith("Stuff."))

    replaced, action = replace_block(inserted, block11)
    check("replaces when present", action == "replaced")
    check("old build gone", "build 106" not in replaced)
    check("new build present", "build 107" in replaced)
    check("exactly one heading", replaced.count("**Latest build:") == 1)
    check("replace keeps intro", replaced.startswith("Hey everyone,"))
    check("replace keeps outro", replaced.rstrip().endswith("Stuff."))
    check("replace is idempotent", replace_block(replaced, block11)[0] == replaced)
    check("no unbounded growth", len(replaced) - len(inserted) < 40)

    for name, body in (
        ("two headings rejected", inserted + "\n" + block10),
        ("heading without closer rejected", base + "\n**Latest build: beta 9 (build 105)**\n"),
        ("missing anchor rejected", "Hey everyone,\n\nNo download line here.\n"),
    ):
        try:
            replace_block(body, block11)
            check(name, False)
        except BlockError:
            check(name, True)

    try:
        replace_block(base, "   ")
        check("empty changelog rejected", False)
    except BlockError:
        check("empty changelog rejected", True)

    print(("\nself-test FAILED: " + ", ".join(failures)) if failures else "\nself-test passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
