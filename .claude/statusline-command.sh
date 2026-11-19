#!/bin/bash
# Converted from ~/.bashrc PS1: '${debian_chroot:+($debian_chroot)}\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# Проценты лимитов приходят с точкой, а LC_NUMERIC=ru_RU ждёт запятую и валит printf.
export LC_NUMERIC=C

now="${STATUSLINE_NOW:-$(date +%s)}"
input=$(cat)
cwd=$(echo "$input" | jq -r '.workspace.current_dir')

# В worktree корень worktree подменяется корнем основного репозитория: путь
# .claude/worktrees/<имя> дублирует ветку, которая выводится следом.
display_cwd="$cwd"
git_toplevel=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
git_common_dir=$(git -C "$cwd" --no-optional-locks rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -n "$git_toplevel" ] && [ "$(basename "$git_common_dir")" = ".git" ]; then
  main_root=$(dirname "$git_common_dir")
  [ "$git_toplevel" != "$main_root" ] && display_cwd="$main_root${cwd#"$git_toplevel"}"
fi

# Без юзера, хоста и префикса ~/projects: остаётся путь вроде /cloud/holday.
short_cwd="${display_cwd#$HOME/projects}"
[ -z "$short_cwd" ] && short_cwd="/"

printf '\033[01;34m%s\033[00m' "$short_cwd"

# Ветка git каталога сессии; вне репозитория ничего не выводится. --no-optional-locks
# не даёт git status брать index.lock, пока рядом работают другие агенты.
# Detached HEAD — короткий хеш, «*» — есть правки, включая неотслеживаемые файлы.
git_branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short -q HEAD 2>/dev/null)
if [ -z "$git_branch" ]; then
  git_branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
fi
if [ -n "$git_branch" ]; then
  printf ' \033[35m%s\033[00m' "$git_branch"
  if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
    printf '\033[33m*\033[00m'
  fi
fi

# Залогиненный аккаунт Claude Code: без него в статуслайне не видно, под каким
# логином уходят запросы (у пользователя несколько профилей через CLAUDE_CONFIG_DIR).
config_dir="${CLAUDE_CONFIG_DIR:-$HOME}"
account=""
if [ -f "$config_dir/.claude.json" ]; then
  account=$(jq -r '.oauthAccount.displayName // .oauthAccount.emailAddress // empty' "$config_dir/.claude.json" 2>/dev/null)
fi
# Пустое имя визуально читается как «обычный аккаунт», хотя означает лишь нечитаемый конфиг
# профиля, — вместо пропуска показываем каталог профиля со знаком вопроса.
[ -z "$account" ] && account="?$(basename "$config_dir")"
printf ' \033[02m%s\033[00m' "$account"

# Модель сессии: без неё не видно, на чём идут запросы после /model.
# Effort — в скобках следом: его тоже меняют на ходу, а в строке его не видно.
model=$(echo "$input" | jq -r '.model.display_name // empty')
effort=$(echo "$input" | jq -r '.effort.level // empty')
[ -n "$model" ] && [ -n "$effort" ] && model="$model ($effort)"
[ -n "$model" ] && printf ' \033[02m| %s\033[00m' "$model"

# Размер израсходованного контекста: входные токены последнего запроса к модели
# (input + запись кэша + чтение кэша). После компакции значение падает само.
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty')
context_tokens=0
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  context_tokens=$(jq -n '[inputs | select(.type == "assistant" and (.isSidechain != true) and (.message.usage != null)) | .message.usage | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))] | last // 0' "$transcript_path" 2>/dev/null)
  [ -z "$context_tokens" ] && context_tokens=0
fi
context_human=$(awk -v t="$context_tokens" 'BEGIN { if (t >= 1000) printf "%.0fk", t / 1000; else printf "%d", t }')
five_hour=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_hour_resets=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_day=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
seven_day_resets=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

normalize_epoch() {
  local val="$1"
  [ -z "$val" ] && return
  if [[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    local val_int=${val%.*}
    if [ "$val_int" -gt 100000000000 ]; then
      val_int=$(( val_int / 1000 ))
    fi
    printf '%s' "$val_int"
  else
    date -d "$val" +%s 2>/dev/null
  fi
}

limit_color() {
  local pct="$1"
  awk -v p="$pct" 'BEGIN {
    if (p >= 90) printf "\\033[31m";
    else if (p >= 70) printf "\\033[33m";
    else printf "\\033[02m";
  }'
}

print_limit() {
  local label="$1" pct="$2" raw_reset="$3" fmt="$4"
  [ -z "$pct" ] && return
  local epoch="" until=""
  epoch=$(normalize_epoch "$raw_reset")
  if [ -n "$epoch" ]; then
    until=$(date -d "@$epoch" "$fmt" 2>/dev/null)
  fi
  if [ -n "$epoch" ] && [ "$epoch" -le "$now" ]; then
    if [ -n "$until" ]; then
      printf ' \033[02m|\033[00m \033[02m%s:уст. (%s)\033[00m' "$label" "$until"
    else
      printf ' \033[02m|\033[00m \033[02m%s:уст.\033[00m' "$label"
    fi
  else
    local color
    color=$(limit_color "$pct")
    printf " \\033[02m|\\033[00m ${color}%s:%.0f%%" "$label" "$pct"
    [ -n "$until" ] && printf ' до %s' "$until"
    printf '\033[00m'
  fi
}

printf ' \033[02m|\033[00m'
# Больше 150k токенов — жёлтый, больше 300k — красный; иначе приглушённый.
if [ "$context_tokens" -gt 300000 ]; then
  ctx_color='\033[31m'
elif [ "$context_tokens" -gt 150000 ]; then
  ctx_color='\033[33m'
else
  ctx_color='\033[02m'
fi
printf " ${ctx_color}ctx:%s\\033[00m" "$context_human"
print_limit "5ч" "$five_hour" "$five_hour_resets" "+%H:%M"
print_limit "7д" "$seven_day" "$seven_day_resets" "+%d.%m %H:%M"
