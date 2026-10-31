local u = require("clihub.util")
local M = {}
local config, token, token_loaded = {}, nil, false
local token_source, last_status

function M.setup(opts, directory)
	config = vim.tbl_extend("force", { use_gh = true, cache_ttl = 300 }, opts or {})
	assert(type(config.cache_ttl) == "number" and config.cache_ttl >= 0, "github.cache_ttl must be nonnegative")
	assert(
		config.token == nil or type(config.token) == "string" or type(config.token) == "function",
		"Invalid GitHub token option"
	)
	config.directory = directory
	token, token_loaded = nil, false
	token_source, last_status = nil, nil
end

-- Report provenance without exposing credentials or resolving them as a side effect.
function M.auth_status()
	return {
		resolved = token_loaded,
		authenticated = token_loaded and token ~= nil,
		source = token_source,
		last_status = last_status,
	}
end

local function credentials()
	if not token_loaded then
		if type(config.token) == "function" then
			local ok, value = pcall(config.token)
			assert(ok, "GitHub token callback failed")
			token = value
		else
			token = config.token
		end
		token_source = "github.token"
		if not token or token == "" then
			token = vim.env.GH_TOKEN
			token_source = "GH_TOKEN"
		end
		if not token or token == "" then
			token = vim.env.GITHUB_TOKEN
			token_source = "GITHUB_TOKEN"
		end
		if (not token or token == "") and config.use_gh and vim.fn.executable("gh") == 1 then
			local ok, result = pcall(
				u.run,
				{ "gh", "auth", "token", "--hostname", "github.com" },
				{ sensitive = true, timeout = 5000 }
			)
			token = ok and vim.trim(result) or nil
			token_source = "gh auth token"
		end
		assert(not token or (type(token) == "string" and not token:find("[%c]")), "Invalid GitHub token")
		if token == "" then
			token = nil
		end
		if not token then
			token_source = "anonymous"
		end
		token_loaded = true
	end
	return token
end

function M.resolve_auth()
	credentials()
	return M.auth_status()
end

function M.fetch(url, opts)
	assert(url:match("^https://api%.github%.com/"), "GitHub authentication is restricted to api.github.com")
	if not config.directory then
		M.setup({}, vim.fn.stdpath("cache") .. "/clihub/http")
	end
	local secret = credentials()
	local path = config.directory .. "/" .. vim.fn.sha256(url .. "\n" .. (secret or "anonymous")) .. ".json"
	local cached = u.json_read(path)
	if cached and (type(cached.body) ~= "string" or type(cached.time) ~= "number") then
		cached = nil
	end
	if cached then
		local valid, release = pcall(vim.json.decode, cached.body)
		if not valid or type(release) ~= "table" or type(release.tag_name) ~= "string" then
			cached = nil
		end
	end
	if
		cached
		and not (opts or {}).refresh
		and os.time() - cached.time >= 0
		and os.time() - cached.time < config.cache_ttl
	then
		return cached.body
	end
	local headers_path, body_path = vim.fn.tempname(), vim.fn.tempname()
	local ok, result = xpcall(function()
		local args = u.curl(url, true)
		vim.list_extend(args, { "--dump-header", headers_path, "--output", body_path, "--write-out", "%{http_code}" })
		if cached and type(cached.etag) == "string" and not cached.etag:find("[%c]") then
			vim.list_extend(args, { "--header", "If-None-Match: " .. cached.etag })
		end
		local stdin
		if secret then
			vim.list_extend(args, { "--config", "-" })
			stdin = 'header = "Authorization: Bearer ' .. secret:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"\n'
		end
		local status = tonumber(u.run(args, { stdin = stdin, sensitive = true }))
		last_status = status
		local headers = {}
		for line in u.read(headers_path):gmatch("[^\r\n]+") do
			if line:match("^HTTP/") then
				headers = {}
			end
			local key, value = line:match("^([^:]+):%s*(.*)$")
			if key then
				headers[key:lower()] = value
			end
		end
		local body = vim.uv.fs_stat(body_path) and u.read(body_path) or ""
		if status == 304 and cached then
			body = cached.body
		elseif status == 403 or status == 429 then
			if headers["x-ratelimit-remaining"] == "0" or status == 429 or body:lower():find("rate limit", 1, true) then
				local reset = tonumber(headers["x-ratelimit-reset"])
				error(
					"GitHub API rate limit exceeded. "
						.. (reset and ("Resets at " .. os.date("!%Y-%m-%d %H:%M UTC", reset) .. ". ") or "Retry later. ")
						.. "Set GH_TOKEN/GITHUB_TOKEN or sign in with gh auth login."
				)
			end
			error("GitHub HTTP " .. status .. ": access denied; check repository access and credentials")
		elseif status == 401 then
			error("GitHub HTTP 401: credentials rejected; check GH_TOKEN/GITHUB_TOKEN or gh auth login")
		elseif status ~= 200 then
			error("GitHub HTTP " .. tostring(status) .. ": release unavailable")
		end
		-- Cache only successful release responses, never credentials or response headers.
		local release = vim.json.decode(body)
		assert(type(release) == "table" and type(release.tag_name) == "string", "Invalid GitHub release response")
		u.atomic_write(
			path,
			vim.json.encode({
				body = body,
				etag = headers.etag or (status == 304 and cached and cached.etag or nil),
				time = os.time(),
			})
		)
		return body
	end, debug.traceback)
	u.unlink(headers_path)
	u.unlink(body_path)
	if not ok then
		error(result, 0)
	end
	return result
end

return M
