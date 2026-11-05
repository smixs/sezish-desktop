------------------------------ MODULE Onboarding ------------------------------
(***************************************************************************)
(* First-run tour of the macOS app: permissions -> engine -> done.          *)
(* Ported from hex (anomalyco/hex@afb11de, src/desktop/onboarding.rs, MIT). *)
(*                                                                         *)
(* Invariants in words (weakening one needs Serge's decision):             *)
(*  FinishOnlyWhenReady   the tour closes only when the microphone and     *)
(*                        Accessibility are on, the shortcut listener runs  *)
(*                        and the engine can transcribe.                    *)
(*  PastPermissionsOnlyWhenGranted  the engine and done screens are shown   *)
(*                        only while both permissions read as on; a grant   *)
(*                        turned off mid-tour sends the person back.        *)
(*  AtMostOneDownload     one model download at a time.                     *)
(*  NoResetOfWorkingGrant "Still grey? Fix it" never clears an              *)
(*                        Accessibility grant that already works.           *)
(*  RelaunchBounded       at most one automatic relaunch per guard window,  *)
(*                        so a grant that never reaches the app cannot loop.*)
(*  StaleOnlyWhenGrey     "Still grey" shows only for an asked, untrusted   *)
(*                        Accessibility row.                                *)
(*  Termination           a person who keeps answering finishes the tour,   *)
(*                        even with an old grey TCC entry.                  *)
(*                                                                         *)
(* Model action -> code (app/Sources/SezishCore/Onboarding.swift):          *)
(*  Poll            OnboardingFlow.on(.status)       1 s permission poll    *)
(*  AskMic          OnboardingFlow.on(.grant(.microphone)), notDetermined   *)
(*  OpenMicSettings OnboardingFlow.on(.grant(.microphone)), denied          *)
(*  AskAx           OnboardingFlow.on(.grant(.accessibility)), not stale    *)
(*  StaleTimeout    StalePermissionTracker.poll -> flow.setAccessibilityStale*)
(*  FixStale        OnboardingFlow.on(.grant(.accessibility)) while stale,  *)
(*                  with trustedNow read at the click                       *)
(*  Advance         OnboardingFlow.on(.status) advanceSoon + .continue      *)
(*  ChooseCloud     OnboardingFlow.on(.chooseEngine(.cloud))                *)
(*  ChooseLocal     OnboardingFlow.on(.chooseEngine(.local))                *)
(*  AutoDownload    OnboardingFlow.autoDownload on .status or .model    *)
(*  Retry           OnboardingFlow.on(.retryDownload)                       *)
(*  ToDone          OnboardingFlow.on(.continue) on .engine                 *)
(*  Back            OnboardingFlow.on(.back)                                *)
(*  Finish          OnboardingFlow.on(.continue) on .done                   *)
(*  ListenerFailed  OnboardingFlow.on(.listenerFailed(relaunchAllowed:))    *)
(*  Reopen          OnboardingFlow.on(.reopen)                              *)
(*  Relaunched      OnboardingFlow.init(start:status:) after a relaunch     *)
(* Environment: DialogAnswer, GrantMic, GrantAx, Revoke, DownloadDone,      *)
(*  GuardExpires (120 s passed, OnboardingRelaunchGuard).                   *)
(*                                                                         *)
(* Assumptions: macOS applies a grant to the running process except when    *)
(* the event tap refuses to install (tap fails, needs a relaunch); a relaunch*)
(* brings the tap up when Accessibility is on. An old grey TCC row blocks   *)
(* the grant until tccutil reset clears it. Cloud is always reachable       *)
(* (release builds bake its credentials).                                   *)
(* Out of the model: the microseconds between the fresh AXIsProcessTrusted  *)
(* read and tccutil itself; window layout; timing values (2 s / 6 s / 120 s,*)
(* unit tests of StalePermissionTracker and OnboardingRelaunchGuard).       *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxRevokes,      \* how many times the person may turn a grant off mid-tour
    MaxFails,        \* how many model downloads may fail
    \* Protections. TRUE in the real code; a witness config sets one FALSE and
    \* must break the invariant named next to it.
    GuardFinish,     \* FinishOnlyWhenReady
    BackOnRevoke,    \* PastPermissionsOnlyWhenGranted
    GuardDownload,   \* AtMostOneDownload
    FreshResetCheck, \* NoResetOfWorkingGrant
    RelaunchGuard,   \* RelaunchBounded
    StaleFix         \* Termination

VARIABLES
    realMic, realAx, tapOk, greyEntry,   \* what macOS holds
    obsMic, obsAx, obsTap,               \* what the last poll saw
    step, askedMic, askedAx, micGuide, stale, reopen,
    engine, model, downloads,
    revokes, fails, guardSet, relaunchesInWindow,
    resetWhileTrusted, finishedOk

vars == <<realMic, realAx, tapOk, greyEntry, obsMic, obsAx, obsTap,
          step, askedMic, askedAx, micGuide, stale, reopen,
          engine, model, downloads,
          revokes, fails, guardSet, relaunchesInWindow,
          resetWhileTrusted, finishedOk>>

MicStates == {"undetermined", "denied", "granted"}
Steps == {"permissions", "engine", "done", "finished"}

PermsOk == obsMic = "granted" /\ obsAx /\ obsTap
EngineReady == engine = "cloud" \/ (engine = "local" /\ model = "ready")

TypeOK ==
    /\ realMic \in MicStates /\ obsMic \in MicStates
    /\ realAx \in BOOLEAN /\ tapOk \in BOOLEAN /\ greyEntry \in BOOLEAN
    /\ obsAx \in BOOLEAN /\ obsTap \in BOOLEAN
    /\ step \in Steps
    /\ askedMic \in BOOLEAN /\ askedAx \in BOOLEAN /\ micGuide \in BOOLEAN
    /\ stale \in BOOLEAN /\ reopen \in BOOLEAN
    /\ engine \in {"cloud", "local"}
    /\ model \in {"missing", "downloading", "ready", "failed"}
    /\ downloads \in 0..2
    /\ revokes \in 0..MaxRevokes /\ fails \in 0..MaxFails
    /\ guardSet \in BOOLEAN /\ relaunchesInWindow \in 0..2
    /\ resetWhileTrusted \in BOOLEAN /\ finishedOk \in BOOLEAN

\* The tour opens on a fresh status read and skips a screen that already passes.
Start(m, a, t) == IF m = "granted" /\ a /\ t THEN "engine" ELSE "permissions"

Init ==
    /\ realMic \in MicStates
    /\ realAx \in BOOLEAN
    /\ tapOk \in BOOLEAN
    /\ greyEntry \in BOOLEAN
    /\ ~(realAx /\ greyEntry)
    /\ ~(tapOk /\ ~realAx)
    /\ obsMic = realMic /\ obsAx = realAx /\ obsTap = tapOk
    /\ step = Start(realMic, realAx, tapOk)
    /\ askedMic = FALSE /\ askedAx = FALSE /\ micGuide = FALSE
    /\ stale = FALSE /\ reopen = FALSE
    /\ engine \in {"cloud", "local"}
    /\ model \in {"missing", "ready"}
    /\ downloads = 0
    /\ revokes = 0 /\ fails = 0
    /\ guardSet = FALSE /\ relaunchesInWindow = 0
    /\ resetWhileTrusted = FALSE /\ finishedOk = FALSE

Touring == step # "finished"

-----------------------------------------------------------------------------
(* Environment *)

\* macOS's own microphone prompt is answered.
DialogAnswer ==
    /\ Touring /\ askedMic /\ realMic = "undetermined"
    /\ realMic' \in {"granted", "denied"}
    /\ UNCHANGED <<realAx, tapOk, greyEntry, obsMic, obsAx, obsTap, step, askedMic,
                   askedAx, micGuide, stale, reopen, engine, model, downloads,
                   revokes, fails, guardSet, relaunchesInWindow,
                   resetWhileTrusted, finishedOk>>

\* The person switches the microphone on in System Settings.
GrantMic ==
    /\ Touring /\ micGuide /\ realMic = "denied"
    /\ realMic' = "granted"
    /\ UNCHANGED <<realAx, tapOk, greyEntry, obsMic, obsAx, obsTap, step, askedMic,
                   askedAx, micGuide, stale, reopen, engine, model, downloads,
                   revokes, fails, guardSet, relaunchesInWindow,
                   resetWhileTrusted, finishedOk>>

\* The person drags the app into the Accessibility list. An old grey row keeps
\* the switch off; the event tap may still refuse until a relaunch.
GrantAx ==
    /\ Touring /\ askedAx /\ ~realAx /\ ~greyEntry
    /\ realAx' = TRUE
    /\ tapOk' \in BOOLEAN
    /\ UNCHANGED <<realMic, greyEntry, obsMic, obsAx, obsTap, step, askedMic,
                   askedAx, micGuide, stale, reopen, engine, model, downloads,
                   revokes, fails, guardSet, relaunchesInWindow,
                   resetWhileTrusted, finishedOk>>

\* The person turns a grant off in System Settings mid-tour.
Revoke ==
    /\ Touring /\ revokes < MaxRevokes
    /\ \/ /\ realMic = "granted" /\ realMic' = "denied"
          /\ UNCHANGED <<realAx, tapOk>>
       \/ /\ realAx /\ realAx' = FALSE /\ tapOk' = FALSE
          /\ UNCHANGED realMic
    /\ revokes' = revokes + 1
    /\ UNCHANGED <<greyEntry, obsMic, obsAx, obsTap, step, askedMic, askedAx,
                   micGuide, stale, reopen, engine, model, downloads, fails,
                   guardSet, relaunchesInWindow, resetWhileTrusted, finishedOk>>

\* A download ends. Failures are bounded, so a person who retries gets the model.
DownloadDone ==
    /\ downloads > 0
    /\ \/ model' = "ready" /\ UNCHANGED fails
       \/ fails < MaxFails /\ model' = "failed" /\ fails' = fails + 1
    /\ downloads' = downloads - 1
    /\ UNCHANGED <<realMic, realAx, tapOk, greyEntry, obsMic, obsAx, obsTap, step,
                   askedMic, askedAx, micGuide, stale, reopen, engine, revokes,
                   guardSet, relaunchesInWindow, resetWhileTrusted, finishedOk>>

\* 120 s pass since the last automatic relaunch.
GuardExpires ==
    /\ Touring /\ guardSet
    /\ guardSet' = FALSE /\ relaunchesInWindow' = 0
    /\ UNCHANGED <<realMic, realAx, tapOk, greyEntry, obsMic, obsAx, obsTap, step,
                   askedMic, askedAx, micGuide, stale, reopen, engine, model,
                   downloads, revokes, fails, resetWhileTrusted, finishedOk>>

-----------------------------------------------------------------------------
(* The flow *)

\* The 1 s poll copies macOS's state in and reacts in the same step.
Poll ==
    /\ Touring
    /\ obsMic' = realMic /\ obsAx' = realAx /\ obsTap' = tapOk
    /\ stale' = (stale /\ ~realAx)
    /\ LET ok == realMic = "granted" /\ realAx /\ tapOk IN
       step' = IF BackOnRevoke /\ step \in {"engine", "done"} /\ ~ok
               THEN "permissions" ELSE step
    /\ UNCHANGED <<realMic, realAx, tapOk, greyEntry, askedMic, askedAx, micGuide,
                   reopen, engine, model, downloads, revokes, fails, guardSet,
                   relaunchesInWindow, resetWhileTrusted, finishedOk>>

AskMic ==
    /\ step = "permissions" /\ obsMic = "undetermined" /\ ~askedMic
    /\ askedMic' = TRUE
    /\ UNCHANGED <<realMic, realAx, tapOk, greyEntry, obsMic, obsAx, obsTap, step,
                   askedAx, micGuide, stale, reopen, engine, model, downloads,
                   revokes, fails, guardSet, relaunchesInWindow,
                   resetWhileTrusted, finishedOk>>

OpenMicSettings ==
    /\ step = "permissions" /\ obsMic = "denied" /\ ~micGuide
    /\ askedMic' = TRUE /\ micGuide' = TRUE
    /\ UNCHANGED <<realMic, realAx, tapOk, greyEntry, obsMic, obsAx, obsTap, step,
                   askedAx, stale, reopen, engine, model, downloads, revokes,
                   fails, guardSet, relaunchesInWindow, resetWhileTrusted,
                   finishedOk>>

\* Prompt + System Settings with the guide.
AskAx ==
    /\ step = "permissions" /\ ~obsAx /\ ~stale /\ ~askedAx
    /\ askedAx' = TRUE
    /\ UNCHANGED <<realMic, realAx, tapOk, greyEntry, obsMic, obsAx, obsTap, step,
                   askedMic, micGuide, stale, reopen, engine, model, downloads,
                   revokes, fails, guardSet, relaunchesInWindow,
                   resetWhileTrusted, finishedOk>>

\* Back from System Settings and still untrusted after 2 s (or 6 s side by side).
StaleTimeout ==
    /\ step = "permissions" /\ askedAx /\ ~obsAx /\ ~stale
    /\ stale' = TRUE
    /\ UNCHANGED <<realMic, realAx, tapOk, greyEntry, obsMic, obsAx, obsTap, step,
                   askedMic, askedAx, micGuide, reopen, engine, model, downloads,
                   revokes, fails, guardSet, relaunchesInWindow,
                   resetWhileTrusted, finishedOk>>

\* "Still grey? Fix it". With the fresh check, a grant that landed after the last
\* poll is taken as is; otherwise tccutil clears every row and the prompt reopens.
FixStale ==
    /\ StaleFix /\ step = "permissions" /\ stale
    /\ stale' = FALSE
    /\ IF FreshResetCheck /\ realAx
       THEN /\ obsAx' = TRUE /\ obsTap' = tapOk
            /\ UNCHANGED <<realAx, tapOk, greyEntry, askedAx, resetWhileTrusted>>
       ELSE /\ resetWhileTrusted' = (resetWhileTrusted \/ realAx)
            /\ realAx' = FALSE /\ tapOk' = FALSE /\ greyEntry' = FALSE
            /\ obsAx' = FALSE /\ obsTap' = FALSE
            /\ askedAx' = TRUE
    /\ UNCHANGED <<realMic, obsMic, step, askedMic, micGuide, reopen, engine, model,
                   downloads, revokes, fails, guardSet, relaunchesInWindow,
                   finishedOk>>

Advance ==
    /\ step = "permissions" /\ PermsOk
    /\ step' = "engine"
    /\ UNCHANGED <<realMic, realAx, tapOk, greyEntry, obsMic, obsAx, obsTap,
                   askedMic, askedAx, micGuide, stale, reopen, engine, model,
                   downloads, revokes, fails, guardSet, relaunchesInWindow,
                   resetWhileTrusted, finishedOk>>

StartDownload ==
    IF model \in {"missing", "failed"} /\ (downloads = 0 \/ ~GuardDownload)
    THEN /\ model' = "downloading" /\ downloads' = downloads + 1
    ELSE IF ~GuardDownload /\ model = "downloading" /\ downloads < 2
    THEN /\ downloads' = downloads + 1 /\ UNCHANGED model
    ELSE UNCHANGED <<model, downloads>>

ChooseCloud ==
    /\ step \in {"engine", "done"} /\ engine # "cloud"
    /\ engine' = "cloud"
    /\ UNCHANGED <<realMic, realAx, tapOk, greyEntry, obsMic, obsAx, obsTap, step,
                   askedMic, askedAx, micGuide, stale, reopen, model, downloads,
                   revokes, fails, guardSet, relaunchesInWindow,
                   resetWhileTrusted, finishedOk>>

\* Choosing the local engine starts its model in the background.
ChooseLocal ==
    /\ step \in {"engine", "done"}
    /\ engine' = "local"
    /\ StartDownload
    /\ (engine # "local" \/ model' # model \/ downloads' # downloads)
    /\ UNCHANGED <<realMic, realAx, tapOk, greyEntry, obsMic, obsAx, obsTap, step,
                   askedMic, askedAx, micGuide, stale, reopen, revokes, fails,
                   guardSet, relaunchesInWindow, resetWhileTrusted, finishedOk>>

\* The local engine is selected and its model is not on disk: the flow starts
\* the download by itself on any screen, so it runs while the person reads
\* (hex starts it the first time it sees no model).
AutoDownload ==
    /\ Touring /\ engine = "local" /\ model = "missing"
    /\ downloads = 0
    /\ StartDownload
    /\ UNCHANGED <<realMic, realAx, tapOk, greyEntry, obsMic, obsAx, obsTap, step,
                   askedMic, askedAx, micGuide, stale, reopen, engine, revokes,
                   fails, guardSet, relaunchesInWindow, resetWhileTrusted,
                   finishedOk>>

Retry ==
    /\ step \in {"engine", "done"} /\ engine = "local" /\ model = "failed"
    /\ StartDownload
    /\ UNCHANGED <<realMic, realAx, tapOk, greyEntry, obsMic, obsAx, obsTap, step,
                   askedMic, askedAx, micGuide, stale, reopen, engine, revokes,
                   fails, guardSet, relaunchesInWindow, resetWhileTrusted,
                   finishedOk>>

ToDone ==
    /\ step = "engine"
    /\ step' = "done"
    /\ UNCHANGED <<realMic, realAx, tapOk, greyEntry, obsMic, obsAx, obsTap,
                   askedMic, askedAx, micGuide, stale, reopen, engine, model,
                   downloads, revokes, fails, guardSet, relaunchesInWindow,
                   resetWhileTrusted, finishedOk>>

Back ==
    /\ step \in {"engine", "done"}
    /\ step' = IF step = "done" THEN "engine" ELSE "permissions"
    /\ UNCHANGED <<realMic, realAx, tapOk, greyEntry, obsMic, obsAx, obsTap,
                   askedMic, askedAx, micGuide, stale, reopen, engine, model,
                   downloads, revokes, fails, guardSet, relaunchesInWindow,
                   resetWhileTrusted, finishedOk>>

Finish ==
    /\ step = "done"
    /\ GuardFinish => (PermsOk /\ EngineReady)
    /\ step' = "finished"
    /\ finishedOk' = (PermsOk /\ EngineReady)
    /\ UNCHANGED <<realMic, realAx, tapOk, greyEntry, obsMic, obsAx, obsTap,
                   askedMic, askedAx, micGuide, stale, reopen, engine, model,
                   downloads, revokes, fails, guardSet, relaunchesInWindow,
                   resetWhileTrusted>>

\* The relaunch itself: a fresh process reads macOS's state; the tap comes up
\* when Accessibility is on. The tour resumes from the fresh status.
DoRelaunch(auto) ==
    /\ tapOk' = realAx
    /\ obsMic' = realMic /\ obsAx' = realAx /\ obsTap' = realAx
    /\ step' = Start(realMic, realAx, realAx)
    /\ askedMic' = FALSE /\ askedAx' = FALSE /\ micGuide' = FALSE
    /\ stale' = FALSE /\ reopen' = FALSE
    /\ guardSet' = TRUE
    /\ relaunchesInWindow' = IF auto THEN relaunchesInWindow + 1 ELSE relaunchesInWindow

\* Accessibility reads on, the listener would not start. Inside the guard
\* window the flow shows "Restart" instead of relaunching again.
ListenerFailed ==
    /\ step = "permissions" /\ obsAx /\ ~obsTap /\ ~reopen
    /\ relaunchesInWindow < 2
    /\ IF guardSet /\ RelaunchGuard
       THEN /\ reopen' = TRUE
            /\ UNCHANGED <<tapOk, obsMic, obsAx, obsTap, step, askedMic, askedAx,
                           micGuide, stale, guardSet, relaunchesInWindow>>
       ELSE DoRelaunch(TRUE)
    /\ UNCHANGED <<realMic, realAx, greyEntry, engine, model, downloads, revokes,
                   fails, resetWhileTrusted, finishedOk>>

\* The person presses "Restart" after the guard held the automatic relaunch back.
Reopen ==
    /\ step = "permissions" /\ reopen
    /\ DoRelaunch(FALSE)
    /\ UNCHANGED <<realMic, realAx, greyEntry, engine, model, downloads, revokes,
                   fails, resetWhileTrusted, finishedOk>>

Done == step = "finished" /\ UNCHANGED vars

Env == DialogAnswer \/ GrantMic \/ GrantAx \/ Revoke \/ DownloadDone \/ GuardExpires
Flow == Poll \/ AskMic \/ OpenMicSettings \/ AskAx \/ StaleTimeout \/ FixStale
        \/ Advance \/ ChooseCloud \/ ChooseLocal \/ AutoDownload \/ Retry \/ ToDone \/ Back
        \/ Finish \/ ListenerFailed \/ Reopen

Next == Env \/ Flow \/ Done

\* A person who keeps answering: every helpful step they or macOS can take is
\* eventually taken. Back and Revoke are never forced.
Fairness ==
    /\ WF_vars(Poll) /\ WF_vars(DialogAnswer) /\ WF_vars(DownloadDone)
    /\ WF_vars(GuardExpires) /\ WF_vars(AutoDownload)
    /\ SF_vars(GrantMic) /\ SF_vars(GrantAx)
    /\ SF_vars(AskMic) /\ SF_vars(OpenMicSettings) /\ SF_vars(AskAx)
    /\ SF_vars(StaleTimeout) /\ SF_vars(FixStale) /\ SF_vars(Advance)
    /\ SF_vars(Retry) /\ SF_vars(ToDone) /\ SF_vars(Finish)
    /\ SF_vars(ListenerFailed) /\ SF_vars(Reopen)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Properties *)

FinishOnlyWhenReady == step = "finished" => finishedOk
PastPermissionsOnlyWhenGranted == step \in {"engine", "done"} => PermsOk
AtMostOneDownload == downloads <= 1
NoResetOfWorkingGrant == ~resetWhileTrusted
RelaunchBounded == relaunchesInWindow <= 1
StaleOnlyWhenGrey == stale => (askedAx /\ ~obsAx)

Termination == <>(step = "finished")
=============================================================================
