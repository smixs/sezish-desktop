----------------------------- MODULE LocalEngine -----------------------------
\* Сколько копий локальной модели держит память (Сергей 05.11: «выжирает дохуя
\* оперативной памяти»). Копия живёт, пока на неё есть ссылка (ARC): из общего слота,
\* из диктовки, из идущей встречи. Код: LocalEngineSlot в SezishCore, AppState
\* (loadLocalTranscriber, rebuildCoordinator, releaseIdleLocalEngine).
\*
\* Соответствие коду:
\*   SetMode      — setTranscriptionMode → rebuildCoordinator;
\*   Rebuild      — setLanguage, setGeminiSmartMode, ключ/модель OpenAI → rebuildCoordinator;
\*   SwitchModel  — setLocalModel → rebuildCoordinator; идущая встреча держит свою копию;
\*   MeetingStart — startMeetingRecording → makeMeetingTranscriptionPipeline;
\*   MeetingEnd   — finishMeeting (defer) → releaseIdleLocalEngine.
\* Shared — диктовка и встреча берут модель из одного слота (без него — старый код:
\*          rebuild всегда грузит новую копию, встреча кэширует свою навсегда).
\* Pin — копия идущей встречи остаётся доступной слоту: модель туда-обратно посреди
\*       встречи не грузит вторую копию той же модели.
\* ReleaseIdle — слот отпускает модель, когда ей не пользуются ни диктовка, ни встреча.

EXTENDS Naturals, FiniteSets

CONSTANTS Shared, ReleaseIdle, Pin, Models, MaxLoads, MaxSteps

None == 0

VARIABLES mode, model, slot, dict, meet, meetingOn, modelOf, loads, steps
vars == <<mode, model, slot, dict, meet, meetingOn, modelOf, loads, steps>>

Ids == 1..MaxLoads

TypeOK ==
  /\ mode \in {"local", "cloud"}
  /\ model \in Models
  /\ slot \in Ids \cup {None}
  /\ dict \in Ids \cup {None}
  /\ meet \in Ids \cup {None}
  /\ meetingOn \in BOOLEAN
  /\ modelOf \in [Ids -> Models \cup {"-"}]
  /\ loads \in 0..MaxLoads
  /\ steps \in 0..MaxSteps

\* Копия в памяти — та, на которую кто-то ссылается.
Loaded == {slot, dict, meet} \ {None}

Init ==
  /\ mode \in {"local", "cloud"}
  /\ model \in Models
  /\ slot = None /\ dict = None /\ meet = None
  /\ meetingOn = FALSE
  /\ modelOf = [i \in Ids |-> "-"]
  /\ loads = 0
  /\ steps = 0

\* Слот уже держит текущую модель — отдаёт её; иначе грузит новую копию.
SlotHit == slot # None /\ modelOf[slot] = model
NewId == loads + 1
CanLoad == loads < MaxLoads

\* Отпустить слот, если модель больше никому не нужна (после шага: mode2, on2).
Released(mode2, on2, s) ==
  IF ReleaseIdle /\ mode2 = "cloud" /\ ~on2 THEN None ELSE s

\* Копия model2, которая уже в памяти: в слоте или у идущей встречи (встреча
\* закрепляет свою копию в слоте — LocalEngineSlot.pin).
Held(model2) ==
  IF slot # None /\ modelOf[slot] = model2 THEN slot
  ELSE IF Pin /\ meet # None /\ modelOf[meet] = model2 THEN meet
  ELSE None

\* Диктовка заново строит движок под текущий режим.
RebuildWith(mode2, model2) ==
  IF mode2 = "local"
  THEN IF Shared
       THEN IF Held(model2) # None
            THEN /\ dict' = Held(model2) /\ slot' = Held(model2)
                 /\ UNCHANGED <<modelOf, loads>>
            ELSE /\ CanLoad
                 /\ dict' = NewId /\ slot' = NewId
                 /\ modelOf' = [modelOf EXCEPT ![NewId] = model2]
                 /\ loads' = NewId
       \* Старый код: каждый rebuild — новая копия; слот (кэш встречи) не трогает.
       ELSE /\ CanLoad
            /\ dict' = NewId
            /\ modelOf' = [modelOf EXCEPT ![NewId] = model2]
            /\ loads' = NewId
            /\ UNCHANGED slot
  ELSE /\ dict' = None
       /\ slot' = Released(mode2, meetingOn, slot)
       /\ UNCHANGED <<modelOf, loads>>

Step == steps < MaxSteps /\ steps' = steps + 1

Rebuild ==
  /\ Step
  /\ RebuildWith(mode, model)
  /\ UNCHANGED <<mode, model, meet, meetingOn>>

SetMode ==
  /\ Step
  /\ \E m \in {"local", "cloud"} \ {mode}:
       /\ mode' = m
       /\ RebuildWith(m, model)
  /\ UNCHANGED <<model, meet, meetingOn>>

SwitchModel ==
  /\ Step
  /\ \E m \in Models \ {model}:
       /\ model' = m
       \* Старый код обнулял кэш встречи; идущая встреча держит свою ссылку сама.
       /\ IF Shared
          THEN RebuildWith(mode, m)
          ELSE /\ slot' = None
               /\ IF mode = "local"
                  THEN /\ CanLoad
                       /\ dict' = NewId
                       /\ modelOf' = [modelOf EXCEPT ![NewId] = m]
                       /\ loads' = NewId
                  ELSE UNCHANGED <<dict, modelOf, loads>>
  /\ UNCHANGED <<mode, meet, meetingOn>>

MeetingStart ==
  /\ Step
  /\ ~meetingOn
  /\ meetingOn' = TRUE
  /\ IF Shared
     THEN IF SlotHit
          THEN /\ meet' = slot /\ UNCHANGED <<slot, modelOf, loads>>
          ELSE /\ CanLoad
               /\ meet' = NewId /\ slot' = NewId
               /\ modelOf' = [modelOf EXCEPT ![NewId] = model]
               /\ loads' = NewId
     \* Старый код: кэш встречи — копия диктовки в локальном режиме, иначе своя.
     ELSE IF slot # None
          THEN /\ meet' = slot /\ UNCHANGED <<slot, modelOf, loads>>
          ELSE IF mode = "local" /\ dict # None
               THEN /\ meet' = dict /\ slot' = dict /\ UNCHANGED <<modelOf, loads>>
               ELSE /\ CanLoad
                    /\ meet' = NewId /\ slot' = NewId
                    /\ modelOf' = [modelOf EXCEPT ![NewId] = model]
                    /\ loads' = NewId
  /\ UNCHANGED <<mode, model, dict>>

MeetingEnd ==
  /\ Step
  /\ meetingOn
  /\ meetingOn' = FALSE
  /\ meet' = None
  /\ slot' = Released(mode, FALSE, slot)
  /\ UNCHANGED <<mode, model, dict, modelOf, loads>>

Next == Rebuild \/ SetMode \/ SwitchModel \/ MeetingStart \/ MeetingEnd

Spec == Init /\ [][Next]_vars

\* Вне встречи в памяти не больше одной копии.
IdleOneCopy == ~meetingOn => Cardinality(Loaded) <= 1

\* Две копии одной и той же модели не живут никогда.
NoTwinCopies ==
  \A a, b \in Loaded: a # b => modelOf[a] # modelOf[b]

\* Облачная диктовка без встречи — модели в памяти нет.
CloudIdleFree == (mode = "cloud" /\ ~meetingOn) => Loaded = {}

=============================================================================
