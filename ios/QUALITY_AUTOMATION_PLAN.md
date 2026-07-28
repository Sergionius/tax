# План улучшения качества и автоматизации iOS

Дата: 2026-07-28

## Контекст

Приложение `tax` написано на SwiftUI и Swift 6, минимальная версия — iOS 17. Основной target собирается для симулятора без ошибок, но в Xcode-проекте пока нет test target и автоматических iOS-проверок. APNs нельзя полноценно проверить на симуляторе, поэтому проверки нужно разделить на автоматические тесты логики и короткий ручной smoke-тест на реальном устройстве.

## Цели

1. Находить ошибки до передачи сборки тестировщику.
2. Автоматически проверять сеть, модели, настройки, навигацию из push и отправку reply.
3. Сделать выпуск TestFlight-сборки воспроизводимым.
4. Не менять пользовательское поведение без отдельного согласования и тестирования.

## Не входит в этот план

- Новый дизайн и крупные пользовательские функции.
- Изменение backend API.
- Автоматическая отправка production-релиза.
- Полная автоматизация реального APNs end-to-end: она требует физического устройства и Apple credentials.

## Этап 1. Основа для тестирования — P0

### 1.1. Добавить test target

- Добавить в `ios/tax/tax.xcodeproj` unit-test target `taxTests`.
- Создать каталог `ios/tax/taxTests`.
- Использовать XCTest либо Swift Testing, поддерживаемый текущей версией Xcode; не смешивать два подхода без необходимости.
- Убедиться, что тесты запускаются командой:

```bash
xcodebuild test \
  -project ios/tax/tax.xcodeproj \
  -scheme tax \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

### 1.2. Сделать зависимости заменяемыми в тестах

- Разрешить передавать `URLSession` или сетевой transport в `TaskService`, сохранив production default.
- Не выполнять реальные HTTP-запросы в unit-тестах.
- Для `SettingsStore` отделить доступ к Keychain и UserDefaults небольшими протоколами или адаптерами.
- Вынести разбор `task_id` и выбор маршрута из `AppDelegate` в независимо тестируемый компонент.
- Не добавлять глобальные mutable singleton-объекты.

### 1.3. Добавить модельные тесты

Проверить:

- декодирование полного ответа backend;
- декодирование nullable-полей `deviceToken`, `context`, `logs`, `reply`;
- декодирование всех значений `PushMode`;
- обработку неизвестного значения статуса без падения UI;
- форматирование даты и отображаемых статусов;
- кодирование `ReplyPayload` и `DeviceTokenPayload`.

**Критерий готовности:** тесты используют JSON fixtures, соответствующие текущим ответам `server/main.py`.

## Этап 2. Сеть и настройки — P0

### 2.1. Тесты `TaskService`

Для каждого endpoint проверить method, URL, заголовки и тело запроса:

- `GET /tasks`;
- `GET /task/{id}`;
- `POST /task/{id}/reply`;
- `POST /register-device`;
- `GET /health`.

Отдельно покрыть:

- `Authorization: Bearer <key>`;
- безопасное построение URL и task ID;
- ответы 401, 404, 422 и 500;
- невалидный JSON;
- timeout и отсутствие сети;
- пустое тело ответа;
- корректный пользовательский текст ошибки без вывода API key.

### 2.2. Тесты `SettingsStore` и Keychain

Проверить:

- загрузку ранее сохранённых настроек;
- сохранение API key только через Keychain;
- сохранение URL и push preferences;
- инвалидацию cached `TaskService` после изменения настроек;
- обработку ошибки Keychain;
- отсутствие API key в логах и описаниях ошибок;
- повторную регистрацию сохранённого device token после изменения настроек.

**Критерий готовности:** тесты не читают и не изменяют настоящий Keychain пользователя.

## Этап 3. Push-навигация и reply flow — P0

### 3.1. Тесты маршрутизации push

Проверить:

- payload с корректным `task_id` открывает нужную задачу;
- payload без `task_id` не ломает навигацию;
- push, полученный до создания UI, сохраняется в `PendingTaskStore`;
- повторный одинаковый push не создаёт дублирующий маршрут;
- foreground push инициирует обновление списка;
- notification action `REPLY` передаёт ответ в правильную задачу.

### 3.2. Тесты состояния экранов

Покрыть логику, не зависящую от snapshot-тестов:

- loading, empty, content и error states списка;
- повторная загрузка после сетевой ошибки;
- запрет отправки пустого reply;
- блокировка повторного нажатия Send во время запроса;
- сохранение введённого текста при временной ошибке;
- обновление detail после успешной отправки.

Если текущие View содержат слишком много логики, вынести только состояние и операции в `@MainActor @Observable` store. Не вводить отдельный архитектурный слой для экранов, где это не даёт тестируемости.

## Этап 4. UI smoke-тесты — P1

Добавить UI-test target только после стабильных unit-тестов. Использовать launch arguments для mock-режима без настоящего backend.

Минимальные сценарии:

1. Первый запуск без настроек показывает понятный empty/configuration state.
2. Сохранение server URL и API key открывает список mock-задач.
3. Открытие задачи, ввод и отправка reply.
4. Ошибка сети показывает Retry и не удаляет введённый reply.
5. Deep link/mock push открывает нужную задачу.

Не использовать UI-тесты для проверки каждой детали layout — это сделает suite медленным и нестабильным.

## Этап 5. CI для iOS — P0

Добавить macOS job в `.github/workflows/ios.yml`:

1. Checkout.
2. Выбор зафиксированной доступной версии Xcode.
3. Сборка Debug для симулятора без signing.
4. Запуск unit-тестов.
5. После появления UI tests — отдельный job или отдельный шаг с timeout.
6. Сохранение `.xcresult` при падении.

CI не должен требовать APNs key, provisioning profile или реальный API key.

Проверки, обязательные для merge:

- simulator build;
- unit tests;
- отсутствие Swift compiler errors и новых concurrency warnings.

## Этап 6. Ручной smoke-тест APNs — P0

Создать короткий checklist `ios/APNS_SMOKE_CHECKLIST.md`:

1. Установить Debug/TestFlight-сборку на реальный iPhone.
2. Проверить разрешение уведомлений и регистрацию device token.
3. Проверить режимы push: `all`, `tax`, `off`.
4. Создать задачу с Mac.
5. Получить push в background и foreground.
6. Открыть задачу нажатием на push.
7. Ответить из приложения и notification action.
8. Убедиться, что Mac получил ответ и backend пометил его `delivered`.
9. Повторить один сценарий после отключения и восстановления сети.

Результат фиксировать: версия, build number, устройство, версия iOS, sandbox/production APNs, итог и ссылка на найденные дефекты.

## Этап 7. Подготовка сборок — P1

- Зафиксировать правила изменения `MARKETING_VERSION` и `CURRENT_PROJECT_VERSION`.
- Добавить скрипт preflight, который выполняет build и tests до архивации.
- Сформировать release notes из изменений после предыдущего тега.
- Проверять наличие App Icon, bundle ID, entitlements и privacy metadata.
- Production/TestFlight upload оставлять явной отдельной командой с подтверждением.
- Не хранить signing credentials и APNs keys в репозитории.

## Этап 8. Репозиторная гигиена и документация — P1

- Удалить из Git уже отслеживаемый `ios/tax/tax.xcodeproj/xcuserdata/.../xcschememanagement.plist`; правило игнорирования оставить в `.gitignore`.
- Сверить `ios/README.md`, `ios/PLAN.md`, `ios/REVIEW.md` с фактическим кодом.
- Устранить расхождение имени entry point (`taxApp`/`TaxApp`) отдельным безопасным рефакторингом.
- Не удалять старые документы, пока полезные инструкции не перенесены в актуальный README.

## Порядок выполнения

1. Test target и dependency injection.
2. Models + `TaskService` tests.
3. Settings + push-routing tests.
4. iOS CI.
5. Ручной APNs checklist.
6. UI smoke tests.
7. Release preflight и документация.

## Итоговые критерии готовности

- `xcodebuild build` и `xcodebuild test` проходят локально и в CI.
- Основные endpoint и error paths покрыты unit-тестами.
- Навигация из push и pending push проверяются автоматически.
- APNs flow имеет воспроизводимый ручной checklist.
- Для TestFlight есть одна preflight-команда.
- В Git нет пользовательских Xcode-файлов и секретов.
