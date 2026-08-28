# tax — remote Orca workspace for iPhone

`tax` позволяет с iPhone подключаться к открытым workspace и терминалам Orca на Mac через зашифрованный relay. Приложение показывает ANSI/TUI-вывод, отправляет ввод в выбранный PTY, создаёт и закрывает терминалы, запускает `pi`, а также позволяет безопасно просматривать и редактировать файлы workspace.

## Архитектура

- **Orca Runtime на Mac** — источник workspace и терминалов;
- **tax remote host на Mac** — адаптер к приватному протоколу Orca и scoped file service;
- **backend/VPS** — маршрутизирует только ciphertext и отправляет APNs;
- **iOS-приложение** — SwiftUI-клиент с xterm.js renderer;
- **E2EE** — отдельный 256-битный ключ tax, которого нет на backend.

Backend не хранит terminal input/output или содержимое файлов. Неопределённо доставленный ввод автоматически не повторяется.

## Что понадобится

- запущенная Orca на Mac;
- установленный `tax` CLI (`./scripts/install.sh`);
- актуальный backend;
- iPhone с установленным приложением `tax`;
- четыре совпадающих значения:
  - backend API key;
  - tax E2EE key;
  - Host ID, обычно `mac-main`;
  - Device ID, обычно `iphone-main`.

API key, E2EE key и Orca pairing code — секреты. Не добавляйте их в Git, сообщения, скриншоты или логи.

## Как получить ключи

### 1. Backend API key

На VPS из-под `root`:

```bash
cd /home/hermes/tax
grep -m1 '^TAX_API_KEY=' server/.env | cut -d= -f2-
```

Скопируйте значение после `TAX_API_KEY=` напрямую в настройки iPhone и в конфигурацию Mac. Не публикуйте вывод команды.

На Mac настройте CLI без сохранения ключа в истории shell:

```bash
read -s 'TAX_KEY?Backend API key: '; echo
tax config \
  --server https://tax.138-249-127-23.nip.io \
  --api-key "$TAX_KEY"
unset TAX_KEY
```

### 2. Tax E2EE key

На Mac сгенерируйте отдельный ключ:

```bash
tax e2ee-key generate
```

Он сохраняется в macOS Keychain под service `tax.remote.e2ee`. Чтобы повторно показать и сразу скопировать его в clipboard:

```bash
tax e2ee-key show | pbcopy
```

Вставьте это значение в поле **256-bit encryption key** на iPhone. Backend этот ключ не получает.

### 3. Orca pairing code для Mac host

1. Откройте Orca на Mac.
2. Откройте **Orca Mobile**.
3. Сгенерируйте pairing code и выберите **Copy pairing code**.
4. Сохраните код в защищённый файл:

```bash
mkdir -p ~/.config/tax
install -m 600 /dev/null ~/.config/tax/orca-pairing
pbpaste > ~/.config/tax/orca-pairing
chmod 600 ~/.config/tax/orca-pairing
```

Pairing code относится к Orca Runtime и не заменяет tax E2EE key.

## Подключение iPhone

### 1. Настройки приложения

Откройте шестерёнку в приложении и заполните:

| Поле | Значение |
|---|---|
| Server URL | `https://tax.138-249-127-23.nip.io` |
| API Key | значение из `server/.env` |
| Host ID | `mac-main` |
| Device ID | `iphone-main` |
| 256-bit encryption key | результат `tax e2ee-key show` |

Нажмите **Save Settings**, затем **Request Push Registration**. Device token регистрируется на backend автоматически.

### 2. Запуск Mac host в фоне

Установите пользовательский LaunchAgent:

```bash
./scripts/install-remote-host-launch-agent.sh
```

Он запускается после входа в macOS, работает без открытого Terminal и автоматически перезапускает host после обрыва. API key берётся из `tax config`, E2EE key — из Keychain, pairing code — из `~/.config/tax/orca-pairing`.

Проверка и управление:

```bash
launchctl print gui/$UID/tax.remote-host
launchctl kickstart -k gui/$UID/tax.remote-host
tail -f ~/.local/state/tax/logs/remote-host.log
```

Для других идентификаторов:

```bash
./scripts/install-remote-host-launch-agent.sh \
  --host-id mac-main \
  --device-id iphone-main \
  --pairing-code-file ~/.config/tax/orca-pairing
```

Ручной foreground-запуск оставлен для диагностики:

```bash
tax remote-host \
  --host-id mac-main \
  --device-id iphone-main \
  --orca-pairing-code-file ~/.config/tax/orca-pairing
```

Индикатор в левом верхнем углу приложения должен стать зелёным и показать `online`. Mac должен быть включён и не спать, а Orca — запущена.

### 3. Проверка

1. Откройте workspace `main`.
2. Откройте существующий терминал и проверьте ANSI/TUI-вывод.
3. Создайте новый терминал кнопкой `+`.
4. Введите `pi` и нажмите `enter`.
5. Проверьте `Ctrl-C`, resize, rename и close.
6. Откройте **Browse workspace files**, текстовый файл, Markdown preview и изображение.

Проверка backend и APNs:

```bash
tax doctor
tax push-doctor
```

Успешный `APNs result: sent` и HTTP `200` означают, что Apple приняла push. Отображение баннера дополнительно зависит от разрешений Notifications, Focus и Scheduled Summary на iPhone.

## Push deep links

Pi extension отправляет в push только routing identifiers: `host_id`, `workspace_id` и `terminal_id`. Для нестандартного Host ID задайте его в окружении Pi/Orca:

```bash
export TAX_HOST_ID=mac-main
```

При нажатии push приложение открывает соответствующий Mac, workspace или terminal. Устаревший task/reply UI удалён.

## Backend deploy

С Mac:

```bash
./scripts/deploy-backend.sh
```

Или на VPS из-под `root`:

```bash
git config --global --add safe.directory /home/hermes/tax
cd /home/hermes/tax
git fetch origin main
git pull --ff-only origin main
./deploy.sh
```

Deploy создаёт backup SQLite, обновляет зависимости, перезапускает `tax.service`, проверяет health и schema.

Эксплуатационные инструкции: [`docs/OPERATIONS.md`](docs/OPERATIONS.md).

## Проверки разработки

```bash
.venv/bin/ruff check .
.venv/bin/pytest -q
./scripts/preflight.sh
```

Дополнительно:

- [`ios/README-REMOTE.md`](ios/README-REMOTE.md) — iOS remote client;
- [`docs/remote-protocol-v1.md`](docs/remote-protocol-v1.md) — E2EE и wire protocol;
- [`docs/orca-runtime-compatibility.md`](docs/orca-runtime-compatibility.md) — совместимость Orca Runtime.
