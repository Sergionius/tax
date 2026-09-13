<!-- ralphex-base: 28caea8591af38f941072109f73d5a63ecfcba6a -->

# Подготовка TAX к публичному распространению

## Goal

Подготовить обезличенный, документированный self-hosted TAX с воспроизводимыми зависимостями, явной privacy-политикой и автоматическими проверками безопасности публикуемых файлов.

Сохранить настройки владельца в приватном локальном хранилище. Не менять существующий private repository на public и не переносить его историю.

## Context

- TAX состоит из Python CLI, FastAPI backend с SQLite/APNs, Pi extension и SwiftUI-приложения для iPhone.
- Mac host соединяет Orca Runtime с TAX relay. Терминалы и файловые операции защищены TAX E2EE; уведомления проходят отдельным HTTPS/APNs-путём.
- CLI, Pi extension и некоторые iOS defaults содержат адрес инфраструктуры владельца.
- Deployment использует systemd, но в репозитории также есть Docker Compose. Порты и пути между вариантами расходятся.
- `server/Dockerfile` не копирует необходимый `server/relay.py`.
- `server/main.py` сохраняет `title`, `body`, `context`, `logs` и routing/diagnostic metadata в SQLite без ограничения срока хранения.
- Python-зависимости определены в `pyproject.toml` и дублируются в `server/requirements.txt`; lock-файла нет.
- Используются Ruff, Pytest, Node tests, iOS unit/UI tests и package smoke checks. Python CI проверяет версии 3.11–3.13.
- iOS project и preflight содержат персональные signing identifiers. SwiftTerm — существующий terminal renderer.
- README уже содержит согласованный раздел “Why TAX when Orca already has a mobile app?” и четыре детерминированных скриншота.
- В Git присутствуют локальные skills, внутренние планы и резервная копия Xcode project.
- Владелец подтвердил право распространять текущую App Icon.
- Исходный план `docs/plans/2026-09-12-podgotovka-tax-k-publichnomu-github-relizu.md` остаётся внутренним референсом; его содержимое не изменяется.

## Scope

- Systemd как основной deployment-вариант; Docker Compose сохраняется.
- Приватная конфигурация вместо инфраструктурных и signing defaults.
- Единый `uv.lock`, включая runtime и dev dependencies.
- Opt-in хранение `context/logs` и автоматическая retention.
- Англоязычные пользовательские документы, UI, diagnostics и комментарии.
- MIT license, security/privacy documentation и third-party notices.
- Исключение внутренних и локальных материалов из публикуемого набора.
- Усиление CI и проверка чистой установки без конфигурации владельца.

## Out of Scope

- Создание public repository, изменение visibility, Git-истории, branches или tags.
- Commit, push, merge, release и deployment.
- Изменение работающего VPS, ротация credentials, отправка реальных APNs и установка на физический iPhone.
- Замена Orca Runtime adapter, terminal renderer или криптографического протокола.
- Возвращение legacy reply API/agent.
- Шифрование notification payloads и изменение формата agent hooks.
- Новые возможности Orca Mobile, Android или multi-user authentication.

## Implementation Steps

### Task 1: Сохранить приватные настройки и определить локальные configuration contracts

**Files:**
- Modify: `.gitignore`
- Create: `deploy.env.example`
- Create: `ios/Config/Local.xcconfig.example`
- Create: `docs/LOCAL_CONFIGURATION.md`

**Приватные файлы, не включаемые в Git:**
- `~/.config/tax/config.json`
- `~/.config/tax/deploy.env`
- `ios/Config/Local.xcconfig`

- [x] Добавить ignore-правила для локального signing config; явно разрешить tracked example-файлы там, где они пересекаются с существующим правилом `*.env`.
- [x] Зафиксировать contract deployment configuration: `TAX_DEPLOY_HOST`, `TAX_DEPLOY_USER`, `TAX_DEPLOY_GROUP`, `TAX_DEPLOY_PROJECT_DIR`, `TAX_DEPLOY_DOMAIN`, `TAX_DEPLOY_PORT`, `TAX_DEPLOY_DB_PATH`, `TAX_DEPLOY_APNS_KEY_PATH`, `TAX_DEPLOY_ENV_FILE`.
- [x] Определить приоритет deployment-настроек: явные environment overrides, затем файл из `TAX_DEPLOY_CONFIG`, затем `~/.config/tax/deploy.env`. Отсутствие явно указанного файла является ошибкой.
- [x] До удаления tracked defaults сохранить доступные текущие настройки владельца в приватных файлах. Не перезаписывать существующие значения; конфликт или отсутствие необходимых данных должно останавливать миграцию, а не подставлять пример.
- [x] Сохранять локальные config-файлы с правами `0600`; не печатать их содержимое и credentials в диагностику.
- [x] Определить signing variables `TAX_DEVELOPMENT_TEAM`, `TAX_APP_BUNDLE_IDENTIFIER`, `TAX_TESTS_BUNDLE_IDENTIFIER`, `TAX_UITESTS_BUNDLE_IDENTIFIER`.
- [x] Оставить существующие Keychain entries и Orca pairing file без изменений.
- [x] Документировать перенос iPhone server URL в явно сохранённые настройки до исчезновения default; не добавлять приватный URL в migration code.
- [x] Описать подготовку private config на VPS без выполнения SSH, изменения сервиса или deployment.

### Task 1 execution notes

- Создан `~/.config/tax/deploy.env` (0600) со всеми 9 contract-переменными; значения сверены со tracked источниками на момент миграции (`deploy.sh`, `server/tax.service`, `scripts/deploy-backend.sh`). Файл ранее отсутствовал, перезаписи не было.
- Создан `ios/Config/Local.xcconfig` (0600) с 4 signing-переменными; значения сверены с `ios/tax/tax.xcodeproj/project.pbxproj`. Файл ранее отсутствовал, игнорируется Git.
- `~/.config/tax/config.json`, `~/.config/tax/orca-pairing*` и Keychain не изменялись.
- Приватные значения (host, user, domain, пути, team, bundle IDs) отсутствуют в tracked файлах; проверено grep-сканированием новых файлов.
- Валидация: `git diff --check` чистый; `git check-ignore` подтверждает ignore `ios/Config/Local.xcconfig` и `deploy.env` при tracked `deploy.env.example`/`server/.env.example`; состав contract-переменных согласован между планом, примерами и `docs/LOCAL_CONFIGURATION.md`. Команды uv/pytest/npm/xcode не применимы: код и скрипты не менялись.

### Task 2: Сделать Python-зависимости воспроизводимыми через uv

**Files:**
- Modify: `pyproject.toml`
- Modify: `server/requirements.txt`
- Modify: `.github/workflows/python.yml`
- Modify: `.github/dependabot.yml`
- Modify: `scripts/preflight.sh`
- Create: `uv.lock`

- [x] Использовать `pyproject.toml` как единственный источник прямых runtime/dev dependencies; сохранить существующий `dev` extra и поддержку Python 3.11–3.13.
- [x] Добавить и зафиксировать совместимую версию `uv`; CI должен устанавливать её без нового стороннего GitHub Action.
- [x] Создать `uv.lock` с resolved versions и hashes для поддерживаемых окружений.
- [x] Сделать `server/requirements.txt` генерируемым export runtime dependencies из lock без самого проекта и dev dependencies; сохранить hashes и удалить независимое ручное определение версий.
- [x] Перевести Python CI и Python-часть preflight на locked sync и запуск через `uv`.
- [x] Сохранить сборку sdist/wheel и установку wheel в отдельное чистое окружение; проверять help для `tax`, `notify`, `run`, `remote-host`.
- [x] Зафиксировать build backend совместимым способом, чтобы package build не обходил выбранную политику воспроизводимости.
- [x] Настроить Dependabot для `uv.lock`, сохранив обновления GitHub Actions.
- [x] Добавить CI-проверку актуальности generated requirements относительно lock; обновление dependencies должно включать согласованное обновление export.
- [x] Не менять пользовательскую установку через pipx без необходимости и не добавлять `uv` как runtime dependency CLI.

### Task 2 execution notes

- `pyproject.toml` остаётся единственным источником прямых зависимостей (9 runtime + `dev` extra, `requires-python = ">=3.11"`, CI-матрица 3.11–3.13 без изменений). `uv` не добавлен в runtime dependencies; pipx-установка CLI не менялась.
- Версия `uv` зафиксирована как `0.12.13`: `[tool.uv] required-version = "==0.12.13"` и `UV_VERSION` в `.github/workflows/python.yml`; CI ставит её через `python -m pip install uv==...` (setup-python + pip, без сторонних Action).
- `uv.lock` создан `uv lock` (uv 0.12.13): universal resolution для `requires-python = ">=3.11"`, 51 пакет, sdist/wheel sha256-hashes.
- `server/requirements.txt` теперь generated export: `uv export --no-dev --no-emit-project -o server/requirements.txt` (команда продублирована в header файла); 39 pinned-пакетов с hashes, без самого проекта и dev dependencies; повторный export побайтно совпадает (кроме строки header с путём вывода). `pip install --dry-run --require-hashes` проходит.
- Build backend зафиксирован: `[build-system] requires = ["hatchling==1.32.0"]`; `uv build` собирает в изолированном окружении с этой версией.
- CI: jobs `test`/`package`/`dependency-audit` переведены на `uv sync --locked --extra dev` и `uv run --locked --extra dev ...`; `pip-audit` запускается через `uv run --with pip-audit`; paths-триггеры дополнены `uv.lock` и `server/requirements.txt`; в `package` добавлен шаг проверки, что повторный export не даёт diff по `server/requirements.txt`.
- `scripts/preflight.sh`: Python-часть переведена на `uv sync/run/build` (переменная `UV_BIN`, ошибка при отсутствии uv); clean-venv wheel smoke с help-проверками `tax`/`notify`/`run`/`remote-host` сохранён.
- Dependabot: экосистема `pip` заменена на `uv` (pyproject + `uv.lock`), обновления `github-actions` сохранены.
- Валидация: `uv lock --check`; `uv sync --locked --extra dev`; `uv run --locked --extra dev ruff check server src tests`; `uv run --locked --extra dev pytest -q` — 79 passed, как на базовом коммите (единственный warning — существующий starlette/anyio DeprecationWarning, присутствует и до изменений); повторный export vs tracked `server/requirements.txt` — идентично; `uv build` во временный каталог + установка wheel в чистый venv + help для `tax`, `notify`, `run`, `remote-host`; `pip install --dry-run --require-hashes -r server/requirements.txt`; `bash -n scripts/preflight.sh`; `git diff --check`. npm/pytest-изменения кода отсутствуют: Python-код не менялся.


### Task 3: Параметризовать systemd и исправить Docker Compose

**Files:**
- Modify: `deploy.sh`
- Modify: `reinstall-backend.sh`
- Modify: `scripts/deploy-backend.sh`
- Modify: `Caddyfile`
- Modify: `server/tax.service`
- Modify: `server/.env.example`
- Modify: `server/docker-compose.yml`
- Modify: `server/Dockerfile`
- Modify: `deploy.env.example`
- Modify: `.github/workflows/python.yml`
- Create: `scripts/deploy-config.sh`
- Create: `tests/test_deploy_configuration.py`

- [x] Реализовать общий shell configuration loader по contract Task 1; убрать private SSH host, username, domain и абсолютные пути из скриптов.
- [x] Обязательные параметры проверять до SSH, Git, sudo, файловых изменений или service commands.
- [x] Валидировать port, domain, service identity и пути; безопасно передавать аргументы SSH и экранировать значения при генерации systemd/Caddy configuration.
- [x] Заменить tracked Caddyfile и systemd unit на нейтральные шаблоны с параметрами; не допускать случайной установки неотрендеренного шаблона.
- [x] Использовать один configured loopback port для systemd, Caddy и health check. В примерах использовать `8000`; существующий owner port сохранять через private config.
- [x] Сохранить online SQLite backup и schema verification в deployment code, не выполняя deployment в рамках этой задачи.
- [x] Не создавать `.env` с пустым API key автоматически; сообщать об отсутствующей обязательной конфигурации.
- [x] Установку backend dependencies выполнять из generated requirements с `--require-hashes`.
- [x] Сохранить Docker container port `8000`, сделать host loopback port, persistent data directory и key directory конфигурируемыми; обеспечить соответствие Caddy host port.
- [x] Исправить Dockerfile: включить `relay.py` и остальные backend runtime modules; использовать locked requirements с проверкой hashes.
- [x] Добавить безопасный режим проверки/render configuration без SSH, service commands и применения конфигурации.
- [x] Покрыть Pytest-проверками precedence, отсутствие required values, неверные значения и согласованность портов. Использовать только временные каталоги и fake executables, без реального SSH/systemd.
- [x] Добавить в `.github/workflows/python.yml` отдельный `container` job на GitHub-hosted `ubuntu-latest` вместо обязательной локальной Docker-проверки.
- [x] Зафиксировать шаги `container` job: проверить availability Docker и Compose, выполнить Compose configuration validation с synthetic environment, собрать backend image и запустить в нём `python -c 'import main, relay, storage, apns'`.
- [x] Для import smoke использовать `--network none`, без host mounts, без реальных credentials и без запуска backend service.
- [x] Synthetic Compose environment создавать во временном каталоге и передавать явно через `--env-file`; не читать owner `.env`.
- [x] Дополнить path filters workflow путями `deploy.sh`, `reinstall-backend.sh`, `Caddyfile`, `deploy.env.example`, `scripts/deploy-backend.sh`, `scripts/deploy-config.sh`; сохранить существующие server/tests/lock triggers.
- [x] Не устанавливать Docker на Mac и не добавлять сторонние Actions для контейнерной проверки.
- [x] Определить обязательную локальную валидацию Task 3: shell syntax (`bash -n` изменённых скриптов), Ruff, Pytest с synthetic deployment fixtures, standalone backend imports в существующем Python-окружении и `git diff --check`. Локальные imports и проверки шаблонов не заменяют Compose validation и выполнение собранного образа.
- [x] Разрешить локальное завершение Task 3 после реализации CI job и успешных применимых локальных проверок; отсутствие Docker само по себе не является причиной `TASK_FAILED`. До появления успешного `container` job контейнерная проверка записывается как «не выполнена локально; результат CI не подтверждён».


### Task 3 execution notes

- Создан `scripts/deploy-config.sh` — общий shell loader по contract Task 1: precedence «явные environment overrides → файл из `TAX_DEPLOY_CONFIG` → `~/.config/tax/deploy.env`»; отсутствующий `TAX_DEPLOY_CONFIG`-файл и отсутствующие/некорректные значения останавливают работу до SSH, Git, sudo, файловых изменений и service commands. Конфиг-файл парсится как строгий `KEY=VALUE` без `source`: значения с кавычками/метасимволами шелла отвергаются, а не исполняются (`deploy;id`, `$(...)` не проходят). Валидируются port (1–65535), domain (hostname), service identity (POSIX user/group), host (`user@host`) и пути (absolute + character allowlist). Безопасный режим без побочных эффектов: `scripts/deploy-config.sh check` и `render DIR` (render пишет только в целевой каталог и отказывается писать файлы с незакрытыми placeholder'ами).
- Private SSH host, username, domain и абсолютные пути удалены из `deploy.sh`, `reinstall-backend.sh`, `scripts/deploy-backend.sh`; все значения приходят из private deployment configuration. `scripts/deploy-backend.sh` передаёт `ssh -t "$TAX_DEPLOY_HOST" "$remote_command"` аргументами argv, удалённая команда собирается через POSIX-экранирование (`tax_deploy_sh_quote`); host value не печатается. `reinstall-backend.sh` при запуске под root делает `sudo -iu "$TAX_DEPLOY_USER"` с явной передачей identity/checkout path.
- `Caddyfile` и `server/tax.service` заменены нейтральными шаблонами с placeholder'ами `@TAX_DEPLOY_*@`; `deploy.sh` рендерит их во временный каталог через loader, повторно проверяет отсутствие placeholder'ов перед установкой и печатает rendered Caddy-блок для root вместо записи в `/etc/caddy`.
- Один loopback port: `TAX_DEPLOY_PORT` используется в systemd unit, rendered Caddyfile и health check; в примерах `8000` (deploy.env.example, Compose default `127.0.0.1:${TAX_DEPLOY_PORT:-8000}:8000`), owner port сохраняется через private config. Container port в Compose/Dockerfile зафиксирован `8000`; host loopback port, `TAX_COMPOSE_DATA_DIR` и `TAX_COMPOSE_KEYS_DIR` конфигурируемы, Caddy host port соответствует через ту же переменную. Обязательные Compose-переменные (`TAX_API_KEY` и APNs) используют `${VAR:?...}`, чтобы Compose падал без конфигурации.
- В `deploy.sh` сохранены online SQLite backup + `PRAGMA integrity_check` и schema verification (10 routing/diagnostic columns); deployment в рамках задачи не выполнялся. `.env` больше не создаётся автоматически: отсутствие файла или пустой `TAX_API_KEY` останавливает deployment с инструкцией (пример — `server/.env.example`; персональный bundle id из примера заменён на нейтральный). Backend dependencies ставятся из generated `server/requirements.txt` с `--require-hashes`. Dockerfile исправлен: копируются все runtime-модули (`logging_config.py apns.py relay.py storage.py main.py`, включая `relay.py`), установка из locked requirements с hash-проверкой.
- `.github/workflows/python.yml`: добавлен job `container` на `ubuntu-latest` — проверка availability Docker/Compose, `docker compose --env-file <tmp>/compose.env -f server/docker-compose.yml config` с synthetic environment во временном каталоге (owner `.env` не читается; проверяется host port 8123→container 8000 и synthetic data/keys dirs), `docker build` backend image и `docker run --rm --network none ... python -c 'import main, relay, storage, apns'` без mounts, credentials и запуска сервиса. Только first-party Actions (checkout), без установки Docker на Mac. Path filters дополнены `deploy.sh`, `reinstall-backend.sh`, `Caddyfile`, `deploy.env.example`, `scripts/deploy-backend.sh`, `scripts/deploy-config.sh`; существующие server/tests/lock triggers сохранены.
- `tests/test_deploy_configuration.py`: 69 Pytest-проверок на временных каталогах и fake executables (`ssh`, `git`) без реального SSH/systemd/Docker: precedence (env над файлом), отсутствующий `TAX_DEPLOY_CONFIG`, все 9 отсутствующих required values, невалидные port/domain/user/group/host/paths (включая metacharacters), render c проверкой значений и отсутствия placeholder'ов, согласованность ports между unit и Caddyfile и с примером/Compose, нейтральность tracked шаблонов (без hardcoded IP кроме loopback и `/home/...`), sh-экранирование, SSH-вызовы deploy-backend и отсутствие SSH/Git при невалидной конфигурации, non-root поток reinstall.
- Валидация: `bash -n deploy.sh reinstall-backend.sh scripts/deploy-backend.sh scripts/deploy-config.sh`; `uv lock --check`; `uv run --locked --extra dev ruff check server src tests`; `uv run --locked --extra dev pytest -q` — 148 passed (79 на базовом коммите + 69 новых; единственный warning — существующий starlette/anyio DeprecationWarning с базового коммита); standalone backend imports `python -c 'import main, relay, storage, apns'` из `server/` в существующем окружении; `git diff --check`; grep-скан изменённых файлов на private values (host/username/IP/bundle id) — чисто; YAML workflow распарсен, job/steps/path filters сверены. Контейнерная проверка (Compose validation и импорт в собранном образе) не выполнена локально; результат CI не подтверждён — подтверждение готовности фиксируется успешным `container` job (Acceptance Criteria).
### Task 4: Удалить private backend defaults и обезличить iOS signing

**Files:**
- Modify: `src/tax/cli.py`
- Modify: `src/tax/agent_notifications.py`
- Modify: `extensions/tax-push.ts`
- Modify: `tests/test_cli.py`
- Modify: `tests/test_agent_notifications.py`
- Modify: `tests/extension/tax-push.test.ts`
- Modify: `ios/tax/tax.xcodeproj/project.pbxproj`
- Modify: `ios/tax/tax/App/AppEnvironment.swift`
- Modify: `ios/tax/tax/Stores/SettingsStore.swift`
- Modify: `ios/tax/tax/Services/DeviceRegistrationService.swift`
- Modify: `ios/tax/taxTests/SettingsStoreTests.swift`
- Modify: `ios/tax/taxUITests/TaxUITests.swift`
- Modify: `scripts/preflight.sh`
- Modify: `server/.env.example`
- Create: `ios/Config/Public.xcconfig`
- Delete: `ios/tax/tax.xcodeproj/project.pbxproj.bak`

- [x] Убрать backend URL по умолчанию из CLI и Pi extension; `https://tax.example.com` оставить только в help/examples/mock fixtures.
- [x] Сохранить существующий CLI precedence: явный command argument, затем непустое значение config, затем environment. Отсутствие адреса или некорректный URL не должно приводить к сетевому запросу.
- [x] Команды, которым нужен backend, должны возвращать понятную configuration error без traceback.
- [x] Сохранить best-effort поведение Claude/Codex hooks и Pi extension: отсутствующая конфигурация пропускает push, не ломая работу агента.
- [x] Не менять выполнение `tax run`: configuration preflight остаётся до запуска команды; после запуска delivery failure не меняет exit code дочернего процесса.
- [x] В обеих initializers `SettingsStore` использовать пустой server URL при отсутствии сохранённого значения; сохранить существующие preferences и Keychain keys.
- [x] Проверить, что ненастроенное приложение не создаёт relay connection и не отправляет device registration.
- [x] Заменить private URL в UI-test defaults нейтральным mock URL; сохранить Debug-only screenshot fixtures и запрет live networking в screenshot mode.
- [x] В `Public.xcconfig` задать `com.example.tax`, `com.example.tax.tests`, `com.example.tax.uitests` и пустую signing team; подключить optional `Local.xcconfig`.
- [x] Привязать все Debug/Release project/target configurations к новым variables, удалив inline values, которые перекрывают xcconfig.
- [x] Сохранить owner bundle IDs/team через private override, не меняя entitlements, Keychain service names или app identity владельца.
- [x] Вычислять OSLog subsystem из `Bundle.main.bundleIdentifier` с нейтральным fallback; не логировать configured server URL публично.
- [x] Обновить preflight: проверять configurable signing contract вместо персонального bundle ID.
- [x] Добавить regression coverage отсутствующей конфигурации и сохранения явно заданных значений.
- [x] Проверить Debug/Release simulator build без local override и разрешение synthetic override через Xcode build settings.

### Task 4 execution notes

- `src/tax/cli.py`: `DEFAULT_SERVER` удалён; `get_server` возвращает непустое значение config, затем `TAX_SERVER`, иначе пустую строку. Новый `require_server(config, override)` проверяет presence и схему http(s) до любых сетевых вызовов и используется в `run` (preflight до запуска child-команды), `status`, `push-doctor`, `remote-host`, `remote-smoke` (explicit `--server` wins) и `doctor` (backend-check не падает с traceback при отсутствии URL). Порядок проверок сохранён: сначала API key, затем server. Ошибки конфигурации выводятся одной строкой `[tax] error: ...` без traceback.
- `src/tax/agent_notifications.py`: hook пропускает push при отсутствии server/API key и при не-http(s) URL; `TAX_SERVER` учитывается в env-fallback. Exit code 0 и no-op при отсутствии конфигурации сохранены.
- `extensions/tax-push.ts`: дефолтный URL на module load удалён; endpoint вычисляется из `TAX_SERVER` в момент `agent_settled`, без переменной — push пропускается с warning, как и при отсутствии API key/terminal handle.
- iOS: оба initializer `SettingsStore` используют пустой `serverURL` по умолчанию (ключи preferences/Keychain не менялись); пустой/некорректный URL даёт `configuredService == nil`, `remoteConfiguration == nil` и no-op `registerSavedDeviceToken` (без создания сервиса и без relay-подключения — guard в `RemoteWorkspaceStore.connect` сохранён). OSLog subsystem вычисляется через `AppLog` (`Bundle.main.bundleIdentifier` с fallback `com.example.tax`); server URL больше не логируется (заменён на `serverURLPresent`). Screenshot fixtures остались Debug-only, live networking в screenshot mode по-прежнему запрещён (`RemoteWorkspaceStore`/`MockDeviceRegistrationService`).
- `AppEnvironment.swift` и `TaxUITests.swift`: private URL в UI-test defaults заменён на `https://tax.example.com`; реальный URL передаётся только явно (`--mock-server-url` / `TAX_UI_SERVER`).
- Создан `ios/Config/Public.xcconfig`: нейтральные defaults (`com.example.tax`, `com.example.tax.tests`, `com.example.tax.uitests`, пустая team), `#include? "Local.xcconfig"` для приватного override, маппинг `DEVELOPMENT_TEAM = $(TAX_DEVELOPMENT_TEAM)`. В `project.pbxproj` все 8 Debug/Release configurations (2 project + 6 target) получили `baseConfigurationReference`; inline `DEVELOPMENT_TEAM`/`PRODUCT_BUNDLE_IDENTIFIER` удалены и заменены ссылками на `$(TAX_*)`-переменные; bundle IDs не встречаются в tracked iOS-файлах. `project.pbxproj.bak` удалён. Entitlements, Info.plist, Keychain keys (`tax.apiKey`, `tax.remoteE2EEKey`) и xcscheme не менялись.
- `scripts/preflight.sh`: проверка персонального bundle ID заменена на контракт — наличие `Public.xcconfig`, всех 4 переменных, optional include, привязки всех configurations через `baseConfigurationReference` и ссылок на `$(TAX_*)` в pbxproj; приватные значения в preflight не встраиваются. `server/.env.example`: `TAX_APNS_BUNDLE_ID` помечен как привязанный к `TAX_APP_BUNDLE_IDENTIFIER` из `Local.xcconfig`.
- Regression coverage: +17 Pytest-проверок (precedence/пустой config/env, отклонение невалидных URL без сети, config-ошибки `status`/`run`/`push-doctor` без запуска child-процесса, сохранение явно заданного server, best-effort hooks) и +3 Node-теста (skip без `TAX_SERVER`, per-event endpoint, существующие сценарии на lazy resolution); +5 XCTest в `SettingsStoreTests` (пустой дефолт, отсутствие сервиса/регистрации, невалидный URL с key, сохранение и reload явно заданного URL).
- Валидация: `bash -n scripts/preflight.sh`; `uv lock --check`; `uv sync --locked --extra dev`; `uv run --locked --extra dev ruff check server src tests`; `uv run --locked --extra dev pytest -q` — 165 passed (148 на базовом коммите + 17 новых; единственный warning — существующий starlette/anyio DeprecationWarning); `npm test` — 19 passed (16 + 3 новых); `git diff --check`. Xcode 26.6: Debug и Release simulator builds (`generic/platform=iOS Simulator`, `CODE_SIGNING_ALLOWED=NO`) без `Local.xcconfig` (временно перемещён и восстановлен с правами 0600) и Debug build с synthetic override (`TAX_APP_BUNDLE_IDENTIFIER`/`TAX_DEVELOPMENT_TEAM` через command-line build settings); `xcodebuild -showBuildSettings` при восстановленном `Local.xcconfig` подтверждает, что team resolves непустым и bundle ID равен app-значению владельца (проверено без печати значений). Grep-скан всех изменённых файлов на private identifiers — чисто.

### Task 5: Ввести opt-in content storage и автоматическую retention

**Files:**
- Modify: `server/main.py`
- Modify: `server/storage.py`
- Modify: `server/.env.example`
- Modify: `server/docker-compose.yml`
- Modify: `tests/test_server.py`

- [ ] Добавить `TAX_STORE_AGENT_CONTENT`, выключенный по умолчанию; opt-in значение — `1`.
- [ ] Добавить `TAX_TASK_RETENTION_DAYS` с default `7`; принимать только положительное целое число, ошибочную настройку отклонять при startup.
- [ ] При выключенном content storage сохранять `context/logs` как пустые строки. Сохранять API response shape, `title/body`, routing и push diagnostics.
- [ ] При startup очищать `context/logs` существующих записей, если content storage выключен.
- [ ] Удалять tasks старше retention по `created_at` в UTC независимо от content-storage flag; не удалять device registrations и не менять legacy physical schema.
- [ ] Выполнять cleanup при startup и затем каждый час через управляемую lifespan background task; корректно завершать её при shutdown.
- [ ] Ограничить scope транзакций и не держать SQLite connection между периодическими итерациями.
- [ ] Ошибку startup cleanup считать ошибкой запуска; периодические ошибки логировать без content и повторять на следующем цикле.
- [ ] Не менять APNs payload, notification adapters или HTTPS transport: запрет сохранения не означает запрет передачи `context/logs` backend.
- [ ] Обновить существующие migration tests с учётом согласованной очистки старых данных.
- [ ] Добавить проверки default/opt-in, очистки старого content, retention boundary, UTC timestamps, сохранения device registrations, startup/shutdown cleanup и неизменности APNs preview.
- [ ] Проверять storage на временной SQLite базе и APNs через существующие stubs; рабочую базу не открывать.

### Task 6: Добавить лицензирование и нормализовать App Icon

**Files:**
- Create: `LICENSE`
- Create: `SECURITY.md`
- Create: `THIRD_PARTY_NOTICES.md`
- Modify: `pyproject.toml`
- Modify: `uv.lock`
- Modify: `server/requirements.txt`
- Modify: `docs/orca-runtime-compatibility.md`
- Modify: `ios/tax/tax/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Rename: `ios/tax/tax/Assets.xcassets/AppIcon.appiconset/93f1c78a-7390-4223-9806-bf65edab19c3 1.png` → `ios/tax/tax/Assets.xcassets/AppIcon.appiconset/AppIcon.png`

- [ ] Добавить MIT license для TAX с public identity `Sergionius`; заменить персональное имя в Python author metadata.
- [ ] Использовать стандартный SPDX expression и включить license file в sdist/wheel; при необходимости синхронно обновить build backend и lock.
- [ ] Добавить security policy для текущей линии `0.4.x`: private reporting через GitHub Security Advisories, без публикации уязвимостей и credentials в issues. Не утверждать, что reporting уже включён в будущем repository.
- [ ] Зафиксировать подтверждённое владельцем право распространения App Icon; переименовать asset без изменения изображения.
- [ ] Сохранить существующие OFL files рядом с JetBrains Mono и Space Grotesk.
- [ ] Добавить attribution и применимые notices для используемой версии SwiftTerm и Orca integration.
- [ ] Проверить bridge на включённый upstream code: TAX распространяет собственный adapter, а Orca helpers загружаются из пользовательской установки. Не включать извлечённые модули Orca в package.
- [ ] Для обнаруженных заимствованных фрагментов сохранить обязательные license notices; при неустановленном происхождении не объявлять подготовку завершённой.
- [ ] Документировать зависимость adapter от совместимой установленной версии Orca без обещания стабильности приватного протокола.

### Task 7: Перевести публичные материалы и описать реальные privacy guarantees

**Files:**
- Modify: `README.md`
- Modify: `docs/OPERATIONS.md`
- Modify: `docs/RELEASE_CHECKLIST.md`
- Modify: `docs/LOCAL_CONFIGURATION.md`
- Modify: `docs/remote-protocol-v1.md`
- Modify: `docs/orca-runtime-compatibility.md`
- Modify: `SECURITY.md`
- Create: `docs/PRIVACY.md`
- Modify: `ios/README.md`
- Modify: `ios/README-REMOTE.md`
- Modify: `ios/APNS_SMOKE_CHECKLIST.md`
- Modify: `ios/tax/tax/Views/FileBrowserView.swift`
- Modify: `ios/tax/tax/Views/SettingsView.swift`
- Modify: `ios/tax/tax/Views/WorkspaceListView.swift`
- Modify: `ios/tax/tax/Views/WorkspaceTheme.swift`
- Modify: `ios/tax/tax/Views/WorkspaceView.swift`
- Modify: `ios/tax/tax/taxApp.swift`

- [ ] Перевести публичный текст, UI strings и комментарии на английский, не меняя поведения и accessibility identifiers.
- [ ] Сохранить согласованный “Why TAX…” раздел и скриншоты; открыть README формулировкой “A self-hosted, end-to-end encrypted iPhone remote for Orca.”
- [ ] Уточнить, что E2EE есть и у Orca Mobile; отличие TAX — управление собственной инфраструктурой и более узкий набор функций.
- [ ] Удалить утверждения, что весь backend видит только ciphertext или push содержит только routing identifiers: notification content обрабатывается отдельно.
- [ ] Описать поля хранения, defaults, opt-in, hourly cleanup, применение политики к старой базе и отсутствие автоматической очистки backups.
- [ ] Указать, что удаление SQLite rows/content не является гарантированным физическим стиранием со storage media.
- [ ] Явно описать границы E2EE: terminal/file traffic шифруется, но backend видит routing/connection metadata, а Apple получает APNs title/body.
- [ ] Указать, что отключение storage не предотвращает поступление `context/logs` backend по HTTPS.
- [ ] Разделить README на назначение, screenshots, requirements и краткий setup; подробные systemd/Compose, APNs и troubleshooting инструкции разместить в соответствующих документах.
- [ ] Использовать только generic domains, paths и bundle IDs. Объяснить необходимость собственного app signing/APNs topic и постоянно доступного Mac.
- [ ] Сохранить инструкции Pi, Claude Code, Codex и `tax run`, включая best-effort delivery и terminal deep links.
- [ ] Удалить ссылки на внутренние планы и локальные skills из публичных документов.
- [ ] Проверить оставшийся публичный текст сканированием; точные дополнительные файлы при обнаружении фиксировать по результатам scan, исключая внутренние каталоги.
- [ ] Не регенерировать screenshots с live data; проверить текущие PNG на metadata и приватные данные.

### Task 8: Исключить локальные материалы и включить постоянные safety checks

**Files:**
- Modify: `.gitignore`
- Modify: `.github/workflows/python.yml`
- Modify: `.github/workflows/extension.yml`
- Modify: `.github/workflows/ios.yml`
- Modify: `.github/dependabot.yml`
- Modify: `scripts/preflight.sh`
- Create: `.github/workflows/security.yml`
- Create: `scripts/check-public-tree.py`
- Create: `tests/test_public_tree.py`
- Untrack, preserve locally: `.pi/skills/`
- Untrack, preserve locally: `ios/skills/`
- Untrack, preserve locally: `plans/`
- Untrack, preserve locally: `docs/plans/`
- Untrack, preserve locally: `ios/docs/plans/`

- [ ] Добавить ignore-правила для локальных skills и внутренних plans; убрать их из Git index, сохранив содержимое на диске, включая референс и этот план.
- [ ] Исключить другие внутренние execution notes только после проверки их назначения; сохранить пользовательскую и protocol documentation.
- [ ] Проверить сохранность локальных skills и отсутствие broken links в публичных документах.
- [ ] Реализовать проверку публикуемого набора через `git ls-files`, не рекурсивный обход private ignored files.
- [ ] Отклонять secrets/generated artifacts, private absolute paths, персональные metadata, неразрешённые Cyrillic strings и внутренние каталоги.
- [ ] Не встраивать удаляемые private значения в scanner или его fixtures. Для точного финального поиска использовать временный внешний denylist без вывода совпавшего содержимого.
- [ ] Разрешать documented generic examples и обязательные third-party copyright notices; исключения должны быть точечными, а не для целых source-каталогов.
- [ ] Добавить Pytest-проверки scanner на synthetic fixtures, не зависящие от реальных данных владельца.
- [ ] Перенести repository-safety/Gitleaks в отдельный workflow без path filters: каждый PR и push в `main`.
- [ ] Сканировать содержимое tracked snapshot без ignored local files; не выдавать этот результат за проверку старой private Git-истории.
- [ ] Закрепить все используемые GitHub Actions полными проверенными commit SHA с комментариями исходных release tags.
- [ ] Сохранить минимальные permissions, системный Xcode `macos-26`, simulator preboot и существующий UI retry.
- [ ] Добавить lock/export/security-script paths в relevant CI triggers.
- [ ] Включить public-tree check и Node extension tests в preflight.
- [ ] Убрать безусловное удаление общих `dist`, `build` и прежних result directories из preflight: создавать отдельный временный output directory и удалять только собственные временные данные.
- [ ] Проверить installation/build из изолированной копии публикуемых файлов с временным HOME и без local signing/config. Не создавать новый Git repository и не выполнять публикацию.

## Validation

Проверки выполняются в изолированных окружениях, без production credentials, SSH, deployment и реальных push.

Для каждого Task запускать применимые к его файлам проверки. Финальные public-tree requirements обязательны после Task 8; промежуточные задачи не обязаны проходить ещё не включённую полную очистку.

Основные команды:

```bash
uv lock --check
uv sync --locked --extra dev
uv run --locked --extra dev ruff check server src tests
uv run --locked --extra dev pytest -q
npm test
git diff --check
```

Дополнительно:

- Сравнение generated `server/requirements.txt` с повторным export из lock.
- Сборка sdist/wheel во временный output directory и существующий clean-wheel smoke.
- `bash -n` для `deploy.sh`, `reinstall-backend.sh` и всех `scripts/*.sh`.
- Deployment configuration tests только с synthetic config и fake external commands.
- Контейнерная проверка выполняется в CI `container` job (GitHub-hosted `ubuntu-latest`): `docker compose ... config` с synthetic environment; сборка образа и импорт `main`, `relay`, `storage`, `apns` без запуска production services. Локальная Docker-валидация не требуется; локальные imports и проверки шаблонов не заменяют Compose validation и выполнение собранного образа.
- Проверка Xcode settings с отсутствующим и synthetic `Local.xcconfig`.
- Debug и Release simulator builds:

```bash
xcodebuild build \
  -project ios/tax/tax.xcodeproj \
  -scheme tax \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO
```

Повторить с `-configuration Release`.

- Существующие unit/UI tests через `xcodebuild test`, `-only-testing:taxTests` и `-only-testing:taxUITests`; simulator выбрать из доступных устройств и предварительно дождаться boot.
- `scripts/preflight.sh` после перевода на изолированные outputs.
- `scripts/check-public-tree.py` и Gitleaks для tracked snapshot.
- Проверка состава wheel/sdist: license и bridge присутствуют, private config, plans и skills отсутствуют.
- Полная проверка новой Git-истории и anonymous clone не выполняется: новый public repository находится вне scope.

## Acceptance Criteria

- Без явной настройки CLI, extension и iPhone не обращаются к инфраструктуре владельца.
- Private owner configuration сохранена отдельно и не включена в tracked/package files; существующие Keychain identities не изменены.
- Systemd и Docker Compose используют согласованные configurable ports/paths; итоговая готовность проекта подтверждается успешным контейнерным CI `container` job (Compose validation и импорт backend в собранном образе), а не локальной проверкой без Docker.
- Runtime/dev dependencies воспроизводятся из `uv.lock`; exported requirements актуальны и содержат hashes.
- `context/logs` по умолчанию не сохраняются и очищаются в существующей базе; opt-in работает.
- Tasks старше установленного срока автоматически удаляются; device registrations сохраняются.
- Privacy documentation точно различает relay E2EE, notification transport, APNs и SQLite storage.
- Публичные документы и UI англоязычны; README сохраняет согласованное позиционирование и sanitized screenshots.
- MIT license и third-party notices включены; право распространения иконки отражено.
- Skills и внутренние планы отсутствуют в tracked snapshot, но сохранены локально.
- Safety workflow не ограничен path filters, Actions закреплены SHA, relevant automated checks проходят.
- Работающий VPS, private repository visibility и Git-история не изменены. Live owner verification не заявляется выполненной.
