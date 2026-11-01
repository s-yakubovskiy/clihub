-- Offline integration: requires uv and Python 3.10+.
-- Run: nvim --headless -u NONE -i NONE -l tests/python.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local u = require("clihub.util")
local hub = require("clihub")
local install = require("clihub.install")
local backend = require("clihub.python")
local workspace = vim.fn.tempname() .. "-python tools"
local saved_run, saved_fetch, saved_executable = u.run, u.fetch, backend.executable
assert(backend.executable(workspace), "This integration test requires uv")
u.mkdir(workspace)

local ok, err = xpcall(function()
	local wheels = workspace .. "/wheels"
	u.mkdir(wheels)
	-- Minimal real wheels exercise uv's dependency resolution and generated entry points.
	local generator = workspace .. "/wheels.py"
	u.write(
		generator,
		[[
import sys, zipfile
from pathlib import Path
directory, name, version = sys.argv[1:]
dist = f"{name}-{version}.dist-info"
files = {
    f"{dist}/WHEEL": "Wheel-Version: 1.0\nGenerator: clihub-test\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
    f"{dist}/METADATA": f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n",
    f"{dist}/RECORD": "",
}
if name == "clihub_probe":
    files[f"{dist}/METADATA"] += "Requires-Dist: clihub-dep>=1\n"
    files[f"{dist}/entry_points.txt"] = "[console_scripts]\npyprobe = clihub_probe:main\n"
    files["clihub_probe.py"] = f"import sys\nimport clihub_dep\ndef main():\n    assert '--fail' not in sys.argv, 'fixture failure'\n    print('{version}/' + clihub_dep.VERSION)\n"
else:
    files["clihub_dep.py"] = f"VERSION = '{version}'\n"
with zipfile.ZipFile(Path(directory) / f"{name}-{version}-py3-none-any.whl", 'w') as wheel:
    for path, contents in files.items():
        wheel.writestr(path, contents)
]]
	)
	local function wheel(name, version)
		local result = vim.system({ "python3", generator, wheels, name, version }, { text = true }):wait()
		assert(result.code == 0, result.stderr)
	end
	wheel("clihub_probe", "1.0.0")
	wheel("clihub_probe", "2.0.0")
	wheel("clihub_dep", "1.0.0")
	local latest, compiles = "1.0.0", 0
	u.fetch = function(url)
		assert(url:match("^https://pypi.org/pypi/clihub%-probe/"), url)
		return vim.json.encode({ info = { version = url:match("/([%d.]+)/json$") or latest } })
	end
	u.run = function(args, opts)
		args = vim.deepcopy(args)
		if args[1] == saved_executable(workspace) then
			assert(vim.tbl_contains(args, "--no-config") and vim.tbl_contains(args, "--no-python-downloads"))
			vim.list_extend(args, { "--cache-dir", workspace .. "/cache" })
			if args[2] == "pip" then
				assert(vim.tbl_contains(args, "--only-binary"))
				vim.list_extend(args, { "--no-index", "--find-links", wheels })
				if args[3] == "compile" then
					compiles = compiles + 1
				else
					assert(args[3] == "sync" and vim.tbl_contains(args, "--require-hashes"))
				end
			end
		end
		return saved_run(args, opts)
	end
	local recipe = {
		description = "Offline Python fixture",
		source = { kind = "pypi", package = "clihub-probe" },
		installer = "uv",
		bins = { pyprobe = "pyprobe" },
		verify = { pyprobe = { "--version" } },
	}
	local root, lockfile = workspace .. "/installed", workspace .. "/lock.json"
	local function setup(directory, entry)
		hub.setup({ root = directory, path = "none", registry = { pyprobe = entry or recipe }, lockfile = lockfile })
	end
	local function action(kind)
		local results
		local complete = function(value)
			results = value
		end
		if kind == "restore" then
			hub.restore(complete)
		else
			hub.run(kind, { "pyprobe" }, complete)
		end
		assert(
			vim.wait(30000, function()
				return results ~= nil
			end, 10),
			"Operation timed out"
		)
		return assert(results.pyprobe, vim.inspect(results))
	end
	local function output()
		local result = vim.system({ hub.config.root .. "/bin/pyprobe", "--version" }, { text = true }):wait()
		assert(result.code == 0, result.stderr)
		return vim.trim(result.stdout)
	end
	setup(root)
	assert(action("check").ok and hub.status("pyprobe").available == "1.0.0")
	assert(action("update").ok) -- Update also installs an absent Python tool.
	assert(output() == "1.0.0/1.0.0", "Managed entry point failed after relocation")
	assert(action("install").result.unchanged and compiles == 1)
	local locked = hub.lock().pyprobe
	assert(locked.requirements[u.platform()]:find("clihub-dep==1.0.0", 1, true))
	local lock_data = u.read(lockfile)
	wheel("clihub_dep", "2.0.0")
	setup(workspace .. "/restored")
	assert(action("restore").ok)
	assert(output() == "1.0.0/1.0.0" and compiles == 1, "Restore resolved dependencies again")
	assert(install.current(hub.config.root, "pyprobe").sha256 == locked.sha256[u.platform()])
	assert(action("remove").ok and not install.current(hub.config.root, "pyprobe"))
	-- The manifest digest and the individual distribution hashes are both enforced.
	local forged = vim.json.decode(lock_data)
	local entry = forged.packages.pyprobe
	entry.requirements[u.platform()] =
		entry.requirements[u.platform()]:gsub("sha256:%x+", "sha256:" .. string.rep("0", 64))
	u.write(lockfile, vim.json.encode(forged))
	setup(workspace .. "/bad-manifest")
	local valid, failure = pcall(hub.restore)
	assert(not valid and tostring(failure):find("Invalid locked Python requirements", 1, true))
	entry.sha256[u.platform()] = vim.fn.sha256(entry.requirements[u.platform()])
	u.write(lockfile, vim.json.encode(forged))
	local rejected = action("restore")
	assert(not rejected.ok and rejected.error:lower():find("hash", 1, true), vim.inspect(rejected))
	assert(not install.current(hub.config.root, "pyprobe") and not vim.uv.fs_lstat(hub.config.root .. "/.lock"))
	u.write(lockfile, lock_data)
	latest = "2.0.0"
	local broken = vim.deepcopy(recipe)
	broken.verify.pyprobe = { "--fail" }
	setup(root, broken)
	assert(not action("update").ok and output() == "1.0.0/1.0.0", "Failed update replaced the active tool")
	assert(not vim.uv.fs_lstat(root .. "/.lock"))
	setup(root)
	assert(action("update").ok and output() == "2.0.0/2.0.0")
	assert(action("update").result.unchanged)
	assert(action("remove").ok and not vim.uv.fs_lstat(root .. "/bin/pyprobe"))
	backend.executable = function()
		return nil
	end
	local missing = action("install")
	assert(not missing.ok and missing.error:find(":CliHub install uv", 1, true), vim.inspect(missing))
	assert(not vim.uv.fs_lstat(root .. "/.lock"))
end, debug.traceback)
u.run, u.fetch, backend.executable = saved_run, saved_fetch, saved_executable
u.delete(workspace)
assert(ok, err)
print(
	"clihub Python: offline install, relocation, dependency hashes, lock/restore, update rollback, removal, and missing uv passed"
)
