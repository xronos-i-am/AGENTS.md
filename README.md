# AGENTS.md

Общие правила поведения и инструкции для AI-агентов (Claude Code, Google Antigravity, OpenCode), а также скрипты и плагины статусной строки для терминала.

## Требования

- [APM (Agent Package Manager)](https://github.com/microsoft/apm) — должен быть доступен в `PATH` (`apm --version`)
- Утилита `make`

## Установка

Чтобы развернуть правила и статуслайны глобально для всех проектов текущего пользователя на хосте, выполните:

```bash
make install
```

### Что делает команда:

1. **Регистрирует пакет в APM на уровне пользователя:**
   Выполняет `apm install -g . --target claude,opencode,gemini`, что добавляет правила в `~/.claude/rules/agents.md`.
2. **Связывает правила для остальных сред:**
   - Создаёт симлинк `~/.gemini/AGENTS.md` -> `AGENTS.md` (действует во всех проектах Google Antigravity).
   - Создаёт симлинк `~/.config/opencode/AGENTS.md` -> `AGENTS.md` (для OpenCode).
3. **Подключает статусную строку:**
   - Для Claude Code: `~/.claude/statusline-command.sh`
   - Для Antigravity (`agy`): `~/.gemini/statusline-agy.sh`
   - Для OpenCode: `~/.config/opencode/plugins/status-line`
4. **Связывает настройки Claude Code (симлинк):**
   - Для Claude Code: `~/.claude/settings.json` -> `.claude/settings.json`

---

## Удаление

Чтобы снять симлинки с правил, настроек и статуслайнов:

```bash
make uninstall
```

Для полного удаления пакета из APM:
```bash
apm deps remove agents-md -g
```

---

## Структура файлов

- `.apm/instructions/agents.instructions.md` — источник общих правил для всех агентов.
- `AGENTS.md` — симлинк на инструкции для прямого связывания сред.
- `.claude/settings.json` — настройки Claude Code (`~/.claude/settings.json`).
- `.gemini/antigravity-cli/settings.json` — эталонные настройки Antigravity CLI.
- `opencode/cli.json` — эталонные настройки CLI OpenCode.
- `.claude/statusline-command.sh` — скрипт статусной строки для Claude Code.
- `.gemini/statusline-agy.sh` — скрипт статусной строки для Antigravity CLI (`agy`).
- `opencode/plugins/status-line/` — плагин статусной строки для OpenCode.
- `Makefile` — команды установки и управления симлинками.
