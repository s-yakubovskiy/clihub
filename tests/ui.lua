-- Run: nvim --headless -u NONE -i NONE -l tests/ui.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local hub = require("clihub")
local custom = vim.deepcopy(require("clihub.registry").bundled.rg)
custom.description = "Custom tool from Neovim configuration"
hub.setup({ root = vim.fn.tempname() .. "-clihub-ui", path = "none", registry = { localtool = custom } })
local original_status = hub.status
hub.status = function(id)
	local state = original_status(id)
	if id == "rg" then
		state.installed, state.available = "15.0.0", "16.0.0"
	end
	if id == "uv" then
		state.installed, state.pin = "0.13.0", "0.13.0"
	end
	return state
end
vim.o.columns, vim.o.lines = 110, 40
require("clihub.ui").open()
local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
local function text()
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end
local function press(lhs)
	local mapping = vim.fn.maparg(lhs, "n", false, true)
	assert(type(mapping.callback) == "function", "Missing mapping: " .. lhs)
	mapping.callback()
end
local config = vim.api.nvim_win_get_config(win)
assert(config.relative == "editor" and config.border, "Expected a bordered floating window")
assert(config.width <= vim.o.columns - 2 and config.height <= vim.o.lines - 2)
assert(text():find("update all installed", 1, true), "Update-all hint missing")
local saved_command, command = hub.command
hub.command = function(args)
	command = args
end
press("U")
assert(vim.deep_equal(command, { "update" }), "U did not request a bulk update")
hub.command = saved_command
assert(text():find("Needs attention", 1, true) and text():find("Installed", 1, true))
assert(text():find("localtool", 1, true), "Local registry addition missing from UI")
assert(#vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().CliHubUI, 0, -1, {}) > 10)
local before = vim.api.nvim_win_get_cursor(win)[1]
press("<CR>")
assert(text():find("Source", 1, true) and text():find("github.com/BurntSushi/ripgrep", 1, true))
hub.changed()
assert(vim.api.nvim_win_get_cursor(win)[1] == before, "Refresh moved the selected package")
press("2")
assert(not text():find("localtool", 1, true), "Installed filter included an absent tool")
assert(text():find("uv", 1, true) and text():find("rg", 1, true))
press("3")
assert(text():find("rg", 1, true) and not text():find("pinned", 1, true), "Update filter is incorrect")
press("<Tab>")
assert(text():find("localtool", 1, true), "Tab did not cycle to All")
vim.o.columns, vim.o.lines = 46, 18
vim.api.nvim_exec_autocmds("VimResized", {})
config = vim.api.nvim_win_get_config(win)
assert(config.width <= 44 and config.height <= 16, "Float did not resize")
for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
	assert(vim.fn.strdisplaywidth(line) <= config.width, "Text overflowed the float")
end
press("q")
assert(not vim.api.nvim_win_is_valid(win), "Close mapping did not close the float")
require("clihub.ui").open()
assert(vim.bo.filetype == "clihub", "Float could not reopen")
assert(not vim.uv.fs_stat(hub.config.root), "Opening the UI created an installation root")
hub.status = original_status
print("CliHub UI: float, highlighting, filters, local registry, details, selection, resize, close/reopen passed")
