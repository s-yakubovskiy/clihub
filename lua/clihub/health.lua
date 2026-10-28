local M = {}

function M.check()
	local health = vim.health
	local hub = require("clihub")
	local config = hub.ensure()
	health.start("CliHub")
	for _, command in ipairs({ "curl", "tar", "sha256sum" }) do
		if vim.fn.executable(command) == 1 then
			health.ok(command .. ": " .. vim.fn.exepath(command))
		else
			health.error("Missing dependency: " .. command)
		end
	end
	local ok, platform = pcall(require("clihub.util").platform)
	if ok then
		health.ok("Platform: " .. platform)
	else
		health.error(tostring(platform))
	end
	health.info("Root: " .. config.root)
	local stat = vim.uv.fs_lstat(config.root)
	if not stat then
		health.info("Root will be created on first installation")
	elseif stat.type ~= "directory" then
		health.error("Root must be a real directory")
	elseif vim.fn.filewritable(config.root) == 2 then
		health.ok("Root is writable")
	else
		health.error("Root is not writable")
	end
	if vim.uv.fs_lstat(config.root .. "/.lock") then
		health.warn("An operation lock exists: " .. config.root .. "/.lock")
	end
	for _, id in ipairs(hub.list()) do
		local current_ok, receipt = pcall(require("clihub.install").current, config.root, id)
		if not current_ok then
			health.error(id .. ": " .. tostring(receipt))
		elseif receipt then
			for command in pairs(receipt.bins) do
				local managed = config.root .. "/bin/" .. command
				local expected = "../packages/" .. id .. "/current/bin/" .. command
				if vim.uv.fs_readlink(managed) ~= expected then
					health.error("Missing or foreign export: " .. managed)
				elseif vim.fn.executable(managed) ~= 1 then
					health.error("Missing/broken export: " .. managed)
				elseif vim.fn.exepath(command) ~= managed then
					health.warn(command .. " is shadowed by " .. vim.fn.exepath(command))
				else
					health.ok(command .. " " .. receipt.tag)
				end
			end
		end
	end
	health.info('Shell PATH: export PATH="${XDG_DATA_HOME:-$HOME/.local/share}/clihub/bin:$PATH"')
end

return M
