if vim.g.loaded_clihub then
	return
end
vim.g.loaded_clihub = true

vim.api.nvim_create_user_command("CliHub", function(opts)
	local ok, err = pcall(require("clihub").command, opts.fargs)
	if not ok then
		vim.notify(tostring(err), vim.log.levels.ERROR)
	end
end, {
	nargs = "*",
	desc = "Manage user CLI tools",
	complete = function(lead, line)
		return require("clihub").complete(lead, line)
	end,
})
