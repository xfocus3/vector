---
name: vector-components-maturity-eval
description: Evaluates all Vector component maturity levels and writes a monthly markdown report to .claude/skill-reports/maturity-YYYY-MM.md. Use when asked to evaluate component maturity or generate the monthly maturity report.
---

You are the Vector Component Maturity Evaluator. Work through the phases below to collect signals for all components, evaluate them, and write the report.

## Maturity Criteria

From `website/content/en/docs/architecture/guarantees.md`:

**Stable** requires ALL of:

- >50 production users for a sustained period without issue (proxy: `commonly_used: true` + age)
- >4 months community testing (proxy: file age in git)
- API stable and unlikely to change (proxy: low config churn)
- No major open bugs

**Beta**: Does not meet stable criteria — use with caution in production.
**Deprecated**: Will be removed in next major version.

## Signal Priority

1. **Open bugs** (highest weight) — open GitHub issues with issue type `Bug` mentioning this component
2. **Test coverage** (second) — integration test exists? unit test count?
3. Equal weight: age, config churn (6 months), `commonly_used`, docs quality (AI judgment)

---

## Phase 1: Inventory

```bash
# All canonical component CUE files (exclude generated/ subdirs)
find website/cue/reference/components/sources \
     website/cue/reference/components/transforms \
     website/cue/reference/components/sinks \
     -maxdepth 1 -name "*.cue" | sort

# Integration test directories
ls tests/integration/
```

---

## Phase 2: Bulk Signal Collection

Use single shell loops to collect all signals at once — do not make one Bash call per component.

### 2a. Open GitHub bugs

Issues use the GitHub issue **Type** field (not a label). The type name is `Bug`.

```bash
gh issue list --state open --search "type:Bug" --json number,title,url --limit 500 2>/dev/null
```

Store the full list. You will map bugs to components in Phase 4 by scanning titles for component names.

### 2b. Component age — date each CUE file was first committed

```bash
for kind in sources transforms sinks; do
  for f in website/cue/reference/components/${kind}/*.cue; do
    name=$(basename "$f" .cue)
    first_date=$(git log --follow --format="%ad" --date=short -- "$f" 2>/dev/null | tail -1)
    echo "${kind}/${name}|${first_date}"
  done
done
```

### 2c. Config churn — commits to CUE file in last 6 months

```bash
for kind in sources transforms sinks; do
  for f in website/cue/reference/components/${kind}/*.cue; do
    name=$(basename "$f" .cue)
    count=$(git log --since="6 months ago" --oneline -- "$f" 2>/dev/null | wc -l | tr -d ' ')
    echo "${kind}/${name}|${count}"
  done
done
```

### 2d. Unit test count

```bash
test_attr_regex='#\[(tokio::test|test|rstest|test_case)(\(|\])'

for kind in sources transforms sinks; do
  for f in website/cue/reference/components/${kind}/*.cue; do
    name=$(basename "$f" .cue)
    paths=()

    add_path() {
      [ -e "$1" ] && paths+=("$1")
    }

    add_path "src/${kind}/${name}.rs"
    add_path "src/${kind}/${name}"

    # Some sink implementations live under shared provider directories.
    case "${kind}/${name}" in
      sinks/aws_kinesis_firehose) add_path "src/sinks/aws_kinesis/firehose" ;;
      sinks/aws_kinesis_streams) add_path "src/sinks/aws_kinesis/streams" ;;
      sinks/aws_sns) add_path "src/sinks/aws_s_s/sns" ;;
      sinks/aws_sqs) add_path "src/sinks/aws_s_s/sqs" ;;
      sinks/datadog_events) add_path "src/sinks/datadog/events" ;;
      sinks/datadog_logs) add_path "src/sinks/datadog/logs" ;;
      sinks/datadog_metrics) add_path "src/sinks/datadog/metrics" ;;
      sinks/datadog_traces) add_path "src/sinks/datadog/traces" ;;
      sinks/gcp_chronicle_unstructured) add_path "src/sinks/gcp_chronicle" ;;
      sinks/gcp_cloud_storage) add_path "src/sinks/gcp/cloud_storage.rs" ;;
      sinks/gcp_pubsub) add_path "src/sinks/gcp/pubsub.rs" ;;
      sinks/gcp_stackdriver_logs) add_path "src/sinks/gcp/stackdriver/logs" ;;
      sinks/gcp_stackdriver_metrics) add_path "src/sinks/gcp/stackdriver/metrics" ;;
      sinks/greptimedb_logs) add_path "src/sinks/greptimedb/logs" ;;
      sinks/greptimedb_metrics) add_path "src/sinks/greptimedb/metrics" ;;
      sinks/humio_logs) add_path "src/sinks/humio/logs.rs" ;;
      sinks/humio_metrics) add_path "src/sinks/humio/metrics.rs" ;;
      sinks/influxdb_logs) add_path "src/sinks/influxdb/logs.rs" ;;
      sinks/influxdb_metrics) add_path "src/sinks/influxdb/metrics.rs" ;;
      sinks/prometheus_exporter) add_path "src/sinks/prometheus/exporter.rs" ;;
      sinks/prometheus_remote_write) add_path "src/sinks/prometheus/remote_write" ;;
      sinks/sematext_logs) add_path "src/sinks/sematext/logs.rs" ;;
      sinks/sematext_metrics) add_path "src/sinks/sematext/metrics.rs" ;;
      sinks/splunk_hec_logs) add_path "src/sinks/splunk_hec/logs" ;;
      sinks/splunk_hec_metrics) add_path "src/sinks/splunk_hec/metrics" ;;
    esac

    if [ ${#paths[@]} -eq 0 ]; then
      count=0
    elif command -v rg >/dev/null 2>&1; then
      count=$(rg -n "$test_attr_regex" "${paths[@]}" 2>/dev/null | wc -l | tr -d ' ')
    else
      count=$(grep -ER "$test_attr_regex" "${paths[@]}" 2>/dev/null | wc -l | tr -d ' ')
    fi
    echo "${kind}/${name}|${count}"
  done
done
```

### 2e. Integration test presence

From the `ls tests/integration/` output, note which component names have a matching directory. A component has an integration test if `tests/integration/<name>` or a close variant exists.

---

## Phase 3: Read CUE Files

Read each component's CUE file in batches of 10–15 (parallel Read calls in a single response). Extract:

- `development` value — `"stable"`, `"beta"`, or `"deprecated"`
- `commonly_used` — `true` or `false`
- Whether `how_it_works` has substantive prose. If it references a shared CUE object, read that referenced object and judge the resolved prose; shared populated docs count as substantive.
- Whether `description` (top-level) is meaningful: at least two sentences explaining what the component does and when to use it
- Whether there are non-trivial `examples` in the configuration section

**Docs quality judgment**: mark docs as `complete`, `partial`, or `minimal`.

- `complete`: all three present (description, how_it_works prose, examples)
- `partial`: one or two present
- `minimal`: none meaningful or all are placeholders/references

---

## Phase 4: Match Bugs to Components

Scan each GitHub issue title from Phase 2a for component names. Use the canonical component names from the CUE filenames as the reference list.

**Avoid false matches on generic terms.** Names like `file`, `http`, `socket`, `vector`, `console`, and `internal` appear in many issue titles without referring to a specific component. Only count a match when the issue title unambiguously refers to the component (e.g. `"kafka source: ..."`, `"[loki sink]"`, or the component name appears as a standalone token next to "source", "sink", or "transform").

Count matched open bugs per component. If an issue mentions multiple components, count it for each. If a title is ambiguous — it contains a generic term that could match several components — do not count it for any component; instead collect these in an "Unmatched / ambiguous" list and include it in the report's Reference section for manual review.

---

## Phase 5: Evaluate Each Component

For every component, assign one recommendation:

| Rec | Meaning |
| --- | --- |
| **promote** | Beta → stable candidate |
| **keep** | No change warranted |
| **watch** | Stable with concerning signals |
| **deprecate-candidate** | Little activity, superseded, or already deprecated in CUE |

**Promote** (beta only): 0–1 open bugs AND (integration test OR unit tests > 10) AND age > 4 months AND churn ≤ 5 commits AND docs at least `partial`.

**Watch** (stable only): ≥ 3 open bugs, OR churn > 10 commits (API instability), OR no tests at all.

Use judgment for borderline cases. A component with 2 bugs but a long stable history is different from one with 2 bugs filed in the last month.

---

## Phase 6: Write Report

Create the output directory and write the report:

```bash
mkdir -p .claude/skill-reports
```

Write to `.claude/skill-reports/maturity-YYYY-MM.md` using the actual current year and month.

---

### Report format

```markdown
# Vector Component Maturity Report — YYYY-MM

_Generated: YYYY-MM-DD. N sources · N transforms · N sinks (N total)._

---

## Summary

| Category | Count |
|----------|-------|
| Promote candidates (beta → stable) | N |
| Near misses (one criterion short) | N |
| Watch list (stable with concerns) | N |
| Deprecation candidates | N |
| No change | N |

---

## Promotion Candidates

_Beta components that strictly meet all stable criteria: 0–1 open bugs, integration or >10 unit tests, age > 4 months, churn ≤ 5 commits, docs at least `partial`._

| Component | Type | Open Bugs | Int Tests | Age | Churn (6mo) | Docs |
|-----------|------|-----------|-----------|-----|-------------|------|
| `name` | source | 0 | ✓ | 18mo | 2 | complete |

---

## Near Misses

_Beta components that fail exactly one promotion criterion. List the blocking criterion._

| Component | Type | Open Bugs | Int Tests | Age | Churn (6mo) | Docs | Blocking |
|-----------|------|-----------|-----------|-----|-------------|------|----------|

---

## Watch List

_Stable components with signals worth a human look._

| Component | Type | Open Bugs | Notes |
|-----------|------|-----------|-------|
| `name` | sink | 4 | 2 labeled critical |

---

## Deprecation Candidates

| Component | Type | Notes |
|-----------|------|-------|

---

## Full Inventory

<details>
<summary>Beta components (N)</summary>

| Component | Type | Open Bugs | Int Tests | Unit Tests | Age | Churn | Commonly Used | Docs | Rec |
|-----------|------|-----------|-----------|------------|-----|-------|---------------|------|-----|

</details>

<details>
<summary>Stable components (N)</summary>

| Component | Type | Open Bugs | Int Tests | Commonly Used | Rec |
|-----------|------|-----------|-----------|---------------|-----|

</details>
```

Notes column: five words max. Keep prose minimal. Tables over paragraphs. All issue number references must be hyperlinked: in markdown use `[#NNNNN](https://github.com/vectordotdev/vector/issues/NNNNN)`, in HTML use `<a href="https://github.com/vectordotdev/vector/issues/NNNNN">#NNNNN</a>`.

---

## Phase 7: Done

The report is complete. Tell the user where the file was written. Do not publish anywhere — distribution is a separate decision made by the user after reviewing the report.

---

## Reference

- CUE files at `website/cue/reference/components/{sources,transforms,sinks}/` are authoritative (ignore `generated/` subdirs)
- Source implementations: `src/sources/<name>.rs` or `src/sources/<name>/`, same pattern for sinks and transforms
- `gh` is pre-authenticated for `vectordotdev/vector`
- Bugs are identified by the GitHub issue **Type** field (`type:Bug` in search), not by label — the old `type: bug` label is deprecated
- Working directory is the Vector repo root

**Parent/shared CUE files**: Some CUE files define shared configuration for families of components and have no `development` field of their own (children inherit it). These will appear as "unknown" status when grepped. Known parent files: `sinks/aws_cloudwatch.cue`, `sinks/datadog.cue`, `sinks/gcp.cue`, `sinks/humio.cue`, `sinks/influxdb.cue`, `sinks/sematext.cue`, `sinks/splunk_hec.cue`, and possibly `sinks/statsd.cue`, `sources/syslog.cue`. Exclude these from per-component counts; note them separately.

**Integration test name mapping**: Integration test directory names use hyphens, not underscores (e.g. `tests/integration/docker-logs/` maps to `docker_logs`, `tests/integration/windows-event-log/` maps to `windows_event_log`). Some test directories cover multiple components under a shared umbrella (e.g. `aws/` covers all `aws_*` sources and sinks, `gcp/` covers all `gcp_*` sinks, `prometheus/` covers `prometheus_scrape`, `prometheus_exporter`, and `prometheus_remote_write`).

**CUE age caveat**: Many component CUE files show a first-commit date of 2020-10-xx, which reflects the batch import of the website CUE system — not the actual component introduction date. Treat these dates as lower bounds and note the caveat in the report.
