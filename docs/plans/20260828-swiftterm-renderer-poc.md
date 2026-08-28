<!-- ralphex-base: a6dc83597efdf965467a932b8276ee44c2f3df50 -->

# PoC нативного терминала SwiftTerm с заменяемым renderer-слоем

## Goal

Добавить SwiftTerm как основной terminal renderer на iOS, сохранив xterm.js как переключаемый fallback. Обобщить границу renderer’а так, чтобы сетевой слой, terminal lifecycle и SwiftUI-экран не зависели от SwiftTerm, WebKit или будущего libghostty.

Исправить общий порядок открытия терминала: сначала создать и измерить renderer, затем подписаться на Orca с корректным mobile viewport, атомарно применить snapshot и только после этого показывать incremental output.

## Context

Сейчас `ios/tax/tax/Views/TerminalView.swift` напрямую создаёт `TerminalWebView`. Реализация в `TerminalWebView.swift` использует xterm.js 5.5 внутри `WKWebView`, собственную очередь JavaScript-рендеринга и ручную обработку touch-scroll.

`RemoteWorkspaceStore` публикует `TerminalRenderUpdate`: snapshot сбрасывает terminal state, incremental output объединяется с интервалом 16 мс. Подписка вызывается из `.task` до получения реального размера renderer’а. Resize отправляется только после создания stream, поэтому первоначальный snapshot может соответствовать неверному viewport.

Mac-сторона создаёт Orca subscription через:

- `src/tax/remote_host.py`;
- `src/tax/orca_runtime.py`;
- `src/tax/resources/orca-runtime-terminal-bridge.cjs`.

Bridge сейчас объявляет tax-agent как desktop-клиент, подписывается без initial viewport и после подписки использует `ClaimViewport` вместе с `Resize`.

Проект использует SwiftUI, UIKit wrappers, Swift 6 strict concurrency, iOS 17+, Observation, Python tests, Swift Testing/XCTest и UI tests. В Xcode-проекте пока нет Swift Package dependencies.

SwiftTerm предоставляет UIKit `TerminalView`, методы `feed(byteArray:)`, `getTerminal().resetToInitialState()`, scrollback и `TerminalViewDelegate` для input и viewport changes. Для PoC должна быть закреплена версия `1.20.0`.

## Scope

- Подключение SwiftTerm 1.20.0 через Swift Package Manager.
- Общий tax-owned renderer contract без типов SwiftTerm и WebKit.
- SwiftTerm и xterm.js как взаимозаменяемые реализации.
- Сохраняемый выбор renderer’а в Settings.
- SwiftTerm как renderer по умолчанию.
- Переключение renderer’а без переустановки приложения.
- Бинарный input, viewport readiness, snapshot completion и focus через общий интерфейс.
- Initial mobile viewport до получения snapshot.
- Атомарное применение snapshot и упорядочивание последующего output.
- Keyboard-aware resize и сохранение видимости активного prompt.
- Reconnect и смена renderer’а через новую подписку и новый snapshot.
- Unit/UI regression coverage и проверка на физическом iPhone.

## Out of Scope

- Удаление xterm.js и его ресурсов.
- Полная миграция на SwiftTerm без fallback.
- Интеграция libghostty в рамках этого PoC.
- Изменения backend relay или E2EE framing.
- Синхронизация выбора renderer’а между устройствами.
- Реализация новых terminal features: tabs, split panes, mouse reporting или clipboard synchronization.
- Переработка connection badge и остальных экранов приложения.

## Implementation Steps

### Task 1: Добавить сохраняемый выбор terminal renderer

**Files:**
- Create: `ios/tax/tax/Models/TerminalRendererKind.swift`
- Modify: `ios/tax/tax/Stores/SettingsStore.swift`
- Modify: `ios/tax/tax/Views/SettingsView.swift`
- Modify: `ios/tax/tax/App/AppEnvironment.swift`
- Modify: `ios/tax/taxTests/SettingsStoreTests.swift`
- Modify: `ios/tax/taxUITests/TaxUITests.swift`

- [x] Добавить `TerminalRendererKind` со стабильными raw values `swiftterm` и `xterm`, пользовательскими названиями и соответствием `Codable`, `CaseIterable`, `Identifiable` и `Sendable`.
- [x] Добавить в `SettingsStore` observable-свойство выбранного renderer’а и отдельный non-secret UserDefaults key.
- [x] При отсутствии сохранённого значения выбирать SwiftTerm; неизвестное сохранённое значение также безопасно нормализовать в SwiftTerm.
- [x] Сохранять renderer сразу после изменения Picker, не затрагивая Keychain и remote configuration.
- [x] Добавить в `SettingsView` секцию `Terminal` с Picker для SwiftTerm и xterm.js.
- [x] Обеспечить детерминированное значение renderer’а в UI-test environment.
- [x] Добавить unit tests для значения по умолчанию, загрузки xterm.js и сохранения выбора.
- [x] Расширить UI smoke test проверкой существования Picker и обоих вариантов renderer’а.

### Task 2: Ввести независимый renderer contract и подключить SwiftTerm

**Files:**
- Create: `ios/tax/tax/Views/TerminalRendererHost.swift`
- Create: `ios/tax/tax/Views/SwiftTermTerminalView.swift`
- Create: `ios/tax/tax/Views/TerminalRenderPipeline.swift`
- Modify: `ios/tax/tax/Views/TerminalWebView.swift`
- Modify: `ios/tax/tax/Views/TerminalView.swift`
- Modify: `ios/tax/tax/Models/RemoteModels.swift`
- Modify: `ios/tax/tax/Stores/RemoteWorkspaceStore.swift`
- Modify: `ios/tax/tax.xcodeproj/project.pbxproj`
- Modify: `ios/tax/taxTests/RemoteProtocolTests.swift`

- [ ] Добавить Swift Package `https://github.com/migueldeicaza/SwiftTerm` с закреплённой версией `1.20.0` и подключить product `SwiftTerm` только к app target.
- [ ] Определить tax-owned события renderer’а: готовность с viewport, изменение viewport, binary input и завершение применения snapshot.
- [ ] Определить общий renderer contract для reset snapshot, incremental bytes и focus без упоминания `WKWebView`, JavaScript, `SwiftTerm.TerminalView` или будущего libghostty.
- [ ] Реализовать `TerminalRendererHost`, который выбирает SwiftTerm или xterm.js по `SettingsStore.terminalRenderer` и предоставляет `TerminalView` одинаковые callbacks.
- [ ] Вынести sequence filtering, ожидание readiness, snapshot reset и очередь incremental output в общий `TerminalRenderPipeline`, чтобы реализации renderer’ов не дублировали lifecycle state machine.
- [ ] Реализовать `SwiftTermTerminalView` как `UIViewRepresentable` над `SwiftTerm.TerminalView`.
- [ ] Настроить в SwiftTerm моноширинный шрифт, существующую тёмную палитру, cursor, scrollback и keyboard dismissal, не добавляя renderer-specific настройки в `TerminalView`.
- [ ] Передавать snapshot в SwiftTerm через reset initial state, очистку старого scrollback и единый `feed(byteArray:)`; incremental output передавать без преобразования через `String`.
- [ ] Реализовать `TerminalViewDelegate.send` как binary callback и `sizeChanged` как viewport callback на `MainActor`.
- [ ] Адаптировать xterm.js implementation к тому же renderer contract, сохранив byte-oriented input и используя completion `terminal.write` для подтверждения применения snapshot.
- [ ] Изменить `RemoteWorkspaceStore.sendInput` на приём `Data`, сохранив удобный text helper только для accessory buttons.
- [ ] Перевести Escape, Tab, Ctrl, Ctrl-C, стрелки и Enter на общий binary input path.
- [ ] При изменении настройки пересоздавать только renderer host, не пересоздавая navigation stack или remote client.
- [ ] Добавить unit tests для отбрасывания повторного sequence, замены ожидающего snapshot новым snapshot и сохранения порядка output, пришедшего во время применения snapshot.

### Task 3: Передавать initial mobile viewport через весь terminal subscription flow

**Files:**
- Modify: `ios/tax/tax/Stores/RemoteWorkspaceStore.swift`
- Modify: `ios/tax/tax/Views/TerminalView.swift`
- Modify: `src/tax/remote_host.py`
- Modify: `src/tax/orca_runtime.py`
- Modify: `src/tax/resources/orca-runtime-terminal-bridge.cjs`
- Modify: `tests/test_remote_host.py`
- Modify: `tests/test_orca_runtime.py`
- Modify: `docs/remote-protocol-v1.md`

- [ ] Заменить немедленную подписку из `.task` на активацию терминала после первого renderer readiness event с валидными columns и rows.
- [ ] Хранить последний валидный viewport активного terminal в `RemoteWorkspaceStore`.
- [ ] Добавлять `columns` и `rows` в payload `terminal.subscribe`; ограничивать их теми же допустимыми пределами, что и последующий resize.
- [ ] При изменении viewport до получения stream обновлять pending viewport без отправки resize; после получения stream отправлять только последнее отличающееся значение.
- [ ] При reconnect использовать последний viewport в новой подписке и не считать старые stream ID/generation пригодными для input или resize.
- [ ] При смене renderer принудительно завершать логическую старую подписку и запрашивать новый snapshot после измерения нового renderer’а.
- [ ] Расширить `WorkspaceRuntime.subscribe_terminal` и `OrcaRuntimeAdapter.subscribe_terminal` обязательными initial columns/rows.
- [ ] Передавать initial viewport bridge-процессу через отдельные числовые CLI arguments без помещения пользовательских данных или credentials в командную строку.
- [ ] На Mac host валидировать viewport до создания subscription и возвращать protocol error для отсутствующих или недопустимых размеров.
- [ ] В Orca bridge подписываться как `client.type = mobile`, передавать `viewport: { cols, rows }` в Orca `Subscribe` frame и убрать desktop-only `desktopViewportClaims`.
- [ ] Для последующего mobile resize отправлять Orca `Resize` без desktop-only `ClaimViewport`.
- [ ] Не менять private Orca framing за пределами bridge и `orca_runtime.py`.
- [ ] Расширить Python tests проверкой передачи initial viewport от tax control message до fake runtime/bridge arguments, валидации размеров и последующего resize активной generation.
- [ ] Документировать initial viewport и mobile subscription semantics в tax remote protocol без раскрытия Orca-private wire details.

### Task 4: Сделать snapshot, reconnect и keyboard lifecycle общими для обоих renderer’ов

**Files:**
- Modify: `ios/tax/tax/Views/TerminalRendererHost.swift`
- Modify: `ios/tax/tax/Views/TerminalRenderPipeline.swift`
- Modify: `ios/tax/tax/Views/SwiftTermTerminalView.swift`
- Modify: `ios/tax/tax/Views/TerminalWebView.swift`
- Modify: `ios/tax/tax/Views/TerminalView.swift`
- Modify: `ios/tax/tax/Stores/RemoteWorkspaceStore.swift`
- Modify: `ios/tax/taxTests/RemoteProtocolTests.swift`

- [ ] Разделить состояния `renderer ready`, `snapshot received` и `snapshot applied`; не считать terminal визуально готовым сразу после получения сетевого frame.
- [ ] Не очищать текущий экран пустым update при subscribe или reconnect.
- [ ] При новом snapshot сбрасывать terminal state один раз, применять полный payload и только после renderer completion публиковать ожидающий incremental output.
- [ ] Если до завершения snapshot приходит новый snapshot или generation, отбросить старый snapshot и относящийся к нему queued output.
- [ ] До первого успешно применённого snapshot показывать нейтральный loading overlay; при reconnect оставлять последний успешно применённый экран видимым с компактным non-blocking reconnect overlay.
- [ ] Не позволять loading/reconnect overlay перехватывать touch, scroll или keyboard focus после появления terminal content.
- [ ] Debounce viewport changes на общем уровне и не отправлять повторный resize для неизменившихся columns/rows.
- [ ] При появлении и скрытии клавиатуры дождаться стабилизации geometry, затем вычислить и отправить один актуальный viewport.
- [ ] Если пользователь находился у нижней границы scrollback, после keyboard resize сохранить активный prompt над клавиатурой; если пользователь просматривал историю, не принудительно возвращать его вниз.
- [ ] Сохранить нативную инерцию и scroll position SwiftTerm при incremental output; убрать из общего слоя любые предположения о JavaScript touch events.
- [ ] Добавить pipeline tests для snapshot-before-readiness, output-during-snapshot, generation replacement, duplicate resize suppression и reconnect с сохранённым экраном.

### Task 5: Зафиксировать границы PoC и сценарий сравнения renderer’ов

**Files:**
- Modify: `ios/README-REMOTE.md`
- Modify: `README.md`

- [ ] Описать SwiftTerm как renderer по умолчанию и xterm.js как доступный fallback.
- [ ] Описать общий renderer contract и правило, что будущий libghostty adapter реализует только этот контракт и не изменяет store, remote protocol или Mac host.
- [ ] Зафиксировать, что выбор renderer’а локален для устройства и сохраняется в UserDefaults.
- [ ] Добавить короткий физический acceptance сценарий для одинакового terminal session: initial snapshot, большой scrollback, быстрый input, keyboard visibility, Pi alternate screen, renderer switch и reconnect.
- [ ] Указать известную границу PoC: xterm.js остаётся в bundle до принятия отдельного решения о полной миграции.

## Validation

```bash
.venv/bin/ruff check server src tests
.venv/bin/pytest -q
```

```bash
xcodebuild build-for-testing \
  -project ios/tax/tax.xcodeproj \
  -scheme tax \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
```

```bash
DEVICE_ID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
ids = [
    device["udid"]
    for devices in data["devices"].values()
    for device in devices
    if device["name"].startswith("iPhone")
]
if not ids:
    raise SystemExit("No available iPhone simulator")
print(ids[0])
')

xcodebuild test \
  -project ios/tax/tax.xcodeproj \
  -scheme tax \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -only-testing:taxTests \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
```

```bash
xcodebuild test \
  -project ios/tax/tax.xcodeproj \
  -scheme tax \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -only-testing:taxUITests \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
```

На физическом iPhone проверить оба renderer’а на одном живом Orca terminal:

1. SwiftTerm выбран по умолчанию после чистой установки.
2. Initial snapshot появляется целиком, без промежуточных блоков.
3. Большой scrollback прокручивается с инерцией и не прыгает при новом output.
4. При открытии клавиатуры активный prompt остаётся видимым.
5. Быстрый ввод не запаздывает и не дублируется.
6. Pi/TUI корректно работает в alternate screen.
7. После reconnect экран восстанавливается из нового snapshot без смешивания generations.
8. Переключение на xterm.js создаёт новый viewport/subscription и сохраняет работоспособность fallback.

## Acceptance Criteria

SwiftTerm 1.20.0 подключён как основной renderer, а xterm.js доступен из сохраняемой настройки.

`TerminalView`, `RemoteWorkspaceStore` и remote protocol используют только tax-owned renderer events и binary data, не завися от API SwiftTerm, WebKit или libghostty.

Terminal subscription начинается только после получения валидного initial viewport и передаёт его Orca как mobile viewport до создания snapshot.

Snapshot применяется целиком до incremental output; reconnect и смена renderer’а не смешивают старые stream generations с новым экраном.

SwiftTerm обеспечивает нативный scrollback, сохраняет позицию при incoming output и оставляет активный prompt видимым при открытой клавиатуре.

Оба renderer’а проходят существующие Python, iOS unit и UI проверки, а SwiftTerm проходит физический сценарий с Pi/TUI.
