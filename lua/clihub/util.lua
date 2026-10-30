local M = {}
local uv = vim.uv

function M.name(value)
	return type(value) == "string" and value:match("^[%w][%w_.-]*$") ~= nil
end

function M.member(value)
	if type(value) ~= "string" or value == "" or value:find("[%c\\]") or value:sub(1, 1) == "/" then
		return false
	end
	for component in value:gmatch("[^/]+") do
		if component == ".." or component == "." then
			return false
		end
	end
	return not value:find("//", 1, true) and value:sub(-1) ~= "/"
end

function M.platform()
	local system = uv.os_uname()
	assert(system.sysname == "Linux", "CliHub currently supports Linux only")
	local arch = ({ x86_64 = "amd64", amd64 = "amd64", aarch64 = "arm64", arm64 = "arm64" })[system.machine]
	assert(arch, "Unsupported architecture: " .. system.machine)
	return "linux-" .. arch
end

function M.expand(template, values)
	assert(type(template) == "string", "Expected a string template")
	local expanded = template:gsub("{([^{}]+)}", function(key)
		assert(values[key] ~= nil, "Unknown template variable: " .. key)
		return values[key]
	end)
	assert(not expanded:find("[{}]"), "Invalid template: " .. template)
	return expanded
end

function M.encode(value)
	return (value:gsub("([^%w_.~-])", function(c)
		return string.format("%%%02X", c:byte())
	end))
end

function M.canonical(value)
	if type(value) ~= "table" then
		return vim.json.encode(value)
	end
	local parts = {}
	for _, key in ipairs(vim.tbl_keys(value)) do
		assert(type(key) == "string" or type(key) == "number", "Invalid registry key")
		parts[#parts + 1] = M.canonical(key) .. ":" .. M.canonical(value[key])
	end
	table.sort(parts)
	return "{" .. table.concat(parts, ",") .. "}"
end

function M.fingerprint(recipe)
	local installation = vim.deepcopy(recipe)
	installation.releases = nil -- Release-page metadata does not change installed artifacts.
	return vim.fn.sha256(M.canonical(installation))
end

function M.read(path)
	local file = assert(io.open(path, "rb"))
	local data = file:read("*a")
	file:close()
	return data
end

function M.write(path, data)
	local file = assert(io.open(path, "wb"))
	local ok, err = file:write(data)
	file:close()
	assert(ok, err)
end

function M.atomic_write(path, data)
	M.mkdir(vim.fs.dirname(path))
	local temporary = path .. "." .. uv.os_getpid() .. "." .. uv.hrtime()
	local fd = assert(uv.fs_open(temporary, "wx", 384))
	local ok, err = pcall(function()
		assert(uv.fs_write(fd, data, 0) == #data, "Short file write")
		assert(uv.fs_fsync(fd))
	end)
	uv.fs_close(fd)
	if ok then
		ok, err = uv.fs_rename(temporary, path)
	end
	if not ok then
		uv.fs_unlink(temporary)
		error(err)
	end
end

function M.json_read(path)
	local ok, value = pcall(function()
		return vim.json.decode(M.read(path))
	end)
	return ok and type(value) == "table" and value or nil
end

-- Unknown tag schemes are deliberately unordered, rather than guessed upgrades.
function M.compare(a, b)
	if not a or not b then
		return nil
	end
	if a == b then
		return 0
	end
	local function parse(tag)
		return vim.version.parse(tag:gsub("%+[%w.-]+$", ""), { strict = true })
	end
	local left, right = parse(a), parse(b)
	if not left or not right then
		return nil
	end
	return left == right and 0 or left < right and -1 or 1
end

function M.age(timestamp)
	if not timestamp then
		return "not checked"
	end
	local seconds = math.max(0, os.time() - timestamp)
	if seconds < 60 then
		return "just now"
	elseif seconds < 3600 then
		return math.floor(seconds / 60) .. "m ago"
	elseif seconds < 86400 then
		return math.floor(seconds / 3600) .. "h ago"
	end
	return math.floor(seconds / 86400) .. "d ago"
end

function M.mkdir(path)
	local existing = uv.fs_lstat(path)
	if existing then
		assert(existing.type == "directory", "Expected a real directory: " .. path)
	else
		assert(vim.fn.mkdir(path, "p", 448) == 1, "Cannot create directory: " .. path)
	end
end

function M.unlink(path)
	if uv.fs_lstat(path) then
		assert(uv.fs_unlink(path))
	end
end

-- Never recurse through symlinks, including a replaced staging/package path.
function M.delete(path)
	local stat = uv.fs_lstat(path)
	if not stat then
		return
	end
	if stat.type ~= "directory" then
		return M.unlink(path)
	end
	local scan = assert(uv.fs_scandir(path))
	while true do
		local name = uv.fs_scandir_next(scan)
		if not name then
			break
		end
		M.delete(path .. "/" .. name)
	end
	assert(uv.fs_rmdir(path))
end

function M.async(fn, done)
	local thread = coroutine.create(function()
		local ok, result = xpcall(fn, debug.traceback)
		done(ok, result)
	end)
	local ok, err = coroutine.resume(thread)
	if not ok then
		done(false, tostring(err))
	end
end

function M.run(args, opts)
	opts = opts or {}
	local thread = coroutine.running()
	assert(thread, "CliHub processes must run inside an async operation")
	local fd, output_error
	if opts.output then
		fd = assert(uv.fs_open(opts.output, "w", 384))
	end
	local ok, process = pcall(vim.system, args, {
		stdin = opts.stdin,
		text = not fd,
		timeout = opts.timeout or 120000,
		stdout = fd and function(err, data)
			if err then
				output_error = err
			end
			if data and not output_error then
				local written, write_err = uv.fs_write(fd, data, -1)
				if not written or written ~= #data then
					output_error = write_err or "Short file write"
				end
			end
		end or nil,
	}, function(result)
		if fd then
			uv.fs_close(fd)
		end
		vim.schedule(function()
			local resumed, err = coroutine.resume(thread, result, output_error)
			-- Operation coroutines handle errors through xpcall at their entry point.
			if not resumed then
				vim.notify(tostring(err), vim.log.levels.ERROR)
			end
		end)
	end)
	if not ok then
		if fd then
			uv.fs_close(fd)
		end
		error(process)
	end
	local result, write_error = coroutine.yield()
	assert(not write_error, write_error)
	assert(
		result.code == 0,
		opts.sensitive and (args[1] .. " request failed (exit " .. result.code .. ")")
			or (
				table.concat(args, " ")
				.. "\n"
				.. (result.stderr or "")
				.. "\n"
				.. (result.stdout or ""):sub(1, 4096)
				.. "\n(exit "
				.. result.code
				.. ")"
			)
	)
	return result.stdout or ""
end

function M.curl(url, allow_http_errors)
	assert(type(url) == "string" and url:match("^https://") and not url:find("[%c]"), "Expected an HTTPS URL")
	local args = {
		"curl",
		"--silent",
		"--show-error",
		"--location",
		"--proto",
		"=https",
		"--proto-redir",
		"=https",
		"--connect-timeout",
		"15",
		"--max-time",
		"120",
		"--retry",
		"2",
		"--user-agent",
		"clihub.nvim",
		"--url",
		url,
	}
	if not allow_http_errors then
		args[#args + 1] = "--fail-with-body"
	end
	return args
end

function M.fetch(url, opts)
	if url:match("^https://api%.github%.com/") then
		return require("clihub.http").fetch(url, opts)
	end
	return M.run(M.curl(url))
end

function M.download(url, path)
	local args = M.curl(url)
	vim.list_extend(args, { "--output", path })
	M.run(args, { timeout = 400000 })
end

function M.checksum(text, format, filename)
	local matches = {}
	if format == "raw" then
		matches[1] = vim.trim(text)
	elseif format == "gnu" then
		for line in text:gmatch("[^\r\n]+") do
			local digest, name = line:match("^(%x+)%s+[%* ](.*)$")
			if name == filename then
				matches[#matches + 1] = digest
			end
		end
	else
		error("Unsupported checksum format: " .. tostring(format))
	end
	assert(
		#matches == 1 and #matches[1] == 64 and matches[1]:match("^%x+$"),
		"Missing, duplicate, or invalid SHA-256 for " .. tostring(filename)
	)
	return matches[1]:lower()
end

function M.elf(path, platform)
	local stat = uv.fs_lstat(path)
	assert(stat and stat.type == "file" and stat.size >= 20, "Not a regular executable: " .. path)
	local file = assert(io.open(path, "rb"))
	local head = file:read(20)
	file:close()
	assert(
		head:sub(1, 4) == "\127ELF" and head:byte(5) == 2 and head:byte(6) == 1,
		"Expected a 64-bit little-endian ELF binary: " .. path
	)
	local machine = head:byte(19) + head:byte(20) * 256
	assert(machine == (platform == "linux-amd64" and 62 or 183), "Wrong executable architecture: " .. path)
end

return M
