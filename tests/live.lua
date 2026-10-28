-- Explicit integration check: downloads upstream tools into a disposable root.
-- Run: nvim --headless -u NONE -i NONE -l tests/live.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local hub = require("clihub")
local u = require("clihub.util")
local root = vim.fn.tempname() .. "-clihub-live"
hub.setup({ root = root, path = "prepend" })
local last = {}
vim.api.nvim_create_autocmd("User", {
	pattern = "CliHubChanged",
	callback = function()
		for id, message in pairs(hub.progress) do
			if last[id] ~= message then
				print(id .. ": " .. message)
				last[id] = message
			end
		end
	end,
})

local function operation(action, ids)
	local completed
	hub.run(action, ids, function(results)
		completed = results
	end)
	assert(
		vim.wait(1200000, function()
			return completed ~= nil
		end, 50),
		"Live check timed out; inspect " .. root
	)
	for id, result in pairs(completed) do
		assert(result.ok, id .. ": " .. tostring(result.error))
	end
	return completed
end

local ok, err = xpcall(function()
	local results = operation("install", hub.list())
	for _, id in ipairs(hub.list()) do
		print("INSTALLED " .. id .. " " .. results[id].result.tag)
		local state = hub.status(id)
		for command, info in pairs(state.commands) do
			assert(info.path == info.managed, command .. " is shadowed")
			assert(vim.fn.executable(info.managed) == 1, command .. " is not executable")
			local args = { "env", command }
			vim.list_extend(args, hub.registry[id].verify[command])
			local executed = vim.system(args, { text = true }):wait(10000)
			assert(executed.code == 0, command .. ": child process could not execute through PATH")
		end
	end
	local updated = operation("update", {})
	for id, result in pairs(updated) do
		assert(result.result.unchanged, id .. ": expected an idempotent update")
	end
	operation("check", {})
	operation("remove", hub.list())
	for _, id in ipairs(hub.list()) do
		assert(not require("clihub.install").current(root, id), "Package remains installed: " .. id)
	end
end, debug.traceback)
u.delete(root)
if not ok then
	io.stderr:write(err .. "\n")
	vim.cmd("cquit 1")
end
print("CliHub live install/update/check/remove passed on " .. u.platform())
