#!/usr/bin/env bash
#
# mayhem/test.sh — BEHAVIORAL oracle for argo-workflows' PROGRESS field parser.
# Runs the dynamically-linked KAT probe (/mayhem/argo_progress_kat, built by
# build.sh) that parses fixed "N/M" progress strings through the real
# pkg/apis/workflow/v1alpha1.ParseProgress path, and asserts the EXACT decoded
# field values (all lifted from upstream's progress_test.go golden cases).
#
# Why not `go test` alone (netnew §4): a Go test binary is statically linked, so
# the gate's LD_PRELOAD sabotage shim cannot neuter it — the suite would survive
# sabotage while proving nothing. The KAT probe is cgo-linked (dynamic), so when
# the program is neutered to _exit(0) it prints nothing, every assertion misses,
# and test.sh FAILS — which is the point (§6.3).
#
# Emits a CTRF summary; exits non-zero iff failed>0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-${SRC:-/mayhem}/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PROBE=/mayhem/argo_progress_kat
passed=0; failed=0

# Unconditional: a missing probe is a build.sh bug — FAIL loudly, never skip.
if [ ! -x "$PROBE" ]; then
  echo "FAIL: KAT probe $PROBE missing or not executable (build.sh should have produced it)" >&2
  emit_ctrf "argo-progress-kat" 0 1
  exit 1
fi

OUT="$("$PROBE" 2>/dev/null)"
echo "--- KAT probe output ---"; printf '%s\n' "$OUT"; echo "------------------------"

# Fixed inputs -> exact expected decodes (progress_test.go golden cases):
#   ParseProgress("0/1")  -> valid, N=0, M=1
#   ParseProgress("")     -> invalid ; ParseProgress("5") -> invalid
#   Progress("1/0").IsValid() -> false ; Progress("0/0").IsValid() -> false
#   Progress("0/0").Add("1/2")   -> "1/2"
#   Progress("0/100").Complete() -> "100/100"
assert() { # <desc> <expected-line>
  if printf '%s\n' "$OUT" | grep -qxF "$2"; then
    echo "PASS: $1"; passed=$((passed+1))
  else
    echo "FAIL: $1 (expected exact line: $2)"; failed=$((failed+1))
  fi
}

assert "ParseProgress(\"0/1\") is valid"        "KAT_VALID_0_1=true"
assert "parsed N is 0"                          "KAT_N=0"
assert "parsed M is 1"                          "KAT_M=1"
assert "ParseProgress(\"\") is invalid"         "KAT_VALID_EMPTY=false"
assert "ParseProgress(\"5\") is invalid"        "KAT_VALID_5=false"
assert "Progress(\"1/0\") is invalid"           "KAT_VALID_1_0=false"
assert "Progress(\"0/0\") is invalid"           "KAT_VALID_0_0=false"
assert "Progress(\"0/0\").Add(\"1/2\") == 1/2"  "KAT_ADD=1/2"
assert "Progress(\"0/100\").Complete() == 100/100" "KAT_COMPLETE=100/100"

emit_ctrf "argo-progress-kat" "$passed" "$failed"
