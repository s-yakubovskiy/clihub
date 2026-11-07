local u = require("clihub.util")
local M = {}
local contexts = setmetatable({}, { __mode = "k" })
local secrets = {}

function M.hide(value)
	if type(value) == "string" and value ~= "" then
		secrets[value] = true
	end
end

function M.redact(value)
	local text = tostring(value)
	local hidden = vim.tbl_keys(secrets)
	vim.list_extend(hidden, { vim.env.GH_TOKEN or "", vim.env.GITHUB_TOKEN or "" })
	for _, secret in ipairs(hidden) do
		if secret ~= "" then
			text = text:gsub(vim.pesc(secret), "[redacted]")
		end
	end
	return text
end

function M.summary(value)
	local text = M.redact(value)
	local glibc
	for version in text:gmatch("version [`']GLIBC_([%d.]+)[`'] not found") do
		if not glibc or u.compare(version .. ".0", glibc .. ".0") == 1 then
			glibc = version
		end
	end
	if glibc then
		return "Binary requires glibc " .. glibc .. "; select a compatible build for this host"
	end
	local line = vim.trim(text:match("[^\r\n]+") or "Operation failed")
	line = line:gsub("^.-:%d+:%s*", "")
	return vim.fn.strcharpart(line, 0, 240)
end

function M.path(root, id)
	assert(u.name(id), "Invalid tool ID")
	return root .. "/logs/" .. id .. ".log"
end

function M.start(root, id, action)
	contexts[coroutine.running()] = {
		path = M.path(root, id),
		lines = { "clihub " .. action .. " " .. id, os.date("!%Y-%m-%dT%H:%M:%SZ"), "Platform: " .. u.platform() },
	}
end

function M.record(args, result, opts)
	local context = contexts[coroutine.running()]
	if not context then
		return
	end
	local text = "\n$ " .. vim.inspect(args) .. "\n(exit " .. result.code .. ")"
	if opts.sensitive then
		text = "\nSensitive request (exit " .. result.code .. "); arguments and output omitted"
	else
		text = text .. "\n" .. (result.stdout or "") .. "\n" .. (result.stderr or "")
	end
	context.lines[#context.lines + 1] = M.redact(text)
end

function M.finish(ok, result)
	local thread = coroutine.running()
	local context = contexts[thread]
	contexts[thread] = nil
	context.lines[#context.lines + 1] = ok and "\nCompleted" or ("\nFailed\n" .. M.redact(result))
	u.atomic_write(context.path, M.redact(table.concat(context.lines, "\n")) .. "\n")
	return context.path
end

function M.read(root, id)
	local path = M.path(root, id)
	assert(vim.uv.fs_stat(path), "No log for " .. id .. "; run an operation first")
	return M.redact(u.read(path))
end

function M.copy(root, id)
	local text = M.read(root, id)
	vim.fn.setreg('"', text)
	local clipboard = vim.fn.has("clipboard") == 1 and pcall(vim.fn.setreg, "+", text)
	vim.notify("Copied " .. id .. " diagnostics to " .. (clipboard and "clipboard" or "unnamed register"))
end

function M.open(root, id)
	local text = M.read(root, id)
	local buffer = vim.api.nvim_create_buf(false, true)
	vim.bo[buffer].buftype, vim.bo[buffer].bufhidden, vim.bo[buffer].swapfile = "nofile", "wipe", false
	vim.bo[buffer].filetype = "log"
	vim.api.nvim_buf_set_lines(buffer, 0, -1, false, vim.split(text, "\n", { plain = true }))
	vim.bo[buffer].modifiable = false
	local width = math.max(1, math.min(110, vim.o.columns - 4))
	local height = math.max(1, math.min(35, vim.o.lines - 4))
	local window = vim.api.nvim_open_win(buffer, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		zindex = 60,
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
		col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
		title = " " .. id .. " log ",
		footer = " y copy · q close ",
	})
	vim.wo[window].wrap = false
	for _, key in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", key, function()
			vim.api.nvim_win_close(window, true)
		end, { buffer = buffer, silent = true })
	end
	vim.keymap.set("n", "y", function()
		M.copy(root, id)
	end, { buffer = buffer, silent = true, desc = "Copy diagnostics" })
end

return M
