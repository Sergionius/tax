# tax — Task Agent eXchange

Push-уведомления и remote reply для AI-агентов, запущенных в [agterm](https://github.com/umputun/agterm) на Mac.

## Что делает

- Когда `pi` (или другой агент) в agterm завершается или блокируется, Mac отправляет push на iPhone.
- iPhone показывает уведомление. Ты открываешь приложение, видишь контекст задачи и историю.
- Можно ответить текстом прямо из приложения.
- Mac забирает ответ с backend и подаёт его обратно в agterm.

## Репозиторий

- `src/tax/` — Python CLI и фоновый reply-agent для Mac.
- `extensions/` — расширение pi, создающее задачи после `agent_settled`.
- `server/` — FastAPI backend на Python.
- `ios/` — SwiftUI приложение для iOS.

## Установка CLI на Mac

```bash
pipx install git+https://github.com/Sergionius/tax.git
```

После установки доступна команда `tax`.

## Настройка CLI

```bash
tax config --server https://tax.138-249-127-23.nip.io --api-key YOUR_API_KEY --device-token YOUR_IOS_DEVICE_TOKEN
```

Или через environment:

```bash
export TAX_SERVER=https://tax.138-249-127-23.nip.io
export TAX_API_KEY=YOUR_API_KEY
export TAX_DEVICE_TOKEN=YOUR_IOS_DEVICE_TOKEN
```

## Pi extension и фоновый агент

Установить extension из репозитория:

```bash
pi install git:github.com/Sergionius/tax
```

Запустить мост ответов вручную:

```bash
tax agent
curl http://127.0.0.1:17373/health
```

Extension отправляет push после `agent_settled`, получает `task_id` и передаёт его локальному агенту. Агент ждёт ответ с iPhone и вводит его в исходную сессию через:

```bash
agtermctl session type --target "$AGTERM_SESSION_ID" --stdin
```

Если локальный HTTP endpoint временно недоступен во время работы агента, extension сохраняет задачу в `~/.local/state/tax/tasks.jsonl`. Агент читает только записи, добавленные после его запуска. При следующем запуске старый fallback и SQLite-состояние очищаются: они нужны только для дедупликации и повторных попыток текущего процесса, а история хранится на backend/iOS.

Для установки CLI, extension и LaunchAgent одной командой:

```bash
./scripts/install.sh
```

## Использование

Запустить агента и получить push по завершении:

```bash
tax run pi -p "напиши REST API на Python"
```

Без ожидания ответа:

```bash
tax run --detach pi -p "сделай рефакторинг"
```

Посмотреть историю задач:

```bash
tax status
```

## Развёртывание backend на VPS

### Docker Compose

```bash
cd server
cp .env.example .env
# отредактируй .env: TAX_APNS_KEY_ID, TAX_APNS_TEAM_ID, TAX_APNS_BUNDLE_ID
mkdir -p data keys
# положи AuthKey.p8 в keys/AuthKey.p8
docker compose up -d
```

### Systemd

```bash
cd server
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
sudo cp tax.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now tax
```

## Caddy reverse proxy

Добавь в `/etc/caddy/Caddyfile`:

```caddy
138.249.127.23.nip.io {
    reverse_proxy 127.0.0.1:8001
}
```

Перезагрузи Caddy:

```bash
sudo systemctl reload caddy
```

## Локальные проверки

```bash
python -m pytest
ruff check server src tests
```

## iOS приложение

См. `ios/README.md`.

## Статус

MVP. APNs требует Apple Developer Program и `.p8` auth key.
