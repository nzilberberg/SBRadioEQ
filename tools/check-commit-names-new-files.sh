#!/bin/sh
# GATE: a commit that ADDS a file must name that file in its message.
#
#   sh tools/check-commit-names-new-files.sh [<ref>]        (default HEAD)
#
# WHY THIS EXISTS
#
# On 2026-08-04 `git add -A` swept two new gate files and a bench change written
# by a PARALLEL SESSION into a commit whose message was entirely about a
# cancel-ordering fix. The history then attributed another session's work to this
# one, and the message described changes it never mentioned. Nothing about the
# commit looked wrong; you had to run `git show --stat` against a message that
# gave you no reason to.
#
# THE SIGNAL. A file appearing for the first time in a commit is a deliberate act
# -- if it was deliberate, the message says what it is. An ADDED file that the
# message never names is either a sweep, or a commit message that does not
# describe its own contents. Both are worth stopping.
#
# WHY "ADDED" AND NOT "MODIFIED". Requiring every MODIFIED path to be named would
# fire on almost every honest commit -- a refactor touching nine files does not
# list nine filenames, and nobody would keep a gate that demanded it. Added files
# are rare and individually meaningful, so the rule stays cheap to satisfy. The
# cost is the known hole: a parallel session's edit to an EXISTING file (the
# bench.sh change in that same incident) is invisible here. That residual is
# recorded rather than papered over.
#
# Exit 0 clean, 1 an added file is unnamed, 2 the gate could not run.

set -e

REF="${1:-HEAD}"

git rev-parse --git-dir >/dev/null 2>&1 || {
	echo "FAIL(2): not a git repository -- gate cannot run"
	exit 2
}
git rev-parse --verify --quiet "$REF" >/dev/null || {
	echo "FAIL(2): '$REF' is not a commit -- gate cannot run"
	exit 2
}

msg=$(git log -1 --format=%B "$REF")
[ -n "$msg" ] || { echo "FAIL(2): empty commit message for $REF"; exit 2; }

# --diff-filter=A -- files this commit introduces. --format= suppresses the
# header so only paths remain.
added=$(git show --diff-filter=A --name-only --format= "$REF" | sed '/^$/d')

if [ -z "$added" ]; then
	echo "check-commit-names-new-files: $REF adds no files -- nothing to check"
	exit 0
fi

missing=""
count=0
for f in $added; do
	count=$((count + 1))
	b=$(basename "$f")
	case "$msg" in
		*"$b"*) ;;
		*) missing="$missing $f" ;;
	esac
done

if [ -z "$missing" ]; then
	echo "check-commit-names-new-files: all $count added file(s) are named in the message"
	exit 0
fi

echo "check-commit-names-new-files: added but NOT named in the commit message:"
for f in $missing; do echo "    $f"; done
echo ""
# ⛔ SINGLE QUOTES. The first version of these lines wrote the offending command
# inside BACKTICKS for emphasis, in a double-quoted echo -- so running the gate
# executed `git add -A` against the repository being inspected. A read-only gate
# that mutates the index, performing the very operation it exists to warn about.
# Caught because the message printed with a blank where the command should have
# been, and `git status` then showed two freshly staged files.
# Same family as the commit-message backtick trap already recorded in the
# project's GitHub notes: backticks are substitution, not emphasis.
echo 'A file introduced by a commit whose message never mentions it is the'
echo 'signature of "git add -A" sweeping up work that was not part of this'
echo "change -- often a parallel session's. Either describe it, or stage"
echo 'explicit paths and leave it for its author to commit.'
exit 1
