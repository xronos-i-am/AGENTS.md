import { Plugin } from "@opencode/plugin/tui"
import { createSignal } from "solid-js"
import { spawnSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

function compact(value: number) {
  return Intl.NumberFormat("en-US", {
    notation: value >= 10_000 ? "compact" : "standard",
    maximumFractionDigits: value >= 10_000 ? 1 : 0,
  }).format(value)
}

function gitStatus(dir) {
  try {
    const { spawnSync } = require("node:child_process")
    const res = spawnSync("git", ["status", "--porcelain", "--branch"], {
      cwd: dir,
      timeout: 5000,
    })
    if (res.status !== 0) return { branch: undefined, dirty: false }
    const lines = res.stdout.toString().split("\n")
    const head = (lines[0] ?? "").replace(/^## /, "")
    const name = head.startsWith("No commits yet on ")
      ? head.slice("No commits yet on ".length)
      : head.split("...")[0]
    return {
      branch: name || undefined,
      dirty: lines.slice(1).some((l) => l.trim().length > 0),
    }
  } catch {
    return { branch: undefined, dirty: false }
  }
}

// --- 5-часовое окно расхода ---
const PROVIDER_CALIBRATIONS = {
  "kimi-code-plan-global": {
    cache_weight: 0.023083,
    output_weight: 6.844187,
    quota_5h_weighted: 1_013_043,
  },
  // Добавьте другие провайдеры по мере необходимости
}

function getWindowUsage(providerID) {
  const calibration = PROVIDER_CALIBRATIONS[providerID]
  if (!calibration) return undefined

  try {
    const dbPath = join(homedir(), ".local/share/opencode/opencode.db")
    const script = `
import sqlite3
import time
import json

db = sqlite3.connect("file:${dbPath}?mode=ro", uri=True)
now = time.time()
now_ms = int(now * 1000)
five_hours_ms = 5 * 3600 * 1000

# Находим все сессии провайдера, отсортированные по времени создания (от старых к новым)
sessions = db.execute(
    """
    SELECT time_created, time_updated, tokens_input, tokens_output, tokens_cache_read, tokens_cache_write
    FROM session_v2
    WHERE json_extract(model, '$.providerID') = ?
    ORDER BY time_created ASC
    """,
    ("${providerID}",),
).fetchall()

if not sessions:
    print(json.dumps({"pct": 0, "reset": None, "weighted": 0, "quota": ${calibration.quota_5h_weighted}}))
    db.close()
    exit()

# Находим текущее активное окно:
# Идём от самой старой сессии вперёд, разбивая на окна по 5 часов
window_start_ms = sessions[0][0]  # Начало первого окна
window_end_ms = window_start_ms + five_hours_ms
input_t = 0
output_t = 0
cache_read_t = 0
cache_write_t = 0

for time_created, time_updated, tp_in, tp_out, tp_cread, tp_cwrite in sessions:
    # Если сессия началась после окончания текущего окна — начинаем новое окно
    if time_created >= window_end_ms:
        window_start_ms = time_created
        window_end_ms = window_start_ms + five_hours_ms
        input_t = 0
        output_t = 0
        cache_read_t = 0
        cache_write_t = 0
    
    # Если сессия в текущем окне — суммируем расход
    if time_created >= window_start_ms and time_created < window_end_ms:
        input_t += tp_in or 0
        output_t += tp_out or 0
        cache_read_t += tp_cread or 0
        cache_write_t += tp_cwrite or 0

# Проверяем, активно ли текущее окно
if now_ms > window_end_ms:
    # Окно истекло, проверяем, есть ли сессии после окончания окна
    has_sessions_after_window = any(s[0] >= window_end_ms for s in sessions)
    if not has_sessions_after_window:
        # Нет сессий после окна — показываем 0%
        print(json.dumps({"pct": 0, "reset": None, "weighted": 0, "quota": ${calibration.quota_5h_weighted}}))
        db.close()
        exit()
    else:
        # Есть сессии после окна — начинаем новое окно с первой такой сессии
        for time_created, time_updated, tp_in, tp_out, tp_cread, tp_cwrite in sessions:
            if time_created >= window_end_ms:
                window_start_ms = time_created
                window_end_ms = window_start_ms + five_hours_ms
                input_t = tp_in or 0
                output_t = tp_out or 0
                cache_read_t = tp_cread or 0
                cache_write_t = tp_cwrite or 0
                break
        
        # Суммируем расход для нового окна
        for time_created, time_updated, tp_in, tp_out, tp_cread, tp_cwrite in sessions:
            if time_created >= window_start_ms and time_created < window_end_ms:
                input_t += tp_in or 0
                output_t += tp_out or 0
                cache_read_t += tp_cread or 0
                cache_write_t += tp_cwrite or 0

# Текущее окно активно
reset_time_ms = window_end_ms

weighted = input_t + ${calibration.cache_weight} * (cache_read_t + cache_write_t) + ${calibration.output_weight} * output_t
pct = weighted / ${calibration.quota_5h_weighted} * 100

print(json.dumps({
    "pct": round(pct, 1),
    "reset": time.strftime("%H:%M", time.localtime(reset_time_ms / 1000)),
    "weighted": int(weighted),
    "quota": ${calibration.quota_5h_weighted},
}))
db.close()

print(json.dumps({
    "pct": round(pct, 1),
    "reset": time.strftime("%H:%M", time.localtime(reset_time_ms / 1000)),
    "weighted": int(weighted),
    "quota": ${calibration.quota_5h_weighted},
}))
db.close()
`
    const result = spawnSync("python3", ["-c", script], {
      encoding: "utf-8",
      timeout: 5000,
    })
    if (result.status !== 0) return undefined
    return JSON.parse(result.stdout.trim())
  } catch {
    return undefined
  }
}

export default Plugin.define({
  id: "status-line",
  async setup(context) {
    const location = context.location ?? context.data.location.default()
    await context.data.location.vcs.sync(location)

    const currentSessionID = () => {
      const route = context.ui.router.current()
      return route?.type === "session" ? route.sessionID : undefined
    }

    // --- git: ветка + незакоммиченные правки ---
    const [branch, setBranch] = createSignal()
    const [dirty, setDirty] = createSignal(false)

    const refreshGit = () => {
      const dir = location?.directory
      if (!dir) return
      const status = gitStatus(dir)
      setBranch(status.branch)
      setDirty(status.dirty)
    }
    refreshGit()

    // --- строка 1: короткий путь + ветка (+ жёлтая * при правках) ---
    const dirText = () =>
      context.ui.format.path(location?.directory ?? "").replace(/^~\/projects\//, "")

    const line1 = () => (
      <box flexDirection="row">
        <text fg="#3b82f6">
          {dirText()}
        </text>
        <text fg={context.theme.text.muted}>
          {branch() ? ` | ⎇  ${branch()}` : null}
        </text>
        {branch() && dirty() ? <text fg="#eab308">{" *"}</text> : null}
      </box>
    )

    // --- строка 2: агент · модель · контекст · токены ---
    const interval = setInterval(() => {
      refreshGit()
      refreshWindowUsage()
      const id = currentSessionID()
      if (id) {
        void context.data.session.sync(id)
        void context.data.session.message.sync(id)
      }
    }, 2000)
    await context.data.location.model.sync(location)
    // длина диалога = реальный размер контекста на последнем ходе модели
    // (из токенов последнего assistant-сообщения, не накопительное)
    let lastContextUsed: number | undefined
    const contextText = () => {
      const id = currentSessionID()
      if (!id) {
        lastContextUsed = undefined
        return undefined
      }

      let used: number | undefined
      const messages = context.data.session.message.list(id) ?? []
      const last = messages.findLast((m) => (m.info ?? m)?.type === "assistant")
      const t = (last?.info ?? last)?.tokens
      if (t) {
        used =
          (t.input ?? 0) +
          (t.cache?.read ?? 0) +
          (t.cache?.write ?? 0) +
          (t.output ?? 0) +
          (t.reasoning ?? 0)
      }
      if (used) {
        lastContextUsed = used
      } else {
        // сообщений ещё нет в памяти — показываем последнее честное значение
        used = lastContextUsed
        if (!used) return undefined
      }

      const current = context.ui.model.current()
      const models = context.data.location.model.list(location) ?? []
      const flat = models.flatMap((entry) =>
        entry?.models
          ? Object.values(entry.models).map((m) => ({
              ...m,
              providerID: entry.providerID ?? entry.id,
            }))
          : [entry],
      )
      const found = flat.find(
        (m) =>
          (m.id === current?.modelID || m.modelID === current?.modelID) &&
          (!current?.providerID || m.providerID === current.providerID),
      )
      const limit = found?.limit?.context
      const text = limit
        ? `ctx ${compact(used)} (${Math.round((used / limit) * 100)}%)`
        : `ctx ${compact(used)}`
      const fg =
        used >= 300_000
          ? "#ef4444"
          : used >= 150_000
            ? "#eab308"
            : context.theme.text.muted
      return { text, fg }
    }

    const tokensText = () => {
      const id = currentSessionID()
      if (!id) return undefined
      const session = context.data.session.get(id)
      const t = session?.tokens
      const cost = session?.cost ?? context.data.session.cost(id)
      if (!t && !cost) return undefined
      const parts = []
      if (t) {
        parts.push(`↑${compact(t.input ?? 0)}`)
        parts.push(`↓${compact((t.output ?? 0) + (t.reasoning ?? 0))}`)
        const cacheRead = t.cache?.read ?? 0
        if (cacheRead > 0) parts.push(`cache ${compact(cacheRead)}`)
      }
      if (cost) parts.push(`$${cost.toFixed(4)}`)
      return parts.join(" ")
    }

    // --- текущий агент ---
    const agentText = () =>
      (context.ui as any).agent?.current?.()?.id as string | undefined

    // --- 5-часовое окно ---
    const [windowUsage, setWindowUsage] = createSignal()
    const refreshWindowUsage = () => {
      const current = context.ui.model.current()
      if (!current?.providerID) {
        setWindowUsage(undefined)
        return
      }
      const usage = getWindowUsage(current.providerID)
      setWindowUsage(usage)
    }
    refreshWindowUsage()

    const windowText = () => {
      const usage = windowUsage()
      if (!usage) return undefined
      const { pct, reset } = usage
      if (reset === null) return undefined // Окно ещё не открылось
      const fg =
        pct >= 90
          ? "#ef4444"
          : pct >= 70
            ? "#eab308"
            : context.theme.text.muted
      return { text: `5h ${pct}% → ${reset}`, fg }
    }

    const lineTwo = () => (
      <box flexDirection="row">
        {agentText() ? <text fg="#ffffff">{agentText()}</text> : null}
        <text fg={context.theme.text.muted}>{agentText() ? " · " : null}</text>
        {contextText() ? (
          <text fg={contextText().fg}>{contextText().text}</text>
        ) : null}
        <text fg={context.theme.text.muted}>
          {[contextText(), tokensText()].some(Boolean) && contextText()
            ? tokensText()
              ? " · "
              : null
            : null}
        </text>
        {tokensText() ? <text fg={context.theme.text.muted}>{tokensText()}</text> : null}
        {windowText() ? (
          <>
            <text fg={context.theme.text.muted}> · </text>
            <text fg={windowText().fg}>{windowText().text}</text>
          </>
        ) : null}
      </box>
    )

    const lines = () => (
      <box flexDirection="column" width="100%" alignItems="flex-end">
        {line1()}
        {lineTwo()}
      </box>
    )

    const dispose = [
      context.ui.slot({ replace: "prompt.footer", render: lines }),
      context.ui.slot({ append: "home.footer.status", render: line1 }),
    ]
    return () => {
      clearInterval(interval)
      dispose.forEach((d) => d?.())
    }
  },
})
