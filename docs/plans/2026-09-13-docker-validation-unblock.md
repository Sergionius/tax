<!-- ralphex-base: 0a8a6c42c5baf761b8cf532b21da2c3b5446863b -->

# Устранение локальной Docker-блокировки Task 3

## Goal

Сделать Task 3 плана подготовки TAX выполнимым на Mac без Docker, сохранив проверку контейнерной установки в GitHub Actions.

## Context

- Tasks 1–2 основного плана выполнены; Task 3 не начат.
- Локально отсутствуют Docker CLI, Compose и контейнерный runtime.
- Основной план требует сборку образа и проверку imports без разграничения локальной и CI-валидации.
- `.github/workflows/python.yml` использует GitHub-hosted `ubuntu-latest`, но контейнерного job пока нет.
- Systemd остаётся основным deployment-вариантом; поддержка Docker Compose сохраняется.

## Scope

- Уточнение Task 3 и Validation основного плана.
- Добавление контейнерной CI-проверки в состав Task 3.
- Явное разделение локального результата и подтверждения контейнерной совместимости.

## Out of Scope

- Установка Docker или VM на Mac.
- Реализация deployment-изменений в рамках этого корректирующего плана.
- Deployment, запуск production services, публикация или изменение Git-истории.
- Изменение завершённых Tasks 1–2 и функционального scope Tasks 4–8.

## Implementation Steps

### Task 1: Разделить локальную и контейнерную валидацию основного плана

**Files:**
- Modify: `docs/plans/2026-09-13-public-distribution-preparation.md`

- [x] В Task 3 добавить `.github/workflows/python.yml` в список изменяемых файлов.
- [x] Заменить обязательную локальную Docker-проверку требованием добавить отдельный `container` job на GitHub-hosted `ubuntu-latest`.
- [x] Зафиксировать шаги job: проверить Docker/Compose availability, выполнить Compose configuration validation с synthetic environment, собрать backend image и запустить в нём `python -c 'import main, relay, storage, apns'`.
- [x] Для import smoke использовать `--network none`, без host mounts, реальных credentials и запуска backend service.
- [x] Synthetic Compose environment создавать во временном каталоге; явно передавать его через `--env-file`, не читать owner `.env`.
- [x] Дополнить workflow path filters путями `deploy.sh`, `reinstall-backend.sh`, `Caddyfile`, `deploy.env.example`, `scripts/deploy-backend.sh`, `scripts/deploy-config.sh`; сохранить существующие server/tests/lock triggers.
- [x] Не устанавливать Docker на Mac и не добавлять сторонние Actions для контейнерной проверки.
- [x] Определить обязательную локальную валидацию Task 3: shell syntax, Ruff, Pytest с synthetic deployment fixtures, standalone backend imports в существующем Python-окружении и `git diff --check`.
- [x] Уточнить, что локальные imports и проверки шаблонов не заменяют Compose validation или выполнение собранного образа.
- [x] Разрешить локальное завершение Task 3 после реализации CI job и успешных применимых локальных проверок. Отсутствие Docker само по себе не является причиной `TASK_FAILED`.
- [x] Требовать явно записывать контейнерную проверку как «не выполнена локально; результат CI не подтверждён», пока нет успешного job.
- [x] В Validation и Acceptance Criteria сохранить обязательность успешного контейнерного CI для подтверждения итоговой готовности проекта.
- [x] Сохранить выполненные checkboxes и execution notes Tasks 1–2; не отмечать Task 3 выполненным этим изменением.

## Validation

Для изменения Markdown:

```bash
git diff --check
```

Проверить согласованность Task 3, Validation и Acceptance Criteria: нигде не должно оставаться требования установить локальный runtime или считать отсутствие Docker успешной контейнерной проверкой.

Команды Pytest, Docker и Xcode при выполнении этого корректирующего плана не требуются: меняется только документ.

## Acceptance Criteria

- Основной план позволяет выполнять Task 3 без Docker на Mac.
- Настоящая Compose/build/import проверка закреплена за CI.
- Непроведённая контейнерная проверка не объявляется успешной.
- Завершённые задачи и остальной scope основного плана сохранены.
