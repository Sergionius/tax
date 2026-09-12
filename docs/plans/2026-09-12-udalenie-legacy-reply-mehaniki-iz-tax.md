# Удаление legacy reply-механики из TAX

## Цель

Полностью удалить неиспользуемую цепочку:

`iPhone reply → backend → tax.agent → orca terminal send`

При этом сохранить без изменений:

- Pi completion push;
- Claude Code Stop hook;
- Codex notify;
- APNs deep links;
- E2EE remote workspace relay;
- `tax remote-host`;
- `tax remote-smoke`;
- `tax doctor`;
- `tax status`;
- упрощённый fire-and-forget `tax run`.

## 1. Backend API

### Удалить из `server/main.py`

- `TaskUpdate`;
- `ReplyPayload`;
- `TASK_REPLY_TTL_SECONDS`;
- `expire_stale_tasks`;
- `POST /task/{task_id}/update`;
- `POST /task/{task_id}/reply`;
- `GET /task/{task_id}/reply`;
- `GET /replies`;
- неиспользуемый после этого импорт `asyncio`;
- reply-specific события логирования.

Вызовы `expire_stale_tasks` удалить из `GET /task/{id}` и `GET /tasks`.

### Оставить

- `POST /push`;
- `GET /task/{id}`;
- `GET /tasks`;
- `/diagnostics/push-test`;
- `/diagnostics/push/{task_id}`;
- `/register-device`;
- `/health`;
- WebSocket relay.

### Task representation

Текущий `SELECT *` больше не использовать. Добавить явную публичную проекцию task:

- `id`;
- `title`, `body`, `context`, `logs`;
- `source`, `agent`, `app`;
- Orca routing identifiers;
- `push_status`;
- APNs diagnostic fields;
- timestamps.

Не возвращать:

- `reply`;
- legacy `status`;
- полный `device_token`.

`tax status` перевести с `task["status"]` на `task["push_status"]`.

## 2. SQLite compatibility

В `server/storage.py`:

- убрать `reply` и `status` из `CREATE TABLE` для новых баз;
- не выполнять destructive migration существующей базы;
- старые колонки оставить физически на месте, но больше не читать, не писать и не возвращать через API;
- убрать `status = "pending"` из `POST /push`.

Добавить тест миграции:

- старая БД с `status/reply` продолжает открываться;
- новые pushes работают;
- старые поля не появляются в API response;
- новая чистая БД не содержит `status/reply`.

## 3. macOS reply agent

Удалить:

- `src/tax/agent.py`;
- `tests/test_agent.py`;
- `tests/test_integration_flow.py`;
- команду `tax agent`;
- `cmd_agent`;
- локальный API на `127.0.0.1:17373`;
- `poll_reply`;
- `send_to_orca`;
- agent DB, polling и fallback-import code.

`orca_cli_command` оставить: он используется `tax doctor` для проверки Orca Runtime.

Из `tax doctor` убрать только health-check `tax-agent`; проверки Orca CLI, Orca Runtime, backend, API key и device registration оставить.

## 4. Безопасное удаление LaunchAgent

Добавить идемпотентный скрипт:

`scripts/uninstall-legacy-reply-agent.sh`

Он должен:

```bash
launchctl bootout "gui/$UID/tax.agent" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/tax.agent.plist"
```

Скрипт не должен удалять:

- `tax.remote-host`;
- E2EE key;
- TAX config;
- Orca pairing URL;
- `agent.db`, logs и `tasks.jsonl`.

В `scripts/install.sh`:

1. сначала вызвать uninstaller;
2. затем обновить CLI;
3. установить Pi extension;
4. больше не устанавливать reply agent.

Удалить `scripts/install-launch-agent.sh`.

В README добавить раздел `Upgrading from versions before 0.4.0` и указать, что `./scripts/install.sh` автоматически удаляет только `tax.agent`.

## 5. Pi extension

В `extensions/tax-push.ts` удалить:

- `LOCAL_AGENT_URL`;
- `LOCAL_TIMEOUT_MS`;
- `TaskHandoff`;
- `handoffToLocalAgent`;
- `fallbackQueuePath`;
- `appendFallback`;
- связанные imports;
- POST на `127.0.0.1:17373/task`;
- запись `~/.local/state/tax/tasks.jsonl`.

Сохранить без изменений:

- `agent_settled`;
- анализ результата Pi;
- truncation;
- deduplication;
- `POST /push`;
- Orca routing metadata;
- обработку ошибок.

`postPush` продолжает проверять наличие `task_id`, после чего пишет debug-сообщение `Push sent`.

## 6. `tax run`

Не удалять команду полностью: оставить как generic command completion wrapper.

Изменить поведение:

- запускать и стримить команду;
- отправлять completion push;
- завершаться с исходным exit code;
- не ждать reply;
- убрать `--detach`;
- переименовать внутренний `run_agent` в `run_command`;
- убрать Pi-specific title;
- использовать executable name, например `pytest completed`;
- передавать:
  - `source = "tax-cli"`;
  - `agent = executable name`;
  - `app = "tax"`;
  - `TAX_HOST_ID`;
  - `ORCA_TERMINAL_HANDLE`;
  - `ORCA_WORKTREE_ID`/`ORCA_WORKSPACE_ID`;
  - `ORCA_TAB_ID`;
  - `ORCA_PANE_KEY`.

Если device token отсутствует в локальном config, полагаться на backend registration fallback без ложного предупреждения.

## 7. CI и package validation

Обновить:

- `scripts/preflight.sh`: заменить `tax agent --help` на проверки `tax notify --help`, `tax run --help`, `tax remote-host --help`;
- `.github/workflows/python.yml`: сделать такую же замену;
- `tests/test_cli.py`:
  - удалить `send_to_orca` test;
  - удалить reply-wait tests;
  - проверить fire-and-forget `tax run`;
  - проверить Orca metadata;
  - проверить doctor без `tax-agent`;
  - проверить `tax status` по `push_status`;
- `tests/test_server.py`:
  - удалить reply/first-writer/TTL/delivery tests;
  - разделить push metadata и task history tests;
  - проверить отсутствие всех четырёх legacy routes;
  - проверить redacted task representation;
  - проверить старую и новую SQLite schemas.

Sensitive-key sets в `src/tax/logging_utils.py` и `server/logging_config.py` не ослаблять: `reply` можно оставить как защиту от исторических или неожиданных payloads.

## 8. Документация и metadata

Обновить:

- `pyproject.toml` description;
- CLI description;
- `package.json` description;
- `README.md`;
- `docs/OPERATIONS.md`;
- `docs/remote-protocol-v1.md`.

Удалить устаревшие reply-specific планы:

- `docs/plans/2026-07-29-reply-expiration-design.md`;
- `docs/plans/2026-08-03-agterm-cookbook-integration-design.md`;
- `ios/docs/plans/2026-08-03-ios-agent-chat-redesign.md`;
- старые top-level планы, если они целиком описывают `tax.agent`/reply architecture.

В конце выполнить tracked-text scan по:

```text
tax agent
TAX_AGENT_URL
127.0.0.1:17373
/task/*/reply
/replies
reply bridge
remote reply
tasks.jsonl
agent.db
```

Разрешённые совпадения — только migration note и текущий removal plan.

## 9. Версии

- Python package: `0.3.2` → `0.4.0`;
- Pi package: `0.2.0` → `0.3.0`;
- iOS version не менять: функциональность приложения не меняется.

## 10. Проверка и rollout

До merge:

- Ruff;
- полный Pytest;
- Node extension tests;
- wheel build;
- `scripts/preflight.sh`;
- никаких живых push.

После merge:

1. запустить новый `scripts/install.sh`;
2. проверить, что `tax.agent` отсутствует;
3. проверить, что `tax.remote-host` продолжает работать;
4. выполнить `tax doctor`;
5. задеплоить backend;
6. выполнить `tax push-doctor`;
7. проверить по одному реальному completion push от:
   - Pi;
   - Claude Code;
   - Codex;
8. нажать каждый push и подтвердить открытие правильного Orca terminal.

## Допущение

Удаление legacy API выполняется без deprecation-периода, поскольку внешних потребителей reply-эндпоинтов нет. Старые SQLite-колонки и локальные state-файлы не удаляются автоматически.
