---
name: release
description: Use when releasing the Agent Watch app — «выпусти релиз», «сделай релиз», «подготовь 0.4.0», "cut a release". Writes the CHANGELOG.md section from the commits since the last tag, asks the owner once, takes the release through the checks, the version commit, the tag and the draft, publishes on a second yes, and checks the published update in a clean machine.
---

# Релиз приложения

Ведёт релиз приложения от коммитов до опубликованной страницы и проверенного обновления. Плагин
IDE не выпускает: у него `publish-plugin.yml` и свой текст изменений в `plugin.xml`. Что лежит в
релизе и как его принимают установленные копии — `docs/distribution.md`.

## Вопросы владельцу

Два, и больше ни одного:

1. **В начале** — раздел `CHANGELOG.md` и версия: «идём до черновика?». «Да» разрешает всё до
   черновика: коммит версии, прогон в машине, пуш `main` и тега. Хук `git-guard` всё равно спросит
   на пуше в `main` — это его вопрос; скилл его не обходит и не отвечает за владельца.
2. **Перед публикацией** — ссылка на черновик и итог проверок: «публикуем?».

Правка текста владельцем — не новый вопрос: внести, показать снова, спросить то же. Упал любой
шаг — остановиться и сказать: команда, что она вывела, вероятная причина, что предлагается.
Дальше — только после ответа. Тег и черновик без вопроса не удалять.

Долгие шаги (проверка коммита, машина, CI) идут в фоне, с одной строкой до и одной после.

## Перед началом — только чтение

- `git status` чист. После `git fetch origin` и `origin/main`, и локальный `main` входят в `HEAD`
  (`git merge-base --is-ancestor <ref> HEAD`): релиз продолжает `main`, ничего из него не теряя.
  `HEAD` — сам `main` или ветка worktree, в которую `main` влит; сессия в worktree приложения не
  может работать с git общего checkout, поэтому релиз идёт оттуда, где она есть.
- `gh secret list --repo glockbender/agentwatcher` содержит `SPARKLE_PRIVATE_KEY`, а
  `Resources/Info.plist` — `SUPublicEDKey`. Нет — `docs/distribution.md`, «Ключ подписи
  обновлений»: это делает владелец.
- `tart list` содержит `aw-golden` (`.claude/skills/readme-media/vm.md`).
- Последний тег — `git describe --tags --abbrev=0 --match 'v*'`, последний опубликованный —
  `gh release view --repo glockbender/agentwatcher --json tagName`. Если они разные (тег без
  релиза, как `v0.2.0`, или висящий черновик), выяснить это с владельцем до раздела.

## Раздел CHANGELOG

Источник — коммиты с последнего тега:
`git log --no-merges --format='%h %s%n%n%b' <тег>..HEAD`. Читать тело коммита, а не только
заголовок; если и по нему не ясно, что увидит человек, — смотреть diff.

- Читатель — человек, который обновляет приложение. В раздел идёт то, что он заметит, и то, что
  ему сделать. Не идут рефакторинг, тесты, документы, README, CI, скиллы, сам процесс релиза.
- Подразделы Keep a Changelog в этом порядке, только непустые: `### Added`, `### Changed`,
  `### Removed`, `### Fixed`.
- Пункт говорит, что человек видит, в настоящем времени, начиная с самой вещи: «The update window
  lists what changed since your version.» Не «Added …» — это уже сказал подраздел. До 25 слов;
  `scripts/changelog.py` отказывает после 50.
- Названия — как на экране (Settings → Tooling, Check for Updates…); команды и пути — в обратных
  кавычках. Ни имён типов, ни ADR, ни файлов исходников.
- Несколько коммитов об одном — один пункт. Исправление того, что появилось в этом же релизе, —
  не пункт.
- Что человек должен сделать после обновления — первым пунктом в `### Changed`, начиная с «After
  updating, …». Такие пункты пишутся сразу в `## [Unreleased]`, в коммите самого изменения
  (`AGENTS.md`); скилл переносит их в раздел версии. `## [Unreleased]` стоит в файле, только пока
  под ним есть пункты.
- Пункт о том, что README показывает картинкой или роликом, может кончаться ссылкой на раздел
  README, закреплённый за тегом:
  `([how it looks](https://github.com/glockbender/agentwatcher/blob/vX.Y.Z/README.md#якорь))`.
  Якорь сверить с заголовком README.
- Плагин IDE — одним пунктом и только когда к релизу приложен новый файл плагина.
- Заголовок — `## [X.Y.Z] - YYYY-MM-DD`, дата коммита версии.

Версия: новое, что человек заметит, — minor; только исправления — patch; несовместимое на 0.x —
тоже minor. Переход на 1.0 решает `docs/release-plan.md`, не скилл.

Проверка: `python3 scripts/changelog.py check X.Y.Z`. Владельцу показать раздел целиком, версию и
одной строкой, какие коммиты не вошли и почему, — чтобы было видно, что выброшено.

## После «да»

1. В `Resources/Info.plist` заменить строку под `CFBundleShortVersionString` правкой текста:
   `plutil -replace` переписывает весь файл табами. Коммит `Set the version to X.Y.Z` с
   `Info.plist` и `CHANGELOG.md`; проверка коммита — `task verify`.
2. `task e2e-update` — обновление этой сборки в чистой машине, со всеми сбоями.
3. `task release` — zip и образ; zip распаковывается и проходит `codesign --verify --strict`,
   как его проверят установленные 0.3.0. Предупреждение о `SPARKLE_PRIVATE_KEY` здесь ожидаемо:
   фид подписывает CI. Затем `./scripts/release-notes.sh X.Y.Z` должен отработать без ошибки.
4. `git push origin HEAD:main` — одинаково с `main` и с ветки worktree. Проверка пуша —
   `task verify-all`; `git-guard` спросит владельца.
5. `git tag -a vX.Y.Z -m "Agent Watch X.Y.Z"`, затем `git push origin vX.Y.Z`.
6. `release.yml`: id из `gh run list --workflow release.yml --limit 1`, затем
   `gh run watch <id> --exit-status`.
7. Черновик: `./scripts/probe-release.sh vX.Y.Z` — архив, его сумма, `--strict`, фид с версией,
   адресом архива и подписью под `SUPublicEDKey`. Текст —
   `gh release view vX.Y.Z --json body`: начинается с `## What changed` и раздела.

## Публикация

После «да» на втором вопросе:
`gh release edit vX.Y.Z --repo glockbender/agentwatcher --draft=false --latest`.

## После публикации

- `task probe-update` — тот же осмотр, но как копии: последний опубликованный и по прямым
  адресам.
- `./scripts/e2e-update.sh --from <прошлый тег>` — прошлый релиз в чистой машине находит новый на
  GitHub и ставит его.
- `./scripts/e2e-update.sh --from vX.Y.Z --as <прошлая версия>` — новый релиз под номером прошлого
  обновляется до самого себя. Так видно, что его Sparkle доходит до настоящего фида и принимает
  настоящий ключ — этим путём копии с ним возьмут следующий релиз.
- Релиз шёл с ветки worktree — локальный `main` общего checkout отстал. Дать владельцу одну
  команду для того checkout: `git merge --ff-only origin/main`.

Красное здесь значит, что копии людей уже видят сломанный релиз. Предложить владельцу вернуть его
в черновик — `gh release edit vX.Y.Z --draft=true`: тогда и `/releases/latest`, и фид снова
отдают прежний.
