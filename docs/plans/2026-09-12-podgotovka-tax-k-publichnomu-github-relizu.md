# Подготовка TAX к публичному GitHub-релизу

## 1. Очистить и обезличить репозиторий

Удалить из публикуемого snapshot:

- IP `138.249.127.23` и домен `tax.138-249-127-23.nip.io`;
- пользователя `hermes`, SSH-адреса и пути `/home/hermes/tax`;
- Apple Team ID `WQ3X4DQT53`;
- bundle ID `ru.madmaximuus.yandexmapstestapp.YandexMapsTestApp`;
- путь `/Users/sergiomalkin/...`;
- `ios/tax/tax.xcodeproj/project.pbxproj.bak`;
- персональные Git identities и имя автора пакета.

Заменить значения универсальными:

- сервер — только явно настроенный self-hosted URL;
- bundle IDs — `com.example.tax`, `.tests`, `.uitests`;
- deployment user, domain и installation path — параметры окружения;
- автор пакета — `Sergionius`;
- OSLog subsystem — `Bundle.main.bundleIdentifier`.

`localhost`, `mac-main`, `iphone-main` и явно тестовые credentials могут остаться.

## 2. Перевести весь публикуемый проект на английский

Перевести на английский:

- `README.md` и всю сохраняемую документацию;
- инструкции установки, эксплуатации и APNs;
- исходные комментарии во всех Python, Swift, TypeScript, shell и configuration-файлах;
- TODO/FIXME и diagnostic messages;
- пользовательские строки, ошибки и CLI help;
- тестовые названия и комментарии;
- GitHub Actions names и comments;
- `.env.example`, Caddy/systemd templates и release documentation.

Удаляемые внутренние планы переводить не нужно. После изменений выполнить поиск кириллицы по всем tracked text-файлам; результат должен быть пустым, кроме случаев, явно требуемых функциональностью продукта.

## 3. Исключить локальные agent skills, сохранив их на компьютере

Добавить в корневой `.gitignore`:

```gitignore
.pi/skills/
ios/skills/
```

Удалить директории только из Git index через `git rm -r --cached`, не удаляя локальные файлы. Проверить, что:

- skills продолжают находиться на локальном диске;
- Pi и локальные coding-agent workflows продолжают их видеть;
- skills отсутствуют в новом публичном репозитории;
- ссылки на удалённые skills удалены из публичной документации.

Это также устраняет необходимость публиковать и сопровождать лицензии скопированных third-party skills.

## 4. Сохранить полностью рабочее локальное окружение

Перед удалением hardcoded private values перенести локальную конфигурацию в ignored-файлы и системные хранилища:

- backend secrets и APNs settings — `server/.env`;
- текущий domain, SSH host, service user и installation path — локальный deployment env/config;
- TAX backend URL и API key на Mac — существующий `tax config`/Keychain;
- E2EE key — macOS Keychain;
- Orca pairing URL — `~/.config/tax/orca-pairing`;
- Apple signing team и персональный bundle ID — локальный Xcode configuration, не tracked-файл.

Добавить безопасные tracked-примеры:

- `server/.env.example`;
- deployment config example;
- optional Xcode `.xcconfig.example`;
- Caddy и systemd templates.

Скрипты должны сначала читать локальную конфигурацию и завершаться понятной ошибкой при её отсутствии, а не обращаться к старому серверу. Существующая локальная установка должна продолжать запускаться с текущим VPS, APNs, Xcode signing, Pi и Orca без ручного возврата private values в tracked-файлы.

До публикации проверить два сценария:

1. **Existing local environment:** текущая машина, VPS deploy, CLI, iOS signing, push и remote host продолжают работать.
2. **Clean self-hosted install:** новый пользователь может настроить проект только по public documentation и example-файлам.

## 5. Оформить и безопасно опубликовать

- Добавить корневые `LICENSE` (MIT) и `SECURITY.md`.
- Оставить только актуальные публичные документы; удалить внутренние/устаревшие plans, review notes и agent instructions, не нужные пользователям.
- Проверить возможность публичного распространения Orca Runtime adapter.
- Проверить права на app icon; сохранить OFL-лицензии bundled fonts.
- Закрепить GitHub Actions dependencies по commit SHA.
- Сохранить Dependabot, минимальные workflow permissions и Gitleaks.
- Создать отдельный public repository из очищенного snapshot без старой `.git`, tags, releases и artifacts.
- Сделать первый коммит как `Sergionius <GitHub noreply email>`.
- Исходный repository и его историю оставить private.
- Перед анонсом сменить backend API key; при необходимости реального сокрытия инфраструктуры также сменить hostname/IP.

## 6. Проверка перед изменением visibility

- `rg` не находит IP, private domain, Team ID, `madmaximuus`, `sergiomalkin`, `hermes`, email или личные абсолютные пути.
- В tracked text-файлах отсутствует кириллица.
- Gitleaks проходит по полной новой истории.
- В Git отсутствуют `.env`, `.p8`, databases, caches, `xcuserdata`, backup-файлы и обе skills-директории.
- Локальные `.pi/skills` и `ios/skills` физически сохранены и доступны.
- Проходят Ruff, Pytest, Python wheel build и iOS unit/UI tests.
- Локально проходят `tax doctor`, remote host, Orca connection, E2EE relay и APNs.
- Backend успешно разворачивается как с локальной private-конфигурацией владельца, так и по чистой self-hosted инструкции.
- iOS-приложение без настройки не обращается к старому backend.
- Финальный public repository проверяется через анонимный clean clone.
