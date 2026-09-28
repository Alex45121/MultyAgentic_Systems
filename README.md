# MultyAgentic_Systems

# ED Mass Casualty Model (NetLogo)

This is an agent-based model of one emergency department during a mass casualty incident, built for the MAS team project. It asks how many casualties the department can absorb before waits become dangerous, and whether co-triage (two triage nurses) raises that limit.

## Files

| File | What |
|---|---|
| `ER_MCI.nlogo` | the model: code, interface, info tab, BehaviorSpace experiments |
| `scenarios/mci_XXX.csv` | fixed scenario files (0–300 casualties, nested) for `scenario-source = file` |
| `analyze_behaviorspace.py` | optional: turns BehaviorSpace table output into breaking points + plots |

## Running it

1. Open `ER_MCI.nlogo` in **NetLogo 6.4** (NetLogo 7 converts it on open). Keep the `scenarios/` folder next to it.
2. Choose `scenario-source`:
   - `generate` builds the incident from the `casualties` + `scenario-seed` sliders.
   - `file` reads the CSV named in `scenario-file`.
3. Set `co-triage?`, then press **setup** and **go**.

You'll see:

- **Floor view:** waiting room, then the triage desk (pink nurse, or two with co-triage), then the wait-for-bed area, then resus bays / ED beds / surge beds / chairs. Doctors are light blue and walk to the bed they are working at.
- **Patient colours:** white until triaged, then the assigned MTS colour; dark grey = expectant in MCI mode.
- **Incident command** (top left) turns red when MCI mode is declared.
- **Plots:** queues, outcomes and resources. The **output box** logs events such as the MCI declaration, surge beds opening and stand-down.
- **show messages** prints the last messages between agents and the totals per message type. **export patients** writes a per-patient CSV.

## The experiment (BehaviorSpace)

*Tools > BehaviorSpace > breaking-point-sweep*

This runs 14 incident sizes (0–300) × co-triage on/off × 30 seeds = 840 runs. `sim-seed` doubles as the replication number, so both setups get the same random streams. Tick **Table output** and uncheck **Spreadsheet**. With "simultaneous runs" at your core count it takes a few minutes. Then:

```bash
pip install pandas matplotlib
python analyze_behaviorspace.py sweep-table.csv --threshold 0.25
```

You get breaking points per criterion, plus figures. You can also open the CSV in Excel and average per `casualties` × `co-triage?`. `quick-test` is a 40-run version for checking that everything works.

### Breaking-point criteria (reporters in the model)
- `critical-delay-rate`: share of true red/orange patients not seen by a doctor within MTS target + 10 min (main criterion, threshold 0.25)
- `deaths-waiting`, `preventable-deaths` (deaths of patients who were salvageable on arrival)
- `p90-door-to-triage`: 90th percentile of the wait before triage starts
- also `lwbs`, `under-triage-rate`, `median-door-to-doctor 2`, `mci-declared-at`, `total-messages`

## Agents (how the grading criteria are met)

| Agent | Autonomous / goal-directed | Proactive | Social (messages) |
|---|---|---|---|
| Patient | worsens while waiting; leaves without being seen (LWBS) when its patience runs out | | ARRIVED, PATIENT_LEFT |
| Triage | estimates severity with noise; pulls critical and pre-notified patients forward; MCI rule = most salvageable first | acts on EXPECT_URGENT before the patient arrives | TRIAGED |
| Bed manager | places patients by priority, keeps resus bays for salvageable reds | opens surge beds; transfers long boarders in MCI mode | PREEMPT, answers doctors' work requests |
| Doctor | pulls the most urgent task; yields when pre-empted; decides disposition | | DISPOSITION, CALL_IN |
| Incident command | monitors arrivals / queues / beds | **declares MCI on a forecast** (arrival trend + ambulance pre-notifications); calls in on-call doctors; stands down | MCI_DECLARED, STAND_DOWN, EXPECT_URGENT |

## Assumptions

These are in `setup-constants` and the sliders. They are placeholder values for a generic Dutch level-1 trauma centre and need justifying in the report.

- 24 ED beds, 3 resus bays, 12 chairs, 10 surge beds (open 30 min after declaration)
- 4 doctors on shift + 3 on call (arrive after 45 min)
- triage takes 4 min for one nurse. Paired co-triage is ×0.65 faster, with severity error SD 0.5 instead of 0.8. In MCI mode triage is ×0.6 faster but less accurate.
- MCI declared at ≥12 arrivals per 30 min, or on a forecast of that many
- untreated red patient at severity 9 dies in ~45 min, orange at 7 in ~4 h
- 4.5 background patients/hour. Casualty mix ≈30% red/orange, walking wounded first, ambulances in waves.

## Status / caveat

I couldn't run NetLogo where I built this. The code passed the NetLogo Web editor's linter (unknown names, agent contexts, brackets), and I checked procedure argument counts and breed variables by hand. It has **not yet been run in NetLogo itself**. On first open, check that setup and go run and that the switches start in the stated positions: co-triage off, ward-boarding on, proactive-command on. A Python/Mesa version of the same model exists as a cross-check. With default settings it gave:

- co-triage raised the triage breaking point from ~29 to ~43 casualties
- the first preventable death moved from ~58 to ~68 casualties
- the critical-delay and died-waiting criteria barely moved: past ~40 casualties the bottleneck is doctors and beds, not triage

NetLogo uses a different random generator, so expect similar but not identical numbers.
