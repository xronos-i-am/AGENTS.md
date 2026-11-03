# Установка общих правил агента и статуслайнов для всех сред хоста (Claude, Antigravity, OpenCode)

HOME_DIR := $(HOME)

.PHONY: install uninstall

install:
	@command -v apm >/dev/null || { echo "make install: нет apm в PATH — установите apm" >&2; exit 1; }
	@# 1. Глобальная установка APM-пакета с правилами
	apm install -g $(CURDIR) --target claude,opencode,gemini
	@# 2. Симлинки общих правил для Antigravity и OpenCode
	ln -sf $(HOME_DIR)/.claude/rules/agents.md $(HOME_DIR)/.gemini/AGENTS.md
	ln -sf $(HOME_DIR)/.claude/rules/agents.md $(HOME_DIR)/.config/opencode/AGENTS.md
	@# 3. Статуслайны для всех сред
	chmod +x $(CURDIR)/statusline-command.sh $(CURDIR)/statusline-agy.sh 2>/dev/null || true
	ln -sf $(CURDIR)/statusline-command.sh $(HOME_DIR)/.claude/statusline-command.sh
	ln -sf $(CURDIR)/statusline-agy.sh $(HOME_DIR)/.gemini/statusline-agy.sh
	mkdir -p $(HOME_DIR)/.config/opencode/plugins
	ln -sfn $(CURDIR)/opencode/plugins/status-line $(HOME_DIR)/.config/opencode/plugins/status-line
	@echo "Установка завершена: правила и статуслайны активны во всех проектах."

uninstall:
	rm -f $(HOME_DIR)/.gemini/AGENTS.md
	rm -f $(HOME_DIR)/.config/opencode/AGENTS.md
	rm -f $(HOME_DIR)/.claude/statusline-command.sh
	rm -f $(HOME_DIR)/.gemini/statusline-agy.sh
	rm -f $(HOME_DIR)/.config/opencode/plugins/status-line
	@echo "Симлинки удалены. Для удаления из APM выполните: apm deps remove agents-md -g"
