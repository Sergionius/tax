<!-- ralphex-base: e8b4fdef86a0c133833ab06a262a098495dcf238 -->

# Удаление legacy reply-механики из TAX

## Goal

Удалить цепочку `iPhone reply → backend → tax.agent → Orca terminal send`, сохранив completion notifications, APNs deep links, историю уведомлений и E2EE remote workspace. Превратить `tax run` в fire-and-forget wrapper произвольной команды.

## Context

Исходное задание: `docs/plans/2026-09-12-udalenie-legacy-reply-mehaniki-iz-tax.md`.

Обнаружено:
- Backend продолжает обслуживать четыре legacy HTTP-операции, изменять TTL/status и возвращать `SELECT *`.
- Новая SQLite-схема всё ещё содержит `status/reply`.
- Pi extension после `/push` обращается к локальному агенту либо записывает fallback JSONL.
- CLI содержит reply-agent, polling, terminal injection и зависимый от локального агента `doctor`.
- Существуют Pytest, Node extension tests, wheel validation и `scripts/preflight.sh`.
- `host_id` передаётся в APNs, но не хранится в таблице tasks; четыре `orca_*` routing-поля сохраняются.
- `push_status` исторических записей после additive migration может быть `NULL`.
- Применимых `AGENTS.md` в репозитории и родительских каталогах не обнаружено.

## Scope

Backend API и SQLite compatibility, CLI, Pi extension, безопасный uninstall-скрипт, существующие тесты и package checks, документация, версии Python/Pi packages.

## Out of Scope

- Изменения iOS-кода и версии приложения.
- Изменения Orca protocol, relay, remote-host и remote-smoke.
- Удаление пользовательских БД, журналов, конфигурации или ключей.
- Новые зависимости, инфраструктура, механизмы повторной доставки.
- Запуск настоящих installers, LaunchAgents, диагностических pushes или других операций с живыми системами.

## Implementation Steps

### Task 1: Удалить backend reply API и ограничить публичную проекцию

**Files:**
- Modify: `server/main.py`
- Modify: `server/storage.py`
- Modify: `tests/test_server.py`

- [x] Удалить `TaskUpdate`, `ReplyPayload`, `TASK_REPLY_TTL_SECONDS`, `expire_stale_tasks`, связанные события логирования и четыре операции: POST update, POST reply, GET reply, GET replies.
- [x] Удалить вызовы expiration из GET task/tasks, неиспользуемые `asyncio` и `timedelta`; сохранить `Literal`, используемый device preferences.
- [x] Ввести единую явную SQL-проекцию для GET task/tasks: `id`, `title`, `body`, `context`, `logs`, `source`, `agent`, `app`, `orca_terminal_handle`, `orca_worktree_id`, `orca_tab_id`, `orca_pane_key`, `push_status`, `push_attempted_at`, `push_environment`, `apns_status_code`, `apns_reason`, `apns_id`, `created_at`, `updated_at`.
- [x] Использовать эту проекцию вместо `SELECT *`; сохранить envelopes, авторизацию, 404 неизвестной задачи, pagination и сортировку по `created_at DESC`. GET-запросы больше не должны изменять БД.
- [x] Удалить `status/reply` из CREATE TABLE новых БД; убрать `status` и `"pending"` из INSERT `/push`, согласовав placeholders. Сохранить additive migrations без DROP, перестроения таблиц и backfill исторических статусов.
- [x] Сохранить `/push`, diagnostics, registration, health, WebSocket relay и APNs routing без изменения поведения; не добавлять хранение `host_id`.
- [x] Разделить существующий metadata/reply-flow тест на проверки push metadata и read-only history. Удалить TTL, first-writer и delivery tests; переписать сортировку через timestamps без legacy status.
- [x] Расширить migration test: заполненная старая БД открывается повторно, старые значения и timestamps не меняются после GET, новые pushes работают, обе history-операции не возвращают legacy поля и device token. Проверить повторную инициализацию и свежую схему через `PRAGMA table_info`.
- [x] Добавить проверку точного набора HTTP path/method из `app.openapi()`: POST `/push`, GET `/task/{task_id}`, GET `/tasks`, GET `/health`, POST `/diagnostics/push-test`, GET `/diagnostics/push/{task_id}`, POST `/register-device`. Это фиксирует отсутствие всех четырёх удалённых операций без legacy URL literals в тестах.
- [x] Сохранить APNs/deep-link tests и добавить проверку registration fallback для `/push` без device token; во всех новых случаях подменять APNs sender.

### Task 2: Удалить macOS reply agent и упростить CLI

**Files:**
- Modify: `src/tax/cli.py`
- Modify: `tests/test_cli.py`
- Delete: `src/tax/agent.py`
- Delete: `tests/test_agent.py`
- Delete: `tests/test_integration_flow.py`

- [ ] Удалить перечисленные agent-файлы, `cmd_agent`, parser subcommand `agent`, `poll_reply` и `send_to_orca`; удалить только ставшие ненужными imports.
- [ ] Сохранить `orca_cli_command`; из `cmd_doctor` удалить только loopback health-check, оставив Orca CLI/runtime, API key, backend и сообщение о device registration fallback.
- [ ] Переименовать `run_agent` в `run_command`, обновить `cmd_run`, удалить `--detach` и весь reply-wait flow.
- [ ] Сохранить запуск argv без shell, streaming объединённых stdout/stderr и последние 500 строк в logs. Дождаться завершения процесса перед чтением exit code, включая ветку terminate/kill после KeyboardInterrupt.
- [ ] Формировать title как `<Path(argv[0]).name> completed` либо `failed`, body с exit code и существующий command context.
- [ ] Расширить `send_push` явными keyword-only metadata-параметрами: `source="tax-cli"`, executable basename в `agent`, `app="tax"`, trimmed `TAX_HOST_ID` с default `mac-main`, `ORCA_TERMINAL_HANDLE`, `ORCA_WORKTREE_ID` с fallback на `ORCA_WORKSPACE_ID`, `ORCA_TAB_ID`, `ORCA_PANE_KEY`.
- [ ] Отправлять один completion push и возвращать исходный exit code независимо от HTTP failure, некорректного JSON или отсутствующего `task_id`; не добавлять retries, polling или локальную очередь. Сохранить существующие проверки API key и пустого argv.
- [ ] Убрать ложное предупреждение при отсутствующем device token; разрешить generic wrapper работать вне Orca с пустыми routing-полями.
- [ ] Перевести `cmd_status` на `task.get("push_status") or "unknown"` без fallback к legacy `status`.
- [ ] Обновить CLI description на `Task Agent eXchange — push notifications and remote Orca workspaces`.
- [ ] Удалить injection test и обновить тест пустой команды. Добавить mocked tests success/nonzero exit, streaming, payload metadata/defaults, backend failure/invalid response, отсутствующего token и отсутствия любых GET после completion.
- [ ] Добавить tests CLI dispatch/help без agent и detach, doctor без локальных обращений и status для `sent`, `failed`, `skipped`, `queued`, `NULL`. Сохранить остальные существующие CLI tests.

### Task 3: Оставить в Pi extension только completion push

**Files:**
- Modify: `extensions/tax-push.ts`
- Modify: `tests/extension/tax-push.test.ts`

- [ ] Удалить filesystem/path/os imports, `LOCAL_AGENT_URL`, `LOCAL_TIMEOUT_MS`, `TaskHandoff`, local handoff, fallback path и JSONL append.
- [ ] После успешного `postPush` и обновления dedupe state вызывать `logQuietly("Push sent")`; сохранить проверку непустого строкового `task_id`, timeout, ошибочные ответы и очистку `inFlightKey`.
- [ ] Заменить предупреждение `skip replyable notification` на `skip push notification`, сохранив обязательность terminal handle для Pi.
- [ ] Не менять `agent_settled`, turn analysis, outcome classification, truncation, session context, routing defaults, deduplication и обработку ошибок.
- [ ] Расширить существующий Node test file fake ExtensionAPI/event handlers и mocked `fetch`: ровно один POST `/push`, правильные metadata, последовательные и concurrent duplicates, invalid JSON/missing task ID/HTTP failure, повторный event после неудачи и debug-only `Push sent`.
- [ ] Сохранить truncation tests и добавить representative success/failure/stopped analysis cases. Изолировать environment, console и fetch между тестами; проверять отсутствие файловых изменений в временном HOME/state directory.

### Task 4: Добавить безопасное снятие legacy LaunchAgent

**Files:**
- Create: `scripts/uninstall-legacy-reply-agent.sh`
- Modify: `scripts/install.sh`
- Modify: `tests/test_cli.py`
- Delete: `scripts/install-launch-agent.sh`

- [ ] Создать executable Bash-скрипт с `set -euo pipefail` и успешным no-op вне Darwin, по precedent прежнего installer.
- [ ] На Darwin выполнить только `launchctl bootout "gui/$UID/tax.agent" 2>/dev/null || true` и `rm -f "$HOME/Library/LaunchAgents/tax.agent.plist"`.
- [ ] Не трогать remote-host, config, Keychain, pairing file, state directory и logs; не добавлять sudo, process-kill или recursive deletion.
- [ ] В `scripts/install.sh` после проверки наличия pipx, но до `pipx install --force -e .`, вызвать uninstaller. Сохранить последующую установку CLI, отключение старой standalone Pi extension copy и `pi install`; удалить установку reply agent.
- [ ] Удалить прежний launch-agent installer.
- [ ] В существующем `tests/test_cli.py` добавить subprocess tests с временным HOME и fake `uname`/`launchctl`/`pipx`/`pi`: два запуска успешны, ошибка bootout допускается, удаляется только целевой plist, соседние файлы остаются, порядок installer — uninstall → pipx → Pi. Реальные пользовательские утилиты не запускать.

### Task 5: Обновить metadata и package validation

**Files:**
- Modify: `pyproject.toml`
- Modify: `package.json`
- Modify: `scripts/preflight.sh`
- Modify: `.github/workflows/python.yml`

- [ ] Повысить Python version `0.3.2` → `0.4.0`, Pi package version `0.2.0` → `0.3.0`; iOS metadata оставить без изменений.
- [ ] Установить Python description `Task Agent eXchange — push notifications and remote Orca workspaces`, Pi description `Pi completion notifications for tax`.
- [ ] В preflight и CI clean-wheel smoke заменить `agent --help` на `notify --help`, `run --help`, `remote-host --help`; сохранить общий `tax --help`.
- [ ] Не менять зависимости, peer dependency, Pi extension manifest, Python matrix и остальные CI jobs.

### Task 6: Обновить документацию и убрать устаревшие планы

**Files:**
- Modify: `README.md`
- Modify: `docs/OPERATIONS.md`
- Modify: `docs/remote-protocol-v1.md`
- Modify: `docs/orca-runtime-compatibility.md`
- Modify: `plans/backend-plan.md`
- Modify: `plans/ios-plan.md`
- Modify: `plans/2026-07-28-non-ios-quality-automation-plan.md`
- Delete: `docs/plans/2026-07-29-reply-expiration-design.md`
- Delete: `docs/plans/2026-08-03-agterm-cookbook-integration-design.md`
- Delete: `ios/docs/plans/2026-08-03-ios-agent-chat-redesign.md`
- Delete: `plans/mac-plan.md`
- Delete: `plans/2026-07-17-agent-startup-boundary-plan.md`

- [ ] Добавить README section `Upgrading from versions before 0.4.0`: installer снимает только `tax.agent`, remote-host не затрагивается, старые SQLite-колонки и локальные `agent.db`, logs, `tasks.jsonl` сохраняются и не используются.
- [ ] Документировать generic `tax run pytest -q`, streaming, executable-based title, metadata, возврат exit code, отсутствие reply ожидания и регистрацию device token на backend.
- [ ] В operations описать `push_status` как единственный актуальный статус доставки, `unknown` в CLI для исторических записей и редактированную публичную history-проекцию. Удалить описание активных legacy status transitions.
- [ ] В protocol/compatibility docs называть runtime host `tax remote-host`, а не reply-agent; сохранить описание encryption, terminal input acknowledgement и запрета replay.
- [ ] Удалить пять перечисленных полностью устаревших планов.
- [ ] В трёх смешанных top-level планах сохранить полезную историю push filtering, device preferences и quality automation, удалив инструкции и acceptance criteria для reply architecture, detach, polling и удаляемых файлов. Обновить help smoke-команды.
- [ ] Сохранить исходный removal document как текущий removal plan; убрать оставшиеся ссылки на удалённые документы из изменяемых смешанных планов.

### Task 7: Выполнить изолированную проверку реализации

**Files:**
- Modify: `tests/test_server.py`
- Modify: `tests/test_cli.py`
- Modify: `tests/extension/tax-push.test.ts`

- [ ] Запустить Ruff, полный Pytest, Node tests, package build и preflight командами из раздела Validation; исправлять только регрессии этого изменения.
- [ ] Проверить содержимое нового wheel: `tax/agent.py` отсутствует, `tax/agent_notifications.py` и bundled Orca terminal bridge сохранены.
- [ ] Выполнить tracked-text scan из Validation; устранить совпадения вне migration note и текущего removal plan, не ослабляя sensitive-key sets.
- [ ] Убедиться по существующим tests relay, remote-host, remote protocol и notification hooks, что удаление не нарушает сохранённые функции; не заменять эти проверки настоящими pushes или подключением к Orca.

## Validation

Команды для последующего исполнителя; на этапе планирования они не выполнялись:

```bash
.venv/bin/ruff check .
.venv/bin/pytest -q
npm test
.venv/bin/python -m build
bash -n scripts/install.sh scripts/uninstall-legacy-reply-agent.sh scripts/preflight.sh
./scripts/preflight.sh
```

Preflight уже собирает package, устанавливает wheel в отдельный venv и при наличии Xcode выполняет simulator build/unit tests. Нужные зависимости и simulator должны быть доступны; не заменять недоступную проверку живой диагностикой и не отмечать её успешной без выполнения.

Tracked-text scan текущих tracked-файлов:

```bash
git grep -n -I -E \
'tax agent|TAX_AGENT_URL|127\.0\.0\.1:17373|/task/[^[:space:]]*/reply|/replies|reply bridge|remote[- ]reply|tasks\.jsonl|agent\.db'
```

Допустимы только строки README migration note и текущего removal plan. Exit code 1 означает отсутствие совпадений. Проверка маршрутов через полный OpenAPI allowlist не требует добавления запрещённых URL literals в тесты.

Не выполнять настоящие `install.sh`, uninstaller, `tax doctor`, `tax push-doctor`, `tax remote-smoke` или agent hooks. Их поведение проверяется только mocks и временными fixtures.

## Acceptance Criteria

- Четыре legacy HTTP-операции и macOS reply-agent полностью отсутствуют.
- Новая БД не содержит `status/reply`; существующая БД сохраняет их физически и принимает новые pushes без обращения приложения к этим колонкам.
- Task history не раскрывает `reply`, legacy `status` и device token, а GET не изменяет данные.
- `tax status` отображает `push_status` и корректно обрабатывает исторический `NULL`.
- Pi выполняет только completion POST, без local handoff и fallback files.
- `tax run` стримит команду, отправляет один completion push с metadata и возвращает исходный exit code без reply ожидания.
- Installer снимает только legacy LaunchAgent до обновления CLI; пользовательские данные и remote-host сохраняются.
- Claude/Codex notifications, APNs deep links и E2EE remote workspace сохраняют существующее поведение.
- Версии Python/Pi обновлены; iOS версия и sensitive-key sets не изменены.
- Доступные автоматические проверки проходят, text scan не содержит неразрешённых совпадений; живые системы не затронуты.

## Execution Notes

- Decision: подготовить только план без исполнения исходного rollout; Alternatives: немедленно менять репозиторий и запускать installers; Reason: текущий workflow требует read-only planning; Side effects: реализация и проверки остаются последующему исполнителю.
- Decision: удалить legacy API без deprecation; Alternatives: compatibility endpoints или переходный период; Reason: исходный документ прямо утверждает отсутствие внешних потребителей; Side effects: старые reply-клиенты больше не поддерживаются.
- Decision: использовать существующие четыре persisted Orca routing-поля без новой колонки `host_id`; Alternatives: расширить SQLite и history contract; Reason: host уже передаётся в APNs, сохранение его в history не требуется для удаления механики; Side effects: history по-прежнему не содержит host_id.
- Decision: оставить исторические `push_status` без backfill и отображать `unknown` при пустом значении; Alternatives: вычислять статус из legacy полей; Reason: запрет читать старые status/reply и отсутствие достоверной APNs истории; Side effects: часть старых уведомлений отображается как unknown.
- Decision: проверять удаление маршрутов точным OpenAPI allowlist; Alternatives: negative tests с legacy URL literals; Reason: одновременно обеспечить route regression coverage и строгий tracked-text scan; Side effects: новые HTTP-операции в будущем потребуют обновления allowlist.
- Decision: сохранить generic `tax run` вне Orca и metadata defaults интеграций; Alternatives: пропускать уведомления без terminal handle; Reason: запрос сохраняет wrapper произвольной команды, в отличие от terminal-only Pi/hooks; Side effects: такой push может открыть только настроенный host.
- Decision: ошибка completion push не меняет exit code, включая malformed response; Alternatives: завершать wrapper ошибкой доставки; Reason: явный contract исходного exit code; Side effects: недоставленное уведомление не превращает успешную команду в неуспешную.
- Decision: сохранить проверку pipx до uninstall и Darwin guard; Alternatives: безусловно снимать агент ещё до проверки installer prerequisites; Reason: существующий platform precedent и минимизация изменений при невозможности установки; Side effects: при отсутствующем pipx installer ничего не снимает.
- Decision: shell regression tests разместить в существующем `tests/test_cli.py` с fake executables и временным HOME; Alternatives: новый framework либо проверка настоящего launchd; Reason: существующий Pytest достаточен и не требует доступа к пользовательским сервисам; Side effects: добавляется shell coverage без инфраструктуры.
- Decision: удалить только полностью reply-specific планы, смешанные документы очистить выборочно; Alternatives: удалить все top-level планы; Reason: сохранить полезные описания действующих push preferences и quality checks; Side effects: исторические документы перестают предписывать удалённую архитектуру.
- Decision: оставить wire client identifier `tax-agent` в Orca adapter/bridge и существующий notification dedupe state; Alternatives: глобально переименовать все строки agent и удалить весь state; Reason: они относятся к сохраняемым runtime/notification функциям, а не reply-agent; Side effects: историческое wire-имя остаётся без изменения совместимости.
- Decision: сохранить `reply` в sensitive-key sets обоих logging modules; Alternatives: удалить вместе с моделью reply; Reason: защита от исторических и неожиданных payloads; Side effects: none.
- Decision: считать полный Pytest пройденным для Task 1 при единственном падении `tests/test_integration_flow.py::test_backend_reply_is_delivered_once_and_acknowledged`; Alternatives: досрочно удалить файл в Task 1; Reason: файл входит в список Delete Task 2, на базовом коммите e8b4fde тест проходит, а после Task 1 падает только на mandated 404 удалённого reply-endpoint, то есть регрессии нет; Side effects: зелёный полный suite остаётся гейтом Task 7.
- Decision: разделить сценарий registration fallback на два теста (fallback на последнюю регистрацию и device_token_missing на чистой БД); Alternatives: один тест с двумя push; Reason: существующее поведение `/push` подставляет последнюю зарегистрированную даже без device_token, поэтому случай missing token требует БД без регистраций; Side effects: дополнительный тест без изменения продакшн-кода.
- Decision: в migration test сравнивать только legacy-колонки строки плюс NULL в новых колонках; Alternatives: сравнивать строку целиком; Reason: additive migration физически добавляет новые NULL-колонки к старой строке; Side effects: none.
