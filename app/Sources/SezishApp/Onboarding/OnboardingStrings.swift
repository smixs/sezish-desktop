import Foundation
import SezishCore

/// Text of the first-run tour. Kept beside `Strings` so the tour can grow without
/// touching the long memberwise tables; same two languages, same ʼ apostrophe.
struct OnboardingStrings {
    let windowTitle: String

    // Permissions
    let permissionsTitle: String
    let permissionsSubtitle: String
    let microphone: String
    let microphoneHint: String
    let accessibility: String
    let accessibilityHint: String
    let allow: String
    let allowed: String
    let openSettings: String
    let deniedHint: String
    let staleHint: String
    let fixStale: String
    let restartHint: String
    let restart: String
    let needsRestart: String
    let guideDrag: String
    let guideSwitchOn: String

    // Engine
    let engineTitle: String
    let engineSubtitle: String
    let cloudTitle: String
    let cloudHint: String
    let localTitle: String
    let localHint: String
    let recommended: String
    let downloading: String
    let downloadFailed: String
    let retry: String
    let ready: String

    // Done
    let doneTitle: String
    let holdPrefix: String
    let holdSuffix: String
    let pressPrefix: String
    let pressSuffix: String
    let livesInMenuBar: String
    let launchAtLogin: String
    let changeKey: String
    let start: String
    let waitingForModel: String

    let runAgain: String

    let `continue`: String
    let back: String

    static func forLanguage(_ language: AppLanguage) -> OnboardingStrings {
        language == .uz ? .uz : .ru
    }

    static let ru = OnboardingStrings(
        windowTitle: "Настройка sezish",
        permissionsTitle: "Пусть sezish слышит и печатает за вас",
        permissionsSubtitle: "macOS спросит один раз. Поменять можно в Системных настройках.",
        microphone: "Микрофон",
        microphoneHint: "Слушает, только пока вы держите клавишу",
        accessibility: "Универсальный доступ",
        accessibilityHint: "Замечает клавишу и вставляет текст в любое приложение",
        allow: "Разрешить",
        allowed: "Разрешено",
        openSettings: "Открыть настройки",
        deniedHint: "Выключен. Включите sezish в Системных настройках",
        staleHint: "Старая запись sezish может держать его выключенным",
        fixStale: "Всё ещё серое? Исправить",
        restartHint: "Включится после перезапуска sezish",
        restart: "Перезапустить sezish",
        needsRestart: "Нужен перезапуск",
        guideDrag: "Перетащите sezish в список выше",
        guideSwitchOn: "Включите sezish в списке выше",
        engineTitle: "Где распознавать речь",
        engineSubtitle: "Поменять можно в настройках, в разделе «Распознавание».",
        cloudTitle: "В облаке",
        cloudHint: "Работает сразу. Нужен интернет",
        localTitle: "На этом Mac",
        localHint: "Без интернета, речь не покидает Mac. Модель 225 МБ",
        recommended: "Рекомендуем",
        downloading: "Скачивается",
        downloadFailed: "Не скачалась",
        retry: "Повторить",
        ready: "Готово",
        doneTitle: "sezish готов",
        holdPrefix: "Удерживайте",
        holdSuffix: "где угодно и говорите",
        pressPrefix: "Нажмите",
        pressSuffix: "где угодно и говорите, нажмите ещё раз — готово",
        livesInMenuBar: "Живёт в строке меню",
        launchAtLogin: "Запускать при входе",
        changeKey: "Сменить клавишу",
        start: "Начать",
        waitingForModel: "Ждём модель",
        runAgain: "Пройти настройку заново",
        continue: "Дальше",
        back: "Назад"
    )

    static let uz = OnboardingStrings(
        windowTitle: "sezish sozlamasi",
        permissionsTitle: "sezish sizni eshitsin va siz uchun yozsin",
        permissionsSubtitle: "macOS bir marta soʼraydi. Istalgan payt Tizim sozlamalarida oʼzgartirish mumkin.",
        microphone: "Mikrofon",
        microphoneHint: "Faqat tugmani bosib turganingizda eshitadi",
        accessibility: "Maxsus imkoniyatlar",
        accessibilityHint: "Tugmani sezadi va matnni istalgan ilovaga qoʼyadi",
        allow: "Ruxsat berish",
        allowed: "Ruxsat berildi",
        openSettings: "Sozlamalarni ochish",
        deniedHint: "Oʼchirilgan. Tizim sozlamalarida sezishni yoqing",
        staleHint: "Eski sezish yozuvi uni oʼchiq holda ushlab turishi mumkin",
        fixStale: "Hali ham kulrangmi? Tuzatish",
        restartHint: "sezish qayta ishga tushgach yoqiladi",
        restart: "sezishni qayta ishga tushirish",
        needsRestart: "Qayta ishga tushirish kerak",
        guideDrag: "sezishni yuqoridagi roʼyxatga torting",
        guideSwitchOn: "Yuqoridagi roʼyxatda sezishni yoqing",
        engineTitle: "Nutq qayerda aniqlansin",
        engineSubtitle: "Sozlamalarning «Nutqni aniqlash» boʼlimida oʼzgartirish mumkin.",
        cloudTitle: "Bulutda",
        cloudHint: "Darhol ishlaydi. Internet kerak",
        localTitle: "Shu Makda",
        localHint: "Internetsiz, nutq Makdan chiqmaydi. Model 225 MB",
        recommended: "Tavsiya etamiz",
        downloading: "Yuklanmoqda",
        downloadFailed: "Yuklanmadi",
        retry: "Qaytadan",
        ready: "Tayyor",
        doneTitle: "sezish tayyor",
        holdPrefix: "Istalgan joyda",
        holdSuffix: "tugmasini bosib turib gapiring",
        pressPrefix: "Istalgan joyda",
        pressSuffix: "tugmasini bosib gapiring, yana bosing — tayyor",
        livesInMenuBar: "Menyu satrida yashaydi",
        launchAtLogin: "Kirishda ishga tushirish",
        changeKey: "Tugmani almashtirish",
        start: "Boshlash",
        waitingForModel: "Modelni kutyapmiz",
        runAgain: "Sozlashni qaytadan oʼtish",
        continue: "Davom etish",
        back: "Orqaga"
    )
}
