local u = require("clihub.util")
local M = {}

local function github(repo, assets, bins, checksum, verify)
	local targets = {}
	for arch, asset in pairs(assets) do
		targets["linux-" .. arch] = { asset = asset, format = "tar.gz", bins = bins[arch] or bins }
	end
	return {
		description = repo,
		source = { kind = "github", repo = repo },
		installer = "artifact",
		targets = targets,
		checksum = checksum,
		verify = verify,
	}
end

M.bundled = {
	pgcli = {
		description = "PostgreSQL client with completion and syntax highlighting",
		source = { kind = "pypi", package = "pgcli" },
		installer = "uv",
		python = ">=3.10",
		requirements = { "psycopg[binary]" },
		bins = { pgcli = "pgcli" },
		verify = { pgcli = { "--version" } },
	},
	gh = github("cli/cli", {
		amd64 = "gh_{version}_linux_amd64.tar.gz",
		arm64 = "gh_{version}_linux_arm64.tar.gz",
	}, {
		amd64 = { gh = "gh_{version}_linux_amd64/bin/gh" },
		arm64 = { gh = "gh_{version}_linux_arm64/bin/gh" },
	}, { asset = "gh_{version}_checksums.txt", format = "gnu" }, { gh = { "--version" } }),
	rg = github("BurntSushi/ripgrep", {
		amd64 = "ripgrep-{version}-x86_64-unknown-linux-musl.tar.gz",
		arm64 = "ripgrep-{version}-aarch64-unknown-linux-musl.tar.gz",
	}, {
		amd64 = { rg = "ripgrep-{version}-x86_64-unknown-linux-musl/rg" },
		arm64 = { rg = "ripgrep-{version}-aarch64-unknown-linux-musl/rg" },
	}, { asset = "{asset}.sha256", format = "gnu" }, { rg = { "--version" } }),
	grpcurl = github(
		"fullstorydev/grpcurl",
		{
			amd64 = "grpcurl_{version}_linux_x86_64.tar.gz",
			arm64 = "grpcurl_{version}_linux_arm64.tar.gz",
		},
		{ grpcurl = "grpcurl" },
		{ asset = "grpcurl_{version}_checksums.txt", format = "gnu" },
		{ grpcurl = { "-version" } }
	),
	k9s = github("derailed/k9s", {
		amd64 = "k9s_Linux_amd64.tar.gz",
		arm64 = "k9s_Linux_arm64.tar.gz",
	}, { k9s = "k9s" }, { asset = "checksums.sha256", format = "gnu" }, { k9s = { "version", "--short" } }),
	kubectl = {
		description = "Kubernetes command line",
		releases = "https://github.com/kubernetes/kubernetes/releases/tag/{tag}",
		source = { kind = "direct", latest = "https://dl.k8s.io/release/stable.txt" },
		installer = "artifact",
		targets = {},
		verify = { kubectl = { "version", "--client=true", "--output=json" } },
	},
	glab = {
		description = "GitLab command line",
		source = { kind = "gitlab", api = "https://gitlab.com/api/v4", project = "gitlab-org/cli" },
		installer = "artifact",
		targets = {},
		checksum = { asset = "checksums.txt", format = "gnu" },
		verify = { glab = { "--version" } },
	},
	uv = github("astral-sh/uv", {
		amd64 = "uv-x86_64-unknown-linux-gnu.tar.gz",
		arm64 = "uv-aarch64-unknown-linux-gnu.tar.gz",
	}, {
		amd64 = { uv = "uv-x86_64-unknown-linux-gnu/uv", uvx = "uv-x86_64-unknown-linux-gnu/uvx" },
		arm64 = { uv = "uv-aarch64-unknown-linux-gnu/uv", uvx = "uv-aarch64-unknown-linux-gnu/uvx" },
	}, { asset = "{asset}.sha256", format = "gnu" }, { uv = { "--version" }, uvx = { "--version" } }),
	fastfetch = github("fastfetch-cli/fastfetch", {
		amd64 = "fastfetch-linux-amd64.tar.gz",
		arm64 = "fastfetch-linux-aarch64.tar.gz",
	}, {
		amd64 = { fastfetch = "fastfetch-linux-amd64/usr/bin/fastfetch" },
		arm64 = { fastfetch = "fastfetch-linux-aarch64/usr/bin/fastfetch" },
	}, { kind = "github_digest" }, { fastfetch = { "--version" } }),
}

for id, description in pairs({
	gh = "GitHub command line",
	rg = "Search file contents, fast",
	grpcurl = "Call gRPC services from your terminal",
	k9s = "Explore and manage Kubernetes clusters",
	uv = "Manage Python packages and environments",
	fastfetch = "Display system information",
}) do
	M.bundled[id].description = description
end

for _, arch in ipairs({ "amd64", "arm64" }) do
	local url = "https://dl.k8s.io/release/{tag}/bin/linux/" .. arch .. "/kubectl"
	M.bundled.kubectl.targets["linux-" .. arch] = {
		url = url,
		format = "binary",
		bins = { kubectl = "." },
		checksum = { url = url .. ".sha256", format = "raw" },
	}
	M.bundled.glab.targets["linux-" .. arch] = {
		asset = "glab_{version}_linux_" .. arch .. ".tar.gz",
		format = "tar.gz",
		bins = { glab = "bin/glab" },
	}
end

function M.target(recipe, platform)
	if recipe.installer == "uv" then
		assert(platform == "linux-amd64" or platform == "linux-arm64", "Unsupported platform")
		return { format = "uv", bins = recipe.bins }
	end
	return recipe.targets[platform]
end

function M.validate(id, recipe)
	assert(u.name(id), "Invalid package ID: " .. tostring(id))
	assert(
		type(recipe) == "table" and (recipe.installer == "artifact" or recipe.installer == "uv"),
		id .. ": unsupported installer"
	)
	local source = recipe.source
	assert(type(source) == "table", id .. ": missing source")
	assert(vim.tbl_contains({ "github", "gitlab", "direct", "pypi" }, source.kind), id .. ": unsupported source")
	assert((source.kind == "pypi") == (recipe.installer == "uv"), id .. ": PyPI requires the uv installer")
	local function https(url)
		assert(type(url) == "string" and url:match("^https://") and not url:find("[%c]"), id .. ": HTTPS URL required")
	end
	if recipe.releases then
		https(u.expand(recipe.releases, { tag = "v1.2.3", version = "1.2.3" }))
	end
	if source.kind == "github" then
		assert(
			type(source.repo) == "string" and source.repo:match("^[%w_.-]+/[%w_.-]+$"),
			id .. ": invalid GitHub repository"
		)
	elseif source.kind == "gitlab" then
		https(source.api)
		assert(
			type(source.project) == "string" and source.project ~= "" and not source.project:find("[%c]"),
			id .. ": invalid GitLab project"
		)
	elseif source.kind == "pypi" then
		assert(u.name(source.package), id .. ": invalid Python package")
		local python = recipe.python or ">=3.10"
		assert(
			type(python) == "string" and (python:match("^%d[%d.]*$") or python:match("^>=%d[%d.]*$")),
			id .. ": invalid Python version"
		)
		assert(
			type(recipe.requirements or {}) == "table" and vim.islist(recipe.requirements or {}),
			id .. ": invalid Python requirements"
		)
		for _, requirement in ipairs(recipe.requirements or {}) do
			assert(
				u.name(requirement)
					or (type(requirement) == "string" and requirement:match("^[%w][%w_.-]*%[[%w_,.-]+%]$")),
				id .. ": expected a Python package name with optional extras"
			)
		end
	else
		https(source.latest)
	end
	local targets = recipe.targets
	if recipe.installer == "uv" then
		targets =
			{ ["linux-amd64"] = M.target(recipe, "linux-amd64"), ["linux-arm64"] = M.target(recipe, "linux-arm64") }
	end
	assert(type(targets) == "table" and next(targets), id .. ": missing targets")
	for platform, target in pairs(targets) do
		assert(platform == "linux-amd64" or platform == "linux-arm64", id .. ": invalid target " .. platform)
		assert(
			target.format == "binary" or target.format == "tar.gz" or recipe.installer == "uv",
			id .. ": unsupported archive format"
		)
		local values = { tag = "v1.2.3", version = "1.2.3", asset = "example.tar.gz" }
		if source.kind == "direct" then
			https(u.expand(target.url, values))
		elseif recipe.installer ~= "uv" then
			assert(u.member(u.expand(target.asset, values)), id .. ": invalid asset name")
		end
		assert(type(target.bins) == "table" and next(target.bins), id .. ": missing exported commands")
		for command, member in pairs(target.bins) do
			assert(u.name(command), id .. ": invalid exported command")
			assert(
				(recipe.installer == "uv" and u.name(member))
					or (target.format == "binary" and member == ".")
					or (target.format == "tar.gz" and u.member(u.expand(member, values))),
				id .. ": invalid member path"
			)
			local args = (recipe.verify or {})[command]
			assert(
				type(args) == "table" and vim.islist(args) and #args > 0,
				id .. ": missing version check for " .. command
			)
			for _, arg in ipairs(args) do
				assert(type(arg) == "string" and not arg:find("%z"), id .. ": invalid version check argument")
			end
		end
		assert(
			target.format ~= "binary" or vim.tbl_count(target.bins) == 1,
			id .. ": raw binary exports exactly one command"
		)
		local checksum = target.checksum or recipe.checksum
		if recipe.installer ~= "uv" then
			assert(type(checksum) == "table", id .. ": SHA-256 configuration required")
			if checksum.kind == "github_digest" then
				assert(source.kind == "github", id .. ": asset digest requires GitHub")
			else
				assert(checksum.format == "raw" or checksum.format == "gnu", id .. ": unsupported checksum format")
				if source.kind == "direct" then
					https(u.expand(checksum.url, values))
				else
					assert(u.member(u.expand(checksum.asset, values)), id .. ": invalid checksum asset")
				end
			end
		end
	end
	return recipe
end

function M.load(overrides)
	local result = vim.deepcopy(M.bundled)
	for id, recipe in pairs(overrides or {}) do
		result[id] = vim.deepcopy(recipe)
	end
	for id, recipe in pairs(result) do
		M.validate(id, recipe)
	end
	return result
end

return M
