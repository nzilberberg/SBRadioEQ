#!/bin/sh
# SBRadioEQ -- prove a release is internally consistent.
#
#   sh tools/verify-release.sh 0.1.0            # check the PUBLISHED release
#   sh tools/verify-release.sh 0.1.0 --local    # check dist/ before publishing
#
# ⛔ THE ARCHIVE IS NOT REPRODUCIBLE. Compress-Archive (and zip) embed
# timestamps, so rebuilding the same source produces a DIFFERENT file with a
# DIFFERENT hash. Observed during 0.1.0: two builds minutes apart gave
# 8442c6a1... and 5f0dc6e2...
#
# That makes one mistake very easy and completely silent: regenerate the zip,
# upload it, and leave repo.xml describing the previous build. LMS then refuses
# every install with a hash failure, and nothing in the repo looks wrong --
# repo.xml and the zip are each individually fine, they just describe different
# files.
#
# package.sh writes both together so following it is safe. This exists to prove
# it, against the bytes that are actually being served.

set -e

VERSION="${1:?usage: sh tools/verify-release.sh <version> [--local]}"
MODE="${2:-published}"

HERE=$(cd "$(dirname "$0")/.." && pwd)
ZIPNAME="SBRadioEQ-$VERSION.zip"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
ok()  { echo "  ok    $1"; }

# Same tool-availability rule as package.sh: GNU coreutils names first, then
# macOS `shasum`, then openssl. See the note there -- these two call sites were
# missed when the zip-listing portability was fixed in the same file.
digest() {                                   # $1 = 1|256, $2 = file
	if command -v "sha$1sum" >/dev/null 2>&1; then
		"sha$1sum" "$2" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a "$1" "$2" | cut -d' ' -f1
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst "-sha$1" "$2" | sed 's/.*= *//'
	fi
}

if [ "$MODE" = "--local" ]; then
	SRC="$HERE/dist"
	[ -f "$SRC/$ZIPNAME" ] || { echo "FAIL: no $SRC/$ZIPNAME -- run package.sh first"; exit 2; }
	cp "$SRC/$ZIPNAME" "$SRC/repo.xml" "$SRC/SHA256SUMS" "$TMP/" 2>/dev/null || true
	echo "checking LOCAL dist/ for $VERSION"
else
	BASE="https://github.com/nzilberberg/SBRadioEQ/releases/download/v$VERSION"
	echo "checking PUBLISHED release $VERSION"
	for f in "$ZIPNAME" repo.xml SHA256SUMS; do
		code=$(curl -sIL -o /dev/null -w '%{http_code}' "$BASE/$f")
		if [ "$code" != "200" ]; then
			bad "$f is not reachable over https (HTTP $code)"
		else
			curl -sL -o "$TMP/$f" "$BASE/$f"
			ok "$f served over https"
		fi
	done
	[ "$fail" -eq 0 ] || { echo ""; echo "verify-release: $fail problem(s)"; exit 1; }
fi

[ -f "$TMP/$ZIPNAME" ] || { echo "FAIL: archive missing"; exit 1; }
[ -f "$TMP/repo.xml" ] || { echo "FAIL: repo.xml missing"; exit 1; }

# --- the check that matters: does repo.xml describe THIS archive? ---------
ACTUAL=$(digest 1 "$TMP/$ZIPNAME")
CLAIMED=$(grep -o '<sha>[^<]*' "$TMP/repo.xml" | sed 's/<sha>//')

if [ -z "$CLAIMED" ]; then
	bad "repo.xml carries no <sha> -- the installer has nothing to verify against"
elif [ "$ACTUAL" != "$CLAIMED" ]; then
	bad "repo.xml describes a DIFFERENT build"
	echo "        archive : $ACTUAL"
	echo "        repo.xml: $CLAIMED"
	echo "        every install will fail its hash check"
else
	ok "repo.xml's SHA-1 matches the archive ($ACTUAL)"
fi

# --- the published SHA-256, if present ------------------------------------
if [ -f "$TMP/SHA256SUMS" ]; then
	want=$(cut -d' ' -f1 "$TMP/SHA256SUMS")
	got=$(digest 256 "$TMP/$ZIPNAME")
	if [ "$want" = "$got" ]; then ok "SHA256SUMS matches the archive"
	else bad "SHA256SUMS does not match the archive"; fi
fi

# --- the descriptor must point at https and at THIS version ---------------
url=$(grep -o '<url>[^<]*' "$TMP/repo.xml" | sed 's/<url>//')
case "$url" in
	https://*) ok "descriptor url is https" ;;
	*) bad "descriptor url is not https: $url" ;;
esac
case "$url" in
	*"$ZIPNAME") ok "descriptor points at $ZIPNAME" ;;
	*) bad "descriptor points at the wrong file: $url" ;;
esac
case "$url" in
	*REPLACE*) bad "descriptor still contains a placeholder url" ;;
	*) ;;
esac

# --- the archive must still be flat ---------------------------------------
#
# ⛔ THIS USED TO BE WRAPPED IN `if command -v powershell.exe`, SO ON ANY MACHINE
# WITHOUT POWERSHELL BOTH CHECKS BELOW SILENTLY DID NOT RUN -- and the script
# still printed "<version> is consistent". A skipped check that reports success is
# worse than a missing check, because the summary line is what anyone reads. The
# lister is now chosen from what exists, and its total absence is a FAILURE to
# verify, not a pass. (Same block as package.sh's; keep the two in step.)
if command -v zipinfo >/dev/null 2>&1; then
	listing=$(zipinfo -1 "$TMP/$ZIPNAME")
elif command -v unzip >/dev/null 2>&1; then
	listing=$(unzip -Z1 "$TMP/$ZIPNAME")
elif command -v powershell.exe >/dev/null 2>&1; then
	listing=$(powershell.exe -NoProfile -Command \
		"Add-Type -A System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::OpenRead('$(cygpath -w "$TMP/$ZIPNAME")').Entries | ForEach-Object { \$_.FullName }" | tr -d '\r')
else
	listing=""
fi

if [ -z "$listing" ]; then
	bad "could not list the archive (no zipinfo, unzip or powershell.exe) -- flatness UNVERIFIED"
else
	if echo "$listing" | grep -q '/'; then
		bad "archive contains directories -- the Applet Installer will install nothing"
	else
		ok "archive is flat ($(echo "$listing" | grep -c .) files at root)"
	fi
	if echo "$listing" | grep -qE 'test_|diag_'; then
		bad "development scripts leaked into the release archive"
	else
		ok "no tests or diagnostics in the archive"
	fi
fi

# --- the STABLE catalog must advance ---------------------------------------
#
# The archive is immutable and the catalog is not; that is the whole point of
# docs/repo.xml. What can go wrong is publishing a release and forgetting to
# commit the catalog, which leaves every existing installation polling a
# descriptor that still names the PREVIOUS version -- silently, at both ends.
# The release looks published because the assets are there.
#
# ⛔ ANCHOR PRECISELY. This one-line extraction was wrong TWICE, and both times it
# returned a plausible-looking answer rather than an error:
#
#   version="[^"]*"     matches the XML DECLARATION first -- <?xml version="1.0">
#                       -- so every descriptor ever written reads as version 1.0.
#   <applet[^>]*>       matches the CONTAINER <applets> first, which carries no
#                       version at all, so head -1 yields an empty string and the
#                       release is reported stale against nothing.
#
# The space in `<applet ` is what separates the element from its container. Both
# faults were found by running the check, not by reading it. Same family as
# amixer's type line, whose `values=` is the value COUNT.
catalog_version() {
	grep -o '<applet [^>]*>' "$1" 2>/dev/null | head -1 \
		| grep -o 'version="[^"]*"' | head -1 | sed 's/version="//;s/"//' || true
}

STABLE_LOCAL="$HERE/docs/repo.xml"
if [ ! -f "$STABLE_LOCAL" ]; then
	bad "docs/repo.xml is missing -- installed users poll that file and would never see $VERSION"
else
	sv=$(catalog_version "$STABLE_LOCAL")
	if [ "$sv" = "$VERSION" ]; then
		ok "docs/repo.xml (the stable catalog) names $VERSION"
	else
		bad "docs/repo.xml still names $sv, not $VERSION -- commit the catalog or nobody is offered the update"
	fi
fi

if [ "$MODE" != "--local" ]; then
	SURL="${STABLE_URL:-https://nzilberberg.github.io/SBRadioEQ/repo.xml}"
	scode=$(curl -sIL -o /dev/null -w '%{http_code}' "$SURL" || echo 000)
	if [ "$scode" != "200" ]; then
		bad "the stable catalog $SURL is not reachable (HTTP $scode) -- is GitHub Pages enabled?"
	else
		curl -sL -o "$TMP/stable.xml" "$SURL"
		psv=$(catalog_version "$TMP/stable.xml")
		if [ "$psv" = "$VERSION" ]; then
			ok "the SERVED stable catalog offers $VERSION"
		else
			bad "the served stable catalog offers $psv, not $VERSION -- existing installs will not see the update"
		fi
	fi
fi

echo ""
if [ "$fail" -gt 0 ]; then
	echo "verify-release: $fail problem(s)"
	exit 1
fi
echo "verify-release: $VERSION is consistent"
