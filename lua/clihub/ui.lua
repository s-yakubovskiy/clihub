local M = {}
local buffer, window, rows, starts
local view, expanded = 1, {}
local namespace = vim.api.nvim_create_namespace("CliHubUI")

local function highlights()
	local groups = {
		Title = "IncSearch",
		Tab = "IncSearch",
		Muted = "Comment",
		Heading = "Title",
		Installed = "DiagnosticOk",
		Available = "DiagnosticHint",
		Update = "DiagnosticWarn",
		Error = "DiagnosticError",
		Progress = "DiagnosticInfo",
		Pin = "Special",
		Key = "Special",
		Border = "FloatBorder",
		Selection = "CursorLine",
	}
	for name, link in pairs(groups) do
		vim.api.nvim_set_hl(0, "CliHub" .. name, { link = link, default = true })
	end
	vim.api.nvim_set_hl(0, "CliHubName", { bold = true, default = true })
end

local function geometry()
	local width = math.max(1, math.min(104, vim.o.columns - 4))
	local height = math.max(1, math.min(40, math.floor((vim.o.lines - vim.o.cmdheight - 2) * 0.88)))
	return {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height - 2) / 2)),
		col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
		style = "minimal",
		border = "rounded",
		zindex = 50,
		footer = {
			{ width >= 60 and " i install  u install/update  U update all  q close " or " q close ", "CliHubMuted" },
		},
		footer_pos = "center",
	}
end

local function clip(text, width)
	text = tostring(text):gsub("[\r\n\t]", " ")
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end
	if width < 2 then
		return ""
	end
	local n = math.min(vim.fn.strchars(text), width - 1)
	while n > 0 and vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, n)) > width - 1 do
		n = n - 1
	end
	return vim.fn.strcharpart(text, 0, n) .. "…"
end

local function selected()
	if not window or not vim.api.nvim_win_is_valid(window) then
		return
	end
	return rows and rows[vim.api.nvim_win_get_cursor(window)[1]]
end

local function is_update(state)
	return state.installed and state.available and state.installed ~= state.available
end

local function source_label(source)
	if source.kind == "github" then
		return "github.com/" .. source.repo
	end
	if source.kind == "gitlab" then
		return source.api:gsub("/api/v4/?$", "") .. "/" .. source.project
	end
	return source.latest
end

function M.render()
	if not buffer or not vim.api.nvim_buf_is_valid(buffer) or not window or not vim.api.nvim_win_is_valid(window) then
		return
	end
	local hub = require("clihub")
	local previous, old_row = selected(), vim.api.nvim_win_get_cursor(window)[1]
	local width = vim.api.nvim_win_get_width(window)
	local lines, spans, positions = {}, {}, {}
	rows, starts = {}, {}
	local function line(chunks, id)
		local text = ""
		for _, chunk in ipairs(chunks or {}) do
			local part = clip(chunk[1], math.max(0, width - 2 - vim.fn.strdisplaywidth(text)))
			if #part > 0 and chunk[2] then
				spans[#spans + 1] = { #lines, #text, #text + #part, "CliHub" .. chunk[2] }
			end
			text = text .. part
		end
		lines[#lines + 1] = text
		rows[#lines] = id
		return #lines
	end
	local function centered(text, group)
		line({
			{ string.rep(" ", math.max(0, math.floor((width - vim.fn.strdisplaywidth(text)) / 2))) },
			{ text, group },
		})
	end
	local states, installed, updates = {}, 0, 0
	for _, id in ipairs(hub.list()) do
		local state = hub.status(id)
		states[#states + 1] = state
		if state.installed then
			installed = installed + 1
		end
		if is_update(state) then
			updates = updates + 1
		end
	end
	centered(" CliHub ", "Title")
	centered(installed .. " installed · " .. #states .. " tools in your registry", "Muted")
	line()
	local tabs = { { "  " } }
	for index, label in ipairs({ "All  " .. #states, "Installed  " .. installed, "Updates  " .. updates }) do
		tabs[#tabs + 1] = { " (" .. index .. ") " .. label .. " ", index == view and "Tab" or "Muted" }
		tabs[#tabs + 1] = { "  " }
	end
	line(tabs)
	line({ { "  " .. string.rep("─", math.max(0, width - 6)), "Border" } })
	local groups = {
		{ title = "In progress", color = "Progress", items = {} },
		{ title = "Needs attention", color = "Update", items = {} },
		{ title = "Installed", color = "Installed", items = {} },
		{ title = "Available", color = "Muted", items = {} },
	}
	for _, state in ipairs(states) do
		if view == 1 or (view == 2 and state.installed) or (view == 3 and is_update(state)) then
			local group = state.progress and 1 or (state.error or is_update(state)) and 2 or state.installed and 3 or 4
			table.insert(groups[group].items, state)
		end
	end
	local visible = 0
	for _, group in ipairs(groups) do
		if #group.items > 0 then
			line()
			line({ { "  " .. group.title, group.color }, { " (" .. #group.items .. ")", "Muted" } })
			for _, state in ipairs(group.items) do
				visible = visible + 1
				local icon, color, label = "○", "Available", "Ready to install"
				if state.progress then
					icon, color, label = "↻", "Progress", state.progress
				elseif state.error then
					icon, color, label = "!", "Error", "Failed · Enter for details"
				elseif is_update(state) then
					icon, color, label = "↑", "Update", state.installed .. " → " .. state.available
				elseif state.pin and state.installed then
					icon, color, label = "◆", "Pin", state.installed .. "  pinned"
				elseif state.installed then
					icon, color, label = "✓", "Installed", state.installed
				end
				local name = clip(state.id, math.max(4, math.min(18, math.floor(width / 3))))
				local padding = string.rep(" ", math.max(2, 20 - vim.fn.strdisplaywidth(name)))
				local row = line(
					{ { "  " }, { icon .. " ", color }, { name, "Name" }, { padding }, { label, color } },
					state.id
				)
				starts[#starts + 1], positions[state.id] = row, row
				line({ { "    " .. state.description, "Muted" } }, state.id)
				if expanded[state.id] then
					local function field(key, value, highlight)
						line({
							{ "      " .. key .. string.rep(" ", math.max(1, 12 - #key)), "Muted" },
							{ value, highlight or "Name" },
						}, state.id)
					end
					line({}, state.id)
					field("Installed", state.installed or "Not managed by CliHub")
					field(
						"Available",
						state.available or "Not checked · press r",
						state.available and "Installed" or "Muted"
					)
					if state.pin then
						field("Pinned", state.pin, "Pin")
					end
					field("Source", source_label(hub.registry[state.id].source), "Progress")
					for _, command in ipairs(vim.fn.sort(vim.tbl_keys(state.commands))) do
						local info = state.commands[command]
						field(command, info.managed)
						if info.path ~= "" and info.path ~= info.managed then
							field("External", info.path, "Update")
						end
					end
					if state.error then
						line({}, state.id)
						local message = state.error:match("^(.-)\nstack traceback:") or state.error
						for _, text in ipairs(vim.split(message, "\n", { trimempty = true })) do
							line({ { "      " .. text, "Error" } }, state.id)
						end
					end
					local result = hub.results[state.id]
					for _, warning in ipairs((result and result.result and result.result.warnings) or {}) do
						line({ { "      " .. warning, "Update" } }, state.id)
					end
					line({}, state.id)
				end
			end
		end
	end
	if visible == 0 then
		line()
		line({
			{
				view == 2 and "  No managed tools yet. Press 1 to choose your first tool."
					or "  No known updates. Press R to check installed tools.",
				"Muted",
			},
		})
	end
	line()
	line({
		{ "  <Tab>", "Key" },
		{ " switch view    ", "Muted" },
		{ "<Enter>", "Key" },
		{ " expand    ", "Muted" },
		{ "/", "Key" },
		{ " search", "Muted" },
	})
	line({
		{ "  U", "Key" },
		{ " update all installed    ", "Muted" },
		{ "R", "Key" },
		{ " check installed    ", "Muted" },
		{ "q", "Key" },
		{ " close", "Muted" },
	})
	vim.bo[buffer].modifiable = true
	vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(buffer, namespace, span[1], span[2], { end_col = span[3], hl_group = span[4] })
	end
	vim.bo[buffer].modifiable = false
	vim.api.nvim_win_set_cursor(window, { positions[previous] or math.min(old_row, #lines), 0 })
end

local function change_view(index)
	view = ((index - 1) % 3) + 1
	M.render()
	if starts[1] then
		vim.api.nvim_win_set_cursor(window, { starts[1], 0 })
	end
end

local function move(direction)
	local current = vim.api.nvim_win_get_cursor(window)[1]
	local target = direction > 0 and starts[#starts] or starts[1]
	for _, row in ipairs(starts) do
		if direction > 0 and row > current then
			target = row
			break
		end
		if direction < 0 and row < current then
			target = row
		end
	end
	if target then
		vim.api.nvim_win_set_cursor(window, { target, 0 })
	end
end

function M.open()
	if window and vim.api.nvim_win_is_valid(window) then
		vim.api.nvim_set_current_win(window)
		return M.render()
	end
	highlights()
	view = 1
	buffer = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buffer, "clihub://registry")
	vim.bo[buffer].buftype, vim.bo[buffer].bufhidden, vim.bo[buffer].swapfile = "nofile", "wipe", false
	vim.bo[buffer].filetype = "clihub"
	window = vim.api.nvim_open_win(buffer, true, geometry())
	vim.wo[window].wrap, vim.wo[window].number, vim.wo[window].relativenumber = false, false, false
	vim.wo[window].cursorline, vim.wo[window].signcolumn, vim.wo[window].foldcolumn = true, "no", "0"
	vim.wo[window].scrolloff = 3
	vim.wo[window].winhighlight = "Normal:NormalFloat,FloatBorder:CliHubBorder,CursorLine:CliHubSelection"
	local function map(key, callback, description)
		vim.keymap.set("n", key, callback, { buffer = buffer, silent = true, nowait = true, desc = description })
	end
	for key, action in pairs({ i = "install", u = "update", r = "check", x = "remove" }) do
		map(key, function()
			local id = selected()
			if not id or require("clihub").status(id).progress then
				return
			end
			local ok, err = pcall(require("clihub").command, { action, id })
			if not ok then
				vim.notify(tostring(err), vim.log.levels.ERROR)
			end
		end, "CliHub " .. action)
	end
	for key, action in pairs({ U = "update", R = "check" }) do
		map(key, function()
			local ok, err = pcall(require("clihub").command, { action })
			if not ok then
				vim.notify(tostring(err), vim.log.levels.ERROR)
			end
		end, "CliHub " .. action .. " installed")
	end
	map("<CR>", function()
		local id = selected()
		if id then
			expanded[id] = not expanded[id]
			M.render()
		end
	end, "Expand tool details")
	for index = 1, 3 do
		map(tostring(index), function()
			change_view(index)
		end, "CliHub view " .. index)
	end
	map("<Tab>", function()
		change_view(view + 1)
	end, "Next view")
	map("<S-Tab>", function()
		change_view(view - 1)
	end, "Previous view")
	for _, key in ipairs({ "j", "<Down>" }) do
		map(key, function()
			move(1)
		end, "Next tool")
	end
	for _, key in ipairs({ "k", "<Up>" }) do
		map(key, function()
			move(-1)
		end, "Previous tool")
	end
	local function close()
		if vim.api.nvim_win_is_valid(window) then
			vim.api.nvim_win_close(window, true)
		end
	end
	map("q", close, "Close CliHub")
	map("<Esc>", close, "Close CliHub")
	local group = vim.api.nvim_create_augroup("CliHubUI", { clear = true })
	vim.api.nvim_create_autocmd("User", { group = group, pattern = "CliHubChanged", callback = M.render })
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = function()
			highlights()
			M.render()
		end,
	})
	vim.api.nvim_create_autocmd("VimResized", {
		group = group,
		callback = function()
			if window and vim.api.nvim_win_is_valid(window) then
				vim.api.nvim_win_set_config(window, geometry())
				M.render()
			end
		end,
	})
	M.render()
	if starts[1] then
		vim.api.nvim_win_set_cursor(window, { starts[1], 0 })
	end
end

return M
