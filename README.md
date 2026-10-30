# CliHub

A small Neovim registry and installer for user-managed CLI tools. Commands installed by CliHub can be used from Neovim and ordinary terminals.

Requires Neovim 0.10+, Linux x86_64 or arm64, curl 7.76+, GNU tar, and sha256sum. No Lua dependencies. Current recipes: `kubectl`, `rg`, `grpcurl`, `k9s`, `glab`, `uv` (also exports `uvx`), and `fastfetch`.

## Setup

With lazy.nvim:

```lua
{
  "s-yakubovskiy/clihub",
  lazy = false,
  opts = {},
}
```

CliHub prepends its managed bin directory to Neovim's PATH. To use the tools in ordinary shells, add this line to your shell configuration:

```sh
export PATH="${XDG_DATA_HOME:-$HOME/.local/share}/clihub/bin:$PATH"
```

Opening Neovim or CliHub does not install or update tools automatically unless you configure `ensure_installed`. Existing installations remain external to CliHub; reinstall selected tools into the dedicated root, verify them, then retire previous copies if desired.

## Use

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

`u` (or `:CliHub update <id>`) installs a tool if absent and updates it if already installed. `U` updates all CliHub installations, skipping pinned tools; it does not install absent registry entries. `check` and `update` without names operate on CliHub installations. Removal asks for confirmation in the UI/command; the Lua API is intended for automation and does not prompt.

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

Each registry entry describes a GitHub/GitLab release or direct download, explicit platform-specific asset names, checksum information, exported binary paths, and harmless version-check arguments. New tools using existing formats require only a registry entry. See [DESIGN.md](DESIGN.md) for a complete example and source contracts, and [registry.lua](lua/clihub/registry.lua) for the working recipes.

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

## Reproduce a tool setup

Run `:CliHub lock` after installing the versions you want. It atomically saves installed tools to `~/.config/nvim/clihub-lock.json` (or your configured `lockfile`), recording exact tags, sources, recipe fingerprints, and archive SHA-256 hashes for the current architecture. Keep this file with your Neovim configuration, including custom registry recipes.

On another machine with the same architecture, `:CliHub restore` installs exactly those versions and verifies both upstream and locked checksums. It fails on unknown tools, changed recipes, conflicting pins, unsupported architectures, or altered release artifacts. A lockfile with no hash for the host architecture cannot be restored on that host. Saving a lockfile replaces the snapshot; it does not make normal updates follow the lockfile.

For an explicit startup tool list, configure:

```lua
opts = {
  ensure_installed = { "rg", "kubectl", "k9s" },
}
```

Startup and `:CliHub ensure` install missing tools and reconcile locked or pinned versions. Existing unpinned tools are left alone. Without a matching lockfile entry, an absent tool uses its configured pin or upstream latest. Ensure never removes other tools. Restore and ensure use the existing operation queue; keep Neovim open until they finish.

## GitHub requests

Release API authentication uses `github.token` (a string or callback), then `GH_TOKEN`, `GITHUB_TOKEN`, or an existing `gh auth login` session. `gh` is optional; set `github.use_gh = false` to disable its lookup. Prefer an environment variable or callback over putting a token in config. Tokens are sent through curl's standard input, never command arguments, logs, or cache files, and only to `api.github.com`.

Successful GitHub release responses are cached per credential under the managed root for five minutes by default. Explicit checks always revalidate with ETags; HTTP 304 responses reuse the cached body. Rate-limit failures explain how to authenticate and show the reset time when provided. Private release asset downloads and GitLab authentication are not supported yet.

Supported payloads are standalone ELF binaries and tar.gz archives containing standalone binaries. Members are selected by exact path, validated for CPU architecture, checksum-verified, and tested before activation. Multiple commands share one package version. Full application bundles, other operating systems, and package-manager/toolchain installs are future work.

Installations live under `${XDG_DATA_HOME:-$HOME/.local/share}/clihub`. Version directories and receipts track ownership; an atomic `current` symlink activates an update. A failed preparation preserves the installed version. A root lock serializes changes across Neovim processes. Normal operations recover dead-owner locks, while ambiguous lock state is reported for inspection. Foreign files are never overwritten or removed.

Failed checks leave managed binaries usable and clear the affected saved availability so a later session does not report an unsuccessful refresh as current data.

For headless automation, `require("clihub").run("install", { "rg" }, function(results) ... end)` completes asynchronously with `{ rg = { ok = true, result = ... } }`, or an `error` field when unsuccessful. Headless callers must keep Neovim alive until completion.

## Verify

```sh
nvim --headless -u NONE -i NONE -l tests/run.lua
nvim --headless -u NONE -i NONE -l tests/ui.lua
```

The regression runner uses temporary roots and offline fixtures for the real checksum, extraction, activation, lock, and removal paths. Upstream integration checks should be run separately in a disposable root. Both CPU architectures have registry entries; arm64 execution needs an arm64 host.

To explicitly download all registered tools into a temporary root and check their complete lifecycle:

```sh
nvim --headless -u NONE -i NONE -l tests/live.lua
```
