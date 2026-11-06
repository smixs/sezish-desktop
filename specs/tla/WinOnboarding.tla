---------------------------- MODULE WinOnboarding ----------------------------
(***************************************************************************)
(* First-run tour of the Windows app: microphone -> engine -> done.         *)
(* The Mac tour (Onboarding.tla) without Accessibility: Windows needs no    *)
(* grant for the low-level keyboard hook, so the listener and its relaunch  *)
(* guard are out. What stays is the microphone, which Windows can switch    *)
(* off for desktop apps under Privacy & security, and the engine.           *)
(*                                                                         *)
(* Invariants in words (weakening one needs Serge's decision):             *)
(*  FinishOnlyWhenReady   the tour closes only when the microphone is on    *)
(*                        and the chosen engine can transcribe.             *)
(*  PastMicOnlyWhenGranted  the engine and done screens are shown only      *)
(*                        while the microphone reads as on; switching it off*)
(*                        mid-tour sends the person back.                   *)
(*  AtMostOneDownload     one model download at a time.                     *)
(*  Termination           a person who keeps answering finishes the tour.   *)
(*                                                                         *)
(* Model action -> code (win/src-tauri/src/onboarding.rs, OnboardingFlow):  *)
(*  Poll            on(Input::Status)          1 s microphone poll          *)
(*  AskMic          on(Input::GrantMicrophone), undetermined: a short probe *)
(*                  of the microphone raises Windows' own prompt            *)
(*  OpenMicSettings on(Input::GrantMicrophone), denied: ms-settings privacy *)
(*  Advance         on(Input::Status) -> AdvanceSoon, then on(Continue)     *)
(*  ChooseCloud     on(Input::ChooseEngine(Cloud)), only when baked in      *)
(*  ChooseLocal     on(Input::ChooseEngine(Local))                          *)
(*  AutoDownload    on(Input::Status | Model) with local and no model       *)
(*  Retry           on(Input::RetryDownload)                                *)
(*  ToDone          on(Input::Continue) on the engine screen                *)
(*  Back            on(Input::Back)                                         *)
(*  Finish          on(Input::Continue) on the done screen                  *)
(* Environment: DialogAnswer, GrantMic (switch turned on in Settings),      *)
(*  Revoke, DownloadDone.                                                   *)
(*                                                                         *)
(* Assumptions: a grant applies to the running process (Windows reads the  *)
(* consent store on every capture). Builds without baked cloud credentials  *)
(* do not offer the cloud (CloudBaked = FALSE).                             *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS
    MaxRevokes,      \* how many times the person may switch the microphone off
    MaxFails,        \* how many model downloads may fail
    CloudBaked,      \* the build carries cloud credentials
    \* Protections. TRUE in the real code; a witness config sets one FALSE and
    \* must break the property named next to it.
    GuardFinish,     \* FinishOnlyWhenReady
    BackOnRevoke,    \* PastMicOnlyWhenGranted
    GuardDownload,   \* AtMostOneDownload
    SettingsPath     \* Termination: a refused microphone has a way back on

VARIABLES
    realMic, obsMic,
    step, askedMic, micGuide,
    engine, model, downloads,
    revokes, fails, finishedOk

vars == <<realMic, obsMic, step, askedMic, micGuide, engine, model, downloads,
          revokes, fails, finishedOk>>

MicStates == {"undetermined", "denied", "granted"}
Steps == {"microphone", "engine", "done", "finished"}
Engines == IF CloudBaked THEN {"cloud", "local"} ELSE {"local"}

MicOk == obsMic = "granted"
EngineReady == (engine = "cloud" /\ CloudBaked) \/ (engine = "local" /\ model = "ready")

TypeOK ==
    /\ realMic \in MicStates /\ obsMic \in MicStates
    /\ step \in Steps
    /\ askedMic \in BOOLEAN /\ micGuide \in BOOLEAN
    /\ engine \in {"cloud", "local"}
    /\ model \in {"missing", "downloading", "ready", "failed"}
    /\ downloads \in 0..2
    /\ revokes \in 0..MaxRevokes /\ fails \in 0..MaxFails
    /\ finishedOk \in BOOLEAN

Init ==
    /\ realMic \in MicStates
    /\ obsMic = realMic
    /\ step = IF realMic = "granted" THEN "engine" ELSE "microphone"
    /\ askedMic = FALSE /\ micGuide = FALSE
    /\ engine \in Engines
    /\ model \in {"missing", "ready"}
    /\ downloads = 0
    /\ revokes = 0 /\ fails = 0
    /\ finishedOk = FALSE

Touring == step # "finished"

Keep(v) == UNCHANGED v

-----------------------------------------------------------------------------
(* Environment *)

\* Windows' own microphone prompt is answered.
DialogAnswer ==
    /\ Touring /\ askedMic /\ realMic = "undetermined"
    /\ realMic' \in {"granted", "denied"}
    /\ Keep(<<obsMic, step, askedMic, micGuide, engine, model, downloads,
              revokes, fails, finishedOk>>)

\* The person switches «Let desktop apps access your microphone» on.
GrantMic ==
    /\ Touring /\ micGuide /\ realMic = "denied"
    /\ realMic' = "granted"
    /\ Keep(<<obsMic, step, askedMic, micGuide, engine, model, downloads,
              revokes, fails, finishedOk>>)

\* The person switches it off again mid-tour.
Revoke ==
    /\ Touring /\ revokes < MaxRevokes /\ realMic = "granted"
    /\ realMic' = "denied"
    /\ revokes' = revokes + 1
    /\ Keep(<<obsMic, step, askedMic, micGuide, engine, model, downloads,
              fails, finishedOk>>)

\* A download ends. Failures are bounded, so a person who retries gets the model.
DownloadDone ==
    /\ downloads > 0
    /\ \/ model' = "ready" /\ UNCHANGED fails
       \/ fails < MaxFails /\ model' = "failed" /\ fails' = fails + 1
    /\ downloads' = downloads - 1
    /\ Keep(<<realMic, obsMic, step, askedMic, micGuide, engine, revokes,
              finishedOk>>)

-----------------------------------------------------------------------------
(* The flow *)

\* The 1 s poll copies Windows' state in and reacts in the same step.
Poll ==
    /\ Touring
    /\ obsMic' = realMic
    /\ step' = IF BackOnRevoke /\ step \in {"engine", "done"} /\ realMic # "granted"
               THEN "microphone" ELSE step
    /\ Keep(<<realMic, askedMic, micGuide, engine, model, downloads, revokes,
              fails, finishedOk>>)

AskMic ==
    /\ step = "microphone" /\ obsMic = "undetermined" /\ ~askedMic
    /\ askedMic' = TRUE
    /\ Keep(<<realMic, obsMic, step, micGuide, engine, model, downloads,
              revokes, fails, finishedOk>>)

\* Without SettingsPath the button only probes the microphone again, which
\* Windows answers with nothing once access is off.
OpenMicSettings ==
    /\ step = "microphone" /\ obsMic = "denied" /\ ~micGuide
    /\ askedMic' = TRUE
    /\ micGuide' = SettingsPath
    /\ Keep(<<realMic, obsMic, step, engine, model, downloads, revokes, fails,
              finishedOk>>)

Advance ==
    /\ step = "microphone" /\ MicOk
    /\ step' = "engine"
    /\ Keep(<<realMic, obsMic, askedMic, micGuide, engine, model, downloads,
              revokes, fails, finishedOk>>)

StartDownload ==
    IF model \in {"missing", "failed"} /\ (downloads = 0 \/ ~GuardDownload)
    THEN /\ model' = "downloading" /\ downloads' = downloads + 1
    ELSE IF ~GuardDownload /\ model = "downloading" /\ downloads < 2
    THEN /\ downloads' = downloads + 1 /\ UNCHANGED model
    ELSE UNCHANGED <<model, downloads>>

ChooseCloud ==
    /\ CloudBaked
    /\ step \in {"engine", "done"} /\ engine # "cloud"
    /\ engine' = "cloud"
    /\ Keep(<<realMic, obsMic, step, askedMic, micGuide, model, downloads,
              revokes, fails, finishedOk>>)

\* Choosing the local engine starts its model in the background.
ChooseLocal ==
    /\ step \in {"engine", "done"}
    /\ engine' = "local"
    /\ StartDownload
    /\ (engine # "local" \/ model' # model \/ downloads' # downloads)
    /\ Keep(<<realMic, obsMic, step, askedMic, micGuide, revokes, fails,
              finishedOk>>)

\* Local engine, no model on disk: the download starts by itself on any screen.
AutoDownload ==
    /\ Touring /\ engine = "local" /\ model = "missing"
    /\ downloads = 0
    /\ StartDownload
    /\ Keep(<<realMic, obsMic, step, askedMic, micGuide, engine, revokes, fails,
              finishedOk>>)

Retry ==
    /\ step \in {"engine", "done"} /\ engine = "local" /\ model = "failed"
    /\ StartDownload
    /\ Keep(<<realMic, obsMic, step, askedMic, micGuide, engine, revokes, fails,
              finishedOk>>)

ToDone ==
    /\ step = "engine"
    /\ step' = "done"
    /\ Keep(<<realMic, obsMic, askedMic, micGuide, engine, model, downloads,
              revokes, fails, finishedOk>>)

Back ==
    /\ step \in {"engine", "done"}
    /\ step' = IF step = "done" THEN "engine" ELSE "microphone"
    /\ Keep(<<realMic, obsMic, askedMic, micGuide, engine, model, downloads,
              revokes, fails, finishedOk>>)

Finish ==
    /\ step = "done"
    /\ GuardFinish => (MicOk /\ EngineReady)
    /\ step' = "finished"
    /\ finishedOk' = (MicOk /\ EngineReady)
    /\ Keep(<<realMic, obsMic, askedMic, micGuide, engine, model, downloads,
              revokes, fails>>)

Done == step = "finished" /\ UNCHANGED vars

Env == DialogAnswer \/ GrantMic \/ Revoke \/ DownloadDone
Flow == Poll \/ AskMic \/ OpenMicSettings \/ Advance \/ ChooseCloud \/ ChooseLocal
        \/ AutoDownload \/ Retry \/ ToDone \/ Back \/ Finish

Next == Env \/ Flow \/ Done

\* A person who keeps answering: every helpful step they or Windows can take is
\* eventually taken. Back, Revoke and switching engines are never forced.
Fairness ==
    /\ WF_vars(Poll) /\ WF_vars(DialogAnswer) /\ WF_vars(DownloadDone)
    /\ WF_vars(AutoDownload)
    /\ SF_vars(GrantMic) /\ SF_vars(AskMic) /\ SF_vars(OpenMicSettings)
    /\ SF_vars(Advance) /\ SF_vars(Retry) /\ SF_vars(ToDone) /\ SF_vars(Finish)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Properties *)

FinishOnlyWhenReady == step = "finished" => finishedOk
PastMicOnlyWhenGranted == step \in {"engine", "done"} => MicOk
AtMostOneDownload == downloads <= 1

Termination == <>(step = "finished")
=============================================================================
