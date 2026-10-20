#!/usr/bin/env bash
# Runs apt/private/Verify.java against the signed fixtures in fixtures/ and compares exit codes (and, for
# cleartext messages, the verified text) with cases.tsv.
#
# usage: verify_test.sh JAVA CLASSPATH VERIFY_JAVA
#   JAVA        java executable (JDK 11+, the source launcher is used)
#   CLASSPATH   bcpg, bcprov and bcutil jars, joined with the platform path separator
#   VERIFY_JAVA path to apt/private/Verify.java
#
# Verification happens as of a fixed time so that the expired-signature and expired-key fixtures stay
# expired and the valid ones stay valid regardless of the clock: 2026-10-20T23:00:00Z.
set -uo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 JAVA CLASSPATH VERIFY_JAVA" >&2
  exit 2
fi
java=$1
classpath=$2
verify_java=$3
here=$(cd "$(dirname "$0")" && pwd)
fixtures=$here/fixtures
at=1792537200
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
total=0
while IFS=$'\t' read -r name mode expected keyrings arg1 arg2; do
  [[ -z "$name" || "$name" == \#* ]] && continue
  total=$((total + 1))
  keyring_args=()
  IFS=',' read -ra rings <<< "$keyrings"
  for ring in "${rings[@]}"; do
    keyring_args+=(--keyring "$fixtures/$ring")
  done
  out=$work/verified.txt
  rm -f "$out"
  if [[ "$mode" == detached ]]; then
    (cd "$work" && "$java" -cp "$classpath" "$verify_java" detached --at "$at" "${keyring_args[@]}" "$fixtures/$arg1" "$fixtures/$arg2") > "$work/stdout" 2> "$work/stderr"
  else
    (cd "$work" && "$java" -cp "$classpath" "$verify_java" clearsigned --at "$at" "${keyring_args[@]}" --output "$out" "$fixtures/$arg1") > "$work/stdout" 2> "$work/stderr"
  fi
  actual=$?
  status=ok
  if [[ "$actual" != "$expected" ]]; then
    status="FAIL (exit $actual, expected $expected)"
  elif [[ "$mode" == clearsigned && "$expected" == 0 && -n "${arg2:-}" ]] && ! cmp -s "$out" "$fixtures/$arg2"; then
    status="FAIL (verified text differs from $arg2)"
  fi
  [[ "$status" != ok ]] && failures=$((failures + 1))
  printf '%-48s %s\n' "$name" "$status"
  if [[ "$status" != ok ]]; then
    sed 's/^/    stdout: /' "$work/stdout"
    sed 's/^/    stderr: /' "$work/stderr"
  fi
done < "$here/cases.tsv"

echo "$((total - failures))/$total cases passed"
[[ $failures -eq 0 ]]
