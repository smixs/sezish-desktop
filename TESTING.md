# Тестирование десктопных сборок

## Готовые сборки

| Платформа | Ссылка |
|---|---|
| Windows (x64) | https://dl.sezi.sh/win/sezish-setup.exe |
| macOS (Apple Silicon) | https://dl.sezi.sh/sezish.dmg |

Обновления приходят сами: на Windows встроенный апдейтер, на macOS Sparkle.

## Сборка Windows из исходников

Нужны: Rust (stable), MSVC toolchain, LLVM (`choco install llvm`), tauri-cli.

```powershell
cargo install tauri-cli --version "^2" --locked
cd win
cargo tauri build --config src-tauri/tauri.conf.json
```

Инсталлер появится в `win\target\release\bundle\nsis\`.
Для быстрой итерации: `cargo tauri dev`.

Без облачного ключа сборка работает в режиме local-only: это нормально.

## Как сообщить о баге

Создайте issue и укажите:

1. Версию приложения и версию ОС.
2. Шаги: что делали, что ожидали, что получили.
3. Скриншот или запись экрана, если есть.

## Что тестировать в первую очередь

- Диктовка: горячая клавиша, запись, вставка текста в активное окно.
- Локальное распознавание (офлайн) и облачное.
- Длинные записи (больше 3 минут).
- Автообновление.
