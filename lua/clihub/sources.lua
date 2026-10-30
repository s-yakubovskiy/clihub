local u = require("clihub.util")
local M = {}

local function asset(release, name, gitlab)
	local matches = {}
	local assets = gitlab and (release.assets or {}).links or release.assets
	for _, item in ipairs(assets or {}) do
		if item.name == name then
			matches[#matches + 1] = item
		end
	end
	assert(#matches == 1, "Expected exactly one release asset: " .. name)
	local item = matches[1]
	return gitlab and (item.direct_asset_url or item.url) or item.browser_download_url, item.digest
end

function M.release_url(recipe, tag)
	local source = recipe.source
	if source.kind == "github" then
		return "https://github.com/" .. source.repo .. "/releases/" .. (tag and "tag/" .. u.encode(tag) or "latest")
	elseif source.kind == "gitlab" then
		return source.api:gsub("/api/v4/?$", "")
			.. "/"
			.. source.project
			.. "/-/releases/"
			.. (tag and u.encode(tag) or "permalink/latest")
	end
	if recipe.releases then
		if not tag and (recipe.releases:find("{tag}", 1, true) or recipe.releases:find("{version}", 1, true)) then
			return nil
		end
		return u.expand(recipe.releases, { tag = tag or "", version = (tag or ""):gsub("^v", "") })
	end
end

function M.resolve(id, recipe, platform, pin, opts)
	require("clihub.registry").validate(id, recipe)
	local target = assert(recipe.targets[platform], id .. ": no binary for " .. platform)
	local source, release, tag = recipe.source, nil, pin
	if pin then
		assert(type(pin) == "string" and pin ~= "" and not pin:find("[%c]"), "Invalid version pin")
	end
	if source.kind == "github" then
		local endpoint = "https://api.github.com/repos/"
			.. source.repo
			.. "/releases/"
			.. (pin and "tags/" .. u.encode(pin) or "latest")
		release = vim.json.decode(u.fetch(endpoint, opts))
		tag = release.tag_name
	elseif source.kind == "gitlab" then
		local endpoint = source.api:gsub("/$", "")
			.. "/projects/"
			.. u.encode(source.project)
			.. "/releases/"
			.. (pin and u.encode(pin) or "permalink/latest")
		release = vim.json.decode(u.fetch(endpoint))
		tag = release.tag_name
	elseif not pin then
		tag = vim.trim(u.fetch(source.latest))
	end
	assert(type(tag) == "string" and tag ~= "" and not tag:find("[%c%s]"), "Invalid upstream release tag")
	assert(not pin or tag == pin, "Upstream returned a different release than the requested pin")
	local values = { tag = tag, version = tag:gsub("^v", "") }
	local url, digest
	if source.kind == "direct" then
		url = u.expand(target.url, values)
		values.asset = url:match("([^/]+)$")
	else
		values.asset = u.expand(target.asset, values)
		url, digest = asset(release, values.asset, source.kind == "gitlab")
	end
	local descriptor = target.checksum or recipe.checksum
	local checksum = { format = descriptor.format, filename = values.asset }
	if descriptor.kind == "github_digest" then
		checksum.digest = type(digest) == "string" and digest:match("^sha256:(%x+)$") or nil
		assert(checksum.digest and #checksum.digest == 64, "Upstream asset has no SHA-256 digest")
	elseif source.kind == "direct" then
		checksum.url = u.expand(descriptor.url, values)
	else
		checksum.url = asset(release, u.expand(descriptor.asset, values), source.kind == "gitlab")
	end
	local bins = {}
	for command, member in pairs(target.bins) do
		bins[command] = u.expand(member, values)
		assert(target.format == "binary" or u.member(bins[command]), "Unsafe resolved member path")
	end
	return {
		id = id,
		tag = tag,
		platform = platform,
		url = url,
		checksum = checksum,
		format = target.format,
		bins = bins,
		verify = recipe.verify,
		source = vim.deepcopy(source),
		fingerprint = u.fingerprint(recipe),
	}
end

return M
