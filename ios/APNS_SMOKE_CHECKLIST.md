# APNs smoke checklist

Проверка выполняется на физическом iPhone: симулятор не получает реальные APNs.

## Данные прогона

- App version / build:
- Git commit:
- Устройство:
- iOS:
- Сборка: Debug / TestFlight
- APNs: sandbox / production
- Дата и исполнитель:
- Итог: PASS / FAIL
- Ссылки на дефекты:

## Подготовка

- [ ] Установить свежую Debug- или TestFlight-сборку.
- [ ] Убедиться, что bundle ID совпадает с APNs topic.
- [ ] На Mac запустить агента (pi, Claude Code или Codex) в терминале Orca, чтобы push привёл в конкретный terminal.
- [ ] В Settings указать server URL, API key, Host ID, Device ID и E2EE key, нажать **Save Settings**.
- [ ] Разрешить уведомления в системных настройках.
- [ ] Нажать **Request Push Registration** и убедиться, что появился device token.
- [ ] Проверить `Check Server Health` и выполнить `tax push-doctor` на Mac.

## Основной сценарий

- [ ] Дождаться завершения хода агента и получить push при закрытом приложении.
- [ ] Нажать уведомление и убедиться, что открылись правильные Mac, workspace и terminal.
- [ ] Получить push при открытом приложении (foreground); проверить banner.
- [ ] Проверить режимы `all`, `tax` и `off`: в `all` и `tax` push приходит, в `off` — нет. Вернуть требуемый режим.
- [ ] Убедиться, что push на закрытый terminal не ломает приложение: открывается workspace с сообщением о закрытом терминале.

## Reconnect

- [ ] Выключить сеть на iPhone, включить снова и убедиться, что приложение переподключилось к relay и восстановило terminal snapshot без смешивания generations.

## Критерий PASS

Все обязательные пункты выполнены; расхождения зафиксированы ссылками на дефекты. APNs environment соответствует типу сборки: sandbox для Debug и production для TestFlight/App Store.
