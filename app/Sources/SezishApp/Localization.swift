import Foundation
import SezishCore

/// UI strings, keyed by language. A code table (not .strings bundles) so the
/// settings picker switches the live UI instantly — same approach as the site's
/// JS i18n dictionary. Uzbek is modern Tashkent Latin with the ʼ apostrophe.
struct Strings {
    // Menu bar popup
    let startMeeting: String
    let stopMeeting: String
    let dictations: String
    let openFolder: String
    let openFolderHelp: String
    let emptyYet: String
    let copyLast: String
    let noTextRow: String
    let noTextRowHelp: String
    let copyRowHelp: String
    let rowHint: String
    let settingsItem: String
    let checkUpdates: String
    let quit: String

    // Model
    let downloadModel: String
    let downloadingModel: String
    let modelInstalled: String
    let modelSection: String
    let modelFooter: String
    let modelMultiTitle: String
    let modelMultiSubtitle: String
    let modelRuEnTitle: String
    let modelRuEnSubtitle: String
    let modelInactiveHint: String
    /// One verb for every delete button: a model, a stored take.
    let delete: String

    // Settings: recognition
    let recognition: String
    let cloudTitle: String
    let cloudSubtitle: String
    let cloudUnavailable: String
    let localTitle: String
    let localSubtitle: String

    // Settings: language
    let language: String

    // Settings: general
    let general: String
    let autoRecordCalls: String
    let launchAtLogin: String
    let launchHiddenToggle: String
    let launchHiddenHint: String
    let soundsToggle: String

    // Settings: notes folder
    let notesFolder: String
    let notSelected: String
    let choose: String
    /// Same action as `choose` but without the trailing ellipsis.
    let choosePrompt: String

    // Settings: summary
    /// Pane title in the settings sidebar.
    let paneSummary: String
    let summaryToggle: String
    /// Subtitles of the two engine options: what the user must already pay for.
    let summaryEngineClaude: String
    let summaryEngineCodex: String
    let summaryChecking: String
    let summaryNotInstalled: String
    let summaryInstall: String
    let summaryInstalling: String
    let summaryNeedsLogin: String
    let summaryLogin: String
    let summaryWaitingBrowser: String
    let summaryOpenAgain: String
    let summaryEnterCode: String
    let summaryConfirm: String
    let summaryCancel: String
    let summaryReady: String
    let summaryFailed: String
    let summaryRetry: String
    let summaryDeviceCodeHint: String
    let summaryOpen: String
    /// Shown instead of a second folder picker — the picker itself stays in General.
    let summaryNoNotesFolder: String

    // Settings: hotkey
    /// Pane title in the settings sidebar.
    let paneHotkey: String
    let hotkeySection: String
    /// Label of the hold-vs-toggle switch.
    let holdModeToggle: String
    let shortcutLabel: String
    let hotkeyModeHoldHint: String
    let hotkeyModeToggleHint: String
    let recorderPrompt: String
    let recorderHelp: String
    let recorderNeedsModifier: String
    /// Side words for modifier-only shortcut labels ("Левый ⌘" / "Chap ⌘").
    let keyLeft: String
    let keyRight: String

    // Settings: updates
    /// Pane title in the settings sidebar.
    let paneUpdates: String
    let updatesVersion: String
    let updatesAutoCheck: String

    // Settings: permissions
    let permissions: String
    let accessibility: String
    let granted: String
    let neededForHotkey: String
    let openSystemSettings: String
    let microphone: String
    let neededForSpeech: String
    let allow: String
    let restartBannerText: String
    let restart: String

    // Meeting recording
    let meetingPanelTitle: String
    let meetingPanelAuto: String
    let meetingPanelManual: String
    let meetingStop: String
    let meetingHide: String
    let meetingProcessing: String
    let notifSystemAudioDenied: String
    let notifMeetingFailed: String
    let notifTranscriptReady: String
    let notifMeetingNoTranscript: String
    let notifLocalLongMeeting: String
    /// Fired once per meeting rebuilt from stems a crash left behind.
    let notifMeetingRecovered: String
    /// Fired when the summary CLI finished and the vault cards are on disk.
    let notifSummaryReady: String
    /// Fired when it did not. The log is named because there is no UI for the
    /// details — the file is where they live.
    let notifSummaryFailed: String
    let meetingDocTitle: String
    let meetingDocDuration: String
    /// Italic banner under the title of a salvaged meeting's transcript.
    let meetingDocRecovered: String
    /// Metadata line stating where the text was recognised — always on-device.
    let meetingDocEngine: String
    /// Prefix of a transcript line from the mic track ("[3:12] Я: текст").
    let meetingSpeakerMe: String
    /// Same, for the system-audio track — everyone else on the call.
    let meetingSpeakerThem: String

    // Notifications
    let notifModelMissing: String
    let notifRecordFailed: String
    let notifNoText: String
    let notifDictationFailed: String
    let notifModelDownloadFailed: String
    let modelLoadErrorPrefix: String
    let downloadIncomplete: String

    // Retrying a take whose text never came out
    let retryTranscription: String
    let revealAudio: String
    let notifRetryDone: String
    let notifRetryFailed: String
    /// Carries a `%d`: how many meetings are still waiting for a transcript.
    let meetingsPending: String
    let notifMeetingRetryHint: String
    let notifMeetingPartial: String

    // Settings: history
    /// Pane title in the settings sidebar.
    let paneHistory: String
    let historyMeetings: String
    /// Reveals a document in Finder; the audio has its own, longer label.
    let revealFile: String
    /// Status line of a meeting whose stems are still parked for a retry.
    let meetingNeedsRetry: String
    let openMeetingsFolder: String

    // Settings: Gemini dictation (the user's own Google key)
    let geminiTitle: String
    let geminiSubtitle: String
    let geminiSection: String
    let geminiKeyLabel: String
    let geminiKeyPlaceholder: String
    let geminiKeyMissing: String
    let geminiFooter: String
    let geminiGetKey: String
    let geminiSmartTitle: String
    let geminiSmartSubtitle: String
}

extension Strings {
    static func forLanguage(_ language: AppLanguage) -> Strings {
        switch language {
        case .ru: .ru
        case .uz: .uz
        // The Mac app is written in two languages; the other three exist for the
        // phone. Reading them in Russian is what this app did for every non-uz
        // system before those cases existed.
        case .kk, .ky, .en: .ru
        }
    }


    static let ru = Strings(
        startMeeting: "Начать запись встречи",
        stopMeeting: "Остановить запись встречи",
        dictations: "Диктовки",
        openFolder: "Открыть папку",
        openFolderHelp: "Все записи (.wav) в Finder",
        emptyYet: "Пока пусто",
        copyLast: "Скопировать последнюю",
        noTextRow: "Текст не распознался",
        noTextRowHelp: "Аудио сохранено. Клик распознаёт заново",
        copyRowHelp: "Скопировать в буфер",
        rowHint: "Клик копирует текст. ↻ распознаёт заново",
        settingsItem: "Настройки…",
        checkUpdates: "Проверить обновления",
        quit: "Выйти",
        downloadModel: "Скачать модель (225 МБ)",
        downloadingModel: "Скачивание модели…",
        modelInstalled: "Модель установлена",
        modelSection: "Модель",
        modelFooter: "Для диктовки и записи встреч",
        modelMultiTitle: "Русский, узбекский, казахский, кыргызский",
        modelMultiSubtitle: "Без знаков препинания. 225 МБ",
        modelRuEnTitle: "Русский и английский",
        modelRuEnSubtitle: "Знаки препинания и заглавные буквы. 225 МБ",
        modelInactiveHint: "Скачана, не используется",
        delete: "Удалить",
        recognition: "Распознавание",
        cloudTitle: "Облако",
        cloudSubtitle: "Быстро и без скачиваний. Нужен интернет",
        cloudUnavailable: "Недоступно в этой сборке",
        localTitle: "Локально",
        localSubtitle: "Офлайн, речь не покидает Мак",
        language: "Язык",
        general: "Общие",
        autoRecordCalls: "Автозапись звонков",
        launchAtLogin: "Запуск при входе",
        launchHiddenToggle: "Запускать свёрнутым",
        launchHiddenHint: "Окно настроек не откроется при запуске. Приложение остаётся в строке меню",
        soundsToggle: "Звуки",
        notesFolder: "Папка заметок",
        notSelected: "Не выбрана",
        choose: "Выбрать…",
        choosePrompt: "Выбрать",
        paneSummary: "AI-саммари",
        summaryToggle: "Саммари после встреч",
        summaryEngineClaude: "Подписка Claude Pro или Max",
        summaryEngineCodex: "Подписка ChatGPT",
        summaryChecking: "Проверяю…",
        summaryNotInstalled: "Не установлен",
        summaryInstall: "Установить",
        summaryInstalling: "Устанавливаю…",
        summaryNeedsLogin: "Установлен, нужен вход",
        summaryLogin: "Войти",
        summaryWaitingBrowser: "Жду вход в браузере…",
        summaryOpenAgain: "Открыть ссылку ещё раз",
        summaryEnterCode: "Ввести код вручную",
        summaryConfirm: "Подтвердить",
        summaryCancel: "Отмена",
        summaryReady: "Готов",
        summaryFailed: "Не получилось",
        summaryRetry: "Повторить",
        summaryDeviceCodeHint: "Откройте ссылку и введите код",
        summaryOpen: "Открыть",
        summaryNoNotesFolder: "Укажите папку заметок во вкладке «Общие»",
        paneHotkey: "Горячая клавиша",
        hotkeySection: "Горячая клавиша диктовки",
        holdModeToggle: "Запись при удержании клавиши",
        shortcutLabel: "Сочетание клавиш",
        hotkeyModeHoldHint: "Запись идёт, пока клавиша удержана",
        hotkeyModeToggleHint: "Нажмите — начать, ещё раз — остановить. Esc — отмена",
        recorderPrompt: "Нажмите сочетание…  (Esc — отмена)",
        recorderHelp: "Нажмите, затем задайте клавишу или сочетание для диктовки",
        recorderNeedsModifier: "Добавьте ⌘, ⌥, ⌃ или ⇧",
        keyLeft: "Левый",
        keyRight: "Правый",
        paneUpdates: "Обновления",
        updatesVersion: "Версия",
        updatesAutoCheck: "Проверять обновления автоматически",
        permissions: "Доступы",
        accessibility: "Универсальный доступ",
        granted: "Разрешён",
        neededForHotkey: "Нужен для горячей клавиши",
        openSystemSettings: "Открыть Настройки",
        microphone: "Микрофон",
        neededForSpeech: "Нужен для записи речи",
        allow: "Разрешить",
        restartBannerText: "Перезапустите sezish, чтобы включить горячую клавишу",
        restart: "Перезапустить",
        meetingPanelTitle: "Идёт запись звонка",
        meetingPanelAuto: "Началась автоматически",
        meetingPanelManual: "Запись началась",
        meetingStop: "Остановить",
        meetingHide: "Скрыть",
        meetingProcessing: "Обрабатываю запись…",
        notifSystemAudioDenied: "Нет доступа к системному звуку — пишется только микрофон. Разрешение: Настройки → Конфиденциальность → Запись экрана и системного звука.",
        notifMeetingFailed: "Запись встречи не получилась.",
        notifTranscriptReady: "Транскрипт встречи готов.",
        notifMeetingNoTranscript: "Текст не распознался, аудио встречи сохранено.",
        notifLocalLongMeeting: "Длинная запись в локальном режиме: распознавание займёт несколько минут и много памяти.",
        notifMeetingRecovered: "Запись встречи восстановлена после сбоя",
        notifSummaryReady: "Саммари встречи готово",
        notifSummaryFailed: "Саммари не получилось — детали в summary.log",
        meetingDocTitle: "Запись звонка",
        meetingDocDuration: "Длительность",
        meetingDocRecovered: "Восстановлено после сбоя",
        meetingDocEngine: "Распознано локально на устройстве",
        meetingSpeakerMe: "Я",
        meetingSpeakerThem: "Они",
        notifModelMissing: "Модель ещё не скачана. Откройте меню sezish и нажмите «Скачать модель».",
        notifRecordFailed: "Не удалось начать запись. Проверьте доступ к микрофону.",
        notifNoText: "Текст не распознался. Аудио сохранено, распознать заново можно из меню sezish.",
        notifDictationFailed: "Запись не получилась. Проверьте доступ к микрофону в Настройках.",
        notifModelDownloadFailed: "Не удалось скачать модель. Попробуйте ещё раз.",
        modelLoadErrorPrefix: "Не удалось загрузить модель: ",
        downloadIncomplete: "Загрузка не завершена",
        retryTranscription: "Распознать заново",
        revealAudio: "Показать аудио",
        notifRetryDone: "Распознано заново. Текст в буфере обмена.",
        notifRetryFailed: "Снова не распознался. Аудио на месте.",
        meetingsPending: "Встречи без текста: %d",
        notifMeetingRetryHint: "Распознать заново: меню sezish.",
        notifMeetingPartial: "Распознано частично. Аудио сохранено, можно распознать заново.",
        paneHistory: "История",
        historyMeetings: "Встречи",
        revealFile: "Показать",
        meetingNeedsRetry: "Без текста, можно распознать заново",
        openMeetingsFolder: "Открыть папку встреч",
        geminiTitle: "Gemini 3.5 Transcribe",
        geminiSubtitle: "Стрим через Google, около $0.01 за минуту. Нужен ключ Google AI Studio",
        geminiSection: "Gemini",
        geminiKeyLabel: "Ключ API",
        geminiKeyPlaceholder: "Вставьте ключ",
        geminiKeyMissing: "Без ключа диктовка идёт через облако или локальную модель",
        geminiFooter: "Ключ хранится на этом Маке и уходит только в Google",
        geminiGetKey: "Получить ключ",
        geminiSmartTitle: "Умная расшифровка",
        geminiSmartSubtitle: "Убирает слова-паразиты и мат, расставляет пунктуацию. Выключите для дословного текста"
    )

    static let uz = Strings(
        startMeeting: "Uchrashuvni yozishni boshlash",
        stopMeeting: "Uchrashuv yozuvini toʼxtatish",
        dictations: "Diktovkalar",
        openFolder: "Papkani ochish",
        openFolderHelp: "Barcha yozuvlar (.wav) Finderda",
        emptyYet: "Hozircha boʼsh",
        copyLast: "Oxirgisini nusxalash",
        noTextRow: "Matn aniqlanmadi",
        noTextRowHelp: "Audio saqlandi. Bosilsa qayta aniqlanadi",
        copyRowHelp: "Buferga nusxalash",
        rowHint: "Bosilsa matn nusxalanadi. ↻ qayta aniqlaydi",
        settingsItem: "Sozlamalar…",
        checkUpdates: "Yangilanishlarni tekshirish",
        quit: "Chiqish",
        downloadModel: "Modelni yuklab olish (225 MB)",
        downloadingModel: "Model yuklanmoqda…",
        modelInstalled: "Model oʼrnatilgan",
        modelSection: "Model",
        modelFooter: "Diktovka va uchrashuv yozuvlari uchun",
        modelMultiTitle: "Rus, oʼzbek, qozoq, qirgʼiz",
        modelMultiSubtitle: "Tinish belgilarisiz. 225 MB",
        modelRuEnTitle: "Rus va ingliz",
        modelRuEnSubtitle: "Tinish belgilari va bosh harflar bilan. 225 MB",
        modelInactiveHint: "Yuklab olingan, ishlatilmayapti",
        delete: "Oʼchirish",
        recognition: "Nutqni aniqlash",
        cloudTitle: "Bulut",
        cloudSubtitle: "Tez, yuklab olishsiz. Internet kerak",
        cloudUnavailable: "Bu versiyada mavjud emas",
        localTitle: "Qurilmada",
        localSubtitle: "Oflayn, nutq Makdan chiqmaydi",
        language: "Til",
        general: "Umumiy",
        autoRecordCalls: "Qoʼngʼiroqlarni avtomatik yozish",
        launchAtLogin: "Kirishda ishga tushirish",
        launchHiddenToggle: "Oynasiz ishga tushirish",
        launchHiddenHint: "Ishga tushganda sozlamalar oynasi ochilmaydi. Ilova menyu satrida qoladi",
        soundsToggle: "Tovushlar",
        notesFolder: "Qaydlar papkasi",
        notSelected: "Tanlanmagan",
        choose: "Tanlash…",
        choosePrompt: "Tanlash",
        paneSummary: "AI xulosa",
        summaryToggle: "Uchrashuvdan keyin xulosa",
        summaryEngineClaude: "Claude Pro yoki Max obunasi",
        summaryEngineCodex: "ChatGPT obunasi",
        summaryChecking: "Tekshiryapman…",
        summaryNotInstalled: "Oʼrnatilmagan",
        summaryInstall: "Oʼrnatish",
        summaryInstalling: "Oʼrnatyapman…",
        summaryNeedsLogin: "Oʼrnatilgan, kirish kerak",
        summaryLogin: "Kirish",
        summaryWaitingBrowser: "Brauzerda kirishni kutyapman…",
        summaryOpenAgain: "Havolani qayta ochish",
        summaryEnterCode: "Kodni qoʼlda kiritish",
        summaryConfirm: "Tasdiqlash",
        summaryCancel: "Bekor qilish",
        summaryReady: "Tayyor",
        summaryFailed: "Xato chiqdi",
        summaryRetry: "Qaytadan",
        summaryDeviceCodeHint: "Havolani oching va kodni kiriting",
        summaryOpen: "Ochish",
        summaryNoNotesFolder: "\"Umumiy\" boʼlimida eslatmalar papkasini tanlang",
        paneHotkey: "Tezkor tugma",
        hotkeySection: "Diktovka uchun tezkor tugma",
        holdModeToggle: "Tugma bosib turilganda yozish",
        shortcutLabel: "Tugmalar birikmasi",
        hotkeyModeHoldHint: "Yozish tugma bosib turilganda davom etadi",
        hotkeyModeToggleHint: "Bosing — boshlash, yana bosing — toʼxtatish. Esc — bekor qilish",
        recorderPrompt: "Birikmani bosing…  (Esc - bekor)",
        recorderHelp: "Bosing, soʼng diktovka uchun tugma yoki birikmani belgilang",
        recorderNeedsModifier: "⌘, ⌥, ⌃ yoki ⇧ qoʼshing",
        keyLeft: "Chap",
        keyRight: "Oʼng",
        paneUpdates: "Yangilanishlar",
        updatesVersion: "Versiya",
        updatesAutoCheck: "Yangilanishlarni avtomatik tekshirish",
        permissions: "Ruxsatlar",
        accessibility: "Maxsus imkoniyatlar",
        granted: "Ruxsat berilgan",
        neededForHotkey: "Tezkor tugma uchun kerak",
        openSystemSettings: "Sozlamalarni ochish",
        microphone: "Mikrofon",
        neededForSpeech: "Nutq yozish uchun kerak",
        allow: "Ruxsat berish",
        restartBannerText: "Tezkor tugma ishlashi uchun sezishni qayta ishga tushiring",
        restart: "Qayta ishga tushirish",
        meetingPanelTitle: "Qoʼngʼiroq yozilmoqda",
        meetingPanelAuto: "Avtomatik boshlandi",
        meetingPanelManual: "Yozish boshlandi",
        meetingStop: "Toʼxtatish",
        meetingHide: "Yashirish",
        meetingProcessing: "Yozuv qayta ishlanmoqda…",
        notifSystemAudioDenied: "Tizim ovoziga ruxsat yoʼq, faqat mikrofon yozilmoqda. Ruxsat: Sozlamalar → Maxfiylik → Ekran va tizim ovozini yozish.",
        notifMeetingFailed: "Uchrashuv yozuvi amalga oshmadi.",
        notifTranscriptReady: "Uchrashuv transkripti tayyor.",
        notifMeetingNoTranscript: "Matn aniqlanmadi, uchrashuv audiosi saqlandi.",
        notifLocalLongMeeting: "Lokal rejimda uzun yozuv: aniqlash bir necha daqiqa va koʼp xotira oladi.",
        notifMeetingRecovered: "Uchrashuv yozuvi tiklandi",
        notifSummaryReady: "Uchrashuv xulosasi tayyor",
        notifSummaryFailed: "Xulosa chiqmadi — batafsil summary.log faylida",
        meetingDocTitle: "Qoʼngʼiroq yozuvi",
        meetingDocDuration: "Davomiyligi",
        meetingDocRecovered: "Nosozlikdan keyin tiklangan yozuv",
        meetingDocEngine: "Matn qurilmaning oʼzida aniqlangan",
        meetingSpeakerMe: "Men",
        meetingSpeakerThem: "Ular",
        notifModelMissing: "Model hali yuklab olinmagan. sezish menyusida «Modelni yuklab olish»ni bosing.",
        notifRecordFailed: "Yozishni boshlab boʼlmadi. Mikrofon ruxsatini tekshiring.",
        notifNoText: "Matn aniqlanmadi. Audio saqlandi, sezish menyusidan qayta aniqlash mumkin.",
        notifDictationFailed: "Yozish amalga oshmadi. Sozlamalarda mikrofon ruxsatini tekshiring.",
        notifModelDownloadFailed: "Modelni yuklab boʼlmadi. Yana urinib koʼring.",
        modelLoadErrorPrefix: "Modelni yuklashda xato: ",
        downloadIncomplete: "Yuklash tugallanmadi",
        retryTranscription: "Qayta aniqlash",
        revealAudio: "Audioni koʼrsatish",
        notifRetryDone: "Qayta aniqlandi. Matn buferda.",
        notifRetryFailed: "Yana aniqlanmadi. Audio joyida.",
        meetingsPending: "Matnsiz uchrashuvlar: %d",
        notifMeetingRetryHint: "Qayta aniqlash: sezish menyusi.",
        notifMeetingPartial: "Qisman aniqlandi. Audio saqlandi, qayta aniqlash mumkin.",
        paneHistory: "Tarix",
        historyMeetings: "Uchrashuvlar",
        revealFile: "Koʼrsatish",
        meetingNeedsRetry: "Matnsiz, qayta aniqlash mumkin",
        openMeetingsFolder: "Uchrashuvlar papkasini ochish",
        geminiTitle: "Gemini 3.5 Transcribe",
        geminiSubtitle: "Google orqali stream, daqiqasi taxminan $0.01. Google AI Studio kaliti kerak",
        geminiSection: "Gemini",
        geminiKeyLabel: "API kaliti",
        geminiKeyPlaceholder: "Kalitni joylashtiring",
        geminiKeyMissing: "Kalitsiz diktovka bulut yoki qurilmadagi model orqali ishlaydi",
        geminiFooter: "Kalit shu Makda saqlanadi va faqat Googlega yuboriladi",
        geminiGetKey: "Kalit olish",
        geminiSmartTitle: "Aqlli matn",
        geminiSmartSubtitle: "Ortiqcha soʼzlar va soʼkinishni olib tashlaydi, tinish belgilarini qoʼyadi. Soʼzma-soʼz matn uchun oʼchiring"
    )
}
