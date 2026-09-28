; =====================================================================
;  Emergency department under a mass casualty incident (MCI)
;  Multi-agent model: patient, triage, bed manager, doctor, incident command
;  One tick = one minute.
; =====================================================================

extensions [ csv table ]

breed [ patients patient ]
breed [ doctors doctor ]
breed [ triagers triager ]          ; the triage agent (1 or 2 nurses)
breed [ bedmanagers bedmanager ]
breed [ commanders commander ]      ; incident command
breed [ nurses nurse ]              ; decorative only (second triage nurse)

globals [
  ; scenario
  scenario arrivals-table prenote-table arrival-counts n-scenario n-arrived
  ; state + bookkeeping
  mci? mci-declared-at records msg-counts msg-log
  deaths deaths-waiting deaths-treatment preventable-deaths lwbs discharged admitted transferred
  the-triager the-bed-manager the-commander
  waiting-patches bedq-patches desk-patches bed-patches doc-counter
  untreated-stages pre-doctor-stages
  ; constants (see setup-constants)
  max-minutes arrival-check-min grace
  det-a det-b frailty-sd in-bed-factor recovery-rate mort-centre mort-slope patience-means
  paired-time-factor solo-error-sd paired-error-sd mci-triage-factor mci-extra-error-sd visible-critical
  eval-times diag-times reassess-time doc-log-sd mci-doc-factor disposition-probs
  surge-activation oncall-delay transfer-transport boarding-transfer-after ward-release-per-hour
  check-interval window horizon prenotify-lead standdown-quiet
  bg-per-hour bg-duration incident-start
]

turtles-own [ agent-name inbox mci-belief? ]

patients-own [
  pid arrival severity init-severity true-level source transport stage frailty patience
  est-severity assigned-level expectant-at-triage? my-bed doomed? p-timer resume-remaining
  t-triage-start t-triage-end t-bed t-doctor t-disp t-out disposition died-waiting?
]
doctors-own [ on-call? available-from current-patient doc-task remaining busy-minutes preemptions home-patch ]
triagers-own [ station-patients station-remaining queue expected-urgent paired? ]
bedmanagers-own [ waiting boarders transfers surge-open-at ward-free ]
commanders-own [ prenotified last-trigger forecast ]
patches-own [ zone bed-kind bed-id bed-order occupant bed-open? ]

; =====================================================================
;  SETUP
; =====================================================================
to setup
  clear-all
  setup-constants
  ifelse scenario-source = "file" [ load-scenario ] [ generate-scenario ]
  random-seed sim-seed
  index-scenario
  build-floor
  create-staff
  set mci? false
  set mci-declared-at -1
  set records []
  set msg-counts table:make
  set msg-log []
  set n-arrived 0
  reset-ticks
end

to setup-constants
  set max-minutes 1440
  set arrival-check-min 1
  set grace 10                        ; tolerance on MTS targets when calling a wait "late"
  ; patient deterioration while untreated: dS/dt = a * exp(b * (S - 10)) * frailty
  set det-a 0.03
  set det-b 0.53
  set frailty-sd 0.3
  set in-bed-factor 0.5               ; slower once monitored in a bed
  set recovery-rate 0.01
  set mort-centre 9.6                 ; mortality once treated: logistic(slope * (S - centre))
  set mort-slope 5
  set patience-means [300 180 120]    ; LWBS patience for true MTS 3, 4, 5 (minutes)
  ; triage
  set paired-time-factor 0.65
  set solo-error-sd 0.8
  set paired-error-sd 0.5
  set mci-triage-factor 0.6
  set mci-extra-error-sd 0.3
  set visible-critical 8.5
  ; doctors
  set eval-times [30 25 20 12 10]     ; by assigned MTS level
  set diag-times [45 60 75 30 20]     ; by true MTS level
  set reassess-time 10
  set doc-log-sd 0.35
  set mci-doc-factor 0.8
  set disposition-probs [[0.75 0.25] [0.6 0.1] [0.3 0.02] [0.05 0] [0 0]]   ; [admit transfer], rest discharge
  ; hospital
  set surge-activation 30
  set oncall-delay 45
  set transfer-transport 30
  set boarding-transfer-after 60
  set ward-release-per-hour 2
  ; incident command
  set check-interval 5
  set window 30
  set horizon 30
  set prenotify-lead 15
  set standdown-quiet 60
  ; scenario generator
  set bg-per-hour 4.5
  set bg-duration 480
  set incident-start 60
  set untreated-stages ["arrival" "waiting-triage" "in-triage" "waiting-bed"]
  set pre-doctor-stages ["arrival" "waiting-triage" "in-triage" "waiting-bed" "waiting-doctor"]
end

; ---------------------------------------------------------------- scenario
; One row per patient: [id arrival-minute severity source transport]
; Casualties are generated in a fixed order from scenario-seed, so the
; N-casualty scenario is exactly the first N casualties of any bigger one.
to generate-scenario
  let rows []
  random-seed scenario-seed
  let t random-exponential (60 / bg-per-hour)
  let i 0
  while [ t < bg-duration ] [
    let lvl draw-level [0.03 0.12 0.35 0.42 0.08]
    let amb? (random-float 1) < (item (lvl - 1) [0.8 0.5 0.3 0.1 0.02])
    set rows lput (list (word "B" i) (floor t) (draw-severity lvl) "background" (ifelse-value amb? ["ambulance"] ["walk-in"])) rows
    set i i + 1
    set t t + random-exponential (60 / bg-per-hour)
  ]
  random-seed (scenario-seed + 100000)
  set i 0
  while [ i < casualties ] [
    let lvl draw-level [0.15 0.15 0.2 0.42 0.08]
    let amb? (random-float 1) < (item (lvl - 1) [0.95 0.85 0.5 0.15 0.05])
    let sev draw-severity lvl
    let delay 0
    ifelse amb?
      [ set delay 20 + random-gamma 2 (1 / (item (lvl - 1) [15 25 40 50 50])) ]
      [ set delay 10 + random-gamma 2 (1 / 15) ]
    set rows lput (list (word "M" i) (floor (incident-start + delay)) sev "incident" (ifelse-value amb? ["ambulance"] ["walk-in"])) rows
    set i i + 1
  ]
  set scenario rows
end

to-report draw-level [ mix ]
  let r random-float 1
  let acc 0
  let k 0
  while [ k < 5 ] [
    set acc acc + (item k mix)
    if r < acc [ report k + 1 ]
    set k k + 1
  ]
  report 5
end

to-report draw-severity [ lvl ]
  let lo item (lvl - 1) [8 6 4 2 0.3]
  let hi item (lvl - 1) [9.6 8 6 4 2]
  report precision (lo + random-float (hi - lo)) 2
end

; CSV with header: patient_id, arrival_minute, severity [, source, transport]
to load-scenario
  let raw csv:from-file scenario-file
  let header first raw
  let id-i position "patient_id" header
  let arr-i position "arrival_minute" header
  let sev-i position "severity" header
  let src-i position "source" header
  let trn-i position "transport" header
  let rows filter [ r -> length r >= 3 ] (but-first raw)
  set scenario map [ r -> (list (item id-i r) (item arr-i r) (item sev-i r)
                               (ifelse-value (src-i = false) ["incident"] [item src-i r])
                               (ifelse-value (trn-i = false) ["walk-in"] [item trn-i r])) ] rows
end

to export-scenario
  csv:to-file (word "scenario_" casualties "_seed" scenario-seed ".csv")
    fput ["patient_id" "arrival_minute" "severity" "source" "transport"] scenario
  output-print "scenario exported"
end

to index-scenario
  set arrivals-table table:make
  set prenote-table table:make
  set arrival-counts table:make
  foreach scenario [ row ->
    let a floor (item 1 row)
    table:put arrivals-table a (lput row (tget arrivals-table a))
    if item 4 row = "ambulance" [
      let pt max list 0 (a - prenotify-lead)
      table:put prenote-table pt (lput row (tget prenote-table pt))
    ]
  ]
  set n-scenario length scenario
end

; ---------------------------------------------------------------- floor plan
to build-floor
  ask patches [
    set zone "" set bed-kind "" set bed-id "" set bed-order 0 set occupant nobody set bed-open? false
    set pcolor black
  ]
  set waiting-patches patches with [ pxcor >= 1 and pxcor <= 9 and pycor >= 2 and pycor <= 20 ]
  ask waiting-patches [ set zone "waiting" set pcolor 2 ]
  set bedq-patches patches with [ pxcor >= 15 and pxcor <= 20 and pycor >= 2 and pycor <= 20 ]
  ask bedq-patches [ set zone "bed-queue" set pcolor 2 ]
  set desk-patches (list (patch 12 13) (patch 12 9))
  ask patch 12 13 [ set pcolor pink - 2 ]
  if co-triage? and co-triage-mode = "parallel" [ ask patch 12 9 [ set pcolor pink - 2 ] ]
  place-beds "resus" resus-beds 23
  place-beds "general" general-beds 20
  place-beds "surge" surge-beds 11
  place-beds "chair" chairs 6
  set bed-patches patches with [ bed-kind != "" ]
  ask patch 8 22 [ set plabel "Waiting room" ]
  ask patch 14 16 [ set plabel "Triage" ]
  ask patch 21 22 [ set plabel "Wait for bed" ]
  ask patch 44 24 [ set plabel "Resus" ]
  ask patch 44 21 [ set plabel "ED beds" ]
  ask patch 44 12 [ set plabel "Surge" ]
  ask patch 44 7 [ set plabel "Chairs" ]
end

to place-beds [ kind n top-y ]
  let i 0
  while [ i < n ] [
    ask patch (24 + 2 * (i mod 10)) (top-y - 2 * floor (i / 10)) [
      set bed-kind kind
      set bed-id (word kind "-" (i + 1))
      set bed-order i
      set occupant nobody
      set bed-open? (kind != "surge")
      recolor-bed
    ]
    set i i + 1
  ]
end

to recolor-bed  ; patch procedure
  ifelse not bed-open? [ set pcolor 1 ] [
    if bed-kind = "resus" [ set pcolor red - 3 ]
    if bed-kind = "general" [ set pcolor 5 ]
    if bed-kind = "surge" [ set pcolor 4 ]
    if bed-kind = "chair" [ set pcolor brown - 2 ]
  ]
end

; ---------------------------------------------------------------- staff
to create-staff
  create-commanders 1 [
    set agent-name "command" set inbox [] set mci-belief? false
    set prenotified [] set last-trigger -1 set forecast 0
    set shape "person" set color gray set size 1.4 setxy 1 23 set label "Incident cmd"
    set the-commander self
  ]
  create-triagers 1 [
    set agent-name "triage" set inbox [] set mci-belief? false
    set paired? (co-triage? and co-triage-mode = "paired")
    let n ifelse-value (co-triage? and co-triage-mode = "parallel") [2] [1]
    set station-patients n-values n [ nobody ]
    set station-remaining n-values n [ 0 ]
    set queue []
    set expected-urgent []
    set shape "person" set color pink set size 1.2 setxy 13 13
    set the-triager self
  ]
  if co-triage? [
    create-nurses 1 [
      set agent-name "nurse-2" set inbox [] set mci-belief? false
      set shape "person" set color pink set size 1.2
      ifelse co-triage-mode = "parallel" [ setxy 13 9 ] [ setxy 11 13 ]
    ]
  ]
  create-bedmanagers 1 [
    set agent-name "bed_manager" set inbox [] set mci-belief? false
    set waiting [] set boarders [] set transfers [] set surge-open-at -1 set ward-free free-ward-beds
    set shape "person" set color violet set size 1.4 setxy 22 23 set label "Bed mgr"
    set the-bed-manager self
  ]
  set doc-counter 0
  create-doctors n-doctors [ setup-doctor false ]
  create-doctors oncall-doctors [ setup-doctor true ]
end

to setup-doctor [ oc ]  ; doctor procedure
  set on-call? oc
  set agent-name (word (ifelse-value oc ["oncall_"] ["doctor_"]) doc-counter)
  set inbox [] set mci-belief? false
  set available-from ifelse-value oc [1000000000] [0]
  set current-patient nobody
  set doc-task ""
  set remaining 0 set busy-minutes 0 set preemptions 0
  set shape "person" set color sky set size 1.1
  set home-patch patch (23 + 2 * (doc-counter mod 11)) 0
  set doc-counter doc-counter + 1
  move-to home-patch
  set hidden? oc
end

; =====================================================================
;  GO
; =====================================================================
to go
  if sim-finished? [ stop ]
  inject
  ask the-commander [ command-step ]
  ask patients [ patient-step ]
  ask the-triager [ triage-step ]
  ask the-bed-manager [ bm-step ]
  ask doctors [ doctor-step ]          ; random order every tick
  ask patients [ set color patient-color ]
  ask the-commander [ set color ifelse-value mci-belief? [red] [gray] ]
  tick
end

to-report sim-finished?
  report ticks >= max-minutes or (ticks > 0 and n-arrived = n-scenario and not any? patients)
end

; new arrivals + ambulance pre-notifications (sent 15 min ahead)
to inject
  foreach tget prenote-table ticks [ row ->
    let reported level-of (max list 0 (min list 10 ((item 2 row) + random-normal 0 0.8)))
    send-msg "ambulance_dispatch" the-commander "PRENOTIFY" (list (item 0 row) (floor (item 1 row)) reported)
  ]
  foreach tget arrivals-table ticks [ row ->
    create-patients 1 [ init-patient row ]
    set n-arrived n-arrived + 1
    table:put arrival-counts ticks (1 + tget-num arrival-counts ticks)
  ]
end

; =====================================================================
;  PATIENT
; =====================================================================
to init-patient [ row ]
  set pid item 0 row
  set arrival floor (item 1 row)
  set severity item 2 row
  set init-severity severity
  set true-level level-of severity
  set source item 3 row
  set transport item 4 row
  set agent-name (word "patient_" pid)
  set inbox [] set mci-belief? false
  set stage "arrival"
  set frailty exp (random-normal 0 frailty-sd)
  set patience ifelse-value (true-level >= 3)
    [ 30 + random-exponential (item (true-level - 3) patience-means) ] [ 1000000000 ]
  set est-severity -1 set assigned-level 0 set expectant-at-triage? false
  set my-bed nobody set doomed? false set p-timer 0 set resume-remaining -1
  set t-triage-start -1 set t-triage-end -1 set t-bed -1 set t-doctor -1 set t-disp -1 set t-out -1
  set disposition "" set died-waiting? false
  set shape "person" set size 0.9 set color white
  move-to one-of waiting-patches
end

to patient-step
  update-severity
  if member? stage pre-doctor-stages and severity >= 10 [
    set died-waiting? true
    finish-patient "deceased" agent-name
    stop
  ]
  if stage = "arrival" [
    if ticks - arrival >= arrival-check-min [
      set stage "waiting-triage"
      send-msg agent-name the-triager "ARRIVED" self
    ]
    stop
  ]
  ; goal-directed: a patient who feels well enough and waited too long gives up
  if (stage = "waiting-triage" or stage = "waiting-bed") and (level-of severity) >= 3 and (ticks - arrival) > patience [
    finish-patient "lwbs" agent-name
    stop
  ]
  if stage = "diagnostics" [
    set p-timer p-timer - 1
    if p-timer <= 0 [ set stage "waiting-reassess" ]
  ]
end

to update-severity
  ifelse member? stage pre-doctor-stages [
    let f ifelse-value (stage = "waiting-doctor") [ in-bed-factor ] [ 1 ]
    let rate det-a * exp (det-b * (severity - 10))
    set severity min list 10 (severity + rate * f * frailty)
  ] [
    set severity max list 0.5 (severity - recovery-rate)
  ]
end

; ends a patient's stay: counts the outcome, records it and removes the turtle
to finish-patient [ disp by ]
  set disposition disp
  set t-out ticks
  if disp = "deceased" [
    set deaths deaths + 1
    ifelse died-waiting? [ set deaths-waiting deaths-waiting + 1 ] [ set deaths-treatment deaths-treatment + 1 ]
    if init-severity < expectant-threshold [ set preventable-deaths preventable-deaths + 1 ]
  ]
  if disp = "lwbs" [ set lwbs lwbs + 1 ]
  if disp = "discharged" [ set discharged discharged + 1 ]
  if disp = "admitted" [ set admitted admitted + 1 ]
  if disp = "transferred" [ set transferred transferred + 1 ]
  set records lput patient-record records
  if my-bed != nobody [ ask my-bed [ if occupant = myself [ set occupant nobody ] ] ]
  if by != "bed_manager" [ send-msg by the-bed-manager "PATIENT_LEFT" pid ]
  die
end

; [0 pid 1 source 2 transport 3 arrival 4 init-severity 5 true-level 6 est-severity 7 assigned-level
;  8 t-triage-start 9 t-triage-end 10 t-bed 11 t-doctor 12 t-out 13 disposition 14 died-waiting?]
to-report patient-record
  report (list pid source transport arrival init-severity true-level (precision est-severity 2) assigned-level
               t-triage-start t-triage-end t-bed t-doctor t-out disposition died-waiting?)
end

to-report patient-color
  if assigned-level = 0 [ report white ]
  if mci? and est-severity >= expectant-threshold [ report gray - 2 ]
  report mts-color assigned-level
end

; =====================================================================
;  TRIAGE AGENT
; =====================================================================
to triage-step
  foreach take-inbox [ m ->
    handle-common m
    if first m = "ARRIVED" [ set queue lput (item 1 m) queue ]
    if first m = "EXPECT_URGENT" [ set expected-urgent lput (item 1 m) expected-urgent ]
  ]
  set queue filter [ p -> p != nobody ] queue
  let i 0
  while [ i < length station-patients ] [
    let p item i station-patients
    if p != nobody [
      set station-remaining replace-item i station-remaining ((item i station-remaining) - 1)
      if (item i station-remaining) <= 0 [
        complete-triage p
        set station-patients replace-item i station-patients nobody
        set p nobody
      ]
    ]
    if p = nobody and not empty? queue [
      let nxt next-triage-patient
      let desk item i desk-patches
      ask nxt [ set stage "in-triage" set t-triage-start ticks move-to desk ]
      set station-patients replace-item i station-patients nxt
      set station-remaining replace-item i station-remaining triage-duration
    ]
    set i i + 1
  ]
end

; obviously critical patients and ambulance patients announced as urgent jump the queue
to-report next-triage-patient
  let eu expected-urgent
  let crit filter [ p -> [severity] of p >= visible-critical or member? ([pid] of p) eu ] queue
  let pick first queue
  if not empty? crit [ set pick first crit ]
  set queue remove pick queue
  report pick
end

to-report triage-duration
  let m triage-time
  if paired? [ set m m * paired-time-factor ]
  if mci-belief? [ set m m * mci-triage-factor ]
  report max list 0.5 (lognormal m 0.35)
end

to complete-triage [ p ]
  let sd ifelse-value paired? [ paired-error-sd ] [ solo-error-sd ]
  if mci-belief? [ set sd sd + mci-extra-error-sd ]
  let tri-mci mci-belief?
  ask p [
    set est-severity max list 0 (min list 10 (severity + random-normal 0 sd))
    set assigned-level level-of est-severity
    set expectant-at-triage? (tri-mci and est-severity >= expectant-threshold)
    set t-triage-end ticks
    set stage "waiting-bed"
    move-to one-of bedq-patches
  ]
  send-msg agent-name the-bed-manager "TRIAGED" p
end

; =====================================================================
;  BED MANAGER
; =====================================================================
to bm-step
  foreach take-inbox [ m ->
    handle-common m
    if first m = "TRIAGED" [ set waiting lput (item 1 m) waiting ]
    if first m = "MCI_DECLARED" [
      if surge-open-at < 0 and any? bed-patches with [ not bed-open? ] [ set surge-open-at ticks + surge-activation ]
    ]
    if first m = "DISPOSITION" [ dispose (first item 1 m) (last item 1 m) ]
  ]
  set waiting filter [ p -> p != nobody ] waiting
  set boarders filter [ p -> p != nobody ] boarders
  set transfers filter [ p -> p != nobody ] transfers

  if surge-open-at >= 0 and ticks >= surge-open-at [
    ask bed-patches with [ not bed-open? ] [ set bed-open? true recolor-bed ]
    log-event "Bed manager opened surge beds"
    set surge-open-at -1
  ]

  ; ward beds free up over time; boarders move up by priority
  set ward-free ward-free + ward-release-per-hour / 60
  set boarders sort-by [ [a b] -> key-less? (prio-key a false) (prio-key b false) ] boarders
  while [ not empty? boarders and ward-free >= 1 ] [
    let p first boarders
    set boarders but-first boarders
    set ward-free ward-free - 1
    ask p [ finish-patient "admitted" "bed_manager" ]
  ]
  ; proactive: in MCI mode, long boarders go to other hospitals to free ED beds
  if mci-belief? [
    foreach boarders [ p ->
      if ticks - [t-disp] of p >= boarding-transfer-after [
        set boarders remove p boarders
        start-transfer p
      ]
    ]
  ]
  foreach transfers [ p ->
    ask p [ set p-timer p-timer - 1 ]
    if [p-timer] of p <= 0 [
      set transfers remove p transfers
      ask p [ finish-patient "transferred" "bed_manager" ]
    ]
  ]
  place-waiting
  request-preemption
end

; priority: normal mode = most severe first; MCI mode = expectant patients go last
to-report prio-key [ p use-mci ]
  let is-expectant? use-mci and [est-severity] of p >= expectant-threshold
  report (list (ifelse-value is-expectant? [1] [0]) ([assigned-level] of p) ([t-triage-end] of p))
end

to-report key-less? [ k1 k2 ]
  if empty? k1 [ report false ]
  if first k1 < first k2 [ report true ]
  if first k1 > first k2 [ report false ]
  report key-less? (but-first k1) (but-first k2)
end

to-report eligible-kinds [ p use-mci ]
  if use-mci and [est-severity] of p >= expectant-threshold [ report ["general" "surge"] ]
  let lvl [assigned-level] of p
  if lvl = 1 [ report ["resus" "general" "surge"] ]
  if lvl <= 3 [ report ["general" "surge"] ]
  if use-mci [ report ["chair"] ]
  report ["chair" "general"]
end

to place-waiting
  let m mci-belief?
  foreach sort-by [ [a b] -> key-less? (prio-key a m) (prio-key b m) ] waiting [ p ->
    let placed? false
    foreach eligible-kinds p m [ k ->
      if not placed? [
        let free-beds bed-patches with [ bed-kind = k and bed-open? and occupant = nobody ]
        if any? free-beds [
          let b min-one-of free-beds [ bed-order ]
          ask b [ set occupant p ]
          ask p [ set my-bed b set stage "waiting-doctor" set t-bed ticks move-to b ]
          set waiting remove p waiting
          set placed? true
        ]
      ]
    ]
  ]
end

; if red/orange patients lie in a bed with no free doctor, ask the doctor on the
; least urgent task to hand over (the doctor decides and yields)
to request-preemption
  let m mci-belief?
  let urgent patients with [ stage = "waiting-doctor" and assigned-level <= 2 and not (m and est-severity >= expectant-threshold) ]
  if not any? urgent [ stop ]
  let active-docs doctors with [ ticks >= available-from ]
  let need (count urgent) - (count active-docs with [ current-patient = nobody ])
  if need <= 0 [ stop ]
  let busy active-docs with [ current-patient != nobody and
    ([stage] of current-patient = "evaluation" or [stage] of current-patient = "reassessment") and
    ([assigned-level] of current-patient >= 3 or (m and [est-severity] of current-patient >= expectant-threshold)) ]
  let ordered sort-by [ [a b] -> key-less? (prio-key ([current-patient] of b) m) (prio-key ([current-patient] of a) m) ] (sort busy)
  foreach sublist ordered 0 (min list need (length ordered)) [ d ->
    send-msg agent-name d "PREEMPT" ([current-patient] of d)
  ]
end

; a doctor asks for work: highest-priority patient in a bed needing evaluation or reassessment
to-report next-task
  let m mci-belief?
  let cands patients with [ my-bed != nobody and (stage = "waiting-doctor" or stage = "waiting-reassess") ]
  if not any? cands [ report nobody ]
  report first sort-by [ [a b] -> key-less? (task-key a m) (task-key b m) ] (sort cands)
end

to-report task-key [ p m ]
  let k prio-key p m
  report (list (item 0 k) (item 1 k) (ifelse-value ([stage] of p = "waiting-reassess") [0] [1]) (item 2 k))
end

to dispose [ p outcome ]
  ask p [ set t-disp ticks ]
  if outcome = "discharged" [
    ask p [ finish-patient "discharged" "bed_manager" ]
    stop
  ]
  if outcome = "admitted" [
    ifelse not ward-boarding? [
      ask p [ finish-patient "admitted" "bed_manager" ]
    ] [
      ifelse ward-free >= 1 [
        set ward-free ward-free - 1
        ask p [ finish-patient "admitted" "bed_manager" ]
      ] [
        ask p [ set stage "boarding" ]
        set boarders lput p boarders
      ]
    ]
    stop
  ]
  start-transfer p
end

to start-transfer [ p ]
  ask p [ set stage "awaiting-transfer" set p-timer transfer-transport ]
  set transfers lput p transfers
end

; =====================================================================
;  DOCTOR
; =====================================================================
to doctor-step
  foreach take-inbox [ m ->
    handle-common m
    if first m = "CALL_IN" and on-call? and available-from > 100000 [ set available-from item 1 m ]
    if first m = "PREEMPT" and current-patient != nobody and current-patient = item 1 m [
      let p current-patient
      let rem remaining
      let tsk doc-task
      ask p [
        set resume-remaining rem
        set stage ifelse-value (tsk = "evaluation") [ "waiting-doctor" ] [ "waiting-reassess" ]
      ]
      set current-patient nobody
      set doc-task ""
      set preemptions preemptions + 1
    ]
  ]
  if ticks < available-from [ stop ]
  if hidden? [ show-turtle ]
  if doc-task != "" and current-patient = nobody [ set doc-task "" ]
  if current-patient != nobody [
    set busy-minutes busy-minutes + 1
    set remaining remaining - 1
    if remaining <= 0 [ complete-task ]
  ]
  if current-patient = nobody [
    count-msg "REQUEST_WORK"
    let p [next-task] of the-bed-manager
    ifelse p != nobody [ start-task p ] [ move-to home-patch ]
  ]
end

to start-task [ p ]
  set current-patient p
  ifelse [resume-remaining] of p >= 0 [
    ; resume an interrupted task
    set doc-task ifelse-value ([stage] of p = "waiting-doctor") [ "evaluation" ] [ "reassessment" ]
    set remaining [resume-remaining] of p
    let tsk doc-task
    ask p [ set stage tsk set resume-remaining -1 ]
  ] [
    ifelse [stage] of p = "waiting-doctor" [
      set doc-task "evaluation"
      let p-death 1 / (1 + exp (0 - mort-slope * ([severity] of p - mort-centre)))
      ask p [ set stage "evaluation" set t-doctor ticks set doomed? (random-float 1 < p-death) ]
      set remaining doc-time (item (([assigned-level] of p) - 1) eval-times)
    ] [
      set doc-task "reassessment"
      ask p [ set stage "reassessment" ]
      set remaining doc-time reassess-time
    ]
  ]
  move-to [my-bed] of p
  set xcor xcor + 0.4
end

to complete-task
  let p current-patient
  let tsk doc-task
  set current-patient nobody
  set doc-task ""
  if tsk = "evaluation" [
    ifelse [doomed?] of p [
      ask p [ finish-patient "deceased" "doctor" ]
    ] [
      let d doc-time (item (([true-level] of p) - 1) diag-times)
      ask p [ set stage "diagnostics" set p-timer d ]
    ]
    stop
  ]
  ; reassessment: decide disposition and tell the bed manager
  let probs item (([true-level] of p) - 1) disposition-probs
  let r random-float 1
  let outcome "discharged"
  if r < (item 0 probs) + (item 1 probs) [ set outcome "transferred" ]
  if r < item 0 probs [ set outcome "admitted" ]
  send-msg agent-name the-bed-manager "DISPOSITION" (list p outcome)
end

to-report doc-time [ mean-time ]
  let mm mean-time
  if mci-belief? [ set mm mm * mci-doc-factor ]
  report max list 1 (lognormal mm doc-log-sd)
end

; =====================================================================
;  INCIDENT COMMAND
; =====================================================================
to command-step
  foreach take-inbox [ m ->
    if first m = "PRENOTIFY" [
      let info item 1 m                     ; [pid eta level]
      set prenotified lput (list (item 1 info) (item 2 info)) prenotified
      if item 2 info <= 2 [ send-msg agent-name the-triager "EXPECT_URGENT" (item 0 info) ]
    ]
  ]
  set prenotified filter [ x -> first x > ticks ] prenotified
  if (ticks mod check-interval) != 0 [ stop ]
  let arrivals arrivals-between (ticks - window) ticks
  let incoming length filter [ x -> first x <= ticks + horizon ] prenotified
  let waiting-n (length [queue] of the-triager) + (length [waiting] of the-bed-manager)
  let free-n count bed-patches with [ bed-open? and occupant = nobody ]
  set forecast arrivals * horizon / window + incoming
  let reason ""
  if arrivals >= mci-threshold [
    set reason (word arrivals " arrivals in last " window " min") ]
  if reason = "" and proactive-command? and forecast >= mci-threshold [
    set reason (word "forecast " round forecast " arrivals in next " horizon " min (" incoming " pre-notified)") ]
  if reason = "" and proactive-command? and forecast >= mci-threshold / 2 and forecast + waiting-n > free-n [
    set reason (word "forecast demand " round (forecast + waiting-n) " exceeds " free-n " free places") ]
  ifelse reason != "" [
    set last-trigger ticks
    if not mci-belief? [
      set mci-belief? true
      set mci? true
      if mci-declared-at < 0 [ set mci-declared-at ticks ]
      log-event (word "Incident command DECLARES MCI: " reason)
      broadcast agent-name "MCI_DECLARED" reason
      foreach sort doctors with [ on-call? and available-from > 100000 ] [ d ->
        send-msg agent-name d "CALL_IN" (ticks + oncall-delay)
      ]
    ]
  ] [
    if mci-belief? and waiting-n = 0 and incoming = 0 and arrivals < mci-threshold / 4
       and ticks - last-trigger >= standdown-quiet [
      set mci-belief? false
      set mci? false
      log-event "Incident command STANDS DOWN: queues cleared, arrivals back to normal"
      broadcast agent-name "STAND_DOWN" 0
    ]
  ]
end

to-report arrivals-between [ t0 t1 ]
  let s 0
  let t max list 0 (t0 + 1)
  while [ t <= t1 ] [
    set s s + tget-num arrival-counts t
    set t t + 1
  ]
  report s
end

; =====================================================================
;  MESSAGING
; =====================================================================
; message = [kind payload sender-name]
to send-msg [ sender-name receiver kind payload ]
  count-msg kind
  set msg-log lput (word "t=" ticks " " sender-name " -> " [agent-name] of receiver " : " kind) msg-log
  if length msg-log > 300 [ set msg-log but-first msg-log ]
  ask receiver [ set inbox lput (list kind payload sender-name) inbox ]
end

to broadcast [ sender-name kind payload ]
  foreach sort turtles with [ breed = triagers or breed = bedmanagers or breed = doctors ] [ r ->
    send-msg sender-name r kind payload
  ]
end

to count-msg [ kind ]
  table:put msg-counts kind (1 + tget-num msg-counts kind)
end

to-report take-inbox
  let msgs inbox
  set inbox []
  report msgs
end

to handle-common [ m ]
  if first m = "MCI_DECLARED" [ set mci-belief? true ]
  if first m = "STAND_DOWN" [ set mci-belief? false ]
end

to log-event [ text ]
  output-print (word "t=" ticks "  " text)
end

to show-messages
  output-print "--- last 25 messages ---"
  foreach sublist msg-log (max list 0 (length msg-log - 25)) (length msg-log) [ s -> output-print s ]
  output-print (word "--- totals: " table:to-list msg-counts)
end

; =====================================================================
;  HELPERS
; =====================================================================
to-report tget [ tbl key ]
  ifelse table:has-key? tbl key [ report table:get tbl key ] [ report [] ]
end

to-report tget-num [ tbl key ]
  ifelse table:has-key? tbl key [ report table:get tbl key ] [ report 0 ]
end

to-report lognormal [ m sd ]
  let mu (ln (max list m 0.000001)) - sd * sd / 2
  report exp (mu + sd * random-normal 0 1)
end

to-report level-of [ s ]    ; Manchester Triage System level from severity (0 well .. 10 dead)
  if s >= 8 [ report 1 ]
  if s >= 6 [ report 2 ]
  if s >= 4 [ report 3 ]
  if s >= 2 [ report 4 ]
  report 5
end

to-report mts-target [ lvl ]  ; max minutes to see a doctor
  report item (lvl - 1) [0 10 60 120 240]
end

to-report mts-color [ lvl ]
  report item (lvl - 1) (list red orange yellow green blue)
end

to-report percentile [ xs q ]
  if empty? xs [ report 0 ]
  let s sort xs
  let idx (q / 100) * (length s - 1)
  let lo floor idx
  let hi ceiling idx
  report (item lo s) + (idx - lo) * ((item hi s) - (item lo s))
end

; =====================================================================
;  OUTPUT METRICS (monitors, plots, BehaviorSpace)
; =====================================================================
to-report n-waiting-triage report count patients with [ stage = "arrival" or stage = "waiting-triage" or stage = "in-triage" ] end
to-report n-waiting-bed report count patients with [ stage = "waiting-bed" ] end
to-report n-waiting-doctor report count patients with [ stage = "waiting-doctor" ] end
to-report n-in-treatment report count patients with [ member? stage ["evaluation" "diagnostics" "waiting-reassess" "reassessment"] ] end
to-report n-boarding report count patients with [ stage = "boarding" or stage = "awaiting-transfer" ] end
to-report n-beds-occupied report count bed-patches with [ occupant != nobody ] end
to-report n-beds-open report count bed-patches with [ bed-open? ] end
to-report n-doctors-busy report count doctors with [ current-patient != nobody ] end
to-report n-doctors-active report count doctors with [ ticks >= available-from ] end
to-report total-messages report sum table:values msg-counts end
to-report n-incident report length filter [ r -> item 3 r = "incident" ] scenario end
to-report unresolved report count patients end
to-report mode-label report ifelse-value mci? ["MCI"] ["normal"] end

to-report late-record? [ r ]
  report (item 11 r) < 0 or ((item 11 r) - (item 3 r)) > ((mts-target (item 5 r)) + grace)
end

; share of true red/orange patients not seen by a doctor within MTS target + grace
to-report critical-delay-rate
  let crit filter [ r -> (item 5 r) <= 2 ] records
  let late-n length filter [ r -> late-record? r ] crit
  let alive patients with [ true-level <= 2 ]
  let late-alive count alive with [ t-doctor < 0 or (t-doctor - arrival) > ((mts-target true-level) + grace) ]
  let n (length crit) + (count alive)
  if n = 0 [ report 0 ]
  report (late-n + late-alive) / n
end

to-report p90-door-to-triage
  let xs map [ r -> (item 8 r) - (item 3 r) ] filter [ r -> (item 8 r) >= 0 ] records
  set xs sentence xs ([ t-triage-start - arrival ] of patients with [ t-triage-start >= 0 ])
  report percentile xs 90
end

to-report under-triage-rate
  let tri filter [ r -> (item 7 r) > 0 ] records
  let n (length tri) + (count patients with [ assigned-level > 0 ])
  if n = 0 [ report 0 ]
  report ((length filter [ r -> (item 7 r) > (item 5 r) ] tri) + (count patients with [ assigned-level > true-level ])) / n
end

to-report median-door-to-doctor [ lvl ]
  let xs map [ r -> (item 11 r) - (item 3 r) ] filter [ r -> (item 5 r) = lvl and (item 11 r) >= 0 ] records
  set xs sentence xs ([ t-doctor - arrival ] of patients with [ true-level = lvl and t-doctor >= 0 ])
  if empty? xs [ report -1 ]
  report median xs
end

to export-patients
  let rows sentence records ([ patient-record ] of patients)
  csv:to-file (word "patients_" casualties "_" (ifelse-value co-triage? ["co"] ["single"]) "_seed" sim-seed ".csv")
    fput ["patient_id" "source" "transport" "arrival" "initial_severity" "true_level" "est_severity" "assigned_level"
          "t_triage_start" "t_triage_end" "t_bed" "t_doctor" "t_out" "disposition" "died_waiting"] rows
  output-print "patient table exported"
end
@#$#@#$#@
GRAPHICS-WINDOW
235
10
873
378
-1
-1
14.0
1
10
1
1
1
0
0
0
1
0
44
0
24
1
1
1
minutes
30.0

BUTTON
5
10
75
43
setup
setup
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
80
10
150
43
go
go
T
1
T
OBSERVER
NIL
NIL
NIL
NIL
0

BUTTON
155
10
225
43
step
go
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
0

CHOOSER
5
50
225
95
scenario-source
scenario-source
"generate" "file"
0

SLIDER
5
100
225
133
casualties
casualties
0
300
80.0
10
1
NIL
HORIZONTAL

SLIDER
5
138
225
171
scenario-seed
scenario-seed
1
100
7.0
1
1
NIL
HORIZONTAL

INPUTBOX
5
176
225
236
scenario-file
scenarios/mci_080.csv
1
0
String

SLIDER
5
241
225
274
sim-seed
sim-seed
1
1000
1.0
1
1
NIL
HORIZONTAL

TEXTBOX
8
282
225
300
Triage (the experiment variable)
11
0.0
1

SWITCH
5
300
225
333
co-triage?
co-triage?
1
1
-1000

CHOOSER
5
338
225
383
co-triage-mode
co-triage-mode
"paired" "parallel"
0

SLIDER
5
388
225
421
triage-time
triage-time
1
10
4.0
0.5
1
min
HORIZONTAL

SLIDER
5
426
225
459
expectant-threshold
expectant-threshold
8
10
9.2
0.1
1
NIL
HORIZONTAL

MONITOR
5
470
80
515
minute
ticks
0
1
11

MONITOR
80
470
155
515
mode
mode-label
0
1
11

MONITOR
155
470
225
515
in ED
count patients
0
1
11

MONITOR
5
520
80
565
deaths
deaths
0
1
11

MONITOR
80
520
155
565
died waiting
deaths-waiting
0
1
11

MONITOR
155
520
225
565
preventable
preventable-deaths
0
1
11

MONITOR
5
570
80
615
left unseen
lwbs
0
1
11

MONITOR
80
570
155
615
red/orange late
critical-delay-rate
2
1
11

MONITOR
155
570
225
615
p90 to triage
p90-door-to-triage
0
1
11

MONITOR
5
620
80
665
under-triage
under-triage-rate
2
1
11

MONITOR
80
620
155
665
messages
total-messages
0
1
11

MONITOR
155
620
225
665
MCI at
mci-declared-at
0
1
11

TEXTBOX
885
10
1100
28
Department
11
0.0
1

SLIDER
880
28
1100
61
general-beds
general-beds
4
40
24.0
1
1
NIL
HORIZONTAL

SLIDER
880
66
1100
99
resus-beds
resus-beds
0
10
3.0
1
1
NIL
HORIZONTAL

SLIDER
880
104
1100
137
chairs
chairs
0
30
12.0
1
1
NIL
HORIZONTAL

SLIDER
880
142
1100
175
surge-beds
surge-beds
0
20
10.0
1
1
NIL
HORIZONTAL

SLIDER
880
180
1100
213
n-doctors
n-doctors
1
15
4.0
1
1
NIL
HORIZONTAL

SLIDER
880
218
1100
251
oncall-doctors
oncall-doctors
0
10
3.0
1
1
NIL
HORIZONTAL

SLIDER
880
256
1100
289
free-ward-beds
free-ward-beds
0
100
20.0
1
1
NIL
HORIZONTAL

SWITCH
880
294
1100
327
ward-boarding?
ward-boarding?
0
1
-1000

TEXTBOX
885
337
1100
355
Incident command
11
0.0
1

SLIDER
880
355
1100
388
mci-threshold
mci-threshold
4
40
12.0
1
1
arrivals/30min
HORIZONTAL

SWITCH
880
393
1100
426
proactive-command?
proactive-command?
0
1
-1000

BUTTON
880
436
988
469
show messages
show-messages
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
992
436
1100
469
export patients
export-patients
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

BUTTON
880
474
1100
507
export scenario
export-scenario
NIL
1
T
OBSERVER
NIL
NIL
NIL
NIL
1

PLOT
235
385
445
565
Queues
minutes
patients
0.0
10.0
0.0
10.0
true
true
"" ""
PENS
"triage" 1.0 0 -2674135 true "" "plot n-waiting-triage"
"bed" 1.0 0 -955883 true "" "plot n-waiting-bed"
"doctor" 1.0 0 -13345367 true "" "plot n-waiting-doctor"
"boarding" 1.0 0 -8630108 true "" "plot n-boarding"

PLOT
450
385
660
565
Outcomes
minutes
patients
0.0
10.0
0.0
10.0
true
true
"" ""
PENS
"deaths" 1.0 0 -16777216 true "" "plot deaths"
"died waiting" 1.0 0 -7500403 true "" "plot deaths-waiting"
"left unseen" 1.0 0 -1184463 true "" "plot lwbs"

PLOT
665
385
873
565
Resources
minutes
count
0.0
10.0
0.0
10.0
true
true
"" ""
PENS
"beds used" 1.0 0 -10899396 true "" "plot n-beds-occupied"
"beds open" 1.0 0 -7500403 true "" "plot n-beds-open"
"doctors busy" 1.0 0 -13345367 true "" "plot n-doctors-busy"
"MCI mode" 1.0 0 -2674135 true "" "plot ifelse-value mci? [5] [0]"

OUTPUT
235
570
1100
700
11

@#$#@#$#@
## WHAT IS IT?

An agent-based model of one emergency department (ED) during a mass casualty incident. It asks how many casualties the department can absorb before waiting times become dangerous, and whether **co-triage** (two triage nurses instead of one) buys the department extra room or whether the bottleneck lies elsewhere.

## HOW IT WORKS

One tick is one minute. Five agent types:

* **Patient** - has a hidden true severity from 0 (well) to 10 (dead). Severity rises while the patient is untreated, following dS/dt = a*exp(b(S-10))*frailty, and rises half as fast once the patient is monitored in a bed. A patient dies if severity reaches 10 before a doctor arrives. Patients who feel well enough (MTS 3-5) leave without being seen once their patience runs out.
* **Triage agent** (1 or 2 nurses) - estimates severity with noise and assigns a Manchester Triage System level. Visibly critical patients and patients the ambulance pre-notified as urgent jump the queue. In MCI mode it triages faster but less accurately. Patients above the *expectant threshold* are then moved behind everyone who can still be saved.
* **Bed manager** - places patients by priority into resus bays, ED beds, surge beds or chairs. It opens surge beds once an MCI is declared and handles boarding (admitted patients waiting for a ward bed). In MCI mode it transfers long boarders to other hospitals. When a red or orange patient has no doctor, it sends a PREEMPT message to the doctor on the least urgent task.
* **Doctor** - pulls the most urgent task (first evaluation or reassessment) from the bed manager, yields when pre-empted, and decides the disposition: admit, transfer or discharge.
* **Incident command** - every 5 minutes it checks arrivals, queues, free beds and ambulance pre-notifications. It declares MCI mode *proactively* on a forecast, calls in the on-call doctors, and stands down when things are back to normal.

All coordination goes through messages (ARRIVED, TRIAGED, PREEMPT, CALL_IN, MCI_DECLARED, ...), which are counted and can be listed with *show messages*.

Patient stages: arrival check -> triage -> bed placement -> evaluation -> diagnostics + reassessment -> disposition (discharged / admitted / transferred / left unseen / deceased).

## HOW TO USE IT

1. Pick a scenario. *generate* builds one from `casualties` and `scenario-seed`; *file* reads a CSV (`patient_id, arrival_minute, severity, source, transport`).
2. Set `co-triage?` and press **setup**, then **go**.
3. For the breaking-point experiment use **Tools > BehaviorSpace > breaking-point-sweep**. It runs every size with and without co-triage for 30 seeds. Open the table output in Excel, or run `analyze_behaviorspace.py`.

Colours: patients are white until triaged, then coloured by assigned MTS level (red, orange, yellow, green, blue); dark grey = expectant. The incident-command figure turns red in MCI mode.

## THINGS TO NOTICE

With co-triage the triage queue empties faster, but the queue often just moves on to "waiting for bed" and "waiting for doctor". Watch the Queues plot.

## THINGS TO TRY

* Change `n-doctors` or `general-beds` to see whether the bottleneck moves.
* Turn off `proactive-command?` to see what a late MCI declaration costs.
* Compare `paired` vs `parallel` co-triage.

## CREDITS

MAS course team project, University of Twente: Kralev, Alagawadi, Tsompanoglou, Mohammadiyan, Pirinski.
@#$#@#$#@
default
true
0
Polygon -7500403 true true 150 5 40 250 150 205 260 250

circle
false
0
Circle -7500403 true true 0 0 300

person
false
0
Circle -7500403 true true 110 5 80
Polygon -7500403 true true 105 90 120 195 90 285 105 300 135 300 150 225 165 300 195 300 210 285 180 195 195 90
Rectangle -7500403 true true 127 79 172 94
Polygon -7500403 true true 195 90 240 150 225 180 165 105
Polygon -7500403 true true 105 90 60 150 75 180 135 105

square
false
0
Rectangle -7500403 true true 30 30 270 270
@#$#@#$#@
NetLogo 6.4.0
@#$#@#$#@
@#$#@#$#@
@#$#@#$#@
<experiments>
  <experiment name="breaking-point-sweep" repetitions="1" sequentialRunOrder="true" runMetricsEveryStep="false">
    <setup>setup</setup>
    <go>go</go>
    <timeLimit steps="1440"/>
    <exitCondition>sim-finished?</exitCondition>
    <metric>n-scenario</metric>
    <metric>deaths</metric>
    <metric>deaths-waiting</metric>
    <metric>deaths-treatment</metric>
    <metric>preventable-deaths</metric>
    <metric>lwbs</metric>
    <metric>discharged</metric>
    <metric>admitted</metric>
    <metric>transferred</metric>
    <metric>unresolved</metric>
    <metric>critical-delay-rate</metric>
    <metric>p90-door-to-triage</metric>
    <metric>under-triage-rate</metric>
    <metric>median-door-to-doctor 2</metric>
    <metric>mci-declared-at</metric>
    <metric>total-messages</metric>
    <enumeratedValueSet variable="scenario-source">
      <value value="&quot;generate&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="casualties">
      <value value="0"/>
      <value value="10"/>
      <value value="20"/>
      <value value="30"/>
      <value value="40"/>
      <value value="50"/>
      <value value="60"/>
      <value value="80"/>
      <value value="100"/>
      <value value="125"/>
      <value value="150"/>
      <value value="200"/>
      <value value="250"/>
      <value value="300"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="co-triage?">
      <value value="false"/>
      <value value="true"/>
    </enumeratedValueSet>
    <steppedValueSet variable="sim-seed" first="1" step="1" last="30"/>
  </experiment>
  <experiment name="quick-test" repetitions="1" sequentialRunOrder="true" runMetricsEveryStep="false">
    <setup>setup</setup>
    <go>go</go>
    <timeLimit steps="1440"/>
    <exitCondition>sim-finished?</exitCondition>
    <metric>deaths</metric>
    <metric>deaths-waiting</metric>
    <metric>preventable-deaths</metric>
    <metric>lwbs</metric>
    <metric>critical-delay-rate</metric>
    <metric>p90-door-to-triage</metric>
    <enumeratedValueSet variable="scenario-source">
      <value value="&quot;generate&quot;"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="casualties">
      <value value="0"/>
      <value value="50"/>
      <value value="100"/>
      <value value="200"/>
    </enumeratedValueSet>
    <enumeratedValueSet variable="co-triage?">
      <value value="false"/>
      <value value="true"/>
    </enumeratedValueSet>
    <steppedValueSet variable="sim-seed" first="1" step="1" last="5"/>
  </experiment>
</experiments>
@#$#@#$#@
@#$#@#$#@
default
0.0
-0.2 0 0.0 1.0
0.0 1 1.0 0.0
0.2 0 0.0 1.0
link direction
true
0
Line -7500403 true 150 150 90 180
Line -7500403 true 150 150 210 180
@#$#@#$#@
0
@#$#@#$#@
