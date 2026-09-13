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

- [ ] Добавить ignore-правила для локального signing config; явно разрешить tracked example-файлы там, где они пересекаются с существующим правилом `*.env`.
- [ ] Зафиксировать contract deployment configuration: `TAX_DEPLOY_HOST`, `TAX_DEPLOY_USER`, `TAX_DEPLOY_GROUP`, `TAX_DEPLOY_PROJECT_DIR`, `TAX_DEPLOY_DOMAIN`, `TAX_DEPLOY_PORT`, `TAX_DEPLOY_DB_PATH`, `TAX_DEPLOY_APNS_KEY_PATH`, `TAX_DEPLOY_ENV_FILE`.
- [ ] Определить приоритет deployment-настроек: явные environment overrides, затем файл из `TAX_DEPLOY_CONFIG`, затем `~/.config/tax/deploy.env`. Отсутствие явно указанного файла является ошибкой.
- [ ] До удаления tracked defaults сохранить доступные текущие настройки владельца в приватных файлах. Не перезаписывать существующие значения; конфликт или отсутствие необходимых данных должно останавливать миграцию, а не подставлять пример.
- [ ] Сохранять локальные config-файлы с правами `0600`; не печатать их содержимое и credentials в диагностику.
- [ ] Определить signing variables `TAX_DEVELOPMENT_TEAM`, `TAX_APP_BUNDLE_IDENTIFIER`, `TAX_TESTS_BUNDLE_IDENTIFIER`, `TAX_UITESTS_BUNDLE_IDENTIFIER`.
- [ ] Оставить существующие Keychain entries и Orca pairing file без изменений.
- [ ] Документировать перенос iPhone server URL в явно сохранённые настройки до исчезновения default; не добавлять приватный URL в migration code.
- [ ] Описать подготовку private config на VPS без выполнения SSH, изменения сервиса или deployment.

### Task 2: Сделать Python-зависимости воспроизводимыми через uv

**Files:**
- Modify: `pyproject.toml`
- Modify: `server/requirements.txt`
- Modify: `.github/workflows/python.yml`
- Modify: `.github/dependabot.yml`
- Modify: `scripts/preflight.sh`
- Create: `uv.lock`

- [ ] Использовать `pyproject.toml` как единственный источник прямых runtime/dev dependencies; сохранить существующий `dev` extra и поддержку Python 3.11–3.13.
- [ ] Добавить и зафиксировать совместимую версию `uv`; CI должен устанавливать её без нового стороннего GitHub Action.
- [ ] Создать `uv.lock` с resolved versions и hashes для поддерживаемых окружений.
- [ ] Сделать `server/requirements.txt` генерируемым export runtime dependencies из lock без самого проекта и dev dependencies; сохранить hashes и удалить независимое ручное определение версий.
- [ ] Перевести Python CI и Python-часть preflight на locked sync и запуск через `uv`.
- [ ] Сохранить сборку sdist/wheel и установку wheel в отдельное чистое окружение; проверять help для `tax`, `notify`, `run`, `remote-host`.
- [ ] Зафиксировать build backend совместимым способом, чтобы package build не обходил выбранную политику воспроизводимости.
- [ ] Настроить Dependabot для `uv.lock`, сохранив обновления GitHub Actions.
- [ ] Добавить CI-проверку актуальности generated requirements относительно lock; обновление dependencies должно включать согласованное обновление export.
- [ ] Не менять пользовательскую установку через pipx без необходимости и не добавлять `uv` как runtime dependency CLI.

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
- Create: `scripts/deploy-config.sh`
- Create: `tests/test_deploy_configuration.py`

- [ ] Реализовать общий shell configuration loader по contract Task 1; убрать private SSH host, username, domain и абсолютные пути из скриптов.
- [ ] Обязательные параметры проверять до SSH, Git, sudo, файловых изменений или service commands.
- [ ] Валидировать port, domain, service identity и пути; безопасно передавать аргументы SSH и экранировать значения при генерации systemd/Caddy configuration.
- [ ] Заменить tracked Caddyfile и systemd unit на нейтральные шаблоны с параметрами; не допускать случайной установки неотрендеренного шаблона.
- [ ] Использовать один configured loopback port для systemd, Caddy и health check. В примерах использовать `8000`; существующий owner port сохранять через private config.
- [ ] Сохранить online SQLite backup и schema verification в deployment code, не выполняя deployment в рамках этой задачи.
- [ ] Не создавать `.env` с пустым API key автоматически; сообщать об отсутствующей обязательной конфигурации.
- [ ] Установку backend dependencies выполнять из generated requirements с `--require-hashes`.
- [ ] Сохранить Docker container port `8000`, сделать host loopback port, persistent data directory и key directory конфигурируемыми; обеспечить соответствие Caddy host port.
- [ ] Исправить Dockerfile: включить `relay.py` и остальные backend runtime modules; использовать locked requirements с проверкой hashes.
- [ ] Добавить безопасный режим проверки/render configuration без SSH, service commands и применения конфигурации.
- [ ] Покрыть Pytest-проверками precedence, отсутствие required values, неверные значения и согласованность портов. Использовать только временные каталоги и fake executables, без реального SSH/systemd.
- [ ] Проверить Docker configuration и импорт backend в собранном образе без реальных APNs credentials.

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

- [ ] Убрать backend URL по умолчанию из CLI и Pi extension; `https://tax.example.com` оставить только в help/examples/mock fixtures.
- [ ] Сохранить существующий CLI precedence: явный command argument, затем непустое значение config, затем environment. Отсутствие адреса или некорректный URL не должно приводить к сетевому запросу.
- [ ] Команды, которым нужен backend, должны возвращать понятную configuration error без traceback.
- [ ] Сохранить best-effort поведение Claude/Codex hooks и Pi extension: отсутствующая конфигурация пропускает push, не ломая работу агента.
- [ ] Не менять выполнение `tax run`: configuration preflight остаётся до запуска команды; после запуска delivery failure не меняет exit code дочернего процесса.
- [ ] В обеих initializers `SettingsStore` использовать пустой server URL при отсутствии сохранённого значения; сохранить существующие preferences и Keychain keys.
- [ ] Проверить, что ненастроенное приложение не создаёт relay connection и не отправляет device registration.
- [ ] Заменить private URL в UI-test defaults нейтральным mock URL; сохранить Debug-only screenshot fixtures и запрет live networking в screenshot mode.
- [ ] В `Public.xcconfig` задать `com.example.tax`, `com.example.tax.tests`, `com.example.tax.uitests` и пустую signing team; подключить optional `Local.xcconfig`.
- [ ] Привязать все Debug/Release project/target configurations к новым variables, удалив inline values, которые перекрывают xcconfig.
- [ ] Сохранить owner bundle IDs/team через private override, не меняя entitlements, Keychain service names или app identity владельца.
- [ ] Вычислять OSLog subsystem из `Bundle.main.bundleIdentifier` с нейтральным fallback; не логировать configured server URL публично.
- [ ] Обновить preflight: проверять configurable signing contract вместо персонального bundle ID.
- [ ] Добавить regression coverage отсутствующей конфигурации и сохранения явно заданных значений.
- [ ] Проверить Debug/Release simulator build без local override и разрешение synthetic override через Xcode build settings.

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
- `docker compose ... config` с fixture environment; сборка образа и импорт `main`, `relay`, `storage`, `apns` без запуска production services.
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
- Systemd и Docker Compose используют согласованные configurable ports/paths; Docker backend импортируется успешно.
- Runtime/dev dependencies воспроизводятся из `uv.lock`; exported requirements актуальны и содержат hashes.
- `context/logs` по умолчанию не сохраняются и очищаются в существующей базе; opt-in работает.
- Tasks старше установленного срока автоматически удаляются; device registrations сохраняются.
- Privacy documentation точно различает relay E2EE, notification transport, APNs и SQLite storage.
- Публичные документы и UI англоязычны; README сохраняет согласованное позиционирование и sanitized screenshots.
- MIT license и third-party notices включены; право распространения иконки отражено.
- Skills и внутренние планы отсутствуют в tracked snapshot, но сохранены локально.
- Safety workflow не ограничен path filters, Actions закреплены SHA, relevant automated checks проходят.
- Работающий VPS, private repository visibility и Git-история не изменены. Live owner verification не заявляется выполненной.
