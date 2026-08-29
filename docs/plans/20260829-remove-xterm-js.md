<!-- ralphex-base: c28e6f04251e171f4425cb6fd329079e9c2ff3e3 -->

# Удаление xterm.js из iOS-приложения

## Goal

Удалить реализацию xterm.js, её WebKit-адаптер и vendored-ресурсы из iOS-приложения. SwiftTerm станет единственным доступным renderer’ом, а существующая архитектурная граница `TerminalRendererHost` и общий terminal renderer contract останутся для возможных будущих адаптеров.

## Context

Сейчас SwiftTerm используется по умолчанию, а xterm.js доступен как переключаемый fallback:

- `TerminalRendererHost` выбирает между `SwiftTermTerminalView` и `TerminalWebView`.
- `TerminalRendererKind` содержит варианты `swiftterm` и `xterm`.
- `SettingsStore` сохраняет выбор в `UserDefaults` под ключом `tax.terminalRenderer`.
- `SettingsView` показывает Picker renderer’а.
- `TerminalView` пересоздаёт renderer при переключении и показывает отдельную панель клавиш для xterm.js.
- `TerminalWebView` загружает `xterm.js` и `xterm.css` из bundle.
- Лицензия xterm.js хранится в `Resources/Terminal/XTERM-LICENSE`.
- Unit- и UI-тесты проверяют выбор и сохранение renderer’а.
- `README.md` и `ios/README-REMOTE.md` описывают xterm.js и сценарий сравнения renderer’ов.

Каталог приложения подключён к Xcode через `PBXFileSystemSynchronizedRootGroup`, поэтому удаление исходников и ресурсов не требует ручного изменения `ios/tax/tax.xcodeproj/project.pbxproj`.

Сохранённое ранее значение `tax.terminalRenderer = xterm` перестанет читаться и не повлияет на запуск: приложение всегда будет использовать SwiftTerm. Удалять устаревший ключ из `UserDefaults` специально не требуется.

## Scope

- Удаление `TerminalWebView` и всех vendored-файлов xterm.js.
- Удаление модели и сохранения пользовательского выбора renderer’а.
- Удаление Picker из Settings и xterm-специфичного UI терминала.
- Перевод `TerminalRendererHost` на единственную реализацию SwiftTerm.
- Сохранение `TerminalRendererHost`, `TerminalRenderPipeline` и renderer contract.
- Актуализация существующих unit/UI-тестов и документации.

## Out of Scope

- Изменение SwiftTerm, terminal protocol, `RemoteWorkspaceStore` или Mac host.
- Замена xterm.js другим renderer’ом.
- Удаление общего renderer contract.
- Изменение исторических документов в `docs/plans/`, описывающих ранее реализованный PoC.
- Явная миграция или очистка старого ключа `tax.terminalRenderer` из `UserDefaults`.

## Implementation Steps

### Task 1: Перевести приложение на единственный SwiftTerm renderer

**Files:**
- Modify: `ios/tax/tax/App/AppEnvironment.swift`
- Modify: `ios/tax/tax/Stores/SettingsStore.swift`
- Modify: `ios/tax/tax/Views/SettingsView.swift`
- Modify: `ios/tax/tax/Views/TerminalRendererHost.swift`
- Modify: `ios/tax/tax/Views/TerminalView.swift`
- Modify: `ios/tax/taxTests/SettingsStoreTests.swift`
- Modify: `ios/tax/taxUITests/TaxUITests.swift`
- Delete: `ios/tax/tax/Models/TerminalRendererKind.swift`
- Delete: `ios/tax/tax/Views/TerminalWebView.swift`
- Delete: `ios/tax/tax/Resources/Terminal/xterm.js`
- Delete: `ios/tax/tax/Resources/Terminal/xterm.css`
- Delete: `ios/tax/tax/Resources/Terminal/XTERM-LICENSE`

- [x] Удалить `TerminalRendererKind`, свойство `SettingsStore.terminalRenderer`, ключ `tax.terminalRenderer`, загрузку сохранённого значения и немедленное сохранение выбора.
- [x] Удалить mock-настройку `tax.terminalRenderer` из UI-test environment.
- [x] Удалить секцию выбора renderer’а из `SettingsView`.
- [x] Сохранить `TerminalRendererHost` как архитектурную границу, но сделать его единственной оболочкой над `SwiftTermTerminalView`.
- [x] Удалить из `TerminalView` зависимость от `SettingsStore`, смену identity renderer’а, обработку переключения renderer’а и xterm-специфичную панель клавиш вместе с более неиспользуемым состоянием и вспомогательной логикой.
- [x] Удалить WebKit-адаптер xterm.js, JavaScript/CSS-файлы и vendored-лицензию из синхронизированного Xcode-каталога.
- [x] Удалить unit-тесты загрузки, нормализации и сохранения выбора renderer’а, не затрагивая остальные тесты `SettingsStore`.
- [x] Обновить UI-тест Settings так, чтобы он проверял отсутствие Picker renderer’а и продолжал проверять остальные настройки.
- [x] Убедиться, что ранее сохранённое значение `xterm` больше нигде не читается, а терминал всегда создаётся через SwiftTerm.

### Task 2: Актуализировать документацию terminal renderer’а

**Files:**
- Modify: `README.md`
- Modify: `ios/README-REMOTE.md`

- [x] Описать SwiftTerm как единственный bundled terminal renderer, сохранив пояснение о независимом tax-owned renderer contract.
- [x] Удалить описание локального выбора renderer’а, xterm.js fallback, WebKit и vendored-лицензии.
- [x] Заменить сценарии сравнения SwiftTerm и xterm.js на актуальную проверку работы единственного SwiftTerm renderer’а: snapshot, scrollback, быстрый input, клавиатура, alternate screen и reconnect.
- [x] Проверить, что активная документация больше не предлагает переключение на xterm.js, не изменяя исторические планы.

## Validation

Из корня репозитория:

```bash
xcodebuild build \
  -project ios/tax/tax.xcodeproj \
  -scheme tax \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

```bash
xcodebuild test \
  -project ios/tax/tax.xcodeproj \
  -scheme tax \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:taxTests
```

```bash
xcodebuild test \
  -project ios/tax/tax.xcodeproj \
  -scheme tax \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:taxUITests
```

Проверка отсутствия активных ссылок вне исторических планов:

```bash
rg -n -i 'xterm(\.js)?|XTERM-LICENSE|TerminalWebView|tax\.terminalRenderer' \
  README.md ios/README-REMOTE.md ios/tax/tax ios/tax/taxTests ios/tax/taxUITests
```

Команда должна завершиться без совпадений.

## Acceptance Criteria

- В bundle приложения отсутствуют JavaScript, CSS и лицензия xterm.js.
- `TerminalWebView` и пользовательский выбор renderer’а удалены.
- Settings не показывает Picker renderer’а.
- Старое сохранённое значение `xterm` не влияет на приложение.
- Все терминалы отображаются через SwiftTerm.
- `TerminalRendererHost`, pipeline и общий renderer contract сохранены.
- Активная документация описывает только SwiftTerm.
- iOS-приложение собирается, unit- и UI-тесты проходят.

## Execution Notes

- Build, unit tests, and UI tests passed for Task 1.
- Task 2 documentation validation passed: the active-reference `rg` command found no matches in `README.md`, `ios/README-REMOTE.md`, `ios/tax/tax`, `ios/tax/taxTests`, or `ios/tax/taxUITests`.
