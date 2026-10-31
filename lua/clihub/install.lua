local u = require("clihub.util")
local uv = vim.uv
local M = {}

local function token()
	return uv.os_getpid() .. "." .. vim.fn.sha256(tostring(uv.hrtime())):sub(1, 16)
end

local function package_path(root, id)
	assert(u.name(id), "Invalid package ID")
	return root .. "/packages/" .. id
end

local function real_directory(path)
	local stat = uv.fs_lstat(path)
	assert(not stat or stat.type == "directory", "Expected a real directory: " .. path)
end

function M.current(root, id)
	local package = package_path(root, id)
	real_directory(root)
	real_directory(root .. "/packages")
	real_directory(package)
	local path = package .. "/current"
	local stat = uv.fs_lstat(path)
	if not stat then
		return nil
	end
	assert(stat.type == "link", "Managed current path is not a symlink: " .. path)
	local target = assert(uv.fs_readlink(path))
	assert(target:match("^versions/%x+$"), "Invalid managed version link: " .. path)
	real_directory(package .. "/versions")
	real_directory(package .. "/" .. target)
	local receipt_path = package .. "/" .. target .. "/receipt.json"
	local receipt_stat = uv.fs_lstat(receipt_path)
	assert(receipt_stat and receipt_stat.type == "file", "Missing or invalid package receipt: " .. receipt_path)
	local receipt = vim.json.decode(u.read(receipt_path))
	assert(
		receipt.id == id and type(receipt.tag) == "string" and type(receipt.bins) == "table" and next(receipt.bins),
		"Invalid package receipt"
	)
	for name in pairs(receipt.bins) do
		assert(u.name(name), "Invalid receipt command")
	end
	return receipt, target
end

function M.prepare(root)
	for _, path in ipairs({ root, root .. "/bin", root .. "/packages", root .. "/staging" }) do
		u.mkdir(path)
	end
end

function M.lock(root)
	local directory = root .. "/.lock"
	local ok, err = uv.fs_mkdir(directory, 448)
	if not ok then
		local stat = uv.fs_lstat(directory)
		assert(stat and stat.type == "directory", err or "Invalid clihub lock")
		local scan = assert(uv.fs_scandir(directory))
		local name = uv.fs_scandir_next(scan)
		assert(
			name and name:match("^owner%.%d+%.%x+%.json$") and not uv.fs_scandir_next(scan),
			"clihub is busy: lock owner is being initialized or is ambiguous"
		)
		local owner = vim.json.decode(u.read(directory .. "/" .. name))
		assert(type(owner.pid) == "number" and owner.pid > 0, "Invalid clihub lock owner")
		local alive, kill_err = uv.kill(owner.pid, 0)
		assert(not alive and tostring(kill_err):find("ESRCH", 1, true), "clihub is busy (PID " .. owner.pid .. ")")
		-- Only the stale owner's unique file can be removed; a contender cannot unlink a replacement lock.
		assert(uv.fs_unlink(directory .. "/" .. name), "clihub lock changed; retry the operation")
		assert(uv.fs_rmdir(directory), "clihub lock changed; retry the operation")
		assert(uv.fs_mkdir(directory, 448), "clihub is busy")
	end
	local name = "owner." .. token() .. ".json"
	local wrote, write_err = pcall(u.write, directory .. "/" .. name, vim.json.encode({ pid = uv.os_getpid() }))
	if not wrote then
		uv.fs_rmdir(directory)
		error(write_err)
	end
	return function()
		assert(uv.fs_unlink(directory .. "/" .. name))
		assert(uv.fs_rmdir(directory))
	end
end

local function export_target(id, command)
	return "../packages/" .. id .. "/current/bin/" .. command
end

function M.check_exports(root, id, bins)
	real_directory(root .. "/bin")
	for command in pairs(bins) do
		local path = root .. "/bin/" .. command
		local stat = uv.fs_lstat(path)
		assert(
			not stat or (stat.type == "link" and uv.fs_readlink(path) == export_target(id, command)),
			"Refusing to replace a foreign command: " .. path
		)
	end
end

function M.reconcile(root, id, bins)
	M.check_exports(root, id, bins)
	local scan = assert(uv.fs_scandir(root .. "/bin"))
	while true do
		local name = uv.fs_scandir_next(scan)
		if not name then
			break
		end
		local path = root .. "/bin/" .. name
		if u.name(name) and not bins[name] and uv.fs_readlink(path) == export_target(id, name) then
			u.unlink(path)
		end
	end
	for command in pairs(bins) do
		local path = root .. "/bin/" .. command
		if not uv.fs_lstat(path) then
			assert(uv.fs_symlink(export_target(id, command), path))
		end
	end
end

local function activate(package, target)
	local temporary = package .. "/.current." .. token()
	assert(uv.fs_symlink(target, temporary))
	local ok, err = uv.fs_rename(temporary, package .. "/current")
	if not ok then
		u.unlink(temporary)
		error(err)
	end
end

local function intact(root, id, receipt, target)
	for command in pairs(receipt.bins) do
		local binary = package_path(root, id) .. "/" .. target .. "/bin/" .. command
		local stat = uv.fs_lstat(binary)
		if not stat or stat.type ~= "file" or vim.fn.executable(binary) ~= 1 then
			return false
		end
	end
	return true
end

function M.apply(root, id, recipe, platform, pin, progress, opts)
	progress = progress or function() end
	opts = opts or {}
	M.prepare(root)
	local unlock = M.lock(root)
	local stage
	local ok, result = xpcall(function()
		M.check_exports(root, id, assert(recipe.targets[platform], "Unsupported platform").bins)
		progress("resolving")
		local resolved = require("clihub.sources").resolve(id, recipe, platform, pin)
		local current, old_target = M.current(root, id)
		if opts.locked then
			assert(
				resolved.tag == opts.locked.tag and resolved.fingerprint == opts.locked.fingerprint,
				"Locked recipe/version mismatch: " .. id
			)
			assert(opts.locked.sha256[platform], "No locked checksum for " .. id .. " on " .. platform)
		end
		if opts.only_upgrade and current then
			local comparison = u.compare(resolved.tag, current.tag)
			assert(
				comparison ~= nil,
				"Cannot order release tags for " .. id .. "; use install to explicitly select the upstream release"
			)
			if comparison < 0 then
				return { tag = current.tag, latest = resolved.tag, unchanged = true, newer_installed = true }
			end
		end
		if
			current
			and current.tag == resolved.tag
			and current.platform == platform
			and current.fingerprint == resolved.fingerprint
			and intact(root, id, current, old_target)
			and (not opts.locked or current.sha256 == opts.locked.sha256[platform])
		then
			M.reconcile(root, id, current.bins)
			return { tag = current.tag, unchanged = true }
		end
		stage = root .. "/staging/" .. token()
		u.mkdir(stage)
		progress("downloading " .. resolved.tag)
		local archive = stage .. "/artifact"
		u.download(resolved.url, archive)
		progress("verifying checksum")
		local checksum = resolved.checksum
		local expected = checksum.digest or u.checksum(u.fetch(checksum.url), checksum.format, checksum.filename)
		local actual = u.run({ "sha256sum", "--", archive }):match("^(%x+)")
		assert(actual and actual:lower() == expected:lower(), "SHA-256 mismatch for " .. id)
		assert(
			not opts.locked or actual:lower() == opts.locked.sha256[platform]:lower(),
			"Lockfile SHA-256 mismatch for " .. id
		)
		local payload = stage .. "/payload"
		u.mkdir(payload)
		u.mkdir(payload .. "/bin")
		local members = {}
		if resolved.format == "tar.gz" then
			for member in u.run({ "tar", "-tzf", archive }):gmatch("[^\r\n]+") do
				members[member] = (members[member] or 0) + 1
			end
		end
		for command, member in pairs(resolved.bins) do
			progress("preparing " .. command)
			local destination = payload .. "/bin/" .. command
			if resolved.format == "binary" then
				assert(uv.fs_copyfile(archive, destination))
			else
				assert(members[member] == 1, "Missing or duplicate archive member: " .. member)
				local listing = u.run({ "tar", "-tvzf", archive, "--no-wildcards", "--", member })
				assert(listing:sub(1, 1) == "-", "Archive member is not a regular file: " .. member)
				u.run({ "tar", "-xOzf", archive, "--no-wildcards", "--", member }, { output = destination })
			end
			u.elf(destination, platform)
			assert(uv.fs_chmod(destination, 493))
			local args = { destination }
			vim.list_extend(args, resolved.verify[command])
			u.run(args, { timeout = 10000 })
		end
		local receipt = {
			id = id,
			tag = resolved.tag,
			platform = platform,
			source = resolved.source,
			url = resolved.url,
			sha256 = actual,
			fingerprint = resolved.fingerprint,
			bins = resolved.bins,
			installer = "artifact",
			installed_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		}
		u.write(payload .. "/receipt.json", vim.json.encode(receipt))
		local package = package_path(root, id)
		u.mkdir(package)
		u.mkdir(package .. "/versions")
		local install_id = vim.fn.sha256(resolved.tag .. platform .. actual .. resolved.fingerprint)
		local target = "versions/" .. install_id
		-- An interrupted previous attempt may have left this complete immutable version.
		if uv.fs_lstat(package .. "/" .. target) then
			assert(target ~= old_target, "Active installation is damaged; remove it before reinstalling")
			u.delete(package .. "/" .. target)
		end
		assert(uv.fs_rename(payload, package .. "/" .. target))
		M.check_exports(root, id, resolved.bins)
		progress("activating " .. resolved.tag)
		activate(package, target)
		local linked, link_error = pcall(M.reconcile, root, id, resolved.bins)
		if not linked then
			if old_target then
				activate(package, old_target)
			else
				u.unlink(package .. "/current")
			end
			pcall(M.reconcile, root, id, current and current.bins or {})
			error(link_error)
		end
		local scan = assert(uv.fs_scandir(package .. "/versions"))
		local warnings = {}
		while true do
			local name = uv.fs_scandir_next(scan)
			if not name then
				break
			end
			if name ~= install_id and name:match("^%x+$") then
				local cleaned, cleanup_error = pcall(u.delete, package .. "/versions/" .. name)
				if not cleaned then
					warnings[#warnings + 1] = tostring(cleanup_error)
				end
			end
		end
		return { tag = resolved.tag, warnings = warnings }
	end, debug.traceback)
	if stage then
		local cleaned, err = pcall(u.delete, stage)
		if not cleaned and ok then
			result.warnings = result.warnings or {}
			table.insert(result.warnings, tostring(err))
		end
	end
	local released, lock_error = pcall(unlock)
	if not ok then
		error(result, 0)
	end
	assert(released, lock_error)
	return result
end

function M.remove(root, id)
	M.prepare(root)
	local unlock = M.lock(root)
	local ok, result = xpcall(function()
		local receipt = M.current(root, id)
		assert(receipt, id .. " is not installed by CliHub")
		M.reconcile(root, id, {})
		u.delete(package_path(root, id))
		return { removed = true }
	end, debug.traceback)
	local released, err = pcall(unlock)
	if not ok then
		error(result, 0)
	end
	assert(released, err)
	return result
end

return M
