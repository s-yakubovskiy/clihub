local u = require("clihub.util")
local installer = require("clihub.install")
local M = { available = {}, errors = {}, progress = {}, results = {} }
local queue = {}

function M.setup(opts)
	assert(not M.busy, "Cannot reconfigure CliHub during an operation")
	opts = opts or {}
	local root = opts.root or ((vim.env.XDG_DATA_HOME or (vim.env.HOME .. "/.local/share")) .. "/clihub")
	root = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(root), ":p")):gsub("/$", "")
	assert(root ~= "" and root ~= vim.env.HOME, "Choose a dedicated CliHub root")
	assert(opts.path == nil or opts.path == "prepend" or opts.path == "none", "path must be 'prepend' or 'none'")
	M.config = { root = root, path = opts.path or "prepend", versions = vim.deepcopy(opts.versions or {}) }
	M.registry = require("clihub.registry").load(opts.registry)
	for id, tag in pairs(M.config.versions) do
		assert(
			M.registry[id] and type(tag) == "string" and tag ~= "" and not tag:find("[%s%c]"),
			"Invalid version pin: " .. tostring(id)
		)
	end
	if M.config.path == "prepend" then
		local paths = { root .. "/bin" }
		for path in (vim.env.PATH or ""):gmatch("[^:]+") do
			if path ~= root .. "/bin" then
				paths[#paths + 1] = path
			end
		end
		vim.env.PATH = table.concat(paths, ":")
	end
	M.available, M.errors, M.progress, M.results = {}, {}, {}, {}
	return M
end

function M.ensure()
	if not M.config then
		M.setup()
	end
	return M.config
end

function M.changed()
	vim.api.nvim_exec_autocmds("User", { pattern = "CliHubChanged", modeline = false })
end

function M.status(id)
	M.ensure()
	local recipe = assert(M.registry[id], "Unknown tool: " .. tostring(id))
	local ok, current = pcall(installer.current, M.config.root, id)
	local state = {
		id = id,
		description = recipe.description or id,
		installed = ok and current and current.tag or nil,
		available = M.available[id],
		pin = M.config.versions[id],
		error = M.errors[id] or (not ok and tostring(current) or nil),
		progress = M.progress[id],
		commands = {},
	}
	if not state.progress then
		for _, request in ipairs(queue) do
			if vim.tbl_contains(request.ids, id) then
				state.progress = "queued " .. request.action
				break
			end
		end
	end
	local platform_ok, platform = pcall(u.platform)
	local target = platform_ok and recipe.targets[platform] or nil
	for name in pairs((ok and current and current.bins) or (target and target.bins) or {}) do
		local path = vim.fn.exepath(name)
		state.commands[name] = { path = path, managed = M.config.root .. "/bin/" .. name }
	end
	state.status = state.progress
		or state.error and "error"
		or state.pin and "pinned"
		or (state.installed and state.available and state.installed ~= state.available and "update available")
		or (state.installed and "installed" or "not installed")
	return state
end

function M.list()
	M.ensure()
	local ids = vim.tbl_keys(M.registry)
	table.sort(ids)
	return ids
end

local function execute(action, ids, done, platform)
	M.busy = true
	local results = {}
	u.async(function()
		for _, id in ipairs(ids) do
			M.errors[id] = nil
			M.progress[id] = action
			M.changed()
			local ok, result = xpcall(function()
				if action == "check" then
					local resolved =
						require("clihub.sources").resolve(id, M.registry[id], platform, M.config.versions[id])
					M.available[id] = resolved.tag
					return { tag = resolved.tag }
				elseif action == "remove" then
					return installer.remove(M.config.root, id)
				else
					local installed = installer.apply(
						M.config.root,
						id,
						M.registry[id],
						platform,
						M.config.versions[id],
						function(message)
							M.progress[id] = message
							M.changed()
						end
					)
					M.available[id] = installed.tag
					return installed
				end
			end, debug.traceback)
			results[id] = { ok = ok, result = ok and result or nil, error = not ok and tostring(result) or nil }
			M.results[id] = results[id]
			M.errors[id] = not ok and tostring(result) or nil
			if not ok and action ~= "remove" then
				M.available[id] = nil
			end
			M.progress[id] = nil
			M.changed()
		end
		return results
	end, function(ok, result)
		M.busy = #queue > 0
		if M.busy then
			vim.schedule(function()
				local request = table.remove(queue, 1)
				execute(request.action, request.ids, request.done, request.platform)
			end)
		end
		M.changed()
		if done then
			done(ok and result or { _operation = { ok = false, error = result } })
		else
			local failures = {}
			for id, item in pairs(results) do
				if not item.ok then
					failures[#failures + 1] = id .. ": " .. item.error
				end
			end
			if not ok then
				failures[#failures + 1] = tostring(result)
			end
			vim.notify(
				#failures > 0 and table.concat(failures, "\n")
					or ("CliHub " .. action .. " completed (" .. #ids .. " tools)"),
				#failures > 0 and vim.log.levels.ERROR or vim.log.levels.INFO
			)
		end
	end)
end

-- The public async API is also usable from headless Neovim; done receives one result per tool.
function M.run(action, ids, done)
	M.ensure()
	assert(
		vim.tbl_contains({ "install", "update", "check", "remove" }, action),
		"Unknown CliHub action: " .. tostring(action)
	)
	ids = vim.deepcopy(ids or {})
	local bulk = #ids == 0
	if bulk then
		assert(action == "update" or action == "check", "Specify at least one tool")
		for _, id in ipairs(M.list()) do
			local ok, receipt = pcall(installer.current, M.config.root, id)
			if (not ok or receipt) and (action ~= "update" or not M.config.versions[id]) then
				ids[#ids + 1] = id
			end
		end
	end
	local seen = {}
	ids = vim.tbl_filter(function(id)
		assert(M.registry[id], "Unknown tool: " .. tostring(id))
		if seen[id] then
			return false
		end
		seen[id] = true
		return true
	end, ids)
	local platform = u.platform()
	if M.busy then
		queue[#queue + 1] = { action = action, ids = ids, done = done, platform = platform }
		M.changed()
	else
		execute(action, ids, done, platform)
	end
end

function M.command(args)
	M.ensure()
	if #args == 0 then
		return require("clihub.ui").open()
	end
	local action = args[1]
	local ids = vim.list_slice(args, 2)
	if action == "remove" then
		assert(#ids > 0, "Specify at least one tool")
		vim.ui.select(
			{ "Cancel", "Remove managed installations" },
			{ prompt = "Remove " .. table.concat(ids, ", ") .. "?" },
			function(choice)
				if choice == "Remove managed installations" then
					local ok, err = pcall(M.run, action, ids)
					if not ok then
						vim.notify(tostring(err), vim.log.levels.ERROR)
					end
				end
			end
		)
	else
		M.run(action, ids)
	end
end

function M.complete(lead, line)
	local words = vim.split(line, "%s+", { trimempty = true })
	local candidates = #words <= 2 and not line:match("^%S+%s+%S+%s") and { "install", "update", "check", "remove" }
		or M.list()
	return vim.tbl_filter(function(item)
		return vim.startswith(item, lead)
	end, candidates)
end

return M
