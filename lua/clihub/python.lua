local u = require("clihub.util")
local M = {}

function M.executable(root)
	local managed = root .. "/bin/uv"
	if vim.fn.executable(managed) == 1 then
		return managed
	end
	local path = vim.fn.exepath("uv")
	return path ~= "" and path or nil
end

function M.prepare(root, resolved, payload, progress, locked)
	assert(resolved.platform == u.platform(), "Python environments must be installed for the current platform")
	local executable = assert(M.executable(root), "Python tools require uv; install it with :CliHub install uv first")
	progress("creating Python environment")
	u.run({
		executable,
		"venv",
		"--no-config",
		"--no-python-downloads",
		"--python",
		resolved.python,
		"--relocatable",
		payload,
	})
	local python = payload .. "/bin/python"
	local requirements
	if locked then
		requirements = (locked.requirements or {})[resolved.platform]
		assert(
			type(requirements) == "string" and vim.fn.sha256(requirements) == locked.sha256[resolved.platform],
			"Lockfile SHA-256 mismatch for " .. resolved.id
		)
	else
		progress("resolving Python dependencies")
		local input = { resolved.source.package .. "==" .. resolved.tag }
		vim.list_extend(input, resolved.requirements)
		u.write(payload .. "/requirements.in", table.concat(input, "\n") .. "\n")
		requirements = u.run({
			executable,
			"pip",
			"compile",
			"--no-config",
			"--no-python-downloads",
			"--python",
			python,
			"--default-index",
			"https://pypi.org/simple",
			"--only-binary",
			":all:",
			"--generate-hashes",
			"--no-header",
			"--no-annotate",
			payload .. "/requirements.in",
		}, { timeout = 400000 })
		assert(requirements:find("--hash=sha256:", 1, true), "Python resolver returned no distribution hashes")
	end
	u.write(payload .. "/requirements.txt", requirements)
	progress("installing Python packages")
	u.run({
		executable,
		"pip",
		"sync",
		"--no-config",
		"--no-python-downloads",
		"--python",
		python,
		"--default-index",
		"https://pypi.org/simple",
		"--only-binary",
		":all:",
		"--require-hashes",
		payload .. "/requirements.txt",
	}, { timeout = 400000 })
	for command, entrypoint in pairs(resolved.bins) do
		local path = payload .. "/bin/" .. entrypoint
		local stat = vim.uv.fs_lstat(path)
		assert(
			stat and stat.type == "file" and vim.fn.executable(path) == 1,
			"Missing Python entry point: " .. entrypoint
		)
		if command ~= entrypoint then
			assert(not vim.uv.fs_lstat(payload .. "/bin/" .. command), "Python command already exists: " .. command)
			assert(vim.uv.fs_copyfile(path, payload .. "/bin/" .. command))
		end
		local args = { payload .. "/bin/" .. command }
		vim.list_extend(args, resolved.verify[command])
		u.run(args, { timeout = 10000 })
	end
	return vim.fn.sha256(requirements), requirements
end

return M
