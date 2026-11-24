# hc-board для macOS (Herdr)

Та же доска и запуск агентов, но внутри [Herdr](https://herdr.dev): доска — мод Herdr,
агенты — вкладки в пространстве проекта. VS Code не нужен.

| Файл | Что делает |
|---|---|
| `hc-board/` | Мод Herdr: доска NEEDS YOU / WORKING / DONE |
| `hc-team` | Поднимает агентов проекта во вкладках Herdr (аналог задач VS Code с `runOn: folderOpen`) |
| `hc-agent` | Как `hc-agent.ps1`: подключает терминал к агенту `<имя>`, запуская его, если он не идёт |

## Установка

```sh
cp -R mac/hc-board ~/.config/herdr-app/mods/
cp mac/hc-team mac/hc-agent ~/.local/bin/ && chmod +x ~/.local/bin/hc-team ~/.local/bin/hc-agent
herdr-app check ~/.config/herdr-app/mods/hc-board
```

Клавиша для доски, в `~/.config/herdr-app/keys.json` → `global`:

```json
"cmd-shift-b": { "command": "tab.new", "args": { "mod": "hc-board", "name": "Board" } }
```

Нужны `hc`, `herdr-app`, `jq`, `python3`.

## Доска

Колонки, карточки и скрытые группы — как в `hc-board.ps1`. Отличия:

- Клик по карточке — к панели агента; у агента без панели — `terminal.peek`.
- `done` становится `idle`, когда агента посмотрели в Herdr (не только «до запуска доски»).
- Секунды тикают только первую минуту, дальше — минуты (меньше перерисовок).
- Уже окно 620 px — колонки друг под другом.

Клавиши (когда доска в фокусе) и кнопки в шапке: `p` обычные программы, `f` завершённые,
`i` idle > 20 мин, `r` перечитать, `t` / **▶ team** — запустить `hc-team` для показанного пространства.

## Команда агентов: `hc-team [папка]`

Берёт команду из `<папка>/.herdr/team.json`:

```json
{ "board": true,
  "agents": [
    { "name": "main-claude", "role": "lead", "run": ["claude", "--continue"] },
    { "name": "main-codex", "run": ["codex", "resume", "--last", "--no-daemon"] } ] }
```

или, если его нет, из `<папка>/.vscode/tasks.json` — проекты с Windows работают без правок:
задачи с `hc-agent.ps1` становятся агентами (имя, `--role`, команда), задача с `hc-board.ps1`
включает доску.

- Идущие агенты не трогает, недостающие запускает через `hc run --keep` с метками
  `herdr.space` / `herdr.tab`: каждый — своя вкладка (по роли) в пространстве проекта
  (пространство с этой папкой, иначе новое). Плюс вкладка Board.
- Команда запускается через login-shell (`$SHELL -lic`), так что PATH — как в терминале.
- `hc-team --print` показывает команду и ничего не запускает.
- `--resume <id>` с Windows на Mac не найдёт сессию: поменяйте id или используйте `--continue`.
