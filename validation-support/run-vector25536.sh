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
    # Match website/Makefile's generate-vrl-docs prerequisite without its tool reinstall.
    # vdev reads VRL's exact Cargo.lock revision and the candidate's local docs/generated.
    # No --vector-sha: the local validation merge is intentionally unpublished upstream.
    prerequisite_dir="$input/vrl-docs"
    mkdir -p "$prerequisite_dir"
    "$VDEV" build vrl-docs --output-dir "$prerequisite_dir"
    # Verify the exact functions behind the CUE failure were actually supplied.
    python3 -c 'import json,sys; f=json.load(open(sys.argv[1]))["remap"]["functions"]; assert "exists" in f and "is_nullish" in f' "$prerequisite_dir/generated.cue"
    generated_functions=website/cue/reference/remap/functions/generated.cue
    # This disposable build input must never replace a tracked candidate file.
    test -z "$(git ls-files -- "$generated_functions")"
    git check-ignore -q "$generated_functions"
    test ! -L "$generated_functions"
    had_generated_functions=0
    if [[ -e "$generated_functions" ]]; then
      cp "$generated_functions" "$prerequisite_dir/original.cue"
      had_generated_functions=1
    fi
    restore_generated_functions() {
      if [[ "$had_generated_functions" -eq 1 ]]; then
        cp "$prerequisite_dir/original.cue" "$generated_functions"
      else
        rm -f "$generated_functions"
      fi
    }
    trap restore_generated_functions EXIT
    before_prerequisite=$(git diff --binary HEAD | sha256sum | cut -d ' ' -f 1)
    mkdir -p "$(dirname "$generated_functions")"
    cp "$prerequisite_dir/generated.cue" "$generated_functions"
    after_prerequisite=$(git diff --binary HEAD | sha256sum | cut -d ' ' -f 1)
    test "$before_prerequisite" = "$after_prerequisite"
    sha256sum < "$prerequisite_dir/generated.cue" | cut -d ' ' -f 1 > "$results/vrl-docs-input.sha256"
    # Use the official example generator with the prerequisite present for both passes.
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
