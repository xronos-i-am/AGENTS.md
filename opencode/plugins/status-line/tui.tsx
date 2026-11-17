import { Plugin } from "@opencode/plugin/tui"
import { createSignal, For } from "solid-js"

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

function twoDigits(value: number) {
  return String(value).padStart(2, "0")
}

// 5-часовое окно заканчивается в тот же или следующий день, ему хватает времени.
// Недельное и месячное показываем с датой, как в статуслайнах agy и Claude Code.
function formatReset(ms: number, withDate: boolean) {
  const date = new Date(ms)
  const time = `${twoDigits(date.getHours())}:${twoDigits(date.getMinutes())}`
  if (!withDate) return time
  return `${twoDigits(date.getDate())}.${twoDigits(date.getMonth() + 1)} ${time}`
}

function capitalize(value: string) {
  return value.charAt(0).toUpperCase() + value.slice(1)
}

type Segment = { text: string; fg: string }[]

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

    const dirSegment = (): Segment => {
      const chunks: Segment = [{ text: dirText(), fg: "#3b82f6" }]
      if (branch()) {
        chunks.push({ text: ` ⎇  ${branch()}`, fg: context.theme.text.muted })
      }
      if (branch() && dirty()) chunks.push({ text: " *", fg: "#eab308" })
      return chunks
    }

    const renderChunks = (chunks: Segment) => (
      <For each={chunks}>
        {(chunk) => <text fg={chunk.fg}>{chunk.text}</text>}
      </For>
    )

    const line1 = () => <box flexDirection="row">{renderChunks(dirSegment())}</box>

    // --- лимиты OpenCode Go из Console ---
    // Проценты и время сброса приходят из /api/experimental/usage/limits.
    // Данные общие для location, поэтому синкаем их не чаще раза в минуту,
    // а читаем из кэша на каждом тике интерфейса.
    const [usageInfo, setUsageInfo] = createSignal<any>()
    let lastUsageSync = 0

    const refreshUsage = () => {
      const providerID = context.ui.model.current()?.providerID
      if (providerID !== "opencode-go" || !location) {
        setUsageInfo(undefined)
        return
      }
      const usage = context.data.location.usage
      if (!usage) return
      if (Date.now() - lastUsageSync >= 60_000) {
        lastUsageSync = Date.now()
        void Promise.resolve(usage.sync(location)).catch(() => {})
      }
      setUsageInfo(usage.limits(location))
    }
    refreshUsage()

    const limitColor = (pct: number) =>
      pct >= 90
        ? "#ef4444"
        : pct >= 70
          ? "#eab308"
          : context.theme.text.muted

    const goLimitParts = () => {
      if (context.ui.model.current()?.providerID !== "opencode-go") return []
      const go = usageInfo()?.go
      if (!go) return []

      return [
        { label: "5ч", meter: go.rolling, withDate: false },
        { label: "7д", meter: go.weekly, withDate: true },
      ]
        .filter(({ meter }) => meter)
        .map(({ label, meter, withDate }) => {
          const pct = Math.round(meter.percent)
          return {
            text: `${label}:${pct}% до ${formatReset(meter.resetsAt, withDate)}`,
            fg: limitColor(pct),
          }
        })
    }

    // --- обновление раз в 2 секунды; лимиты синкаем не чаще раза в минуту ---
    const interval = setInterval(() => {
      refreshGit()
      refreshUsage()
      const id = currentSessionID()
      if (id) {
        void context.data.session.sync(id)
        void context.data.session.message.sync(id)
      }
    }, 2000)
    await context.data.location.model.sync(location)

    const currentModel = () => {
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
      return { current, found }
    }

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

      const { found } = currentModel()
      const limit = found?.limit?.context
      const text = limit
        ? `ctx:${compact(used)} (${Math.round((used / limit) * 100)}%)`
        : `ctx:${compact(used)}`
      const fg =
        used >= 300_000
          ? "#ef4444"
          : used >= 150_000
            ? "#eab308"
            : context.theme.text.muted
      return { text, fg }
    }

    // --- текущий агент и модель ---
    const agentText = () =>
      (context.ui as any).agent?.current?.()?.id as string | undefined

    const agentColor = (agent: string) =>
      agent === "plan"
        ? "#22d3ee"
        : agent === "build"
          ? "#22c55e"
          : context.theme.text.muted

    const modelText = () => {
      const { current, found } = currentModel()
      if (!current?.modelID) return undefined
      const name = found?.name ?? current.modelID
      const variant = current.variant ? ` (${capitalize(current.variant)})` : ""
      return { text: `${name}${variant}`, fg: "#ffffff" }
    }

    // Сегменты строки: модель с агентом не разрываем разделителем,
    // как «Claude Sonnet 5.5 (Low) [auto]» в статуслайне agy.
    const lineSegments = () => {
      const segments: Segment[] = []
      const title: Segment = []
      const model = modelText()
      if (model) title.push(model)
      const agent = agentText()
      if (agent) {
        title.push({
          text: `${model ? " " : ""}[${agent}]`,
          fg: agentColor(agent),
        })
      }
      if (title.length) segments.push(title)

      const ctx = contextText()
      if (ctx) segments.push([ctx])

      for (const limit of goLimitParts()) segments.push([limit])
      return segments
    }

    // Вся строка — один ряд: путь с веткой, модель с агентом, контекст и лимиты.
    const allSegments = () => [dirSegment(), ...lineSegments()]

    const line = () => (
      <box flexDirection="row" width="100%" justifyContent="flex-start">
        <For each={allSegments()}>
          {(segment, index) => (
            <>
              {index() > 0 ? (
                <text fg={context.theme.text.muted}>{" | "}</text>
              ) : null}
              {renderChunks(segment)}
            </>
          )}
        </For>
      </box>
    )

    const dispose = [
      context.ui.slot({ replace: "prompt.footer", render: line }),
      context.ui.slot({ append: "home.footer.status", render: line1 }),
    ]
    return () => {
      clearInterval(interval)
      dispose.forEach((d) => d?.())
    }
  },
})
