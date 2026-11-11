#!/bin/bash
##===----------------------------------------------------------------------===##
##
## This source file is part of the Swift open source project
##
## Copyright (c) 2026 Apple Inc. and the Swift project authors
## Licensed under Apache License v2.0
##
## See LICENSE.txt for license information
## See CONTRIBUTORS.txt for the list of Swift project authors
##
## SPDX-License-Identifier: Apache-2.0
##
##===----------------------------------------------------------------------===##

# Counts the instructions and heap allocations of one benchmark tool under valgrind, which
# makes both counts deterministic enough to compare across machines.
#
# Usage: benchmark-count.sh <tool> <binary-directory> <results-file>
#
# Writes one tab-separated line per measurement to the results file:
#   <metric: instructions|allocations> <repeat> <count>
#
# Valgrind runs the program tens of times slower, so the workloads are much smaller than a
# timed run would use. Each count is repeated to show how far from deterministic it is, since
# threads make some tools' instruction counts vary a little between runs.

set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "usage: $0 <tool> <binary-directory> <results-file>" >&2
    exit 2
fi

tool="$1"
binary="${2}/${tool}"
results_file="$3"

instruction_repeats=3
allocation_repeats=2

tool_arguments() {
    case "$1" in
    QUICTransfer) echo "-logging none -iterations 50" ;;
    QUICStreamLoad) echo "-logging none -stream-count 3000" ;;
    IPUDPTransfer) echo "-logging none -iterations 100" ;;
    *)
        echo "unknown tool: $1" >&2
        return 1
        ;;
    esac
}

arguments="$(tool_arguments "$tool")"
work_directory="$(mktemp -d)"

# Prints the first capture group of the pattern in valgrind's report. It fails if the program
# exits with an error or reports a failed run, or if the report lacks the count. The tools print
# a failed run on standard output and some still exit with success, so the output is checked too.
# Call it as its own assignment, since a failure inside an argument's substitution is not an error
# to the shell.
valgrind_count() {
    local description="$1" pattern="$2"
    shift 2
    local report output count status=0
    report="${work_directory}/report"
    output="${work_directory}/output"
    # shellcheck disable=SC2086 # the arguments are deliberately split
    "$@" "$binary" $arguments >"$output" 2>"$report" || status=$?
    tail -n 3 "$report" >&2
    if [ "$status" -ne 0 ]; then
        echo "::error::${tool} exited with status ${status} under valgrind." >&2
        tail -n 20 "$output" >&2
        exit 1
    fi
    if grep -E 'Error running|Issue took place|something failed' "$output" >&2; then
        echo "::error::${tool} reported a failed run under valgrind." >&2
        exit 1
    fi
    count="$(sed -n "s/${pattern}/\\1/p" "$report" | head -n 1 | tr -d ',')"
    if [ -z "$count" ]; then
        echo "::error::No ${description} in valgrind's report for ${tool}." >&2
        sed -n '1,40p' "$report" >&2
        exit 1
    fi
    echo "$count"
}

record() {
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$results_file"
}

: >"$results_file"
for ((repeat = 1; repeat <= instruction_repeats; repeat++)); do
    echo "=== ${tool} instructions repeat ${repeat} ===" >&2
    instructions="$(valgrind_count 'instruction count' '.*Collected : \([0-9]*\).*' \
        valgrind --tool=callgrind --fair-sched=yes --callgrind-out-file="${work_directory}/callgrind.out")"
    record instructions "$repeat" "$instructions"
done
for ((repeat = 1; repeat <= allocation_repeats; repeat++)); do
    echo "=== ${tool} allocations repeat ${repeat} ===" >&2
    allocations="$(valgrind_count 'allocation count' '.*total heap usage: \([0-9,]*\) allocs.*' \
        valgrind --tool=memcheck --fair-sched=yes --leak-check=no)"
    record allocations "$repeat" "$allocations"
done
