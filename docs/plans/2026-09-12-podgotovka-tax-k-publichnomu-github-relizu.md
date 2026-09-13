# Подготовка TAX к публичному GitHub-релизу

> Внутренний рабочий документ. Он содержит приватные идентификаторы для контроля очистки и должен быть удалён из публичного snapshot.

## Цель и модель публикации

Подготовить безопасный self-hosted open-source snapshot TAX, не ломая текущую локальную установку владельца.

Публиковать нужно **новый GitHub repository с новой историей**, а не менять visibility существующего private repository. В public repository должны попасть только очищенный `main` и один новый root commit. Старые branches, tags, releases, artifacts и `.git` переносить нельзя.

## Результаты текущего аудита

На момент аудита в tracked-файлах остаются:

- IP `138.249.127.23` и домен `tax.138-249-127-23.nip.io`;
- deployment user `hermes` и пути `/home/hermes/tax`;
- Apple Team ID `WQ3X4DQT53`;
- bundle IDs `ru.madmaximuus.*`;
- персональные Git identities и имя автора Python package;
- `ios/tax/tax.xcodeproj/project.pbxproj.bak`;
- `.pi/skills/`, `ios/skills/` и внутренние plans;
- кириллица в README, iOS UI/comments и документации;
- отсутствующие `LICENSE` и `SECURITY.md`;
- непроверенное происхождение App Icon;
- изменяемые tags GitHub Actions вместо commit SHA;
- Gitleaks, запускающийся только при изменениях Python paths;
- разные backend ports (`8000`, `8001`, `8002`) в deployment-файлах;
- бессрочное хранение notification `context/logs` в SQLite;
- bundled bridge к приватным Orca Runtime modules, право на распространение которого нужно подтвердить.

История private repository уже содержит инфраструктурные идентификаторы и персональные email. Простого удаления значений из текущего HEAD недостаточно.

## 1. Сохранить рабочее локальное окружение

До удаления hardcoded values перенести текущую конфигурацию в ignored/system storage:

- backend secrets и APNs settings — существующий VPS `server/.env`;
- Mac CLI backend URL/API key — `~/.config/tax/config.json`;
- E2EE key — macOS Keychain;
- Orca pairing URL — `~/.config/tax/orca-pairing`;
- domain, SSH host/user, service user, installation path и port — `~/.config/tax/deploy.env`;
- Apple signing team и персональные bundle IDs — ignored `ios/Config/Local.xcconfig`.

Добавить безопасные tracked-примеры:

- `server/.env.example`;
- `deploy.env.example`;
- `ios/Config/Local.xcconfig.example`;
- generic Caddy и systemd templates.

Скрипты должны читать локальную конфигурацию и завершаться понятной ошибкой при её отсутствии. Они не должны обращаться к старому VPS по умолчанию.

Перед продолжением проверить текущую owner-инсталляцию: backend deploy, APNs, signing, Pi, Claude Code, Codex, `tax remote-host`, Orca и E2EE relay.

## 2. Удалить приватную инфраструктуру из tracked snapshot

Заменить или удалить во всех code/docs/tests/templates:

- private IP/domain → configured self-hosted URL или `https://tax.example.com` только в examples/tests;
- `hermes` и `/home/hermes/tax` → deployment parameters;
- private SSH defaults → обязательные `TAX_DEPLOY_HOST`/config values;
- персональные абсолютные пути → нейтральные fixtures;
- author metadata → `Sergionius`.

Особое внимание:

- `README.md`;
- `src/tax/cli.py`;
- `extensions/tax-push.ts`;
- `Caddyfile`, `deploy.sh`, `reinstall-backend.sh`;
- `scripts/deploy-backend.sh`;
- `server/tax.service`, `server/.env.example`;
- iOS defaults, tests и preflight checks.

CLI, extension и iOS должны требовать явную настройку backend. Приложение без настройки не должно обращаться к owner backend.

## 3. Сделать deployment универсальным

Выбрать и документировать основной deployment mode:

- Docker Compose: container port `8000`, host bind port через config;
- либо systemd: configurable local backend port.

Устранить неявное смешивание `8000`, `8001` и `8002`. Caddy должен проксировать на тот же configured port, который использует выбранный backend service.

Deployment templates должны параметризовать:

- domain;
- service user/group;
- project directory;
- database path;
- APNs key path;
- backend port;
- environment file.

Проверить два сценария:

1. Existing owner VPS продолжает обновляться через private config.
2. Новый пользователь разворачивает backend только по public README и example-файлам.

## 4. Обезличить iOS project и сохранить signing владельца

В tracked project установить:

- app: `com.example.tax`;
- tests: `com.example.tax.tests`;
- UI tests: `com.example.tax.uitests`;
- пустой/default development team;
- OSLog subsystem через `Bundle.main.bundleIdentifier`.

Персональные Team ID и bundle IDs подключать только через ignored `Local.xcconfig`.

Обновить:

- `project.pbxproj`;
- `server/.env.example`;
- iOS README;
- preflight assertions;
- UI test defaults;
- APNs setup documentation.

Удалить tracked `ios/tax/tax.xcodeproj/project.pbxproj.bak`.

Проверить Debug simulator build, Release simulator build, tests и реальный owner signing через local xcconfig.

## 5. Удалить локальные agent skills и внутренние планы из public snapshot

Добавить в `.gitignore`:

```gitignore
.pi/skills/
ios/skills/
ios/Config/Local.xcconfig
```

Удалить skills только из Git index через `git rm -r --cached`, не удаляя локальные файлы. Проверить, что Pi и локальные workflows продолжают их видеть.

Из public snapshot удалить:

- `plans/`;
- `docs/plans/`;
- `ios/docs/plans/`;
- внутренние execution notes/reviews;
- текущий release-preparation plan.

Оставить только документацию, полезную пользователю, оператору или contributor.

## 6. Перевести публикуемый проект на английский

Перевести:

- root README и iOS README;
- installation, APNs и operations documentation;
- Swift/Python/TypeScript/shell comments;
- UI strings, errors и diagnostics;
- test names/comments;
- configuration templates и CI descriptions.

После удаления внутренних планов выполнить tracked-text scan по кириллице. Результат должен быть пустым, кроме текста, необходимого функциональности продукта.

## 7. Зафиксировать privacy и retention model

Явно описать в README и `SECURITY.md`:

- APNs title/body видны Apple и не покрыты TAX E2EE;
- Mac передаёт notification content backend по HTTPS;
- E2EE применяется к remote workspace relay, terminal I/O и file operations;
- backend не имеет E2EE key.

Минимизировать хранение agent content:

- по умолчанию не сохранять полные `context/logs`, если они не нужны продукту;
- либо добавить explicit opt-in `TAX_STORE_AGENT_CONTENT=1`;
- добавить configurable retention, например `TAX_TASK_RETENTION_DAYS=7`;
- реализовать автоматическую очистку task history;
- задокументировать, какие поля сохраняются и как отключить storage.

Добавить тесты retention и режима без хранения content.

## 8. Лицензии и права распространения

Добавить:

- root `LICENSE` с MIT text;
- `SECURITY.md` с private vulnerability reporting и supported versions.

Обновить Python metadata на стандартный SPDX license expression и включить license file в wheel/sdist.

Проверить:

- право на распространение App Icon; переименовать случайное имя asset в `AppIcon.png`;
- OFL-лицензии JetBrains Mono и Space Grotesk остаются рядом со шрифтами;
- лицензию SwiftTerm;
- возможность публичного распространения `src/tax/resources/orca-runtime-terminal-bridge.cjs`, который загружает private Orca Runtime modules.

Если bridge нельзя распространять, заменить его documented adapter/API integration либо исключить из public snapshot.

## 9. Усилить CI и supply chain

Уже выполнено:

- удалён `maxim-lobanov/setup-xcode@v1`; iOS workflow использует системный Xcode `macos-26` runner и печатает выбранную версию;
- workflow permissions минимальны;
- Dependabot и Gitleaks существуют.

Осталось:

- вынести repository-safety/Gitleaks в отдельный workflow без path filters, чтобы он запускался на каждом PR и push в `main`;
- закрепить GitHub Actions по full commit SHA:
  - `actions/checkout`;
  - `actions/setup-python`;
  - `actions/setup-node`;
  - `actions/upload-artifact`;
  - `gitleaks/gitleaks-action`;
- добавить comments с исходными release tags рядом с SHA;
- добавить reproducible Python constraints/lock с hashes для backend и development dependencies;
- убедиться, что Dependabot обновляет actions и dependency lock;
- сохранить package build и clean-wheel smoke tests.

## 10. Финальная проверка очищенного дерева

`rg`/`git grep` не должны находить:

- private IP/domain;
- Team ID;
- `madmaximuus`, `sergiomalkin`, `hermes`;
- персональные email;
- личные абсолютные пути;
- legacy backend defaults;
- кириллицу;
- внутренние plans/skills.

`git ls-files` не должен содержать:

- `.env`, `.p8`, keys;
- DB/SQLite;
- caches и `__pycache__`;
- `xcuserdata`, DerivedData;
- `.bak`, logs, artifacts;
- `.pi/skills`, `ios/skills`;
- internal plans.

Запустить:

- Gitleaks по полной новой истории;
- Ruff и полный Pytest;
- Node extension tests;
- Python sdist/wheel build и clean install;
- `scripts/preflight.sh`;
- iOS Debug/Release simulator builds;
- iOS unit/UI tests;
- `tax doctor`;
- mock verification Pi/Claude/Codex notification adapters;
- shell syntax checks;
- anonymous clean clone verification.

Проверить, что README screenshots не содержат metadata или приватные identifiers.

## 11. Проверка реального owner environment

После code cleanup, но до публикации, отдельно проверить с private local config:

- текущий VPS deploy;
- backend health и APNs;
- `tax push-doctor`;
- Pi completion push;
- Claude Code completion push;
- Codex completion push;
- переход каждого push в правильный Orca terminal;
- `tax remote-host` LaunchAgent;
- E2EE reconnect;
- terminal snapshot/input/resize;
- workspace file read/write/conflict handling;
- Xcode signing на физическом iPhone.

Никакие реальные credentials, device tokens, paths или screenshots этого прогона не должны попасть в Git/CI artifacts.

## 12. Создать новый public repository

Из очищенного working tree создать отдельный snapshot без `.git`:

1. скопировать только tracked public files;
2. инициализировать новый Git repository;
3. создать один root commit от `Sergionius <GitHub noreply email>`;
4. создать новый GitHub repository;
5. push только `main`;
6. не переносить branches, tags, releases, issues, Actions artifacts и private history;
7. проверить repository через anonymous clean clone;
8. только после проверки выставить public visibility.

Существующий `Sergionius/tax` и его история остаются private archive/source repository.

## 13. Действия после публикации

- сменить backend API key;
- при необходимости реального сокрытия инфраструктуры сменить hostname/IP;
- проверить APNs credentials и при необходимости rotate;
- включить Dependabot Alerts, Security Updates, secret scanning и private vulnerability reporting в новом repository;
- настроить branch protection/ruleset для `main`;
- включить автоматическое удаление merged branches;
- добавить repository description, topics и social preview;
- создать первый tagged release только после повторного clean-clone preflight.

## Критерий готовности

Public release готов только когда одновременно выполняются условия:

1. чистый self-hosted пользователь может установить проект по public documentation;
2. owner environment работает через private ignored configuration;
3. в public snapshot и новой истории нет приватных identifiers или secrets;
4. privacy/retention поведение явно документировано;
5. права на icon, fonts, SwiftTerm и Orca bridge подтверждены;
6. все automated и real-device проверки пройдены;
7. существующий private repository не меняет visibility.
