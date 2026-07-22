# Flow A: Build Patterns (full algorithm)

Load the multi-day intent log and produce `<user>.patterns.json` for one user. Read this when invoked from wellbeing enrichment, a Hermes cron refresh, or when the user explicitly asks about habits.

## Self-throttle guard (run first, always)

```bash
PATTERNS=/root/.hermes/intern-data/habits/<user>.patterns.json
if [ -f "$PATTERNS" ] && [ $(( $(date +%s) - $(stat -c %Y "$PATTERNS") )) -lt 21600 ]; then
  cat "$PATTERNS"   # fresh, under 6h old: return existing, skip rebuild
  exit 0
fi
DAYS=$(cut -d'"' -f8 /root/.hermes/intern-data/habits/<user>.jsonl 2>/dev/null | sort -u | wc -l)
[ "$DAYS" -lt 3 ] && { echo "insufficient_data: days=$DAYS"; exit 0; }
```

(The `cut` extracts the `date` field values; if the row shape ever changes, swap in `jq -r .date | sort -u | wc -l`.)

This makes Flow A idempotent and safe to invoke on every wellbeing nudge. The hot path costs one `stat` and an integer compare; only the cold path (missing or stale patterns, 3+ days of data) runs the full read below.

## Steps

1. **Load the log**: read the user's intent rows, keeping roughly the last 30 days.
   ```bash
   tail -n 500 /root/.hermes/intern-data/habits/<user>.jsonl
   ```
   Count distinct `date` values: that's `days_observed`. Patterns emit from `days_observed >= 3`; the wider window only deepens accuracy as data accumulates.

2. **Filter relevant actions.** Only intent actions can form habits: `meal`, `coffee`, `sleep`, `exercise`. Never read agent-written rows from the wellbeing log for pattern building; nudges and greetings are agent output, not user behavior, and would pollute detection.

3. **Group by (action, hour).** For each pair, collect the list of dates it appeared:
   ```
   meal @ hour=12 -> [2026-07-10, 2026-07-11, 2026-07-14, 2026-07-15]
   sleep @ hour=23 -> [2026-07-10, 2026-07-13, 2026-07-14]
   ```

4. **Compute frequency**: `frequency = len(dates_appeared) / days_observed`

5. **Compute typical minute.** For days where the action occurred at the habitual hour, collect the minute values and take the median.

6. **Assign strength** per the table in `SKILL.md` (< 0.50 weak and skipped, 0.50 to 0.75 moderate, > 0.75 strong).

7. **Write the patterns file**:
   ```bash
   mkdir -p /root/.hermes/intern-data/habits
   cat > /root/.hermes/intern-data/habits/<user>.patterns.json << 'PATTERNS'
   {the computed JSON}
   PATTERNS
   ```

## patterns.json schema

```json
{
  "updated_at": "2026-07-16T08:00:00+02:00",
  "days_observed": 7,
  "patterns": [
    {
      "action": "meal",
      "typical_hour": 12,
      "typical_minute": 30,
      "window_minutes": 45,
      "frequency": 0.71,
      "days_observed": 7,
      "strength": "moderate"
    }
  ]
}
```

## Matching a pattern to "now" (for wellbeing enrichment)

1. Get current hour and minute.
2. Find a pattern entry with the relevant `action` and strength moderate or better (`frequency >= 0.5`).
3. Is now within `typical_hour:typical_minute` plus or minus `window_minutes`?
4. Yes: hand the matched habit to wellbeing so it can phrase "you usually X around now". No match: wellbeing falls back to generic phrasing.

Window sizes by action:

| Action | Window |
|---|---|
| `meal` | ±45 min |
| `coffee` | ±30 min |
| `sleep` | ±30 min |
| `exercise` | ±60 min |
