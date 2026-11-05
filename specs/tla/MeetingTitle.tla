---------------------------- MODULE MeetingTitle ----------------------------
\* Имя встречи после саммари (hex-polish п.39).
\* Человек переименовывает встречу когда угодно; саммари (и его повтор) приходит
\* в любой момент. Код: AppState.titleFromSummary в AppStateMeeting.swift и
\* MeetingTitle / MeetingDocument.renamed в SezishCore.
\*
\* Соответствие коду:
\*   UserRename   — MeetingsPane «Переименовать» → MeetingDocument.renamed, одна атомарная запись;
\*   SummaryStart — performSummary запускает агента (сотни секунд, файл в это время живёт);
\*   SummaryLand  — после .done на главном акторе: читает файл ЗАНОВО, имя автоматическое →
\*                  ставит заголовок карточки, иначе ничего;
\*   Retry        — «Повторить саммари».
\* Apply — саммари вообще ставит имя (без него встречу «хуй найдёшь», Сергей 05.11).
\* Флаги-защиты: CAS (сверка перед записью), FreshRead (сверка по файлу сейчас, а не
\* по снимку на старте саммари).

EXTENDS Naturals

CONSTANTS Apply, CAS, FreshRead, MaxRenames, MaxRuns

VARIABLES title, renamed, run, seenAuto, renames, runs
vars == <<title, renamed, run, seenAuto, renames, runs>>

Titles == {"auto", "user", "summary"}

TypeOK ==
  /\ title \in Titles
  /\ renamed \in BOOLEAN
  /\ run \in {"idle", "running", "landed"}
  /\ seenAuto \in BOOLEAN
  /\ renames \in 0..MaxRenames
  /\ runs \in 0..MaxRuns

Init ==
  /\ title = "auto"
  /\ renamed = FALSE
  /\ run = "idle"
  /\ seenAuto = TRUE
  /\ renames = 0
  /\ runs = 0

UserRename ==
  /\ renames < MaxRenames
  /\ title' = "user"
  /\ renamed' = TRUE
  /\ renames' = renames + 1
  /\ UNCHANGED <<run, seenAuto, runs>>

SummaryStart ==
  /\ run \in {"idle", "landed"}
  /\ runs < MaxRuns
  /\ run' = "running"
  /\ runs' = runs + 1
  /\ seenAuto' = (title = "auto")
  /\ UNCHANGED <<title, renamed, renames>>

\* Решение о записи: по файлу сейчас (FreshRead) или по снимку на старте.
StillAuto == IF FreshRead THEN title = "auto" ELSE seenAuto

SummaryLand ==
  /\ run = "running"
  /\ run' = "landed"
  /\ title' = IF Apply /\ (~CAS \/ StillAuto) THEN "summary" ELSE title
  /\ UNCHANGED <<renamed, seenAuto, renames, runs>>

Next == UserRename \/ SummaryStart \/ SummaryLand

Spec == Init /\ [][Next]_vars /\ WF_vars(SummaryLand) /\ WF_vars(SummaryStart)

\* Ручное имя сильнее саммари.
UserWins == renamed => title = "user"
\* Имя из саммари бывает только у встречи, которую человек не трогал.
SummaryOnlyOverAuto == title = "summary" => ~renamed

\* Без ручного переименования встреча в итоге получает имя из саммари.
NamedAfterSummary == <>[](renamed \/ title = "summary")
=============================================================================
