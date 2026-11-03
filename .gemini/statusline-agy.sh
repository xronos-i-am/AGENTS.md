#!/bin/bash
# Status line script for Antigravity CLI (agy), Claude Code and compatible agents.
# Formats:
#   <dir> <branch><*> [model] | ctx:<tokens> [(session:<tokens>)] | 5ч:<%> до <time> | 7д:<%> до <date>

export LC_NUMERIC=C

input=$(cat)
# 1. Текущая папка / workspace root
cwd=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // .workspace // empty' 2>/dev/null)
[ -z "$cwd" ] && cwd=$(pwd)

display_cwd="$cwd"
git_toplevel=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
git_common_dir=$(git -C "$cwd" --no-optional-locks rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
if [ -n "$git_toplevel" ] && [ "$(basename "$git_common_dir")" = ".git" ]; then
  main_root=$(dirname "$git_common_dir")
  [ "$git_toplevel" != "$main_root" ] && display_cwd="$main_root${cwd#"$git_toplevel"}"
fi

short_cwd="${display_cwd#$HOME/projects}"
[ -z "$short_cwd" ] && short_cwd="/"

printf '\033[01;34m%s\033[00m' "$short_cwd"

# 2. Текущая ветка git и звездочка (*) при наличии изменений
git_branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short -q HEAD 2>/dev/null)
if [ -z "$git_branch" ]; then
  git_branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
fi
if [ -z "$git_branch" ]; then
  git_branch=$(echo "$input" | jq -r '.vcs.branch // empty' 2>/dev/null)
fi

if [ -n "$git_branch" ]; then
  printf ' \033[35m%s\033[00m' "$git_branch"
  is_dirty=""
  if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
    is_dirty=1
  elif [ "$(echo "$input" | jq -r '.vcs.dirty // empty' 2>/dev/null)" = "true" ]; then
    is_dirty=1
  fi
  [ -n "$is_dirty" ] && printf '\033[33m*\033[00m'
fi

# 3. Модель сессии (если передана)
model=$(echo "$input" | jq -r '.model.display_name // .model.id // empty' 2>/dev/null)
effort=$(echo "$input" | jq -r '.effort.level // .model.effort // empty' 2>/dev/null)
if [ -n "$model" ] && [ -n "$effort" ]; then
  # Не дублируем effort, если он уже включен в display_name (например, "Gemini 3.8 Flash (High)")
  if ! [[ "$model" =~ \([a-zA-Z0-9_+\ -]+\)$ ]]; then
    model="$model ($effort)"
  fi
fi
[ -n "$model" ] && printf ' \033[02m| %s\033[00m' "$model"

# 4. Размер израсходованного контекста (входные токены последнего шага)
conv_id=$(echo "$input" | jq -r '.conversation_id // .session_id // empty' 2>/dev/null)
transcript_path=$(echo "$input" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -z "$transcript_path" ] && [ -n "$conv_id" ]; then
  candidate="$HOME/.gemini/antigravity-cli/brain/$conv_id/.system_generated/logs/transcript.jsonl"
  [ -f "$candidate" ] && transcript_path="$candidate"
fi

context_tokens=$(echo "$input" | jq -r '
  (if .context_window.current_usage != null then
    ((.context_window.current_usage.input_tokens // 0) + (.context_window.current_usage.cache_read_input_tokens // 0) + (.context_window.current_usage.cache_creation_input_tokens // 0))
   else empty end)
  // .context_window.total_tokens
  // (if .context_window.total_input_tokens != null then (.context_window.total_input_tokens + (.context_window.total_output_tokens // 0)) else empty end)
  // empty
' 2>/dev/null)

if [ -z "$context_tokens" ] || [ "$context_tokens" = "0" ]; then
  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    context_tokens=$(jq -n '
      [inputs | 
        if .type == "PLANNER_RESPONSE" and .input_tokens != null then
          ((.input_tokens // 0) + (.cache_read_tokens // 0))
        elif .type == "assistant" and (.isSidechain != true) and (.message.usage != null) then
          ((.message.usage.input_tokens // 0) + (.message.usage.cache_creation_input_tokens // 0) + (.message.usage.cache_read_input_tokens // 0))
        else empty end
      ] | last // 0
    ' "$transcript_path" 2>/dev/null)
  fi
fi

[ -z "$context_tokens" ] && context_tokens=0

context_human=$(awk -v t="$context_tokens" 'BEGIN {
  if (t >= 1000000) printf "%.1fm", t / 1000000;
  else if (t >= 1000) printf "%.0fk", t / 1000;
  else printf "%d", t;
}')

if [ "$context_tokens" -gt 300000 ]; then
  ctx_color='\033[31m'
elif [ "$context_tokens" -gt 150000 ]; then
  ctx_color='\033[33m'
else
  ctx_color='\033[02m'
fi

printf ' \033[02m|\033[00m'
printf " ${ctx_color}ctx:%s\\033[00m" "$context_human"

# 5. Лимиты 5-часового и недельного окна со временем сброса
model_lower=$(echo "$model" | tr '[:upper:]' '[:lower:]')
q_prefix="gemini"
if [[ "$model_lower" =~ claude|gpt|openai|anthropic|3p ]]; then
  q_prefix="3p"
fi

five_hour=$(echo "$input" | jq -r --arg p "$q_prefix" '
  .rate_limits.five_hour.used_percentage
  // .rate_limits["5h"].used_percentage
  // (if (.quota[$p + "-5h"].remaining_fraction != null) then ((1 - .quota[$p + "-5h"].remaining_fraction) * 100)
      elif (.quota["gemini-5h"].remaining_fraction != null) then ((1 - .quota["gemini-5h"].remaining_fraction) * 100)
      elif (.quota["3p-5h"].remaining_fraction != null) then ((1 - .quota["3p-5h"].remaining_fraction) * 100)
      elif (.quotas[$p + "-5h"].remaining_fraction != null) then ((1 - .quotas[$p + "-5h"].remaining_fraction) * 100)
      else empty end)
' 2>/dev/null | head -n 1)

five_hour_resets=$(echo "$input" | jq -r --arg p "$q_prefix" '
  .rate_limits.five_hour.resets_at
  // .rate_limits["5h"].resets_at
  // .quota[$p + "-5h"].reset_time
  // .quota[$p + "-5h"].reset_in_seconds
  // .quota["gemini-5h"].reset_time
  // .quota["gemini-5h"].reset_in_seconds
  // .quota["3p-5h"].reset_time
  // .quota["3p-5h"].reset_in_seconds
  // .quotas[$p + "-5h"].reset_time
  // empty
' 2>/dev/null | head -n 1)

seven_day=$(echo "$input" | jq -r --arg p "$q_prefix" '
  .rate_limits.seven_day.used_percentage
  // .rate_limits.weekly.used_percentage
  // .rate_limits["7d"].used_percentage
  // (if (.quota[$p + "-weekly"].remaining_fraction != null) then ((1 - .quota[$p + "-weekly"].remaining_fraction) * 100)
      elif (.quota["gemini-weekly"].remaining_fraction != null) then ((1 - .quota["gemini-weekly"].remaining_fraction) * 100)
      elif (.quota["3p-weekly"].remaining_fraction != null) then ((1 - .quota["3p-weekly"].remaining_fraction) * 100)
      elif (.quotas[$p + "-weekly"].remaining_fraction != null) then ((1 - .quotas[$p + "-weekly"].remaining_fraction) * 100)
      else empty end)
' 2>/dev/null | head -n 1)

seven_day_resets=$(echo "$input" | jq -r --arg p "$q_prefix" '
  .rate_limits.seven_day.resets_at
  // .rate_limits.weekly.resets_at
  // .quota[$p + "-weekly"].reset_time
  // .quota[$p + "-weekly"].reset_in_seconds
  // .quota["gemini-weekly"].reset_time
  // .quota["gemini-weekly"].reset_in_seconds
  // .quota["3p-weekly"].reset_time
  // .quota["3p-weekly"].reset_in_seconds
  // .quotas[$p + "-weekly"].reset_time
  // empty
' 2>/dev/null | head -n 1)

format_reset() {
  local val="$1"
  local fmt="$2"
  [ -z "$val" ] && return
  if [[ "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    local val_int=${val%.*}
    if [ "$val_int" -lt 10000000 ]; then
      local target=$(( $(date +%s) + val_int ))
      date -d "@$target" "$fmt" 2>/dev/null
    else
      if [ "$val_int" -gt 100000000000 ]; then
        val_int=$(( val_int / 1000 ))
      fi
      date -d "@$val_int" "$fmt" 2>/dev/null
    fi
  else
    date -d "$val" "$fmt" 2>/dev/null
  fi
}

five_hour_until=$(format_reset "$five_hour_resets" "+%H:%M")
seven_day_until=$(format_reset "$seven_day_resets" "+%d.%m %H:%M")

limit_color() {
  local pct="$1"
  awk -v p="$pct" 'BEGIN {
    if (p >= 90) printf "\\033[31m";
    else if (p >= 70) printf "\\033[33m";
    else printf "\\033[02m";
  }'
}

if [ -n "$five_hour" ]; then
  c_5h=$(limit_color "$five_hour")
  printf " \\033[02m|\\033[00m ${c_5h}5ч:%.0f%%" "$five_hour"
  [ -n "$five_hour_until" ] && printf ' до %s' "$five_hour_until"
  printf '\033[00m'
fi

if [ -n "$seven_day" ]; then
  c_7d=$(limit_color "$seven_day")
  printf " \\033[02m|\\033[00m ${c_7d}7д:%.0f%%" "$seven_day"
  [ -n "$seven_day_until" ] && printf ' до %s' "$seven_day_until"
  printf '\033[00m'
fi
