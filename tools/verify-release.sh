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
ACTUAL=$(sha1sum "$TMP/$ZIPNAME" | cut -d' ' -f1)
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
	got=$(sha256sum "$TMP/$ZIPNAME" | cut -d' ' -f1)
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
if command -v powershell.exe >/dev/null 2>&1; then
	listing=$(powershell.exe -NoProfile -Command \
		"Add-Type -A System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::OpenRead('$(cygpath -w "$TMP/$ZIPNAME")').Entries | ForEach-Object { \$_.FullName }" 2>/dev/null | tr -d '\r')
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

echo ""
if [ "$fail" -gt 0 ]; then
	echo "verify-release: $fail problem(s)"
	exit 1
fi
echo "verify-release: $VERSION is consistent"
