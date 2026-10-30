-- Run: nvim --headless -u NONE -i NONE -l tests/run.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local u = require("clihub.util")
local sources = require("clihub.sources")
local install = require("clihub.install")
local hub = require("clihub")
local uv = vim.uv
local workspace = vim.fn.tempname() .. "-clihub-tests"
u.mkdir(workspace)
local passed, failed = 0, 0

local function check(name, fn)
	local ok, err = xpcall(fn, debug.traceback)
	if ok then
		passed = passed + 1
		print("PASS " .. name)
	else
		failed = failed + 1
		print("FAIL " .. name .. "\n" .. err)
	end
end

local function equal(actual, expected)
	assert(vim.deep_equal(actual, expected), "Expected " .. vim.inspect(expected) .. "; got " .. vim.inspect(actual))
end

local function raises(fn, needle)
	local ok, err = pcall(fn)
	assert(not ok, "Expected failure")
	assert(tostring(err):find(needle, 1, true), tostring(err))
end

local function await(fn)
	local finished, success, result = false, nil, nil
	u.async(fn, function(ok, value)
		success, result, finished = ok, value, true
	end)
	assert(
		vim.wait(20000, function()
			return finished
		end, 10),
		"Async operation timed out"
	)
	assert(success, result)
	return result
end

local function process(args)
	local result = vim.system(args, { text = true }):wait(10000)
	assert(result.code == 0, result.stderr)
	return result.stdout
end

local platform = u.platform()
local fixture = workspace .. "/fixture"
u.mkdir(fixture .. "/bin")
assert(uv.fs_copyfile(vim.fn.exepath("true"), fixture .. "/bin/probe"))
u.write(fixture .. "/probe", "This is a completion script, not the executable\n")
local archive = workspace .. "/fixture.tar.gz"
process({ "tar", "-czf", archive, "-C", fixture, "probe", "bin/probe" })
local digest = process({ "sha256sum", archive }):match("^%x+")
local original_fetch, original_download = u.fetch, u.download
local release_tag, checksum_tag, downloads, invalid_checksum = "v1.0.0", "v1.0.0", 0, false
local recipe = {
	description = "Offline fixture",
	source = { kind = "github", repo = "example/probe" },
	installer = "artifact",
	targets = { [platform] = { asset = "probe-{version}.tar.gz", format = "tar.gz", bins = { probe = "bin/probe" } } },
	checksum = { asset = "checksums.txt", format = "gnu" },
	verify = { probe = { "--version" } },
}

u.fetch = function(url)
	if url:find("checksums.txt", 1, true) then
		return (invalid_checksum and string.rep("0", 64) or digest) .. "  probe-" .. checksum_tag:sub(2) .. ".tar.gz\n"
	end
	local tag = url:match("/tags/(.*)$") or release_tag
	checksum_tag = tag
	return vim.json.encode({
		tag_name = tag,
		assets = {
			{
				name = "probe-" .. tag:gsub("^v", "") .. ".tar.gz",
				browser_download_url = "https://example.test/probe.tar.gz",
			},
			{ name = "checksums.txt", browser_download_url = "https://example.test/checksums.txt" },
		},
	})
end
u.download = function(_, path)
	downloads = downloads + 1
	assert(uv.fs_copyfile(archive, path))
end

check("registry validates every bundled target and rejects traversal/templates", function()
	local registry = require("clihub.registry")
	equal(vim.tbl_count(registry.load()), 7)
	for _, target in ipairs({ "linux-amd64", "linux-arm64" }) do
		for id, entry in pairs(registry.bundled) do
			assert(entry.targets[target], id .. " missing " .. target)
		end
	end
	local bad = vim.deepcopy(recipe)
	bad.targets[platform].bins.probe = "../outside"
	raises(function()
		registry.validate("probe", bad)
	end, "invalid member path")
	raises(function()
		u.expand("{unknown}", { tag = "v1" })
	end, "Unknown template")
	raises(function()
		u.expand("{tag", { tag = "v1" })
	end, "Invalid template")
end)

check("checksum parser matches exact names, rejects duplicates and missing hashes", function()
	equal(
		u.checksum(
			digest .. "  probe.tar.gz\n" .. string.rep("0", 64) .. "  probe.tar.gz.sbom.json\n",
			"gnu",
			"probe.tar.gz"
		),
		digest
	)
	equal(u.checksum(digest .. " *probe.tar.gz", "gnu", "probe.tar.gz"), digest)
	equal(u.checksum(digest .. "\n", "raw", "unused"), digest)
	raises(function()
		u.checksum(digest .. "  a\n" .. digest .. "  a", "gnu", "a")
	end, "duplicate")
	raises(function()
		u.checksum("", "gnu", "a")
	end, "Missing")
end)

check("source resolution preserves tags, strips one v, and supports exact pins", function()
	local resolved = sources.resolve("probe", recipe, platform)
	equal(resolved.tag, "v1.0.0")
	equal(resolved.bins, { probe = "bin/probe" })
	equal(sources.resolve("probe", recipe, platform, "v0.9.0").tag, "v0.9.0")
	raises(function()
		sources.resolve("probe", recipe, "linux-other")
	end, "no binary")
end)

check("GitLab project/tag encoding and direct URLs use one resolved version", function()
	local saved = u.fetch
	local request
	u.fetch = function(url)
		request = url
		return vim.json.encode({
			tag_name = "v1/test",
			assets = {
				links = {
					{ name = "probe-1/test.tar.gz", direct_asset_url = "https://example.test/asset" },
					{ name = "checksums.txt", url = "https://example.test/checksums.txt" },
				},
			},
		})
	end
	local entry = vim.deepcopy(recipe)
	entry.source = { kind = "gitlab", api = "https://gitlab.test/api/v4", project = "group/sub/project" }
	local resolved = sources.resolve("probe", entry, platform, "v1/test")
	assert(request:find("group%2Fsub%2Fproject/releases/v1%2Ftest", 1, true))
	equal(resolved.url, "https://example.test/asset")
	entry.source = { kind = "direct", latest = "https://example.test/stable.txt" }
	entry.targets[platform] = {
		url = "https://example.test/{tag}/probe",
		format = "binary",
		bins = { probe = "." },
		checksum = { url = "https://example.test/{tag}/probe.sha256", format = "raw" },
	}
	u.fetch = function()
		return "v2.0.0\n"
	end
	resolved = sources.resolve("probe", entry, platform)
	equal(resolved.url, "https://example.test/v2.0.0/probe")
	equal(resolved.checksum.url, "https://example.test/v2.0.0/probe.sha256")
	u.fetch = saved
end)

local root = workspace .. "/managed"
check("install extracts the exact ELF member and executes its version check", function()
	local result = await(function()
		return install.apply(root, "probe", recipe, platform)
	end)
	equal(result.tag, "v1.0.0")
	equal(uv.fs_readlink(root .. "/bin/probe"), "../packages/probe/current/bin/probe")
	equal(install.current(root, "probe").tag, "v1.0.0")
	u.elf(assert(uv.fs_realpath(root .. "/bin/probe")), platform)
end)

-- ELF validation applies to staged files, while users execute exported symlinks.
check("managed export runs and repeated installs are idempotent", function()
	process({ root .. "/bin/probe", "--version" })
	local before = downloads
	local result = await(function()
		return install.apply(root, "probe", recipe, platform)
	end)
	assert(result.unchanged)
	equal(downloads, before)
end)

check("missing exports are repaired; foreign exports are preserved", function()
	u.unlink(root .. "/bin/probe")
	await(function()
		return install.apply(root, "probe", recipe, platform)
	end)
	assert(uv.fs_readlink(root .. "/bin/probe"))
	u.unlink(root .. "/bin/probe")
	u.write(root .. "/bin/probe", "foreign")
	raises(function()
		await(function()
			install.apply(root, "probe", recipe, platform)
		end)
	end, "foreign command")
	equal(u.read(root .. "/bin/probe"), "foreign")
	u.unlink(root .. "/bin/probe")
	install.reconcile(root, "probe", { probe = true })
end)

check("checksum failure preserves the active version and releases the lock", function()
	release_tag, invalid_checksum = "v2.0.0", true
	raises(function()
		await(function()
			install.apply(root, "probe", recipe, platform)
		end)
	end, "SHA-256 mismatch")
	equal(install.current(root, "probe").tag, "v1.0.0")
	process({ root .. "/bin/probe", "--version" })
	assert(not uv.fs_lstat(root .. "/.lock"))
	invalid_checksum = false
end)

check("update switches versions and cleans the superseded version", function()
	await(function()
		install.apply(root, "probe", recipe, platform)
	end)
	equal(install.current(root, "probe").tag, "v2.0.0")
	equal(#vim.fn.glob(root .. "/packages/probe/versions/*", false, true), 1)
end)

check("interruption before activation preserves the current installation", function()
	local changed = vim.deepcopy(recipe)
	changed.description = "interrupted operation"
	raises(function()
		await(function()
			install.apply(root, "probe", changed, platform, nil, function(message)
				if message:match("^activating") then
					error("simulated interruption")
				end
			end)
		end)
	end, "simulated interruption")
	equal(install.current(root, "probe").tag, "v2.0.0")
	process({ root .. "/bin/probe", "--version" })
	assert(not uv.fs_lstat(root .. "/.lock"))
end)

check("export failure after activation rolls back the previous version", function()
	local saved_reconcile = install.reconcile
	local attempts = 0
	install.reconcile = function(...)
		attempts = attempts + 1
		if attempts == 1 then
			error("simulated export failure")
		end
		return saved_reconcile(...)
	end
	local changed = vim.deepcopy(recipe)
	changed.description = "activation rollback"
	raises(function()
		await(function()
			install.apply(root, "probe", changed, platform)
		end)
	end, "simulated export failure")
	install.reconcile = saved_reconcile
	equal(install.current(root, "probe").fingerprint, vim.fn.sha256(u.canonical(recipe)))
	process({ root .. "/bin/probe", "--version" })
end)

check("non-ELF, wrong-architecture, and duplicate members fail before activation", function()
	local bad = vim.deepcopy(recipe)
	bad.targets[platform].bins.probe = "probe"
	raises(function()
		await(function()
			install.apply(root, "probe", bad, platform)
		end)
	end, "ELF")
	local binary = workspace .. "/wrong-arch"
	local file = assert(io.open(fixture .. "/bin/probe", "rb"))
	local contents = file:read("*a")
	file:close()
	u.write(
		binary,
		contents:sub(1, 18)
			.. (platform == "linux-amd64" and string.char(183, 0) or string.char(62, 0))
			.. contents:sub(21)
	)
	raises(function()
		u.elf(binary, platform)
	end, "Wrong executable architecture")
	local duplicate = workspace .. "/duplicate.tar.gz"
	process({ "tar", "-czf", duplicate, "-C", fixture, "bin/probe", "bin/probe" })
	local saved_archive, saved_digest = archive, digest
	archive, digest = duplicate, process({ "sha256sum", duplicate }):match("^%x+")
	local changed = vim.deepcopy(recipe)
	changed.description = "force reinstall"
	raises(function()
		await(function()
			install.apply(root, "probe", changed, platform)
		end)
	end, "duplicate archive member")
	archive, digest = saved_archive, saved_digest
	equal(install.current(root, "probe").tag, "v2.0.0")
end)

check("live locks reject competitors and dead-owner locks are reclaimed", function()
	local release = install.lock(root)
	raises(function()
		install.lock(root)
	end, "busy")
	release()
	u.mkdir(root .. "/.lock")
	u.write(root .. "/.lock/owner.2147483647.abc.json", vim.json.encode({ pid = 2147483647 }))
	release = install.lock(root)
	release()
	assert(not uv.fs_lstat(root .. "/.lock"))
end)

check("multiple commands share one atomic package version", function()
	local multi = vim.deepcopy(recipe)
	multi.targets[platform].bins.probe2 = "bin/probe"
	multi.verify.probe2 = { "--version" }
	await(function()
		install.apply(root, "probe", multi, platform)
	end)
	process({ root .. "/bin/probe2", "--version" })
	equal(uv.fs_readlink(root .. "/bin/probe2"), "../packages/probe/current/bin/probe2")
	await(function()
		install.apply(root, "probe", recipe, platform)
	end)
	assert(not uv.fs_lstat(root .. "/bin/probe2"))
end)

check("explicit update installs absent tools; bulk update only updates installed unpinned tools", function()
	local upsert = vim.deepcopy(recipe)
	upsert.targets[platform].bins = { upsertprobe = "bin/probe" }
	upsert.verify = { upsertprobe = { "--version" } }
	hub.setup({
		root = root,
		path = "none",
		registry = { probe = recipe, upsertprobe = upsert },
		versions = { probe = "v1.0.0" },
	})
	local function action(kind, ids)
		local results
		hub.run(kind, ids, function(value)
			results = value
		end)
		assert(vim.wait(20000, function()
			return results ~= nil
		end, 10))
		return results
	end
	assert(action("install", { "probe" }).probe.ok)
	equal(install.current(root, "probe").tag, "v1.0.0")
	equal(action("update", {}), {})
	assert(not install.current(root, "upsertprobe"), "Bulk update installed an absent tool")
	assert(action("check", { "probe" }).probe.ok)
	equal(hub.status("probe").available, release_tag)
	assert(action("update", { "upsertprobe" }).upsertprobe.ok)
	equal(install.current(root, "upsertprobe").tag, release_tag)
	process({ root .. "/bin/upsertprobe", "--version" })
	local updated = action("update", {})
	equal(vim.tbl_keys(updated), { "upsertprobe" })
	assert(updated.upsertprobe.ok and updated.upsertprobe.result.unchanged)
	assert(not hub.busy)
end)

check("failed upstream checks clear stale availability and preserve installed commands", function()
	local saved = u.fetch
	u.fetch = function()
		error("API rate limit exceeded; retry after reset")
	end
	local results
	hub.run("check", { "probe" }, function(value)
		results = value
	end)
	assert(vim.wait(5000, function()
		return results ~= nil
	end, 10))
	assert(not results.probe.ok and results.probe.error:find("API rate limit", 1, true))
	equal(hub.status("probe").available, nil)
	equal(install.current(root, "probe").tag, "v1.0.0")
	process({ root .. "/bin/probe", "--version" })
	assert(not hub.busy)
	u.fetch = saved
end)

check("UI installs queue in order, ignore repeat presses, and continue after failure", function()
	local entries = { probe = recipe }
	for _, id in ipairs({ "queue_a", "queue_b", "queue_c" }) do
		entries[id] = vim.deepcopy(recipe)
		entries[id].targets[platform].bins = { [id] = id == "queue_b" and "missing" or "bin/probe" }
		entries[id].verify = { [id] = { "--version" } }
	end
	local queue_root = workspace .. "/queue"
	hub.setup({ root = queue_root, path = "none", registry = entries })
	local saved_download, saved_notify = u.download, vim.notify
	local order, notices = {}, {}
	u.download = function(url, path)
		u.run({ "sleep", "0.05" })
		return saved_download(url, path)
	end
	vim.notify = function(message)
		notices[#notices + 1] = message
	end
	vim.api.nvim_create_autocmd("User", {
		pattern = "CliHubChanged",
		callback = function()
			for _, id in ipairs({ "queue_a", "queue_b", "queue_c" }) do
				if hub.progress[id] == "install" then
					order[#order + 1] = id
				end
			end
		end,
		once = false,
		group = vim.api.nvim_create_augroup("CliHubQueueTest", { clear = true }),
	})
	require("clihub.ui").open()
	local function press_install(id)
		for row, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
			if line:find(id, 1, true) then
				vim.api.nvim_win_set_cursor(0, { row, 0 })
				vim.fn.maparg("i", "n", false, true).callback()
				return
			end
		end
		error("Missing UI tool: " .. id)
	end
	press_install("queue_a")
	assert(hub.busy)
	press_install("queue_b")
	press_install("queue_b")
	equal(hub.status("queue_b").progress, "queued install")
	local completed
	hub.run("install", { "queue_c" }, function(results)
		completed = results
	end)
	assert(table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("queued install", 1, true))
	raises(function()
		hub.run("install", { "unknown" })
	end, "Unknown tool")
	raises(function()
		hub.setup({ root = queue_root })
	end, "Cannot reconfigure")
	vim.fn.maparg("q", "n", false, true).callback()
	assert(vim.wait(10000, function()
		return completed ~= nil and not hub.busy
	end, 10))
	equal(order, { "queue_a", "queue_b", "queue_c" })
	assert(hub.results.queue_a.ok and not hub.results.queue_b.ok and completed.queue_c.ok)
	assert(install.current(queue_root, "queue_a") and install.current(queue_root, "queue_c"))
	assert(not uv.fs_lstat(queue_root .. "/.lock"))
	equal(#notices, 2)
	assert(not hub.status("queue_b").progress and not hub.status("queue_c").progress)
	vim.api.nvim_del_augroup_by_name("CliHubQueueTest")
	u.download, vim.notify = saved_download, saved_notify
	hub.setup({ root = root, path = "none", registry = { probe = recipe } })
end)

local function operation(kind, ids)
	local results
	hub.run(kind, ids, function(value)
		results = value
	end)
	assert(vim.wait(10000, function()
		return results ~= nil
	end, 10))
	return results
end

check("version comparison orders upgrades, downgrades, prereleases, and ignores build metadata", function()
	for _, pair in ipairs({ { "v1.10.0", "1.9.0" }, { "1.0.0", "1.0.0-rc.2" }, { "1.0.0-rc.10", "1.0.0-rc.2" } }) do
		equal(u.compare(pair[1], pair[2]), 1)
		equal(u.compare(pair[2], pair[1]), -1)
	end
	equal(u.compare("v1.2.3+build.1", "1.2.3+build.2"), 0)
	equal(u.compare("release-2026-10", "nightly-42"), nil)
	equal(u.compare("nightly-42", "nightly-42"), 0)
end)

check("checks survive restart, ignore pins, and invalidate changed recipes and corrupt cache", function()
	local opts = { root = root, path = "none", registry = { probe = recipe }, versions = { probe = "v1.0.0" } }
	hub.setup(opts)
	assert(operation("check", { "probe" }).probe.ok)
	local timestamp = hub.status("probe").checked_at
	assert(timestamp and hub.available.probe == release_tag)
	hub.setup(opts)
	equal(hub.available.probe, release_tag)
	equal(hub.status("probe").checked_at, timestamp)
	equal(hub.status("probe").status, "pinned")
	local path = root .. "/checks/probe.json"
	local saved = u.read(path)
	local changed = vim.deepcopy(recipe)
	changed.description = "new recipe"
	hub.setup({ root = root, path = "none", registry = { probe = changed } })
	equal(hub.available.probe, nil)
	u.write(path, "broken JSON")
	hub.setup(opts)
	equal(hub.available.probe, nil)
	u.write(path, saved)
	hub.setup(opts)
end)

check("update preserves a newer installation and rejects unordered release changes", function()
	local managed = workspace .. "/newer"
	await(function()
		install.apply(managed, "probe", recipe, platform, "v9.0.0")
	end)
	local before = downloads
	local result = await(function()
		return install.apply(managed, "probe", recipe, platform, nil, nil, { only_upgrade = true })
	end)
	assert(result.newer_installed and result.unchanged)
	equal(install.current(managed, "probe").tag, "v9.0.0")
	equal(downloads, before)
	local tag = release_tag
	release_tag = "nightly-42"
	raises(function()
		await(function()
			install.apply(managed, "probe", recipe, platform, nil, nil, { only_upgrade = true })
		end)
	end, "Cannot order release tags")
	release_tag = tag
	assert(not uv.fs_lstat(managed .. "/.lock"))
end)

check("lockfiles restore exact tags and hashes, ensure on startup, and reject drift", function()
	local saved_config = { root = root, path = "none", registry = { probe = recipe } }
	local managed, lockpath = workspace .. "/locked", workspace .. "/clihub-lock.json"
	hub.setup({
		root = managed,
		path = "none",
		registry = { probe = recipe },
		versions = { probe = "v1.0.0" },
		lockfile = lockpath,
	})
	assert(operation("install", { "probe" }).probe.ok)
	local locked = hub.lock()
	equal(locked.probe.tag, "v1.0.0")
	equal(locked.probe.sha256[platform], digest)
	local file = u.read(lockpath)
	hub.lock()
	equal(u.read(lockpath), file)
	local restored = workspace .. "/restored"
	hub.setup({ root = restored, path = "none", registry = { probe = recipe }, lockfile = lockpath })
	local complete
	hub.restore(function(results)
		complete = results
	end)
	assert(vim.wait(10000, function()
		return complete ~= nil
	end, 10))
	assert(complete.probe.ok, complete.probe.error)
	equal(install.current(restored, "probe").tag, "v1.0.0")
	local config = {
		root = restored,
		path = "none",
		registry = { probe = recipe },
		lockfile = lockpath,
		ensure_installed = { "probe" },
	}
	local before = downloads
	hub.setup(config)
	vim.wait(20, function()
		return false
	end)
	equal(downloads, before)
	config.root = workspace .. "/ensured"
	hub.setup(config)
	assert(vim.wait(10000, function()
		return install.current(config.root, "probe") ~= nil and not hub.busy
	end, 10))
	equal(install.current(config.root, "probe").tag, "v1.0.0")
	local forged = vim.json.decode(file)
	forged.packages.probe.sha256[platform] = string.rep("0", 64)
	u.write(lockpath, vim.json.encode(forged))
	hub.setup({ root = workspace .. "/tampered", path = "none", registry = { probe = recipe }, lockfile = lockpath })
	complete = nil
	hub.restore(function(results)
		complete = results
	end)
	assert(vim.wait(10000, function()
		return complete ~= nil
	end, 10))
	assert(not complete.probe.ok and complete.probe.error:find("Lockfile SHA-256 mismatch", 1, true))
	assert(not install.current(hub.config.root, "probe"))
	u.write(lockpath, file)
	local changed = vim.deepcopy(recipe)
	changed.description = "recipe drift"
	hub.setup({ root = restored, path = "none", registry = { probe = changed }, lockfile = lockpath })
	raises(hub.restore, "Recipe changed")
	hub.setup({
		root = restored,
		path = "none",
		registry = { probe = recipe },
		versions = { probe = "v9.0.0" },
		lockfile = lockpath,
	})
	raises(hub.restore, "Version pin conflicts")
	u.write(lockpath, "{")
	raises(hub.restore, "Invalid CliHub lockfile")
	hub.setup(saved_config)
end)

check("release links cover GitHub, GitLab, direct recipes, and browser action", function()
	equal(sources.release_url(recipe, "v1.0/test"), "https://github.com/example/probe/releases/tag/v1.0%2Ftest")
	local entry = vim.deepcopy(recipe)
	entry.source = { kind = "gitlab", api = "https://gitlab.test/api/v4", project = "group/sub/project" }
	equal(sources.release_url(entry, "v1.0"), "https://gitlab.test/group/sub/project/-/releases/v1.0")
	entry.source = { kind = "direct", latest = "https://example.test/stable.txt" }
	equal(sources.release_url(entry, "v1.0"), nil)
	entry.releases = "https://example.test/releases/{tag}"
	equal(sources.release_url(entry, "v1.0"), "https://example.test/releases/v1.0")
	equal(sources.release_url(entry), nil)
	local linked = vim.deepcopy(recipe)
	linked.releases = "https://example.test/releases/{tag}"
	equal(u.fingerprint(linked), u.fingerprint(recipe))
	local saved, opened = vim.ui.open
	vim.ui.open = function(url)
		opened = url
	end
	hub.available.probe = "v1.0.0"
	hub.open_release("probe")
	equal(opened, "https://github.com/example/probe/releases/tag/v1.0.0")
	vim.ui.open = saved
end)

check("GitHub auth is private, cached per credential, revalidates ETags, and explains rate limits", function()
	local http = require("clihub.http")
	local saved_run, saved_gh, saved_github = u.run, vim.env.GH_TOKEN, vim.env.GITHUB_TOKEN
	local calls, gh_calls, code, response_headers = 0, 0, "200", 'ETag: "one"\r\n'
	local directory = workspace .. "/http"
	local secret, expected_secret = "dummy-token-for-test", "dummy-token-for-test"
	local response = vim.json.encode({ tag_name = "v1.0.0" })
	local saw_etag = false
	u.run = function(args, opts)
		if args[1] == "gh" then
			gh_calls = gh_calls + 1
			return secret .. "\n"
		end
		calls = calls + 1
		assert(not table.concat(args, " "):find(secret, 1, true), "Token exposed in command arguments")
		assert(opts.sensitive)
		if expected_secret then
			assert(opts.stdin and opts.stdin:find(expected_secret, 1, true))
		else
			assert(not opts.stdin)
		end
		for i, value in ipairs(args) do
			if value == "--dump-header" then
				u.write(args[i + 1], "HTTP/2 " .. code .. "\r\n" .. response_headers .. "\r\n")
			end
			if value == "--output" and code ~= "304" then
				u.write(args[i + 1], response)
			end
			if value == 'If-None-Match: "one"' then
				saw_etag = true
			end
		end
		return code
	end
	local url = "https://api.github.com/repos/example/probe/releases/latest"
	http.setup({ token = secret, use_gh = false }, directory)
	equal(http.fetch(url), response)
	equal(http.fetch(url), response)
	equal(calls, 1)
	code = "304"
	equal(http.fetch(url, { refresh = true }), response)
	assert(saw_etag)
	equal(calls, 2)
	for _, path in ipairs(vim.fn.glob(directory .. "/*.json", false, true)) do
		assert(not u.read(path):find(secret, 1, true), "Token persisted to disk")
		equal(uv.fs_stat(path).mode % 512, 384)
	end
	code, response_headers = "403", "x-ratelimit-remaining: 0\r\nx-ratelimit-reset: 1800000000\r\n"
	raises(function()
		http.fetch(url, { refresh = true })
	end, "GitHub API rate limit exceeded")
	code, response_headers = "401", ""
	raises(function()
		http.fetch(url, { refresh = true })
	end, "credentials rejected")
	raises(function()
		http.fetch("https://other.test/releases/latest")
	end, "restricted to api.github.com")
	code = "200"
	vim.env.GH_TOKEN, vim.env.GITHUB_TOKEN = nil, nil
	http.setup({ use_gh = true }, directory .. "/gh")
	if vim.fn.executable("gh") == 1 then
		http.fetch(url)
		equal(gh_calls, 1)
	end
	vim.env.GH_TOKEN = "environment-test-token"
	expected_secret = vim.env.GH_TOKEN
	http.setup({
		token = function()
			return nil
		end,
		use_gh = false,
	}, directory)
	http.fetch(url)
	equal(calls, vim.fn.executable("gh") == 1 and 6 or 5)
	http.setup({ token = "different-token", use_gh = false }, directory)
	expected_secret = "different-token"
	http.fetch(url)
	local before = calls
	local cached_path = directory .. "/" .. vim.fn.sha256(url .. "\ndifferent-token") .. ".json"
	local cached = u.json_read(cached_path)
	cached.body = "broken JSON"
	u.write(cached_path, vim.json.encode(cached))
	http.fetch(url)
	equal(calls, before + 1)
	cached = u.json_read(cached_path)
	cached.time = os.time() - 600
	u.write(cached_path, vim.json.encode(cached))
	http.fetch(url)
	equal(calls, before + 2)
	u.run, vim.env.GH_TOKEN, vim.env.GITHUB_TOKEN = saved_run, saved_gh, saved_github
	local success, failure = pcall(function()
		await(function()
			return u.run({ "sh", "-c", "printf dummy-token-for-test; exit 1" }, { sensitive = true })
		end)
	end)
	assert(not success and tostring(failure):find("request failed", 1, true))
	assert(not tostring(failure):find("dummy-token-for-test", 1, true), "Sensitive output leaked through errors")
	http.setup({ use_gh = false }, workspace .. "/http-finished")
end)

check("raw binary source installs with a raw checksum", function()
	local saved_fetch, saved_download = u.fetch, u.download
	local binary = fixture .. "/bin/probe"
	local sha = process({ "sha256sum", binary }):match("^%x+")
	local entry = vim.deepcopy(recipe)
	entry.source = { kind = "direct", latest = "https://example.test/stable.txt" }
	entry.targets[platform] = {
		url = "https://example.test/{tag}/probe",
		format = "binary",
		bins = { rawprobe = "." },
		checksum = { url = "https://example.test/{tag}/probe.sha256", format = "raw" },
	}
	entry.verify = { rawprobe = { "--version" } }
	u.fetch = function(url)
		return url:find("sha256", 1, true) and sha or "v1.0.0"
	end
	u.download = function(_, path)
		assert(uv.fs_copyfile(binary, path))
	end
	await(function()
		install.apply(root, "rawprobe", entry, platform)
	end)
	process({ root .. "/bin/rawprobe", "--version" })
	u.fetch, u.download = saved_fetch, saved_download
end)

check("removal leaves foreign files and other packages intact", function()
	u.unlink(root .. "/bin/probe")
	u.write(root .. "/bin/probe", "external replacement")
	await(function()
		return install.remove(root, "probe")
	end)
	equal(u.read(root .. "/bin/probe"), "external replacement")
	assert(not install.current(root, "probe"))
	process({ root .. "/bin/rawprobe", "--version" })
end)

check("command registration and UI work without network or installation", function()
	vim.cmd("runtime plugin/clihub.lua")
	assert(vim.fn.exists(":CliHub") == 2)
	vim.cmd("CliHub")
	equal(vim.bo.filetype, "clihub")
	assert(vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]:find("CliHub", 1, true))
	equal(hub.complete("in", "CliHub in"), { "install" })
	assert(vim.tbl_contains(hub.complete("", "CliHub install "), "probe"))
end)

u.fetch, u.download = original_fetch, original_download
u.delete(workspace)
print(string.format("\nCliHub: %d passed, %d failed", passed, failed))
if failed > 0 then
	vim.cmd("cquit 1")
end
