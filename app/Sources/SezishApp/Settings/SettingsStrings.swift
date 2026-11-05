import Foundation
import SezishCore

/// Text of the redesigned settings window (General card, History, Meetings).
/// Beside `Strings` for the same reason as `OnboardingStrings`.
struct SettingsStrings {
    let permissionsNeeded: String
    let shortcutMode: String
    let modeHold: String
    let modeToggle: String
    let advanced: String
    let quit: String
    let version: String

    let search: String
    let nothingFound: String
    let today: String
    let yesterday: String
    let copy: String
    let copied: String
    let listen: String

    let recordings: String
    let meetingSettings: String
    let summary: String
    let transcript: String
    let openSummary: String
    let copyTranscript: String
    let showInFinder: String
    let retryTranscript: String
    let retrySummary: String
    let rename: String
    let save: String
    let cancel: String
    let pickMeeting: String
    let noTranscript: String
    let minutes: String
    let meetingsItem: String

    static func forLanguage(_ language: AppLanguage) -> SettingsStrings {
        language == .uz ? .uz : .ru
    }

    static let ru = SettingsStrings(
        permissionsNeeded: "Нужны разрешения",
        shortcutMode: "Режим клавиши",
        modeHold: "Удерживать",
        modeToggle: "Нажать",
        advanced: "Дополнительно",
        quit: "Выйти из sezish",
        version: "Версия",
        search: "Поиск",
        nothingFound: "Ничего не найдено",
        today: "Сегодня",
        yesterday: "Вчера",
        copy: "Скопировать",
        copied: "Скопировано",
        listen: "Послушать",
        recordings: "Записи",
        meetingSettings: "Настройки",
        summary: "Саммари",
        transcript: "Расшифровка",
        openSummary: "Открыть",
        copyTranscript: "Скопировать расшифровку",
        showInFinder: "Показать в Finder",
        retryTranscript: "Распознать заново",
        retrySummary: "Повторить саммари",
        rename: "Переименовать",
        save: "Сохранить",
        cancel: "Отмена",
        pickMeeting: "Выберите встречу слева",
        noTranscript: "Текст не распознался",
        minutes: "мин",
        meetingsItem: "Встречи…"
    )

    static let uz = SettingsStrings(
        permissionsNeeded: "Ruxsatlar kerak",
        shortcutMode: "Tugma rejimi",
        modeHold: "Bosib turish",
        modeToggle: "Bosish",
        advanced: "Qoʼshimcha",
        quit: "sezishdan chiqish",
        version: "Versiya",
        search: "Qidiruv",
        nothingFound: "Hech narsa topilmadi",
        today: "Bugun",
        yesterday: "Kecha",
        copy: "Nusxalash",
        copied: "Nusxalandi",
        listen: "Tinglash",
        recordings: "Yozuvlar",
        meetingSettings: "Sozlamalar",
        summary: "Xulosa",
        transcript: "Matn",
        openSummary: "Ochish",
        copyTranscript: "Matnni nusxalash",
        showInFinder: "Finderda koʼrsatish",
        retryTranscript: "Qayta aniqlash",
        retrySummary: "Xulosani qaytarish",
        rename: "Nomini oʼzgartirish",
        save: "Saqlash",
        cancel: "Bekor qilish",
        pickMeeting: "Chapdan uchrashuvni tanlang",
        noTranscript: "Matn aniqlanmadi",
        minutes: "daq",
        meetingsItem: "Uchrashuvlar…"
    )
}
