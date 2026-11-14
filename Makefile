# Установка общих правил агента и статуслайнов для всех сред хоста (Claude, Antigravity, OpenCode)

HOME_DIR := $(HOME)
# Корень Claude для apm install -g: ~/.claude → профиль, ~/.claude/skills и rules — симлинки в shared,
# а сквозь симлинк apm не пишет (Unsafe skill destination), поэтому ставит прямо в реальный каталог
APM_GLOBAL_ENV := CLAUDE_CONFIG_DIR=$(HOME_DIR)/.claude-profiles/shared
APM_TARGETS := claude,opencode,gemini

.PHONY: install uninstall

install:
	@command -v apm >/dev/null || { echo "make install: нет apm в PATH — установите apm" >&2; exit 1; }
	@# 1. Глобальная установка APM-пакетов из ~/.apm/apm.yml. Версии скиллов там двигают их релизы
	@# (make release в репозитории скилла), поэтому здесь они не закрепляются; без файла ставится
	@# только пакет этого репозитория, а скиллы приходят своим make install
	mkdir -p $(HOME_DIR)/.apm
	cd $(HOME_DIR)/.apm && { [ -f apm.yml ] || $(APM_GLOBAL_ENV) apm install -g --target $(APM_TARGETS) xronos-i-am/AGENTS.md#master; }
	cd $(HOME_DIR)/.apm && $(APM_GLOBAL_ENV) apm install -g --target $(APM_TARGETS)
	@# master не двигается сам: ref закреплён в apm.lock.yaml на коммите прошлой установки
	cd $(HOME_DIR)/.apm && $(APM_GLOBAL_ENV) apm update -g --yes --target $(APM_TARGETS) xronos-i-am/AGENTS.md
	@# Эталон настроек Antigravity: источник правды — системный файл, в репозиторий идёт копия без личных путей
	$(CURDIR)/.gemini/sync-antigravity-settings.sh
	@# 2. Настройки и правила для Antigravity и OpenCode
	mkdir -p $(HOME_DIR)/.gemini/config
	@printf '{\n  "entries": [\n    {\n      "path": "%s/.agents/skills"\n    }\n  ]\n}\n' "$(HOME_DIR)" > $(CURDIR)/.gemini/config/skills.json
	ln -sf $(CURDIR)/.gemini/config/skills.json $(HOME_DIR)/.gemini/config/skills.json
	ln -sf $(CURDIR)/AGENTS.md $(HOME_DIR)/.gemini/AGENTS.md
	ln -sf $(CURDIR)/AGENTS.md $(HOME_DIR)/.config/opencode/AGENTS.md
	@# 3. Статуслайны для всех сред
	chmod +x $(CURDIR)/.claude/statusline-command.sh $(CURDIR)/.gemini/statusline-agy.sh 2>/dev/null || true
	ln -sf $(CURDIR)/.claude/statusline-command.sh $(HOME_DIR)/.claude/statusline-command.sh
	ln -sf $(CURDIR)/.gemini/statusline-agy.sh $(HOME_DIR)/.gemini/statusline-agy.sh
	mkdir -p $(HOME_DIR)/.config/opencode/plugins
	ln -sfn $(CURDIR)/opencode/plugins/status-line $(HOME_DIR)/.config/opencode/plugins/status-line
	@# 4. Настройки Claude Code
	ln -sf $(CURDIR)/.claude/settings.json $(HOME_DIR)/.claude/settings.json
	@echo "Установка завершена: правила, настройки и статуслайны активны во всех проектах."

uninstall:
	rm -f $(HOME_DIR)/.gemini/config/skills.json
	rm -f $(HOME_DIR)/.gemini/AGENTS.md
	rm -f $(HOME_DIR)/.config/opencode/AGENTS.md
	rm -f $(HOME_DIR)/.claude/statusline-command.sh
	rm -f $(HOME_DIR)/.gemini/statusline-agy.sh
	rm -f $(HOME_DIR)/.claude/settings.json
	rm -f $(HOME_DIR)/.config/opencode/plugins/status-line
	@echo "Симлинки удалены. Для удаления из APM выполните: apm deps remove agents-md -g"
