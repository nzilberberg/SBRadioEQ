#!/bin/sh
# SBRadioEQ -- build a release archive and the repository XML for the Radio's
# Applet Installer.
#
#   sh tools/package.sh 0.1.0
#
# Produces in dist/:
#   SBRadioEQ-<version>.zip   the applet, files at the ZIP ROOT (no directory)
#   repo.xml                  repository descriptor with the archive's SHA-1
#   SHA256SUMS                for anyone who wants to verify by hand
#
# WHY THE HASHES MATTER. Jive loads applet code into its shared global
# environment; the framework has no sandbox and marks only where one would go.
# An installed applet is trusted code running as root on the device. LMS's
# repository format carries a SHA-1 for the archive, so that is the integrity
# check the installer actually performs -- it must be correct and the archive it
# describes must be immutable. A SHA-256 is published alongside because SHA-1
# alone is not a defence anyone should rely on in 2026; LMS simply requires it.
#
# Serve both files over HTTPS. A plain-HTTP repository lets anything on the path
# substitute the archive, and the SHA-1 in the descriptor is no help when the
# descriptor came down the same wire.

set -e

VERSION="${1:?usage: sh tools/package.sh <version>   e.g. 0.1.0}"
# The old `case` glob was [0-9]*.[0-9]*.[0-9]*, where `*` matches anything: it
# admits 1.2.3.4.5 and 1.2.3junk. The version ends up in a filename, a git tag and
# a URL, so it is worth pinning to the shape actually intended -- three numeric
# fields, with an optional pre-release/build suffix.
echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$' || {
	echo "FAIL: version must look like 1.2.3 (optionally 1.2.3-rc1)"
	exit 1
}

HERE=$(cd "$(dirname "$0")/.." && pwd)
DIST="$HERE/dist"
STAGE="$DIST/stage"
ZIPNAME="SBRadioEQ-$VERSION.zip"

# ---- what ships ----------------------------------------------------------
# Runtime only. The tests and the diag_* scripts are how this was built, not
# what users run; shipping them puts development code on the device and makes
# the archive bigger for no benefit.
RUNTIME="
applet/SBRadioEQApplet.lua
applet/SBRadioEQMeta.lua
applet/strings.txt
lua/eqdesign.lua
lua/eqapply.lua
lua/uistate.lua
"

rm -rf "$DIST"
mkdir -p "$STAGE"

# FLAT. The Applet Installer expects the applet's files at the archive root, not
# nested in a directory.
for f in $RUNTIME; do
	[ -f "$HERE/$f" ] || { echo "FAIL: missing $f"; exit 1; }
	cp "$HERE/$f" "$STAGE/$(basename "$f")"
done

# ---- the version must match what the applet reports ----------------------
# A user reporting a bug quotes the build number on screen. If the archive's
# version and that number cannot be related, the report is unusable.
BUILD=$(grep -oE '^local BUILD = [0-9]+' "$HERE/applet/SBRadioEQApplet.lua" | grep -oE '[0-9]+')
[ -n "$BUILD" ] || { echo "FAIL: cannot read BUILD from the applet"; exit 1; }

# ---- archive -------------------------------------------------------------
# No `zip` on this machine, so PowerShell's Compress-Archive does it. -DestinationPath
# with a directory/* source puts the files at the root, which is what is wanted.
if command -v zip >/dev/null 2>&1; then
	( cd "$STAGE" && zip -q -X "../$ZIPNAME" ./* )
elif command -v powershell.exe >/dev/null 2>&1; then
	WSTAGE=$(cygpath -w "$STAGE" 2>/dev/null || echo "$STAGE")
	WZIP=$(cygpath -w "$DIST/$ZIPNAME" 2>/dev/null || echo "$DIST/$ZIPNAME")
	powershell.exe -NoProfile -Command \
		"Compress-Archive -Path '$WSTAGE\\*' -DestinationPath '$WZIP' -Force" >/dev/null
else
	echo "FAIL: no zip and no powershell.exe -- cannot build the archive"
	exit 1
fi
[ -f "$DIST/$ZIPNAME" ] || { echo "FAIL: archive was not created"; exit 1; }

# ---- verify the archive is FLAT and complete -----------------------------
# A nested directory makes the Applet Installer silently install nothing useful,
# and that is not visible until a user tries it.
#
# ⛔ THE LISTING TOOL IS CHOSEN BY WHAT EXISTS. This block used to call
# powershell.exe and cygpath unconditionally, while the archive STEP above already
# preferred `zip`. On Linux or macOS the archive therefore built and the
# verification then died -- and it died reporting "<file> is not at the archive
# root", because the missing tool produced an empty listing and every lookup in it
# failed. A portability bug wearing a corrupt-archive error message sends whoever
# hits it to inspect a perfectly good zip.
if command -v zipinfo >/dev/null 2>&1; then
	listing=$(zipinfo -1 "$DIST/$ZIPNAME")
elif command -v unzip >/dev/null 2>&1; then
	listing=$(unzip -Z1 "$DIST/$ZIPNAME")
elif command -v powershell.exe >/dev/null 2>&1; then
	listing=$(powershell.exe -NoProfile -Command \
		"Add-Type -A System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::OpenRead('$(cygpath -w "$DIST/$ZIPNAME")').Entries | ForEach-Object { \$_.FullName }" \
		| tr -d '\r')
else
	echo "FAIL: no zipinfo, unzip or powershell.exe -- cannot verify the archive"
	exit 2
fi
# An empty listing must never read as "nothing wrong". Exit 2, not 1: the gate
# could not run, which is a different fact from the archive being bad.
[ -n "$listing" ] || { echo "FAIL: archive listing came back empty"; exit 2; }
for f in $RUNTIME; do
	b=$(basename "$f")
	echo "$listing" | grep -qx "$b" || { echo "FAIL: $b is not at the archive root"; exit 1; }
done
nested=$(echo "$listing" | grep '/' || true)
[ -z "$nested" ] || { echo "FAIL: archive contains directories: $nested"; exit 1; }

SHA1=$(sha1sum "$DIST/$ZIPNAME" | cut -d' ' -f1)
SHA256=$(sha256sum "$DIST/$ZIPNAME" | cut -d' ' -f1)

# ---- where the archive will live -----------------------------------------
#
# Derived from the git remote, not typed in: a placeholder that has to be edited
# by hand before the descriptor works is a step that gets forgotten, and the
# failure is silent -- LMS just cannot fetch it.
#
# GitHub serves release assets over HTTPS, and a tagged release asset is
# immutable, which is what the SHA-1 below depends on. Override with BASE_URL if
# hosting elsewhere; it must be https.
origin=$(git -C "$HERE" remote get-url origin 2>/dev/null || echo "")
slug=$(echo "$origin" | sed -e 's#^git@github.com:#https://github.com/#' \
                            -e 's#\.git$##')

if [ -z "$BASE_URL" ]; then
	[ -n "$slug" ] || { echo "FAIL: no git remote and no BASE_URL set"; exit 1; }
	BASE_URL="$slug/releases/download/v$VERSION"
fi
case "$BASE_URL" in
	https://*) ;;
	*) echo "FAIL: BASE_URL must be https -- a plain-HTTP repository lets anything"
	   echo "      on the path swap the archive, and the SHA-1 in the descriptor is"
	   echo "      no defence when the descriptor came down the same wire."
	   exit 1 ;;
esac

# ---- repository descriptor ----------------------------------------------
# target="baby" -- the coefficient controls exist on the Radio's AIC3104 and
# nowhere else, so this must not offer itself to a Touch or Controller.
#
# minTarget/maxTarget are deliberately ABSENT. They are a claim about which
# firmware versions were tested, and none have been beyond the author's own.
# Asserting a range that was never checked is worse than leaving it open.
cat > "$DIST/repo.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<extensions>
  <applets>
    <applet name="SBRadioEQ" version="$VERSION" target="baby">
      <title lang="EN">Equalizer</title>
      <desc lang="EN">Two-band parametric EQ using the Radio's AIC3104 hardware effects filter. Adjusted with the knob; no CPU cost and no server required.</desc>
      <creator>nzilberberg</creator>
      <email>nzilberberg@gmail.com</email>
      <url>$BASE_URL/$ZIPNAME</url>
      <sha>$SHA1</sha>
    </applet>
  </applets>
</extensions>
XML

printf '%s  %s\n' "$SHA256" "$ZIPNAME" > "$DIST/SHA256SUMS"
rm -rf "$STAGE"

#[[ ---- the STABLE catalog ---------------------------------------------------
#
# ⛔ THE ARCHIVE IS IMMUTABLE; THE CATALOG MUST NOT BE.
#
# Up to and including v0.2.0 the URL handed to users was
# .../releases/download/v0.2.0/repo.xml -- a descriptor living inside a specific
# release. A GitHub release asset is immutable, which is exactly right for the
# ZIP and exactly wrong for the catalog: every user who pasted that URL into LMS
# is polling a file that can never mention a later version. Publishing v0.2.1
# would reach nobody, and nothing would look broken at either end.
#
# So the same descriptor is also written to docs/repo.xml, which GitHub Pages
# serves from a STABLE address. The <url> inside it still points at the versioned,
# immutable release asset -- only the catalog moves.
#]]
# The catalog copy is written UNCONDITIONALLY. Making it depend on being able to
# guess the Pages URL would mean that anyone overriding BASE_URL to self-host
# silently got no catalog at all -- the release would look complete and no
# installed user would ever be offered it.
mkdir -p "$HERE/docs"
cp "$DIST/repo.xml" "$HERE/docs/repo.xml"

if [ -n "$slug" ]; then
	owner=$(echo "$slug" | sed -e 's#^https://github.com/##' -e 's#/.*##')
	name=$(basename "$slug")
	STABLE_URL="${STABLE_URL:-https://$owner.github.io/$name/repo.xml}"
fi

echo "built dist/$ZIPNAME"
echo "  applet build number : b$BUILD"
echo "  files at root       : $(echo $RUNTIME | wc -w)"
echo "  sha1   (repo.xml)   : $SHA1"
echo "  sha256 (published)  : $SHA256"
echo "  archive url         : $BASE_URL/$ZIPNAME"
echo ""
echo "publish with:"
echo "  gh release create v$VERSION dist/$ZIPNAME dist/repo.xml dist/SHA256SUMS \\"
echo "     --title \"SBRadioEQ $VERSION\" --notes-file <notes>"
echo ""
echo "then COMMIT docs/repo.xml -- that is the catalog users actually poll:"
echo "  git add docs/repo.xml && git commit -m \"Catalog: $VERSION\" && git push"
echo ""
if [ -n "$STABLE_URL" ]; then
	echo "the URL to give users (LMS > Settings > Plugins > Additional Repositories):"
	echo "  $STABLE_URL"
	echo ""
	echo "  (requires GitHub Pages serving /docs on the default branch -- one-time"
	echo "   repository setting, without it this URL 404s)"
fi
