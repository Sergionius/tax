# tax — Task Agent eXchange

Push-уведомления и remote reply для Pi, запущенного в [Orca](https://github.com/stablyai/orca) на Mac.

## Как это работает

1. Pi extension после `agent_settled` отправляет результат задачи на backend.
2. Backend сохраняет задачу и отправляет APNs на iPhone.
3. Пользователь открывает iOS-приложение `tax` и отправляет reply.
4. `tax-agent` на Mac забирает reply и передаёт его в исходный терминал Orca через:

```bash
orca terminal send --terminal "$ORCA_TERMINAL_HANDLE" --text "reply" --enter --json
```

Extension сохраняет точный `ORCA_TERMINAL_HANDLE`, worktree, tab и pane. Активный терминал никогда не используется как fallback. Если handle устарел после перезапуска Orca, агент может восстановить его только по однозначному совпадению tab/leaf; иначе задача получает `delivery_failed`.

## Структура

- `src/tax/` — Python CLI и постоянный reply bridge для Mac;
- `extensions/tax-push.ts` — Pi extension;
- `server/` — FastAPI backend и APNs;
- `ios/` — SwiftUI приложение.

## Установка на Mac

Требования: macOS, запущенная Orca с установленным CLI, `pipx` и Pi.

```bash
./scripts/install.sh
```

Настройка:

```bash
tax config \
  --server https://tax.138-249-127-23.nip.io \
  --api-key YOUR_API_KEY \
  --device-token YOUR_IOS_DEVICE_TOKEN
```

Device token можно не задавать, если iOS-приложение уже зарегистрировало его на backend.

Проверка:

```bash
tax doctor
curl http://127.0.0.1:17373/health
```

## Использование

Запусти Pi в терминале Orca. После завершения turn extension отправит push. Reply с iPhone будет вставлен и отправлен в тот же терминал.

Дополнительные команды:

```bash
tax status
tax recap
tax recap --session-file FILE
tax run pi -p "выполни задачу"
```

`tax run` поддерживает remote reply только при запуске внутри терминала Orca, где задан `ORCA_TERMINAL_HANDLE`.

## Гарантии доставки

- задача и reply истекают через 30 минут;
- reply доставляется не более одного раза;
- закрытый, неоднозначный или недоступный терминал приводит к `delivery_failed`;
- неизвестный результат записи не повторяется автоматически;
- локальные финальные записи удаляются через 7 дней.

## Backend

Production deploy с Mac выполняется одной командой:

```bash
./scripts/deploy-backend.sh
```

Скрипт подключается к `hermes@138.249.127.23`, обновляет `main`, создаёт backup SQLite, проверяет целостность БД, перезапускает systemd service, проверяет health и Orca schema. Host и каталог можно переопределить через `TAX_DEPLOY_HOST` и `TAX_DEPLOY_PROJECT_DIR`.

Эксплуатационные инструкции: [`docs/OPERATIONS.md`](docs/OPERATIONS.md).

## Проверки

```bash
python -m pytest
ruff check server src tests
./scripts/preflight.sh
```

iOS-инструкции: [`ios/README.md`](ios/README.md).
