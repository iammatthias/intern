# Meal reminder route

Fires only when the decision table in `SKILL.md` picks `meal-reminder` (row 4: inside lunch 11:30 to 13:30 or dinner 18:30 to 20:30, no meal signal this window). Otherwise STOP.

## Intent

It's a meal window and there's no meal signal yet: no reminder you already sent, and no "going to lunch" intent in the habits log. Ask once per window, light, not nagging. If the user already told you they ate or are eating, this route is silently skipped by the gate.

## Phrasing rules

- **1 to 3 sentences**, casual, a roommate checking in, not an app pinging. A one-liner is fine when the moment is sleepy.
- **Open-ended** ("had lunch yet?"). Avoid door-closing yes/no like "do you want to eat?".
- **Optional health-context aside** (one short clause, never a lecture): "so you've got fuel for the afternoon", "don't let your blood sugar tank". At most one per reminder, never the same line two days in a row.
- Don't list food or suggest what to eat. The goal is the prompt, not the menu.
- Match the user's language.
- Paraphrase every time; never send a template verbatim.

## Tone table (reference only, paraphrase, never copy)

| Window | Example tones |
|---|---|
| `lunch` | "Lunch hour, eaten anything or buried in something?" / "Time for lunch. Grab a bite so you've got fuel for the afternoon." |
| `dinner` | "Dinner time, anything yet or skipping tonight?" / "Evening's here. Eat something so you don't crash later." |

## Ledger row

After sending, append (note the extra `trigger` field carrying the window):

```bash
printf '%s\n' '{"ts":"'"$(date -Is)"'","date":"'"$(date +%F)"'","hour":'"$(date +%-H)"',"action":"meal_reminder","trigger":"lunch","notes":"<your sentence>"}' \
  >> /root/.hermes/intern-data/wellbeing/<user>.jsonl
```

This row is the once-per-window gate. Lunch and dinner gate independently (match on `trigger`).

## Follow-up

One reminder per meal window. If the user replies "ate already", that's a normal chat turn; don't push, and remember habit Flow D may want the intent logged if they say they're heading to eat NOW.
