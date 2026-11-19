#!/bin/bash
# Status line script for Antigravity CLI (agy), Claude Code and compatible agents.
# Formats:
#   <dir> <branch><*> | <model> [<mode>] | ctx:<tokens> | 5ч:<%> до <time> | 7д:<%> до <date>

export LC_NUMERIC=C

now="${STATUSLINE_NOW:-$(date +%s)}"
cache_dir="${STATUSLINE_QUOTA_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/agy-statusline}"
git_cache_ttl="${STATUSLINE_GIT_CACHE_TTL:-5}"
input=$(cat)

hash_key() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-16
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -c1-16
  else
    printf '%s' "$1" | cksum | awk '{print $1}'
  fi
}

# Общий парсер timestamp (ISO-8601, unix s/ms, относительные секунды < 1e7) в unix epoch.
JQ_PARSE_TS='
def parse_ts($now):
  if type == "number" then
    if . < 10000000 then ($now + floor)
    elif . > 100000000000 then (. / 1000 | floor)
    else floor end
  elif type == "string" then
    if test("^[0-9]+(\\.[0-9]+)?$") then
      (tonumber | if . < 10000000 then ($now + floor)
                  elif . > 100000000000 then (. / 1000 | floor)
                  else floor end)
    elif test("Z$") then
      (sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null)
    elif test("[+-][0-9]{2}:?[0-9]{2}$") then
      (capture("^(?<dt>.+?)(\\.[0-9]+)?(?<sign>[+-])(?<hh>[0-9]{2}):?(?<mm>[0-9]{2})$")
       | ((.dt + "Z") | try fromdateiso8601 catch null) as $base
       | if $base == null then null
         else $base + ((if .sign == "+" then -1 else 1 end) * ((.hh | tonumber) * 3600 + (.mm | tonumber) * 60))
         end)
    else null end
  else null end;
'

# Один проход jq по stdin: все базовые поля + rate_limits.
mapfile -t parsed < <(printf '%s' "$input" | jq -r --argjson now "$now" "$JQ_PARSE_TS"'
  def clean: if . == null then "" else tostring | gsub("[\r\n]+"; " ") end;
  [
    (.cwd // .workspace.current_dir // .workspace // ""),
    (.vcs.branch // ""),
    (if .vcs.dirty == true then "true" else "" end),
    (.model.display_name // .model.id // ""),
    (.effort.level // .model.effort // ""),
    (.cycle_mode // .permission_mode // .mode // ""),
    (.conversation_id // .session_id // ""),
    (.transcript_path // ""),
    (if .context_window.current_usage != null then
       ((.context_window.current_usage.input_tokens // 0) + (.context_window.current_usage.cache_read_input_tokens // 0) + (.context_window.current_usage.cache_creation_input_tokens // 0))
     elif .context_window.total_tokens != null then
       .context_window.total_tokens
     elif .context_window.total_input_tokens != null then
       (.context_window.total_input_tokens + (.context_window.total_output_tokens // 0))
     else "" end),
    (.email // ""),
    (.plan_tier // ""),
    (if ((.quota // .quotas) | type) == "object" and (((.quota // .quotas) | length) > 0) then "1" else "" end),
    (.rate_limits.five_hour.used_percentage // .rate_limits["5h"].used_percentage // ""),
    ((.rate_limits.five_hour.resets_at // .rate_limits["5h"].resets_at) | parse_ts($now)),
    (.rate_limits.seven_day.used_percentage // .rate_limits.weekly.used_percentage // .rate_limits["7d"].used_percentage // ""),
    ((.rate_limits.seven_day.resets_at // .rate_limits.weekly.resets_at // .rate_limits["7d"].resets_at) | parse_ts($now))
  ] | map(clean) | .[]
' 2>/dev/null)

cwd="${parsed[0]:-}"
vcs_branch="${parsed[1]:-}"
vcs_dirty="${parsed[2]:-}"
model="${parsed[3]:-}"
effort="${parsed[4]:-}"
mode="${parsed[5]:-}"
conv_id="${parsed[6]:-}"
transcript_path="${parsed[7]:-}"
context_tokens="${parsed[8]:-}"
email="${parsed[9]:-}"
plan_tier="${parsed[10]:-}"
has_quota="${parsed[11]:-}"
rl_5h_pct="${parsed[12]:-}"
rl_5h_epoch="${parsed[13]:-}"
rl_7d_pct="${parsed[14]:-}"
rl_7d_epoch="${parsed[15]:-}"

# 1–2. Текущая папка (с нормализацией worktree), ветка git и статус изменений (кэш на 5 сек)
[ -z "$cwd" ] && cwd=$(pwd)

display_cwd="$cwd"
git_branch=""
git_dirty="0"
git_cache_hit=""
git_cache_file="$cache_dir/git-$(hash_key "$cwd").cache"

if [ -r "$git_cache_file" ] && [[ "$git_cache_ttl" =~ ^[0-9]+$ ]] && [ "$git_cache_ttl" -gt 0 ]; then
  mapfile -t git_cached < "$git_cache_file" 2>/dev/null
  git_cached_ts="${git_cached[0]:-}"
  if [[ "$git_cached_ts" =~ ^[0-9]+$ ]] && [ "$now" -ge "$git_cached_ts" ] && [ $(( now - git_cached_ts )) -lt "$git_cache_ttl" ]; then
    display_cwd="${git_cached[1]:-$cwd}"
    git_branch="${git_cached[2]:-}"
    git_dirty="${git_cached[3]:-0}"
    git_cache_hit=1
  fi
fi

if [ -z "$git_cache_hit" ]; then
  git_toplevel=$(git -C "$cwd" --no-optional-locks rev-parse --show-toplevel 2>/dev/null)
  git_common_dir=$(git -C "$cwd" --no-optional-locks rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  if [ -n "$git_toplevel" ] && [ "$(basename "$git_common_dir")" = ".git" ]; then
    main_root=$(dirname "$git_common_dir")
    [ "$git_toplevel" != "$main_root" ] && display_cwd="$main_root${cwd#"$git_toplevel"}"
  fi

  git_branch=$(git -C "$cwd" --no-optional-locks symbolic-ref --short -q HEAD 2>/dev/null)
  if [ -z "$git_branch" ]; then
    git_branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  fi
  if [ -n "$git_branch" ] && [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
    git_dirty="1"
  fi

  if [[ "$git_cache_ttl" =~ ^[0-9]+$ ]] && [ "$git_cache_ttl" -gt 0 ] && mkdir -p "$cache_dir" 2>/dev/null; then
    tmp_git_cache="$git_cache_file.$$.$RANDOM"
    if printf '%s\n%s\n%s\n%s\n' "$now" "$display_cwd" "$git_branch" "$git_dirty" > "$tmp_git_cache" 2>/dev/null; then
      mv -f "$tmp_git_cache" "$git_cache_file" 2>/dev/null || rm -f "$tmp_git_cache" 2>/dev/null
    else
      rm -f "$tmp_git_cache" 2>/dev/null
    fi
  fi
fi

short_cwd="${display_cwd#$HOME/projects}"
[ -z "$short_cwd" ] && short_cwd="/"

printf '\033[01;34m%s\033[00m' "$short_cwd"

if [ -z "$git_branch" ]; then
  git_branch="$vcs_branch"
fi

if [ -n "$git_branch" ]; then
  printf ' \033[35m%s\033[00m' "$git_branch"
  if [ "$git_dirty" = "1" ] || [ "$vcs_dirty" = "true" ]; then
    printf '\033[33m*\033[00m'
  fi
fi

# 3. Модель сессии и текущий режим работы (plan/auto/accept-edits/default)
if [ -n "$model" ] && [ -n "$effort" ]; then
  # Не дублируем effort, если он уже включен в display_name (например, "Gemini 3.8 Flash (High)")
  if ! [[ "$model" =~ \([a-zA-Z0-9_+\ -]+\)$ ]]; then
    model="$model ($effort)"
  fi
fi

[ -z "$mode" ] && mode="default"
case "$mode" in
  plan)
    mode_color='\033[36m'
    ;;
  auto)
    mode_color='\033[32m'
    ;;
  accept-edits|acceptEdits)
    mode="accept-edits"
    mode_color='\033[33m'
    ;;
  *)
    mode_color='\033[02m'
    ;;
esac

if [ -n "$model" ]; then
  printf " \\033[02m| %s\\033[00m ${mode_color}[%s]\\033[00m" "$model" "$mode"
else
  printf " \\033[02m|\\033[00m ${mode_color}[%s]\\033[00m" "$mode"
fi

# 4. Размер израсходованного контекста (входные токены последнего шага)
if [ -n "$conv_id" ] && { [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; }; then
  candidate="$HOME/.gemini/antigravity-cli/brain/$conv_id/.system_generated/logs/transcript.jsonl"
  [ -f "$candidate" ] && transcript_path="$candidate"
fi

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

# 5. Лимиты 5-часового и недельного окна со временем сброса.
# Каждый процесс agy кэширует снимок .quota в памяти и может долго слать устаревшие
# значения (даже после наступления reset_time). Мержим .quota всех сессий одного
# аккаунта через общий кэш: побеждает более поздний reset_time, а в том же окне —
# меньший remaining_fraction.
model_lower=$(printf '%s' "$model" | tr '[:upper:]' '[:lower:]')
q_prefix=""
if [ -n "$model_lower" ]; then
  q_prefix="gemini"
  if [[ "$model_lower" =~ claude|gpt|openai|anthropic|3p ]]; then
    q_prefix="3p"
  fi
fi

five_hour="$rl_5h_pct"
five_hour_epoch="$rl_5h_epoch"
seven_day="$rl_7d_pct"
seven_day_epoch="$rl_7d_epoch"

if [ "$has_quota" = "1" ]; then
  if [ -n "$email" ] || [ -n "$plan_tier" ]; then
    acct_key=$(hash_key "${email}"$'\n'"${plan_tier}")
  else
    acct_key="default"
  fi
  cache_file="$cache_dir/quota-$acct_key.json"
  lock_file="$cache_dir/quota-$acct_key.lock"
  cache_writable=""
  mkdir -p "$cache_dir" 2>/dev/null && cache_writable=1

  q_out=()
  merge_quota() {
    local raw_cache=""
    [ -r "$cache_file" ] && raw_cache=$(<"$cache_file")

    mapfile -t q_out < <(printf '%s' "$input" | jq -r \
      --argjson now "$now" \
      --arg p "$q_prefix" \
      --arg raw_cache "$raw_cache" \
      "$JQ_PARSE_TS"'
      def norm_bucket:
        if (type == "object") and (.remaining_fraction != null) then
          (if .reset_time != null then (.reset_time | parse_ts($now))
           elif .reset_epoch != null then (.reset_epoch | parse_ts($now))
           elif .reset_in_seconds != null then ($now + (.reset_in_seconds | tonumber | floor))
           else null end) as $ep
          | {
              remaining_fraction: (.remaining_fraction | tonumber),
              reset_epoch: $ep
            }
        else null end;

      def pick_fresher($inc; $old):
        if $old == null then $inc
        elif $inc == null then $old
        elif ($inc.reset_epoch != null) and ($old.reset_epoch != null) then
          if $inc.reset_epoch > ($old.reset_epoch + 2) then $inc
          elif $old.reset_epoch > ($inc.reset_epoch + 2) then $old
          elif $inc.remaining_fraction < $old.remaining_fraction then $inc
          else $old end
        elif $inc.reset_epoch != null then $inc
        elif $old.reset_epoch != null then $old
        elif $inc.remaining_fraction < $old.remaining_fraction then $inc
        else $old end;

      (try ($raw_cache | fromjson | if type == "object" then . else {} end) catch {}) as $cached_raw
      | ($cached_raw | with_entries(.value |= norm_bucket | select(.value != null))) as $cached
      | ((.quota // .quotas // {}) | with_entries(.value |= norm_bucket | select(.value != null))) as $incoming
      | (($cached | keys_unsorted) + ($incoming | keys_unsorted) | unique) as $keys
      | (reduce $keys[] as $k ({};
          pick_fresher($incoming[$k]; $cached[$k]) as $best
          | if $best != null then .[$k] = $best else . end
        )) as $merged
      | (if $p != "" then $merged[$p + "-5h"] else ($merged["gemini-5h"] // $merged["3p-5h"]) end) as $b5
      | (if $p != "" then $merged[$p + "-weekly"] else ($merged["gemini-weekly"] // $merged["3p-weekly"]) end) as $b7
      | [
          (if ($merged != $cached) or ($raw_cache == "") or ($cached_raw != $cached) then "1" else "0" end),
          ($merged | tojson),
          (if $b5 != null then (((1 - $b5.remaining_fraction) * 100) | tostring) else "" end),
          (if ($b5 != null) and ($b5.reset_epoch != null) then ($b5.reset_epoch | tostring) else "" end),
          (if $b7 != null then (((1 - $b7.remaining_fraction) * 100) | tostring) else "" end),
          (if ($b7 != null) and ($b7.reset_epoch != null) then ($b7.reset_epoch | tostring) else "" end)
        ] | .[]
    ' 2>/dev/null)

    if [ "${q_out[0]:-0}" = "1" ] && [ -n "${q_out[1]:-}" ] && [ -n "$cache_writable" ]; then
      local tmp_cache="$cache_file.$$.$RANDOM"
      if printf '%s\n' "${q_out[1]}" > "$tmp_cache" 2>/dev/null; then
        mv -f "$tmp_cache" "$cache_file" 2>/dev/null || rm -f "$tmp_cache" 2>/dev/null
      else
        rm -f "$tmp_cache" 2>/dev/null
      fi
    fi
  }

  if [ -n "$cache_writable" ] && command -v flock >/dev/null 2>&1 && exec 9>"$lock_file" 2>/dev/null; then
    if flock -w 0.5 9 2>/dev/null; then
      merge_quota
      flock -u 9 2>/dev/null
    else
      merge_quota
    fi
    exec 9>&- 2>/dev/null
  else
    merge_quota
  fi

  [ -z "$five_hour" ] && five_hour="${q_out[2]:-}"
  [ -z "$five_hour_epoch" ] && five_hour_epoch="${q_out[3]:-}"
  [ -z "$seven_day" ] && seven_day="${q_out[4]:-}"
  [ -z "$seven_day_epoch" ] && seven_day_epoch="${q_out[5]:-}"
fi

limit_color() {
  local pct="$1"
  awk -v p="$pct" 'BEGIN {
    if (p >= 90) printf "\\033[31m";
    else if (p >= 70) printf "\\033[33m";
    else printf "\\033[02m";
  }'
}

print_limit() {
  local label="$1" pct="$2" epoch="$3" fmt="$4"
  [ -z "$pct" ] && return
  local until=""
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

print_limit "5ч" "$five_hour" "$five_hour_epoch" "+%H:%M"
print_limit "7д" "$seven_day" "$seven_day_epoch" "+%d.%m %H:%M"
