# clihub

A small Neovim registry and installer for user-managed CLI tools. Commands installed by clihub can be used from Neovim and ordinary terminals.

Requires Neovim 0.10+, Linux x86_64 or arm64, curl 7.76+, GNU tar, and sha256sum. No Lua dependencies. Current recipes: `kubectl`, `rg`, `grpcurl`, `k9s`, `gh`, `glab`, `uv` (also exports `uvx`), `fastfetch`, and `pgcli`. Python tools additionally require uv and an installed Python 3.10+.

## Setup

With lazy.nvim:

```lua
{
  "s-yakubovskiy/clihub",
  lazy = false,
  opts = {},
}
```

clihub prepends its managed bin directory to Neovim's PATH. To use the tools in ordinary shells, add this line to your shell configuration:

```sh
export PATH="${XDG_DATA_HOME:-$HOME/.local/share}/clihub/bin:$PATH"
```

Opening Neovim or clihub does not install or update tools automatically unless you configure `ensure_installed`. Existing installations remain external to clihub; reinstall selected tools into the dedicated root, verify them, then retire previous copies if desired.

## Use

The displayed name is `clihub`. The command is `:CliHub` because Neovim requires user-defined commands to start with an uppercase letter. To type it in lowercase interactively, add this abbreviation to your Neovim config:

```lua
vim.cmd([[cnoreabbrev <expr> clihub getcmdtype() == ':' && getcmdline() ==# 'clihub' ? 'CliHub' : 'clihub']])
```

The abbreviation expands when you press Space or Enter; scripts and mappings should continue using `:CliHub`.

```vim
:CliHub
:CliHub install kubectl rg grpcurl k9s
:CliHub check
:CliHub update
:CliHub update rg
:CliHub remove rg
:CliHub releases rg
:CliHub lock
:CliHub restore
:checkhealth clihub
```

The centered, theme-aware window groups tools by status. Use `1` / `2` / `3` or `<Tab>` to switch All / Installed / Updates, `j` / `k` to select a tool, and `<Enter>` to expand its details inline. Actions: `i` install, `u` update, `r` check, `x` remove, `o` open release notes, `U` update installed, `R` check installed, and `q` / `<Esc>` close. Normal `/` search works. The default local key binding is `<leader>cH`.

Select another tool and press `i` while an install runs to queue it. Queued requests run in order and appear under In progress. Repeated actions on an active or queued tool are ignored in the UI. Closing the window keeps the queue running while Neovim stays open.

`u` (or `:CliHub update <id>`) installs a tool if absent and updates it if already installed. `U` updates all clihub installations, skipping pinned tools; it does not install absent registry entries. `check` and `update` without names operate on clihub installations. Removal asks for confirmation in the UI/command; the Lua API is intended for automation and does not prompt.

Checks discover upstream releases independently of pins. Their versions and timestamps persist under the managed root, survive restarting Neovim, and are invalidated when a recipe changes. Details show the check age; checks older than 24 hours are marked stale. Opening the UI never fetches automatically: press `R` to refresh.

Semantic versions distinguish upgrades, newer installed versions, and pins. Build metadata does not change version precedence. Unknown tag schemes are shown as different releases rather than guessed upgrades. Unpinned `update` refuses downgrades and unordered release changes; explicit `install`, a configured version pin, or `restore` can deliberately select an older release.

## Configure and extend

```lua
require("clihub").setup({
  -- root = "/absolute/path/to/clihub",
  path = "prepend", -- or "none"
  versions = { kubectl = "v1.37.0" }, -- exact upstream tags
  ensure_installed = {}, -- IDs to install/reconcile asynchronously at startup
  -- lockfile = vim.fn.stdpath("config") .. "/clihub-lock.json",
  github = { use_gh = true, cache_ttl = 300 },
  registry = {}, -- Add entries or replace a bundled recipe by its ID.
})
```

Each registry entry describes a GitHub/GitLab release, direct download, or PyPI package, exported commands, and harmless version-check arguments. Binary recipes specify platform-specific assets and checksums; Python recipes use the uv backend described below. New tools using existing formats require only a registry entry. See [registry.lua](lua/clihub/registry.lua) for the working recipes.

GitHub and GitLab release pages are derived from the source. Direct recipes can add `releases = "https://example.org/releases/{tag}"` to enable the `o` shortcut. The shortcut opens the checked upstream release, falling back to the installed version or latest release page.

With lazy.nvim, put additions directly in the plugin spec's `opts.registry`; they merge with the bundled catalog. Your local `~/.config/nvim/lua/plugins/clihub.lua` includes `fzf` as a working example:

```lua
opts = {
  registry = {
    fzf = {
      description = "Find files and commands interactively",
      source = { kind = "github", repo = "junegunn/fzf" },
      installer = "artifact",
      targets = {
        ["linux-amd64"] = {
          asset = "fzf-{version}-linux_amd64.tar.gz",
          format = "tar.gz",
          bins = { fzf = "fzf" },
        },
        ["linux-arm64"] = {
          asset = "fzf-{version}-linux_arm64.tar.gz",
          format = "tar.gz",
          bins = { fzf = "fzf" },
        },
      },
      checksum = { kind = "github_digest" },
      verify = { fzf = { "--version" } },
    },
  },
}
```

Restart Neovim after editing the configuration. The entry appears in `:CliHub` and command completion; install it with `:CliHub install fzf`. Reusing a bundled ID replaces the entire recipe, so include all required fields. GitHub digest checksums require the selected release asset to publish its SHA-256 digest.

## Python tools

Install pgcli with:

```vim
:CliHub install uv pgcli
```

An existing uv on PATH also works. clihub prefers its managed uv, creates a relocatable virtual environment inside the package version directory, and exports `pgcli` through its normal bin directory. It requires an installed Python 3.10+ and does not download Python. Your project environment and system Python packages are left alone. The pgcli recipe includes `psycopg[binary]`, so a separate system libpq installation is unnecessary.

`i`, `u`, `r`, `x`, version pins, startup ensure, and lock/restore work as for other tools. Checks use PyPI, and `o` opens the package's version page. Requests containing both uv and Python tools install/update uv first; include both in `ensure_installed` if uv should also be managed. Installing only pgcli without an available uv reports how to install the prerequisite.

To register another Python CLI, use this schema in `opts.registry` (the bundled pgcli recipe is shown):

```lua
pgcli = {
  description = "PostgreSQL client with completion and syntax highlighting",
  source = { kind = "pypi", package = "pgcli" },
  installer = "uv",
  python = ">=3.10", -- An installed interpreter version or minimum; defaults to >=3.10.
  requirements = { "psycopg[binary]" }, -- Optional additional packages, with optional extras.
  bins = { pgcli = "pgcli" }, -- Exported command -> package entry point.
  verify = { pgcli = { "--version" } },
}
```

uv resolves the exact package version and its dependencies into a hashed requirements file, then installs with required hash checks and prebuilt wheels only. Source builds are disabled. Normal updates track the main package version; they do not refresh dependencies when that version is unchanged.

## Reproduce a tool setup

Run `:CliHub lock` after installing the versions you want. It atomically saves installed tools to `~/.config/nvim/clihub-lock.json` (or your configured `lockfile`), recording exact tags, sources, recipe fingerprints, and SHA-256 hashes for the current architecture. For binary tools these identify release artifacts; for Python tools they identify the complete requirements file, which also records exact dependency versions and distribution hashes. Keep this file with your Neovim configuration, including custom registry recipes.

On another machine with the same architecture, `:CliHub restore` installs exactly those versions and verifies both upstream and locked checksums. It fails on unknown tools, changed recipes, conflicting pins, unsupported architectures, or altered release artifacts. A lockfile with no hash for the host architecture cannot be restored on that host. Saving a lockfile replaces the snapshot; it does not make normal updates follow the lockfile.

Python restores reuse the saved requirements without resolving dependencies again. They require a compatible installed Python interpreter and uv (already available or included in the lockfile); interpreter versions themselves are not locked. Requirements are resolved for the originating interpreter and architecture, so cross-interpreter restores can fail if a locked dependency is incompatible.

For an explicit startup tool list, configure:

```lua
opts = {
  ensure_installed = { "rg", "kubectl", "k9s" },
}
```

Startup and `:CliHub ensure` install missing tools and reconcile locked or pinned versions. Existing unpinned tools are left alone. Without a matching lockfile entry, an absent tool uses its configured pin or upstream latest. Ensure never removes other tools. Restore and ensure use the existing operation queue; keep Neovim open until they finish.

## GitHub requests

Release API authentication uses `github.token` (a string or callback), then `GH_TOKEN`, `GITHUB_TOKEN`, or an existing `gh auth login` session. `gh` is optional; set `github.use_gh = false` to disable its lookup. Prefer an environment variable or callback over putting a token in config. Tokens are sent through curl's standard input, never command arguments, logs, or cache files, and only to `api.github.com`.

Run `:checkhealth clihub` to see the credential source (`github.token`, `GH_TOKEN`, `GITHUB_TOKEN`, `gh auth token`, or unauthenticated) and the last HTTP response status, if any. Health resolves credentials locally, including an optional `gh auth token` lookup, without making a GitHub API request or printing token values. This identifies the selected credential source; a successful API response is needed to verify that GitHub accepts it. The same safe metadata is available through `require("clihub.http").auth_status()`.

Successful GitHub release responses are cached per credential under the managed root for five minutes by default. Explicit checks always revalidate with ETags; HTTP 304 responses reuse the cached body. Rate-limit failures explain how to authenticate and show the reset time when provided. Private release asset downloads and GitLab authentication are not supported yet.

Binary payloads are standalone ELF binaries and tar.gz archives containing standalone binaries. Members are selected by exact path, validated for CPU architecture, checksum-verified, and tested before activation. Python packages use isolated uv environments with hashed wheel installs and entry point checks. Multiple commands share one package version. Full application bundles and other operating systems are future work.

Installations live under `${XDG_DATA_HOME:-$HOME/.local/share}/clihub`. Version directories and receipts track ownership; an atomic `current` symlink activates an update. A failed preparation preserves the installed version. A root lock serializes changes across Neovim processes. Normal operations recover dead-owner locks, while ambiguous lock state is reported for inspection. Foreign files are never overwritten or removed.

Failed checks leave managed binaries usable and clear the affected saved availability so a later session does not report an unsuccessful refresh as current data.

For headless automation, `require("clihub").run("install", { "rg" }, function(results) ... end)` completes asynchronously with `{ rg = { ok = true, result = ... } }`, or an `error` field when unsuccessful. Headless callers must keep Neovim alive until completion.

## Verify

```sh
nvim --headless -u NONE -i NONE -l tests/run.lua
nvim --headless -u NONE -i NONE -l tests/ui.lua
# With uv and Python 3.10+ installed:
nvim --headless -u NONE -i NONE -l tests/python.lua
```

The regression runners use temporary roots and offline fixtures for the real checksum, extraction, activation, lock, and removal paths. The Python runner builds local wheel fixtures and tests actual uv resolution, relocation, hashed restore, failed-update rollback, and removal. Upstream integration checks should be run separately in a disposable root. Both CPU architectures have registry entries; arm64 execution needs an arm64 host.

To explicitly download all registered tools into a temporary root and check their complete lifecycle:

```sh
nvim --headless -u NONE -i NONE -l tests/live.lua
```
