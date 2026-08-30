#!/usr/bin/env sh
# mutcheck — run the test suite over a MUTATED tree and classify the outcome,
# refusing to classify what never ran.
#
# Why this exists (ledger, 2026-08-25): twice in one session a mutation check
# reported "0 failures" because the mutant DID NOT COMPILE — an unused capture
# once, a syntax slip once — and the ad-hoc harness read a build error as a
# clean run. That is the exact shape of every green tick from a machine that
# did no work: a check whose pass condition is "nothing bad was reported".
# The structural fix is polarity, not vigilance: this script reports BITTEN
# only when it saw tests fail, reports SURVIVED only when it saw tests pass,
# and treats everything else — a compile error above all — as a failure of
# the harness itself that refuses to say anything about the gate.
#
# Usage: apply your mutation to the working tree, then run
#     tools/mutcheck.sh
# from the repo root (any repo whose `zig build test` is the suite).
#
# Exit codes:
#   0  mutation BITTEN   — at least one test failed; the gate watched something
#   1  mutation SURVIVED — full suite passed; the gate watched nothing (act!)
#   2  HARNESS FAILURE   — the mutant did not compile, or the output had no
#                          recognisable verdict; NOTHING WAS TESTED

set -u

out=$(zig build test --summary all 2>&1)
status=$?

# A compile error means no test ran, whatever else the output says.
if printf '%s' "$out" | grep -q "compilation errors"; then
    printf '%s\n' "$out" | grep -E "error:" | head -5
    echo "mutcheck: HARNESS FAILURE — the mutant did not compile; nothing was tested."
    echo "mutcheck: a mutation that does not compile is not a mutation. Fix it and rerun."
    exit 2
fi

if [ $status -eq 0 ]; then
    if printf '%s' "$out" | grep -qE "[0-9]+/[0-9]+ tests passed|tests passed"; then
        summary=$(printf '%s' "$out" | grep "Build Summary" | head -1)
        echo "mutcheck: MUTATION SURVIVED — $summary"
        echo "mutcheck: the gate watched nothing. The mutation is a finding about the gate."
        exit 1
    fi
    echo "mutcheck: HARNESS FAILURE — build succeeded but no test verdict was found in the output."
    exit 2
fi

if printf '%s' "$out" | grep -qE "error: 'tests|tests passed; [0-9]+ failed|[0-9]+ failed|while executing test"; then
    printf '%s' "$out" | grep -E "error: '|terminated with signal" | head -8
    # A test that PANICS is a bite too — it prints "terminated with signal",
    # not "error: '<test>'", and the first draft counted those as 0.
    n=$(printf '%s' "$out" | grep -cE "error: '|terminated with signal" )
    echo "mutcheck: mutation BITTEN — $n failing test(s). The gate watched something."
    exit 0
fi

echo "mutcheck: HARNESS FAILURE — non-zero exit with no recognisable test failure; refusing to classify."
printf '%s\n' "$out" | tail -10
exit 2
