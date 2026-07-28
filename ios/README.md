# tax iOS

SwiftUI-клиент для просмотра задач `tax`, навигации из APNs и отправки reply.

- iOS 17+
- Swift 6, strict concurrency
- SwiftUI Observation (`@Observable`)
- API key в Keychain; URL и push preferences в UserDefaults
- Bundle ID: `ru.madmaximuus.yandexmapstestapp.YandexMapsTestApp`

## Запуск

1. Открыть `tax/tax.xcodeproj`.
2. Выбрать signing team и физический iPhone для проверки APNs.
3. Убедиться, что включена capability **Push Notifications**.
4. В приложении открыть Settings, указать `https://tax.138-249-127-23.nip.io` и API key.
5. Нажать **Save Settings**, затем **Request Push Registration**.

Симулятор подходит для build, unit- и mock UI-тестов, но не для реального APNs.

## Автоматические проверки

```bash
xcodebuild build \
  -project tax/tax.xcodeproj \
  -scheme tax \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO

xcodebuild test \
  -project tax/tax.xcodeproj \
  -scheme tax \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:taxTests

xcodebuild test \
  -project tax/tax.xcodeproj \
  -scheme tax \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:taxUITests
```

UI tests запускают приложение с mock backend через launch arguments и не используют сеть, Keychain пользователя или секреты.

Из корня репозитория:

```bash
./scripts/preflight.sh                 # build + unit tests
IOS_UI_TESTS=1 ./scripts/preflight.sh  # также UI smoke tests
```

Preflight ничего не загружает в TestFlight/App Store.

## Версии и сборки

- `MARKETING_VERSION` (`CFBundleShortVersionString`) меняется для пользовательского релиза: `major.minor.patch`.
- `CURRENT_PROJECT_VERSION` (`CFBundleVersion`) увеличивается для каждой загружаемой сборки и не переиспользуется.
- Изменения выполняются одновременно для Debug и Release configurations.
- Upload — отдельная явная команда с подтверждением; signing credentials и APNs `.p8` не хранятся в Git.
- Черновик release notes: `./scripts/release-notes.sh [previous-tag]`.

## Проверка APNs

Следовать [`APNS_SMOKE_CHECKLIST.md`](APNS_SMOKE_CHECKLIST.md). Для Debug используется APNs sandbox, для TestFlight/App Store — production.

## Структура

- `tax/tax/` — приложение, stores, services и push routing.
- `tax/taxTests/` — unit-тесты и JSON fixtures из текущего backend schema.
- `tax/taxUITests/` — mock UI smoke-тесты.
- `.github/workflows/ios.yml` — simulator build, unit и UI jobs.
