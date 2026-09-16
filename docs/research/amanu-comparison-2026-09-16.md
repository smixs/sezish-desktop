# Amanu vs sezish (macOS meetings), 2026-09-16

Источник: github.com/gsamat/amanu, коммит «Publish amanu 0.4.25» (16.09.2026), shallow clone, прочитаны
Audio/MicActivityMonitor, Audio/AudioProcesses, Audio/SystemAudioRecorder, Audio/MicRoute, Audio/EchoCanceller,
Meetings/AutoRecordController, Meetings/CalendarWatcher, Meetings/MeetingContext, Sessions/SpeakerNamer,
Sessions/SessionClaim, Transcription/SpeakerAttribution, Transcription/EchoFilter, Config, docs/pitfalls.md, .issues/*.
MIT-лицензия.

## Как amanu определяет «идёт звонок»

- Тот же источник, что у нас: `kAudioHardwarePropertyProcessObjectList` + `IsRunningInput` (macOS 14.4+).
- Правило противоположное нашему: **whitelist** префиксов bundle id (`defaultCallApps`: Zoom, Teams, Telegram ×2,
  WhatsApp, FaceTime, Discord, Telemost, Express, kontur.talk и все браузеры) плюс маленький `alwaysIgnored`
  (VoiceMemos, Siri, speechrecognitiond, VoiceInk). Пустой список = «любой процесс» (наш режим).
  Флаг output в детекции не используется.
- Тайминги: тик 5 с, start 12 с, stop 15 с (и тишина на far-end ≥ 15 с), minDuration 45 с, потолок 300 мин,
  тишина на обоих треках 10 мин = стоп. У нас: тик 1 с, start 2 с, stop 10 с, порог транскрипции 60 с,
  потолка и стоп-по-тишине нет.
- Второй триггер: календарь (EventKit, opt-in), событие «похоже на звонок» = есть участники или ссылка;
  окно 3 мин после начала; конец события + 2 мин + тишина far-end 60 с = стоп.
- Discard короткой записи считает длину встречи как `длина файла − ожидание стоп-правила`
  (.issues/008: иначе правило недостижимо). У нас порог по сырой длительности файла.
- «lastDecision» - строка в меню «почему не пишу»: «микрофон занят: X, это не приложение для звонков».
- После ручного стопа автозапись молчит до конца текущего звонка; ручная запись авто-правилами не трогается.

Вывод по детекции: наш full-duplex + deny-list ловит незнакомые приложения, у amanu whitelist безопаснее от
ложных записей. Менять правило не надо. Брать нужно то, что whitelist даёт дальше: «семейство» процесса.

## Что у amanu есть, а у нас нет

1. **Тап только на процессы звонка.** `CATapDescription(stereoMixdownOfProcesses:)` по семейству bundle id
   (Chrome → все helper'ы), fallback на глобальный тап, если процессов нет; на macOS 26 тап следует за
   перезапуском приложения. У нас `monoGlobalTapButExcludeProcesses: []` - музыка и уведомления попадают
   в «Они». Наш детектор уже знает bundleID кандидата, семейство = префикс до `.helper`.
2. **Микрофон вслед за приложением звонка.** `kAudioProcessPropertyDevices` у процесса Zoom → пишем то
   устройство, в которое человек говорит, а не system default; default меняется под запись - AVAudioEngine
   молча остаётся на старом (замерено 20.08.2026).
3. **Эхоподавление после записи.** Мик пишется raw (voice-processing глушит playback собеседнику),
   потом LocalVQE (gguf-модель ~AEC, dylib) чистит копию мика по референсу system-трека, затем текстовый
   проход EchoFilter снимает точные повторы ≥ 5 слов. Наш ADR-0013 фиксирует это как «известный лимит».
4. **Стоп по тишине и потолок длительности** - страховка от приложения, не отпускающего микрофон
   (у них было 15 часов записи за ночь).
5. **Имена спикеров.** Диаризация внутри «them» (AssemblyAI multichannel / OpenAI diarize), majority-verdict
   «me/them» по огибающей 100 мс, затем LLM даёт имена из участников календаря и обращений в тексте; принимается
   только high confidence и только если цитата-доказательство реально есть в транскрипте; `speakers.json`.
6. **Календарь как контекст:** имя папки `2026.08.17-2039 Integration sync (zoom.us)`, участники в промпт саммари.
7. **Папка = база.** `meta.json`, `.recording.json` (владелец pid), `.transcribing.json` (claim через O_EXCL,
   чтобы app и CLI не транскрибировали одно дважды), `transcribe.log`; аудио - PCM CAF до транскрипта, потом
   стерео AAC (L=мик, R=система). У нас PCM spool + salvage уже есть, но архив моно-микс.
8. **CLI** `amanu record|process|sessions|setup|doctor`, импорт готовых файлов (drag&drop, нормализация).
9. **Цепочка бэкендов:** CLI-подписки (Claude Code, Codex) приоритетнее API-ключей, при исчерпании падает
   на следующий; работа без сети помечается deferred и возобновляется.
10. **Sparkle не обновляет во время записи;** App Nap activity на всё время жизни (иначе таймеры дрейфуют).
11. `.issues/` с RCA и «failures become tests», `docs/pitfalls.md` (TCC на код-подпись, права уходят терминалу
    при запуске из shell, hardened runtime молча закрывает EventKit без entitlement).

## Что у нас лучше или не хуже

- Детекция незнакомых приложений (duplex + deny-list, sticky output для браузера на тихом звонке).
- Meeting-hook (у amanu нет), диктация, узбекский, GigaAM у обоих.
- Live-транскрипт есть у обоих (у них FluidAudio/Nemotron, опционально).

## Рекомендация (по цене)

Дёшево, сразу: (1) тап по семейству процесса вместо глобального, (2) стоп по тишине + потолок,
(3) строка «почему не пишу» в меню, (4) discard с вычетом ожидания стопа.
Средне: (5) мик вслед за приложением, (6) календарь для имени встречи и участников.
Дорого: (7) LocalVQE-эхоподавление (проверить лицензию модели), (8) имена спикеров через LLM с проверкой цитат.
