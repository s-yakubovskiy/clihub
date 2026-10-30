local u = require("clihub.util")
local installer = require("clihub.install")
local M = { available = {}, errors = {}, progress = {}, results = {}, checks = {} }
local queue = {}

local function check_path(id)
	return M.config.root .. "/checks/" .. id .. ".json"
end

local function remember_check(id, tag)
	local record = {
		tag = tag,
		checked_at = os.time(),
		platform = u.platform(),
		fingerprint = u.fingerprint(M.registry[id]),
	}
	u.atomic_write(check_path(id), vim.json.encode(record))
	M.available[id], M.checks[id] = tag, record
end

function M.setup(opts)
	assert(not M.busy, "Cannot reconfigure CliHub during an operation")
	opts = opts or {}
	local root = opts.root or ((vim.env.XDG_DATA_HOME or (vim.env.HOME .. "/.local/share")) .. "/clihub")
	root = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(root), ":p")):gsub("/$", "")
	assert(root ~= "" and root ~= vim.env.HOME, "Choose a dedicated CliHub root")
	assert(opts.path == nil or opts.path == "prepend" or opts.path == "none", "path must be 'prepend' or 'none'")
	M.config = {
		root = root,
		path = opts.path or "prepend",
		versions = vim.deepcopy(opts.versions or {}),
		lockfile = vim.fs.normalize(
			vim.fn.fnamemodify(vim.fn.expand(opts.lockfile or (vim.fn.stdpath("config") .. "/clihub-lock.json")), ":p")
		),
		ensure_installed = vim.deepcopy(opts.ensure_installed or {}),
	}
	M.registry = require("clihub.registry").load(opts.registry)
	for id, tag in pairs(M.config.versions) do
		assert(
			M.registry[id] and type(tag) == "string" and tag ~= "" and not tag:find("[%s%c]"),
			"Invalid version pin: " .. tostring(id)
		)
	end
	assert(vim.islist(M.config.ensure_installed), "ensure_installed must be a list of tool IDs")
	for _, id in ipairs(M.config.ensure_installed) do
		assert(M.registry[id], "Unknown ensured tool: " .. tostring(id))
	end
	require("clihub.http").setup(opts.github, root .. "/cache/http")
	if M.config.path == "prepend" then
		local paths = { root .. "/bin" }
		for path in (vim.env.PATH or ""):gmatch("[^:]+") do
			if path ~= root .. "/bin" then
				paths[#paths + 1] = path
			end
		end
		vim.env.PATH = table.concat(paths, ":")
	end
	M.available, M.errors, M.progress, M.results, M.checks = {}, {}, {}, {}, {}
	for id, recipe in pairs(M.registry) do
		local record = u.json_read(check_path(id))
		if
			record
			and record.fingerprint == u.fingerprint(recipe)
			and record.platform == u.platform()
			and type(record.tag) == "string"
			and record.tag ~= ""
			and not record.tag:find("[%s%c]")
			and type(record.checked_at) == "number"
			and record.checked_at <= os.time()
		then
			M.available[id], M.checks[id] = record.tag, record
		end
	end
	if #M.config.ensure_installed > 0 then
		local configured = M.config
		vim.schedule(function()
			if M.config == configured then
				local ok, err = pcall(M.ensure_tools)
				if not ok then
					vim.notify(tostring(err), vim.log.levels.ERROR)
				end
			end
		end)
	end
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
		checked_at = M.checks[id] and M.checks[id].checked_at,
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
	state.comparison = u.compare(state.available, state.installed)
	state.stale = state.checked_at and os.time() - state.checked_at >= 86400 or false
	state.release_url = require("clihub.sources").release_url(recipe, state.available or state.installed)
	state.status = state.progress
		or state.error and "error"
		or state.pin and "pinned"
		or (state.comparison == 1 and "update available")
		or (state.comparison == -1 and "newer installed")
		or (state.installed and state.available and state.comparison == nil and "different release")
		or (state.installed and "installed" or "not installed")
	return state
end

function M.list()
	M.ensure()
	local ids = vim.tbl_keys(M.registry)
	table.sort(ids)
	return ids
end

local function execute(action, ids, done, platform, locked)
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
						require("clihub.sources").resolve(id, M.registry[id], platform, nil, { refresh = true })
					remember_check(id, resolved.tag)
					return { tag = resolved.tag }
				elseif action == "remove" then
					return installer.remove(M.config.root, id)
				else
					local entry = locked and locked[id]
					local installed = installer.apply(
						M.config.root,
						id,
						M.registry[id],
						platform,
						entry and entry.tag or M.config.versions[id],
						function(message)
							M.progress[id] = message
							M.changed()
						end,
						{
							locked = entry,
							only_upgrade = action == "update" and not entry and not M.config.versions[id],
						}
					)
					if not entry and not M.config.versions[id] then
						local tag = installed.latest or installed.tag
						M.available[id] = tag
						local saved, err = pcall(remember_check, id, tag)
						if not saved then
							installed.warnings = installed.warnings or {}
							table.insert(installed.warnings, "Could not save update check: " .. tostring(err))
						end
					elseif not M.checks[id] then
						M.available[id] = installed.latest or installed.tag
					end
					return installed
				end
			end, debug.traceback)
			results[id] = { ok = ok, result = ok and result or nil, error = not ok and tostring(result) or nil }
			M.results[id] = results[id]
			M.errors[id] = not ok and tostring(result) or nil
			if not ok and action ~= "remove" then
				M.available[id] = nil
				M.checks[id] = nil
				pcall(u.unlink, check_path(id))
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
				execute(request.action, request.ids, request.done, request.platform, request.locked)
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
function M.run(action, ids, done, opts)
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
		queue[#queue + 1] =
			{ action = action, ids = ids, done = done, platform = platform, locked = vim.deepcopy((opts or {}).locked) }
		M.changed()
	else
		execute(action, ids, done, platform, vim.deepcopy((opts or {}).locked))
	end
end

function M.lock()
	M.ensure()
	assert(not M.busy, "Wait for current operations before saving the lockfile")
	local packages = require("clihub.lockfile").write(M.config.lockfile, M.config.root, M.registry)
	vim.notify("Locked " .. vim.tbl_count(packages) .. " tools in " .. M.config.lockfile)
	return packages
end

local function locked_tools(required)
	local entries = require("clihub.lockfile").read(M.config.lockfile, M.registry)
	if required then
		assert(next(entries), "No locked tools in " .. M.config.lockfile .. "; run :CliHub lock first")
	end
	for id, entry in pairs(entries) do
		assert(
			not M.config.versions[id] or M.config.versions[id] == entry.tag,
			"Version pin conflicts with lockfile: " .. id
		)
		assert(entry.sha256[u.platform()], "No locked checksum for " .. id .. " on " .. u.platform())
	end
	return entries
end

function M.restore(done)
	M.ensure()
	local entries = locked_tools(true)
	local ids = vim.tbl_keys(entries)
	table.sort(ids)
	M.run("install", ids, done, { locked = entries })
end

function M.ensure_tools(done)
	M.ensure()
	local entries, ids = locked_tools(false), {}
	for _, id in ipairs(M.config.ensure_installed) do
		local current = installer.current(M.config.root, id)
		local entry = entries[id]
		local tag = entry and entry.tag or M.config.versions[id]
		if
			not current
			or (tag and current.tag ~= tag)
			or current.fingerprint ~= u.fingerprint(M.registry[id])
			or (entry and current.sha256 ~= entry.sha256[u.platform()])
		then
			ids[#ids + 1] = id
		end
	end
	if #ids == 0 then
		if done then
			done({})
		end
		return
	end
	M.run("install", ids, done, { locked = entries })
end

function M.open_release(id)
	local url = assert(
		M.status(id).release_url,
		"Release page unavailable; check the tool with r, or add releases to its recipe"
	)
	assert(url:match("^https://") and not url:find("[%c]"), "Invalid release URL")
	vim.ui.open(url)
end

function M.command(args)
	M.ensure()
	if #args == 0 then
		return require("clihub.ui").open()
	end
	local action = args[1]
	local ids = vim.list_slice(args, 2)
	if action == "lock" or action == "restore" or action == "ensure" then
		assert(#ids == 0, action .. " does not accept tool IDs")
		return ({ lock = M.lock, restore = M.restore, ensure = M.ensure_tools })[action]()
	elseif action == "releases" then
		assert(#ids == 1, "Specify one tool")
		return M.open_release(ids[1])
	end
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
	local candidates = #words <= 2
			and not line:match("^%S+%s+%S+%s")
			and { "install", "update", "check", "remove", "lock", "restore", "ensure", "releases" }
		or M.list()
	return vim.tbl_filter(function(item)
		return vim.startswith(item, lead)
	end, candidates)
end

return M
