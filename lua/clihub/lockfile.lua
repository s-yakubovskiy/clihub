local u = require("clihub.util")
local M = {}

function M.read(path, registry)
	if not vim.uv.fs_lstat(path) then
		return {}
	end
	local data = u.json_read(path)
	assert(data and data.version == 1 and type(data.packages) == "table", "Invalid clihub lockfile: " .. path)
	for id, item in pairs(data.packages) do
		local recipe = registry[id]
		assert(recipe, "Lockfile references unknown tool: " .. tostring(id))
		assert(
			type(item) == "table" and type(item.tag) == "string" and item.tag ~= "" and not item.tag:find("[%s%c]"),
			"Invalid locked version: " .. id
		)
		assert(
			item.fingerprint == u.fingerprint(recipe) and vim.deep_equal(item.source, recipe.source),
			"Recipe changed for " .. id .. "; review it and regenerate the lockfile"
		)
		assert(type(item.sha256) == "table" and next(item.sha256), "Missing locked checksum: " .. id)
		for platform, digest in pairs(item.sha256) do
			assert(
				(platform == "linux-amd64" or platform == "linux-arm64")
					and type(digest) == "string"
					and #digest == 64
					and digest:match("^%x+$"),
				"Invalid locked checksum: " .. id
			)
		end
	end
	return data.packages
end

function M.write(path, root, registry)
	local packages = {}
	for id, recipe in pairs(registry) do
		local receipt = require("clihub.install").current(root, id)
		if receipt then
			assert(
				receipt.fingerprint == u.fingerprint(recipe) and vim.deep_equal(receipt.source, recipe.source),
				"Installed recipe changed for " .. id .. "; reinstall it before locking"
			)
			assert(
				(receipt.platform == "linux-amd64" or receipt.platform == "linux-arm64")
					and type(receipt.sha256) == "string"
					and #receipt.sha256 == 64
					and receipt.sha256:match("^%x+$"),
				"Invalid installed checksum/platform: " .. id
			)
			packages[id] = {
				tag = receipt.tag,
				source = receipt.source,
				fingerprint = receipt.fingerprint,
				sha256 = { [receipt.platform] = receipt.sha256 },
			}
		end
	end
	local lines = { "{", '  "version": 1,', '  "packages": {' }
	local ids = vim.tbl_keys(packages)
	table.sort(ids)
	for i, id in ipairs(ids) do
		lines[#lines + 1] = "    "
			.. vim.json.encode(id)
			.. ": "
			.. u.canonical(packages[id])
			.. (i < #ids and "," or "")
	end
	lines[#lines + 1] = "  }\n}\n"
	u.atomic_write(path, table.concat(lines, "\n"))
	return packages
end

return M
