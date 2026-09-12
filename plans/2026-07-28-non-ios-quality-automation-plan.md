# План улучшения backend, Mac agent, CLI и процессов

Дата: 2026-07-28

## Статус выполнения

Реализовано 2026-07-28:

- Python CI для 3.11–3.13, wheel smoke-test, dependency audit, gitleaks и repository checks;
- Dependabot для Python и GitHub Actions;
- интеграционный backend → Mac agent → acknowledgement тест и recovery/idempotency suite;
- отдельные CLI-тесты и дополнительные backend/APNs validation tests;
- структурированные редактируемые логи, request ID и проверка БД в `/health`;
- извлечение SQLite и APNs из `server/main.py` в отдельные модули;
- устранение предупреждения TestClient через `httpx2`;
- release preflight, operations runbook, status contract и release checklist;
- удаление отслеживаемого `xcuserdata`.

Внешние действия намеренно не выполнялись: production deployment, реальная отправка APNs и публикация релиза. Они требуют credentials, физического устройства и отдельного явного подтверждения.

## Контекст

Текущий baseline:

- 24 Python-теста проходят;
- `ruff check server src tests` проходит;
- GitHub Actions отсутствует;
- тесты хорошо покрывают отдельные сценарии backend;
- `server/main.py` объединяет API, SQLite и APNs;
- используется большое количество `print`, а структурированного логирования и общих correlation ID нет;
- test suite выводит предупреждение о deprecated-интеграции Starlette `TestClient`/httpx;
- автоматизированного release preflight нет.

## Цели

1. Проверять каждый PR без участия тестировщика.
2. Улучшить диагностику production-проблем без утечки секретов.
3. Упростить подготовку тестовых релизов.
4. Сначала зафиксировать поведение тестами, затем выполнять рефакторинг.

## Не входит в этот план

- Новая продуктовая функциональность.
- Production deployment без явного подтверждения.
- Замена SQLite или FastAPI без подтверждённой проблемы масштабирования.
- Большой архитектурный rewrite.

## Этап 1. Общий CI — P0

Добавить `.github/workflows/python.yml` со следующими job:

### 1.1. Lint и tests

- Ubuntu runner.
- Python 3.11, 3.12 и 3.13; одну версию назначить основной, остальные можно запускать matrix.
- Установка проекта с dev dependencies.
- Команды:

```bash
ruff check server src tests
pytest -q
```

- Cache для pip.
- Отмена устаревшего workflow при новом push в тот же PR.

### 1.2. Packaging smoke-test

- Сборка wheel и sdist.
- Установка wheel в чистое окружение.
- Проверка:

```bash
tax --help
tax notify --help
tax run --help
tax remote-host --help
```

- Проверить, что пакет не зависит от файлов рабочей директории.

### 1.3. Security и repository checks

- Secret scanning (`gitleaks` или аналог) для текущего дерева и новых коммитов.
- Dependency audit с явно зафиксированной политикой severity.
- Проверка отсутствия `.env`, `.p8`, SQLite databases, `xcuserdata`, `__pycache__` и `.pyc` среди tracked files.
- Не передавать настоящие TAX/APNs credentials в PR workflow.

**Критерий готовности:** CI обязателен для merge в `main`, а локальные команды совпадают с командами CI.

## Этап 2. Дополнение unit-тестов — P0

### Backend

Добавить проверки:

- отсутствующий и неверный Authorization header;
- limits/offset для `/tasks`;
- неизвестный task ID;
- APNs 400/403/410/429/500 и network timeout;
- выбор sandbox/production host;
- invalid/missing APNs configuration;
- миграции старой схемы SQLite;
- сохранение задач независимо от результата отправки push.

Перед ограничением размеров payload согласовать лимиты и добавить их как явный API contract.

### CLI

Добавить отдельный `tests/test_cli.py`:

- приоритет CLI config/environment/defaults;
- `tax config` без вывода API key;
- `tax run` для success, command failure и backend failure;
- `tax status` и невалидный ответ backend.

## Этап 3. Наблюдаемость и безопасные логи — P0

### 3.1. Структурированное логирование

- Перейти с `print` на стандартный `logging`.
- Использовать единые поля: component, event, task_id, session_id, status, duration_ms, attempt.
- В production поддержать JSON-формат; локально оставить читаемый текстовый formatter.
- Назначать request ID, принимать его из заголовка или генерировать на backend.
- Прокидывать task ID через backend events.

### 3.2. Редакция чувствительных данных

Никогда не логировать:

- API key и Authorization header;
- APNs auth token и полный device token;
- содержимое `.p8`;
- полный reply, context и logs по умолчанию.

Допустимы boolean-флаги, длины, task ID и короткий необратимый fingerprint device token. Удалить подробные debug-сообщения после появления структурированных событий.

### 3.3. Health и диагностика

- `/health`: жив ли процесс и доступна ли БД.
- Отдельная readiness-проверка при необходимости deployment orchestration.
- Логировать результат APNs с категорией ответа и `apns-id`, не записывая секреты.
- Добавить счётчики на уровне логов: tasks created, pushes queued/skipped/sent/failed.
- Не внедрять тяжёлый metrics stack, пока нет потребителя метрик.

## Этап 4. Устранение предупреждений и зависимости — P1

- Разобраться с предупреждением Starlette `TestClient`/httpx: обновить совместимые версии либо перейти на рекомендованный transport/test client.
- Зафиксировать прямые runtime dependencies в одном источнике истины; проверить необходимость дублирования `pyproject.toml` и `server/requirements.txt`.
- Добавить контролируемое обновление зависимостей Dependabot/Renovate не чаще одного раза в неделю.
- Для dependency PR обязательно запускать полный CI.
- Проверить минимальную Python 3.11 и выбранную production-версию отдельно.

## Этап 5. Безопасный рефакторинг backend — P1

Начинать только после этапов 1–4 и без изменения API contract.

Предлагаемое разделение:

```text
server/
  app.py             # создание FastAPI и lifespan
  api.py             # endpoints и request/response models
  storage.py         # SQLite queries и migrations
  apns.py            # JWT, payload и HTTP transport
  settings.py        # environment configuration
  logging_config.py  # formatters и redaction
```

Правила:

- Сначала characterization tests, затем перенос кода.
- Один модуль за PR.
- Сохранять endpoint paths и JSON schema.
- Убрать module-level mutable configuration, чтобы тесты не зависели от `monkeypatch` глобальных переменных.
- APNs HTTP client и clock передавать как зависимости для deterministic tests.
- Не добавлять ORM: для текущего объёма это необязательная сложность.

## Этап 6. Release preflight и тестовые релизы — P1

Добавить единую локальную команду, например `scripts/preflight.sh`, которая:

1. Проверяет чистоту рабочего дерева или явно сообщает об изменениях.
2. Запускает Ruff и pytest.
3. Собирает Python package.
4. Проверяет установку CLI из wheel.
5. Запускает iOS build/tests, если доступен Xcode.
6. Показывает версию и список коммитов после предыдущего тега.
7. Не выполняет upload/deploy автоматически.

Для тестового релиза:

- version/build number изменяются отдельно и прозрачно;
- release notes генерируются, но проверяются человеком;
- production endpoint и production upload требуют явного выбора;
- после отправки сохраняется краткий отчёт: commit SHA, версия, каналы доставки и результат.

## Этап 7. Документация и runbooks — P1

Обновить или создать:

- `README.md`: актуальные install/run/test команды;
- troubleshooting для backend и LaunchAgent;
- runbook восстановления после недоступности VPS;
- runbook APNs 400/403/410;
- инструкция ротации TAX API key и APNs key;
- backup/restore SQLite с проверкой восстановления;
- release checklist со ссылкой на отдельный iOS plan.

Документы не должны содержать настоящие credentials, Team ID, device tokens или пользовательские данные.

## Рекомендуемый порядок работ

### Неделя/итерация 1

1. Python CI и packaging smoke-test.
2. Repository/secret checks.
3. CLI unit-тесты.

### Итерация 2

1. Структурированные безопасные логи.
2. APNs/backend error tests.
3. Устранение dependency warning.

### Итерация 3

1. Release preflight.
2. Runbooks и backup/restore drill.
3. Небольшой поэтапный backend refactor.

## Итоговые критерии готовности

- Каждый PR автоматически проверяется CI.
- Wheel устанавливается и CLI запускается в чистом окружении.
- Логи позволяют найти путь задачи по task ID и не содержат секретов.
- Есть одна preflight-команда перед тестовой сборкой/релизом.
- Документированы статусы, восстановление, backup и ротация ключей.
