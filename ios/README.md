# TaxApp

iOS-приложение на SwiftUI для получения push-уведомлений и remote reply.

## Создание проекта в Xcode

1. File → New → Project → iOS → App.
2. Name: `TaxApp`.
3. Bundle Identifier: `com.sergionius.tax` (или свой).
4. Interface: SwiftUI.
5. Language: Swift.
6. Скопируй файлы `TaxApp.swift` и `ContentView.swift` из этой папки в проект, заменив сгенерированные.

## Включение push-уведомлений

1. Signing & Capabilities → + Capability → Push Notifications.
2. Добавь Background Modes → Remote notifications.

## APNs

Для push нужен Apple Developer Program:
- Создай App ID с Push Notifications.
- Сгенерируй APNs Auth Key `.p8`.
- Передай `Key ID`, `Team ID`, `Bundle ID` на backend в `.env`.

## Backend

По умолчанию приложение ходит на `https://138.249.127.23.nip.io`. Можно поменять в настройках.
