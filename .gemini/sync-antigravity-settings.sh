#!/usr/bin/env bash
# Обновляет эталон настроек Antigravity CLI в репозитории из системного файла: источник правды —
# ~/.gemini/antigravity-cli/settings.json (CLI правит его сам, симлинк он не держит), а в репозиторий
# уходит копия без личных данных:
#   - ключ trustedWorkspaces удаляется: CLI сам заполняет его абсолютными путями доверенных папок;
#   - в правилах command(...) путь «$HOME/projects/<проект>/…» становится относительным «…»,
#     дубли после замены убираются с сохранением порядка.
# Остаток домашнего пути в результате — ошибка: файл не записывается.
#   sync-antigravity-settings.sh
set -euo pipefail

command -v jq >/dev/null || {
  echo "sync-antigravity-settings: нет jq — поставьте его (apt install jq)" >&2
  exit 1
}

src=$HOME/.gemini/antigravity-cli/settings.json
dst=$(dirname "$0")/antigravity-cli/settings.json

if [[ ! -f $src ]]; then
  echo "sync-antigravity-settings: нет $src — Antigravity CLI не запускался, эталон не обновлён"
  exit 0
fi

prefix="command($HOME/projects/"
clean=$(jq --arg prefix "$prefix" '
  del(.trustedWorkspaces)
  | if .permissions.allow then
      .permissions.allow |= (
        map(if startswith($prefix)
            then "command(" + (ltrimstr($prefix) | sub("^[^/]+/"; ""))
            else . end)
        | reduce .[] as $rule ([]; if index([$rule]) then . else . + [$rule] end)
      )
    else . end
' "$src")

if grep -n -F "$HOME" <<<"$clean" >&2; then
  echo "sync-antigravity-settings: в настройках остались пути из $HOME (строки выше) — научите скрипт их заменять" >&2
  exit 1
fi

if [[ -f $dst ]] && diff -q <(printf '%s\n' "$clean") "$dst" >/dev/null; then
  echo "$dst: без изменений"
else
  printf '%s\n' "$clean" >"$dst"
  echo "$dst обновлён из $src — проверьте git diff и закоммитьте"
fi
