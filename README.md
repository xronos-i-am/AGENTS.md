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

1. **Ставит APM-пакеты на уровне пользователя:**
   Сначала подключает `.config/git/gitlab.gitconfig` в `include.path` файла `~/.gitconfig`: файл даёт git логин для `https://gitlab.groupprice.ru` и `https://gitlab.com` из токена `glab`, как `gh` для GitHub. `apm` ходит в gitlab по https, даже когда в `apm.yml` записан ssh. Без логина `git ls-remote` падает, и `apm outdated` молча показывает зависимость как `unknown`. Нужен `glab` с входом на каждый хост: `glab auth login --hostname <хост>`.
   Затем выполняет `apm install -g` в `~/.apm` с `CLAUDE_CONFIG_DIR=~/.claude-profiles/shared`: `apm` не пишет скиллы сквозь симлинк `~/.claude/skills`, и профиль Claude берёт их из `shared`. Версии скиллов в `~/.apm/apm.yml` двигают их релизы. Пакет этого репозитория ставится последним выпущенным тегом `vX.Y.Z`, а правила попадают в `~/.claude-profiles/shared/rules/agents.md`.
   Затем обновляет эталон настроек Antigravity из `~/.gemini/antigravity-cli/settings.json` скриптом `.gemini/sync-antigravity-settings.sh`: в копию в репозитории не попадают `trustedWorkspaces` и абсолютные пути.
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

## Разработка и выпуск версий

Обвязка разработки приходит из приватного пакета [skill-kit](https://github.com/xronos-i-am/skill-kit): без доступа к нему `make setup` не пройдёт, а `make install` пройдёт.

| Команда | Когда |
| --- | --- |
| `make setup` | после клона, после правки правил и чтобы взять свежий skill-kit: ставит `apm`, `lefthook` и `worktrunk` из `mise.toml`, поднимает версии `skill-kit` в `apm.yml` и проверок в `lefthook.yml` — закоммитьте |
| `make release [minor\|major]` | выпустить версию: тег `vX.Y.Z`, push и глобальная установка выпущенной версии |

Правила доезжают до всех проектов только выпущенной версией: правка в `master` без `make release` не действует. Настройки, статуслайны и плагин OpenCode раскладываются симлинками из рабочего дерева и в релиз не входят.

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
- `.config/git/gitlab.gitconfig` — логин glab для https gitlab, подключается в `~/.gitconfig`.
- `.gemini/sync-antigravity-settings.sh` — обновляет эталон настроек Antigravity из системного файла без личных путей.
- `Makefile` — команды установки, разработки и выпуска версий.
- `apm.yml`, `mise.toml`, `lefthook.yml`, `.config/wt.toml` — обвязка skill-kit: зависимости, инструменты, git-хуки и worktree для `/task`.
