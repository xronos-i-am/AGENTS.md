import { Plugin } from "@opencode/plugin/tui"
import { createSignal } from "solid-js"

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
          {branch() ? ` | ⎇  ${branch()}` : ""}
        </text>
        {branch() && dirty() ? <text fg="#eab308">{" *"}</text> : ""}
      </box>
    )

    // --- строка 2: агент · модель · контекст · токены ---
    const interval = setInterval(() => {
      refreshGit()
      const id = currentSessionID()
      if (id) {
        void context.data.session.sync(id)
        void context.data.session.message.sync(id)
      }
    }, 2000)
    await context.data.location.model.sync(location)
    await context.data.location.agent.sync(location)

    const capitalize = (s) => s.charAt(0).toUpperCase() + s.slice(1)

    const agentText = () => {
      try {
        const id = currentSessionID()
        const messages = id
          ? (context.data.session.message.list(id) ?? [])
          : []
        for (let i = messages.length - 1; i >= 0; i--) {
          const info = messages[i]?.info ?? messages[i]
          if (info?.role === "user" && info.agent) return capitalize(String(info.agent))
        }
        const agents = context.data.location.agent.list(location) ?? []
        const primary = agents.find((a) => a.mode === "primary") ?? agents[0]
        return primary?.name ? capitalize(String(primary.name)) : undefined
      } catch {
        return undefined
      }
    }

    const modelText = () => {
      const model = context.ui.model.current()
      if (!model) return undefined
      const m = model
      const name = m.name ?? m.modelID ?? m.id
      if (!name) return undefined
      const provider = typeof m.providerID === "string" ? m.providerID.split("-")[0] : undefined
      const label = provider ? `${provider}/${name}` : name
      return m.variant ? `${label} (${m.variant})` : label
    }

    const contextText = () => {
      const id = currentSessionID()
      if (!id) return undefined
      const session = context.data.session.get(id)
      const t = session?.tokens
      if (!t) return undefined
      const used =
        (t.input ?? 0) + (t.output ?? 0) + (t.reasoning ?? 0) + (t.cache?.read ?? 0)
      if (!used) return undefined

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
      return limit ? `ctx ${compact(used)} (${Math.round((used / limit) * 100)}%)` : `ctx ${compact(used)}`
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

    const lineTwo = () => (
      <box flexDirection="row">
        {agentText() ? <text fg="#ffffff">{agentText()}</text> : ""}
        <text fg={context.theme.text.muted}>
          {[modelText(), contextText(), tokensText()].filter(Boolean).length > 0
            ? (agentText() ? " · " : "") +
              [modelText(), contextText(), tokensText()].filter(Boolean).join(" · ")
            : ""}
        </text>
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
