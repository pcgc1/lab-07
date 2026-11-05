#!/usr/bin/env bash
#
# validate.sh - tests a check.sh (and script.sh) for ILC 7
#
# Usage:  bash validate.sh [path-to-repo]       (default: current directory)
#
# Output: one "TestcaseN: PASS" line for every Testcase folder where all tests pass.
#         For a Testcase where something fails, only the failing tests are printed.
#
# For every Testcase folder it checks:
#   script.sh : TestcaseNDiff/ exists when the Testcase has differences (and not otherwise),
#               and the files inside have the correct `diff -u` output
#   check.sh  : exits 0 and prints "TestcaseN: PASS" on the correct output, and prints
#               "TestcaseN: FAIL" (exit non-zero) when, for that Testcase,
#                 - TestcaseNDiff/ is missing although it should exist
#                 - a file inside TestcaseNDiff/ has the wrong contents
#                 - an output file exists for a pair that is identical
#                 - TestcaseNDiff/ exists although nothing differs
#
# Only the given Testcase files are used; nothing is added except by editing/removing the
# output folders in a temp copy. The repo itself is never modified.
#
# Every failure message starts with the script it is about ("script.sh:" or "check.sh:").
# Either script can be tested before the other one exists (the missing one is reported).
#
# Exit status: 0 if every test passes, 1 otherwise, 2 on a setup problem.

set -u

REPO="$(cd "${1:-.}" 2>/dev/null && pwd)" || { echo "Usage: bash $0 [path-to-repo]"; exit 2; }
[ -f "$REPO/check.sh" ] || [ -f "$REPO/script.sh" ] || { echo "No check.sh or script.sh found in $REPO"; exit 2; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run() { if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"; else "$@"; fi; }

# ---- results are collected per Testcase (0 = general, not tied to one Testcase) ----
RES_N=(); RES_OK=(); RES_MSG=()
record() { RES_N+=("$1"); RES_OK+=("$2"); RES_MSG+=("$3"); }   # <testcase> <1|0> <message>

# Match files with the same name but different number endings.
pairs_for_dir() {   # <base> <dir>  ->  "key|fileA|fileB" (paths relative to base)
    local base=$1 dir=$2 f b key suf i n
    local keys=() files=() lines=""
    lines=$(
        cd "$base" || exit
        for f in "$dir"/*.txt; do
            [ -f "$f" ] || continue
            b=$(basename "$f" .txt)
            if [[ $b =~ ^(.*)\.([0-9]+)$ ]]; then key=${BASH_REMATCH[1]}; suf=${BASH_REMATCH[2]}
            else key=$b; suf=0; fi
            key=${key// /}
            printf '%s|%s|%s\n' "$key" "$suf" "$f"
        done | LC_ALL=C sort -V
    )
    [ -n "$lines" ] || return 0
    while IFS='|' read -r key suf f; do keys+=("$key"); files+=("$f"); done <<< "$lines"
    n=${#keys[@]}; i=0
    while [ "$i" -lt "$n" ]; do
        if [ $((i + 1)) -lt "$n" ] && [ "${keys[i]}" = "${keys[i + 1]}" ] \
           && { [ $((i + 2)) -ge "$n" ] || [ "${keys[i + 2]}" != "${keys[i]}" ]; }; then
            printf '%s|%s|%s\n' "${keys[i]}" "${files[i]}" "${files[i + 1]}"
            i=$((i + 2))
        else
            i=$((i + 1))
        fi
    done
}

testcase_dirs() {   # <base> -> Testcase1 Testcase2 ... (input folders only, sorted)
    local d
    for d in "$1"/Testcase*; do
        [ -d "$d" ] && [[ $(basename "$d") =~ ^Testcase[0-9]+$ ]] && basename "$d"
    done | LC_ALL=C sort -V
}

make_golden() {     # <base>  writes the correct TestcaseNDiff/ folders into <base>
    local base=$1 t n key a b
    for t in $(testcase_dirs "$base"); do
        n=${t#Testcase}
        rm -rf "${base:?}/Testcase${n}Diff"
        while IFS='|' read -r key a b; do
            [ -n "$key" ] || continue
            if ! cmp -s "$base/$a" "$base/$b"; then
                mkdir -p "$base/Testcase${n}Diff"
                (cd "$base" && diff -u "$a" "$b" > "Testcase${n}Diff/${key}Diff.txt")
            fi
        done < <(pairs_for_dir "$base" "$t")
    done
}

listing_tc() { (cd "$1" && find . -mindepth 1 -path "./Testcase$2Diff*" | LC_ALL=C sort); }

# Compare the generated files, ignoring the first two diff header lines.
same_output_tc() {  # <goodbase> <otherbase> <n>: same files/dirs and contents (ignoring 2 header lines)
    local g=$1 o=$2 n=$3 f
    [ "$(listing_tc "$g" "$n")" = "$(listing_tc "$o" "$n")" ] || return 1
    while IFS= read -r f; do
        [ -f "$g/$f" ] || continue
        diff <(tail -n +3 "$g/$f") <(tail -n +3 "$o/$f") >/dev/null 2>&1 || return 1
    done < <(listing_tc "$g" "$n")
    return 0
}

# ---------------------------------------------------------------------------------------------
# Setup: copy only what is needed (Testcase folders + the two scripts), build the good output
# ---------------------------------------------------------------------------------------------
copy_inputs() {     # <dest>
    local t
    mkdir -p "$1"
    for t in $TESTCASES; do cp -a "$REPO/$t" "$1/"; done
    [ -f "$REPO/check.sh" ] && cp -a "$REPO/check.sh" "$1/"
    [ -f "$REPO/script.sh" ] && cp -a "$REPO/script.sh" "$1/"
    return 0
}

TESTCASES="$(testcase_dirs "$REPO")"
[ -n "$TESTCASES" ] || { echo "No TestcaseN/ folders found in $REPO"; exit 2; }
GOOD="$TMP/good"; copy_inputs "$GOOD"; make_golden "$GOOD"

RC=0; OUT=""
run_check() { OUT="$(cd "$1" && run bash check.sh 2>/dev/null)"; RC=$?; }

expect_fail() {     # <label> <testcase number>   (runs check.sh in $GOOD, which is currently broken)
    run_check "$GOOD"
    if [ "$RC" -eq 124 ]; then
        record "$2" 0 "check.sh: timed out (over 30 seconds) on broken output: $1"
    elif [ "$RC" -eq 0 ]; then
        if grep -q "^Testcase$2: FAIL" <<< "$OUT"; then
            record "$2" 0 "check.sh: printed 'Testcase$2: FAIL' but exited 0 on broken output: $1 (it must exit non-zero when a Testcase fails)"
        else
            record "$2" 0 "check.sh: did not detect broken output: $1 (exited 0, no 'Testcase$2: FAIL' line)"
        fi
    elif ! grep -q "^Testcase$2: FAIL" <<< "$OUT"; then
        record "$2" 0 "check.sh: exited $RC but printed no 'Testcase$2: FAIL' line on broken output: $1"
    else
        record "$2" 1 "$1"
    fi
}

# Extra hints, shown at the end only when something failed
NOTES=""
note() { NOTES="${NOTES}    - $1"$'\n'; }

# check.sh rejected correct output: try the same output in two other forms to find out why
diagnose_correct_output() {
    local t n same=1
    if [ -n "${REGEN:-}" ] && [ -f "$REGEN/script.sh" ]; then
        for t in $TESTCASES; do
            same_output_tc "$GOOD" "$REGEN" "${t#Testcase}" || same=0
        done
        if [ "$same" -eq 1 ]; then
            run_check "$REGEN"
            if [ "$RC" -eq 0 ]; then
                note "check.sh accepts the header lines your script.sh writes, but not the same output with different header lines. Compare with 'tail -n +3' on both sides, because the first two lines of 'diff -u' can differ."
            fi
        fi
    fi
    FULL="$TMP/full"; mkdir -p "$FULL"; cp -a "$REPO/." "$FULL/"; rm -rf "$FULL/.git"
    for t in $TESTCASES; do
        n=${t#Testcase}
        rm -rf "$FULL/Testcase${n}Diff"
        [ -d "$GOOD/Testcase${n}Diff" ] && cp -a "$GOOD/Testcase${n}Diff" "$FULL/"
    done
    run_check "$FULL"
    if [ "$RC" -eq 0 ]; then
        note "check.sh passes only when other files from your repo are present. It may read only the Testcase# folders and the Testcase#Diff output folders."
    fi
}

# ------------------------------- 1. script.sh: folder exists when it should, files correct -------------------------------
if [ -f "$REPO/script.sh" ]; then
    REGEN="$TMP/regen"; copy_inputs "$REGEN"
    (cd "$REGEN" && run bash script.sh >/dev/null 2>&1)
    for t in $TESTCASES; do
        n=${t#Testcase}
        if same_output_tc "$GOOD" "$REGEN" "$n"; then
            record "$n" 1 "script.sh: output"
        elif [ -d "$GOOD/Testcase${n}Diff" ] && [ ! -d "$REGEN/Testcase${n}Diff" ]; then
            record "$n" 0 "script.sh did not create Testcase${n}Diff/"
        elif [ ! -d "$GOOD/Testcase${n}Diff" ] && [ -d "$REGEN/Testcase${n}Diff" ]; then
            record "$n" 0 "script.sh created Testcase${n}Diff/ but nothing differs in $t"
        else
            record "$n" 0 "script.sh: files in Testcase${n}Diff/ are missing or have the wrong contents"
        fi
    done
else
    record 0 0 "script.sh: not found"
fi

# ------------------------------- 2. check.sh on correct output -------------------------------
TEST_BROKEN=0
if [ ! -f "$REPO/check.sh" ]; then
    record 0 0 "check.sh: not found"
else
    run_check "$GOOD"
    if [ "$RC" -eq 124 ]; then
        record 0 0 "check.sh: timed out (over 30 seconds) on correct output. Remove any sleep or read, and don't run script.sh from it."
    else
        TEST_BROKEN=1
        CHECK_RC=$RC; ALL_PASS=1
        for t in $TESTCASES; do
            n=${t#Testcase}
            nlines=$(grep -c "^Testcase$n: " <<< "$OUT")
            if [ "$nlines" -eq 1 ] && grep -q "^Testcase$n: PASS" <<< "$OUT"; then
                record "$n" 1 "check.sh: prints one PASS line on correct output"
            else
                ALL_PASS=0
                if [ "$nlines" -eq 0 ]; then
                    record "$n" 0 "check.sh: printed no 'Testcase$n:' line on correct output (expected 'Testcase$n: PASS')"
                elif [ "$nlines" -gt 1 ]; then
                    record "$n" 0 "check.sh: printed $nlines 'Testcase$n:' lines on correct output (expected exactly one)"
                else
                    record "$n" 0 "check.sh: printed '$(grep "^Testcase$n: " <<< "$OUT")' on correct output (expected 'Testcase$n: PASS')"
                fi
            fi
        done
        if [ "$CHECK_RC" -eq 0 ]; then
            record 0 1 "check.sh: exits 0 on correct output"
        elif [ "$ALL_PASS" -eq 1 ]; then
            record 0 0 "check.sh: printed every PASS line correctly, but exited $CHECK_RC (it must exit 0). A last line like '[ \$rc -eq 1 ] && exit 1' causes this; end with 'exit \$rc'."
        else
            record 0 0 "check.sh: exited $CHECK_RC on correct output (it must exit 0)"
        fi
        [ "$ALL_PASS" -eq 1 ] || diagnose_correct_output
    fi
    if grep -v '^[[:space:]]*#' "$REPO/check.sh" | grep -qE '/Users/|/home/|~/|\$HOME|git rev-parse|cd[[:space:]]+["'\'']?/'; then
        note "check.sh seems to use a fixed path or git to find your repo, so it may read your real files instead of the copy being tested. Use relative paths such as Testcase1/ and Testcase1Diff/."
    fi
fi

# ------------------------------- 3. check.sh on broken output -------------------------------
# Each case breaks $GOOD in place, runs check.sh, then restores it (no extra copies).
[ "$TEST_BROKEN" -eq 1 ] && for t in $TESTCASES; do
    n=${t#Testcase}; out="$GOOD/Testcase${n}Diff"
    if [ -d "$out" ]; then
        # folder missing although it should exist
        mv "$out" "$TMP/saved_dir"
        expect_fail "folder missing: Testcase${n}Diff/" "$n"
        mv "$TMP/saved_dir" "$out"

        # wrong contents in a file inside the folder (first file)
        f="$(cd "$out" && ls -1 | LC_ALL=C sort -V | head -n 1)"
        cp -p "$out/$f" "$TMP/saved_file"
        echo "THIS LINE SHOULD NOT BE HERE" >> "$out/$f"
        expect_fail "wrong contents: Testcase${n}Diff/$f" "$n"
        cp -p "$TMP/saved_file" "$out/$f"

        # output file for an identical pair (first identical pair in this Testcase, if any)
        while IFS='|' read -r key a b; do
            [ -n "$key" ] || continue
            if cmp -s "$GOOD/$a" "$GOOD/$b"; then
                echo "should not exist" > "$out/${key}Diff.txt"
                expect_fail "output file for identical pair: Testcase${n}Diff/${key}Diff.txt" "$n"
                rm -f "$out/${key}Diff.txt"
                break
            fi
        done < <(pairs_for_dir "$GOOD" "$t")
    else
        # folder present although nothing differs
        mkdir "$out"
        expect_fail "folder Testcase${n}Diff/ exists but nothing differs" "$n"
        rmdir "$out"
    fi
done

# ------------------------------- report -------------------------------
echo "Validating: $REPO"
BAD_TC=0

# tests not tied to one Testcase are only shown if they failed
general_failed=0
for i in "${!RES_N[@]}"; do
    if [ "${RES_N[i]}" -eq 0 ] && [ "${RES_OK[i]}" -eq 0 ]; then
        [ "$general_failed" -eq 0 ] && echo "General: FAIL"
        general_failed=1
        echo "    - ${RES_MSG[i]}"
    fi
done
[ "$general_failed" -eq 1 ] && BAD_TC=$((BAD_TC + 1))

for t in $TESTCASES; do
    n=${t#Testcase}
    failed=0
    for i in "${!RES_N[@]}"; do
        [ "${RES_N[i]}" -eq "$n" ] && [ "${RES_OK[i]}" -eq 0 ] && failed=$((failed + 1))
    done
    if [ "$failed" -eq 0 ]; then
        echo "Testcase$n: PASS"
    else
        BAD_TC=$((BAD_TC + 1))
        echo "Testcase$n: FAIL"
        for i in "${!RES_N[@]}"; do
            [ "${RES_N[i]}" -eq "$n" ] && [ "${RES_OK[i]}" -eq 0 ] && echo "    - ${RES_MSG[i]}"
        done
    fi
done

if [ "$BAD_TC" -gt 0 ] && [ -n "$NOTES" ]; then
    echo "Possible causes:"
    printf '%s' "$NOTES"
fi

[ "$BAD_TC" -eq 0 ]
