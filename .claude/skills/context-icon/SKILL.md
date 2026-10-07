---
name: context-icon
description: Use when adding or changing a contextual icon on a widget row — a glyph in the counter block that shows while something happens in a session (shell, subagent, compaction, advisor, an MCP server's question) — «добавь иконку в строку», «контекстный значок», «значок для события», "add a row icon". Walks the whole route so no place is missed — the event, core state, drawing, settings, saved layout, tests and docs.
---

# Контекстный значок в строке виджета

Контекстный значок — символ в блоке счётчиков строки (`RowPart.counters`). Он виден, пока в сессии
что-то происходит, и пропадает, когда это кончилось. Один вид значка — один case `ActivityKind`:
например, вопрос MCP-сервера, сжатие контекста, советчик, shell.

Маршрут ниже прошёл значок вопроса MCP-сервера (коммит «Show an MCP server's question to the person
on the row»): его дифф — рабочий пример каждого шага.

## Шаг 0. Сначала факт, потом код

1. **Замерить источник.** Какой хук или запись транскрипта говорит о начале и о конце, в каком
   порядке, с какими полями, есть ли `agent_id` и идентификатор. Как замерять без человека:
   - сервер-проба или сценарий, который вызывает событие;
   - `claude -p --model haiku --settings <файл>` с хуками, которые дописывают stdin в файл в
     scratchpad;
   - код агента читать в бинарнике (`LC_ALL=C grep -a`). Не запускать бинарник ради версии:
     `claude --version` внутри ClaudeCode.app вывел на экран владельца диалог Gatekeeper.
2. **Решить, что это за факт**, — от этого зависит всё остальное:
   - **вызов с началом и концом** → активность в `snapshot.activities` (как shell, сжатие);
   - **человека о чём-то спросили** → фаза `waitingForUser` и вид `UserInputRequestKind`, а значок
     выводится из открытых диалогов (как вопрос MCP-сервера);
   - **список, который присылает агент** → значок выводится из него (как фоновые задачи из `Stop`).

   Не делать активностью то, что ей не является: `activityStarted` гасит ожидание своего агента
   и ставит фазу «работает».
3. **Источник без хука тоже бывает**: советчика видно только в транскрипте (`TranscriptReader`).

## Шаг 1. Событие — если нужно новое

- `HookEventName` (`Sources/AgentWatchCore/HookEventName.swift`) — новый case.
- `ToolingHooks.events(for:)` (`ToolingIntegration.swift`) — добавить в список агента.
  **Компилятор этого не потребует.** Установленные копии после обновления покажут «Hooks missing»
  с кнопкой Repair, а Claude Code ещё нужен `/reload-plugins`.
- `HookEventNormalizer.normalize` (`EventProtocol.swift`): switch исчерпывающий. Событие одного
  агента — `guard source == .claude`, как у `statusLine`. Не требовать полей: тест
  `testEveryHookAskedForIsOneTheProtocolUnderstands` шлёт обобщённую нагрузку.
- Нет `tool_use_id` и своего идентификатора — один фиксированный на сессию
  (`compactionActivityID`, `elicitationActivityID`).
- Редактор `HookCaptureRedactor` (`HookCapture.swift`) принимает имя события сам. Ключи вне
  `knownPayloadKeys` отбрасываются, тексты из `sensitiveKeys` вычёркиваются. Новый ключ на провод —
  только отдельным решением по ADR-0001. Добавить тест, что содержимое события через сокет не идёт.

## Шаг 2. Состояние в ядре

- `ActivityKind` (`SessionModels.swift`) — новый case. Порядок объявления — это порядок в меню
  настроек и в сохранённом `rowLayout.counterKinds`.
- Вид ожидания — новый case `UserInputRequestKind`. **Он сохраняется** в
  `sessions-remembered.json`, а старая сборка, встретив незнакомое значение, теряет весь файл
  (`SessionHistoryStore.read`). Сказать владельцу.
- Тест на каждый переход (этого требует `AGENTS.md`): через `HookIngressProcessor.normalize` и
  `engine.ingest`, как в `ElicitationTests` и `SubagentDialogTests`. Идентификаторы на входе
  хешируются, поэтому сравнивать видом и числом, а не исходной строкой.

## Шаг 3. Рисунок

- `ActivityIcon.symbolName` (`AgentIcons.swift`) — символ SF Symbols, который есть на macOS 14.
  Проверяет `testEveryActivityKindHasASymbolThisSystemActuallyHas`.
- **Символ выбирать рисунком, а не по названию:**
  - полоска кандидатов рядом с уже нарисованными значками, 11 pt в рамке 12 pt, в 1x и 2x — у
    владельца экран 1x;
  - весь виджет: добавить строку в `sessions()` пробы `WidgetRenderProbe` и выполнить
    `WIDGET_RENDER_DIR=<каталог> swift test --filter WidgetRenderProbe`;
  - PNG показать владельцу до коммита: значки уже отклоняли на глаз.
- `ActivityIcon.name` — слова для карточки; там они идут после «waiting on».
- `counterText` (`WidgetText.swift`) — с числом или без; без, если число всегда 1.
- **`activityCounts` (`WidgetText.swift`) — порядок написан руками. Вид, которого там нет, не
  рисуется нигде.** Значок, выведенный из другого состояния, получает там свою ветку.
- Значок вида ожидания меняет и слова:
  - лампа — `SessionLamp.builtInAppearance`, switch по `userInputRequestKind`;
  - `SessionPhase.explanation` (`WidgetText.swift`) совпадает с колонкой «Значение» таблицы фаз в
    `docs/widget.md`, «Лампочка фазы».

## Шаг 4. Настройки

- `ActivityKind.settingsName` (`WidgetText.swift`) — строка в меню Counters
  (Settings → Widget → Rows). Меню само перебирает `ActivityKind.allCases`.
- **Сохранённый список.** `rowLayout.counterKinds` хранит включённые виды. У того, кто уже
  настроил приложение, новый вид выключен — миграций нет; у новой установки включён
  (`RowLayout.standard`). Это закрепляет `testAKindAddedAfterTheFileWasWrittenIsNotCountedUntilTicked`,
  а в `TROUBLESHOOTING.md` нужна запись, где его включить.
- Цвет. Счётчики красятся `secondaryForegroundColor` фона, своей роли в теме у них нет. Свой цвет —
  это роль в `WidgetTheme.Role` и `ThemeEditorPane`, то есть отдельное решение; по ADR-0003 цвет
  не может быть единственным носителем смысла.
- Меню и значок в строке меню показывают только внимание (`SessionAttention`). Если фаза верна,
  там делать нечего.

## Шаг 5. Документация — в том же изменении

- `docs/agent-events.md`, «Какие события мы просим» — список событий и их число; число имён в
  `HookEventName`; раздел с замером.
- `docs/session-model.md`, «Единая модель событий» — модель событий.
- `docs/widget.md`:
  - «Лампочка фазы» — таблица фаз, если меняется её смысл;
  - «Счётчики активностей».
- Замер — пометка `(замер: Claude Code <версия>)` у самого факта; `docs/measurements.md` из них
  собирает `task measurements`. «Прочитано в коде» — не «замерено»: писать, что из двух.
- `TROUBLESHOOTING.md` — что сделать существующей установке: Repair, `/reload-plugins`, галочка в
  Counters.
- `docs/implementation-plan.md` — статус.
- Комментарии со счётом: «2 of N missing» у `case incomplete(missing:)` в `ToolingIntegration.swift`.

## Шаг 6. Проверить и сказать

- `swift test --filter` по затронутым тестам, потом `task verify`.
- Владельцу назвать:
  - что нажать: Repair в Tooling, `/reload-plugins`, галочку в Counters;
  - что не замерено;
  - что сохраняется в файлах и чем грозит переход на старую сборку.
