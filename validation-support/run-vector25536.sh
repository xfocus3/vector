#!/usr/bin/env bash
set -euo pipefail
results="$RUNNER_TEMP/vector25536-results"
input="$RUNNER_TEMP/vector25536-input"
cat > "$input/datadog.yaml" <<'YAML'
sources:
  datadog:
    type: datadog_agent
    address: 127.0.0.1:18080
sinks:
  discard:
    type: blackhole
    inputs: [datadog]
YAML
"$VDEV" features "$input/datadog.yaml" | sort -u > "$results/features.txt"
features=$(paste -sd, "$results/features.txt")
# Guard against an empty or accidentally broadened configuration, without guessing its feature set.
[[ -n "$features" && "$features" != *default* ]]
case "$CHECK" in
  tests)
    cargo test --locked --package vector --lib --no-default-features --features "$features" sources::datadog_agent::tests -- --test-threads=1
    ;;
  clippy)
    # Exact equivalent of FEATURES=... make check-clippy, plus --locked.
    cargo clippy --locked --workspace --all-targets --no-default-features --features "$features" -- -D warnings -Dclippy::print_stdout -Dclippy::print_stderr -Dclippy::dbg_macro
    ;;
  format-examples)
    # Check both upstream's tracked workflows and the new workflow stored outside its tree.
    failed=0
    make check-actionlint || failed=1
    actionlint "$input/validate-vector25536.yml" || failed=1
    # Formatter failure means its transformations may be incomplete; record it and stop.
    fmt_status=0
    make fmt || fmt_status=$?
    printf 'make fmt exit status: %s\n' "$fmt_status" > "$results/format-status.txt"
    git diff --binary > "$results/formatting.patch"
    if [[ "$fmt_status" -ne 0 ]]; then
      printf 'Formatter could not complete; examples were not generated.\n' >> "$results/format-status.txt"
      exit "$fmt_status"
    fi
    check_fmt_status=0
    make check-fmt || check_fmt_status=$?
    printf 'make check-fmt exit status: %s\n' "$check_fmt_status" >> "$results/format-status.txt"
    [[ "$check_fmt_status" -eq 0 ]] || failed=1
    [[ ! -s "$results/formatting.patch" ]] || failed=1
    # Use the official generator directly: the Make wrapper would build all default features.
    # Keep independent statuses so the second run still happens after any first-run failure.
    for pass in first second; do
      generation_status=0
      "$VDEV" build component-examples website/generated/example-configs || generation_status=$?
      printf '%s generation exit status: %s\n' "$pass" "$generation_status" >> "$results/example-status.txt"
      if [[ "$generation_status" -eq 0 ]]; then
        python3 "$input/validate-vector25536.py" snapshot "$pass" || failed=1
      else
        failed=1
      fi
      git diff --exit-code -- website/generated/example-configs > "$results/examples-$pass.patch" || failed=1
      test -z "$(git ls-files --others --exclude-standard -- website/generated/example-configs)" || failed=1
    done
    if [[ -f "$results/examples-first.json" && -f "$results/examples-second.json" ]]; then
      cmp "$results/examples-first.json" "$results/examples-second.json" || failed=1
    else
      failed=1
    fi
    git diff --exit-code || failed=1
    test "$failed" -eq 0
    ;;
  *) exit 2 ;;
esac
printf 'PASS: %s\n' "$CHECK" > "$results/check-result.txt"
