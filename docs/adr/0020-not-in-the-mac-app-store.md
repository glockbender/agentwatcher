# Agent Watch не распространяется через Mac App Store

**Статус:** принято 2026-09-11.

Приложение раздаётся подписанным и нотаризованным бандлом из GitHub Releases, а не через Mac App
Store ([distribution.md](../distribution.md)).

## Почему

Приложение само ставит интеграции и для этого пишет в три чужих места: каталог плагина под
`~/.claude/skills/`, ключ `statusLine` в `~/.claude/settings.json` и `~/.codex/hooks.json`
([agent-integration.md](../agent-integration.md)). Правило 2.4.5 гайдлайнов Apple требует от
приложения из Store быть «self-contained, single app installation bundle», запрещает «install code
or resources in shared locations» и «install … additional code, or resources to add functionality»,
а чужие данные разрешает менять только через API самой Apple. Три места выше — ровно перечисленное;
[ADR-0019](0019-the-ide-plugin-comes-from-marketplace-and-the-app-plants-the-first-copy.md) добавляет
четвёртое — каталог плагинов IDE.

Закладкой на выбранный человеком каталог это не обходится: песочница и правило ревью — разные слои,
и запрет здесь во втором.

## Чем за это платим

Подпись, нотаризация и обновление — своими силами. Версия для Store возможна, но она заменяет
«поставить» на «показать, что вставить», то есть это другой продукт.

## Когда пересмотреть

Если правило 2.4.5 изменится или агенты начнут принимать внешние хуки без записи в их файлы.
