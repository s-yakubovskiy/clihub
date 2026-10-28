# CliHub

A small Neovim registry and installer for user-managed CLI tools. Commands installed by CliHub can be used from Neovim and ordinary terminals.

Requires Neovim 0.10+, Linux x86_64 or arm64, curl 7.76+, GNU tar, and sha256sum. No Lua dependencies. Current recipes: `kubectl`, `rg`, `grpcurl`, `k9s`, `glab`, `uv` (also exports `uvx`), and `fastfetch`.

## Setup

With lazy.nvim, point at this checkout:

```lua
{
  dir = vim.fn.expand("~/work/dev/repos/code.talos.lowlife.us/baza/clihub"),
  name = "clihub",
  lazy = false,
  opts = {},
}
```

CliHub prepends its managed bin directory to Neovim's PATH. To use the tools in ordinary shells, add this line to your shell configuration:

```sh
export PATH="${XDG_DATA_HOME:-$HOME/.local/share}/clihub/bin:$PATH"
```

Opening Neovim or CliHub does not install or update tools automatically. Existing installations remain external to CliHub; reinstall selected tools into the dedicated root, verify them, then retire previous copies if desired.

## Use

```vim
:CliHub
:CliHub install kubectl rg grpcurl k9s
:CliHub check
:CliHub update
:CliHub update rg
:CliHub remove rg
:checkhealth clihub
```

The centered, theme-aware window groups tools by status. Use `1` / `2` / `3` or `<Tab>` to switch All / Installed / Updates, `j` / `k` to select a tool, and `<Enter>` to expand its details inline. Actions: `i` install, `u` update, `r` check, `x` remove, `U` update installed, `R` check installed, and `q` / `<Esc>` close. Normal `/` search works. The default local key binding is `<leader>cH`.

Select another tool and press `i` while an install runs to queue it. Queued requests run in order and appear under In progress. Repeated actions on an active or queued tool are ignored in the UI. Closing the window keeps the queue running while Neovim stays open.

`u` (or `:CliHub update <id>`) installs a tool if absent and updates it if already installed. `U` updates all CliHub installations, skipping pinned tools; it does not install absent registry entries. `check` and `update` without names operate on CliHub installations. Removal asks for confirmation in the UI/command; the Lua API is intended for automation and does not prompt.

## Configure and extend

```lua
require("clihub").setup({
  -- root = "/absolute/path/to/clihub",
  path = "prepend", -- or "none"
  versions = { kubectl = "v1.37.0" }, -- exact upstream tags
  registry = {}, -- Add entries or replace a bundled recipe by its ID.
})
```

Each registry entry describes a GitHub/GitLab release or direct download, explicit platform-specific asset names, checksum information, exported binary paths, and harmless version-check arguments. New tools using existing formats require only a registry entry. See [DESIGN.md](DESIGN.md) for a complete example and source contracts, and [registry.lua](lua/clihub/registry.lua) for the working recipes.

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

Supported payloads are standalone ELF binaries and tar.gz archives containing standalone binaries. Members are selected by exact path, validated for CPU architecture, checksum-verified, and tested before activation. Multiple commands share one package version. Full application bundles, private authentication, other operating systems, and package-manager/toolchain installs are future work.

Installations live under `${XDG_DATA_HOME:-$HOME/.local/share}/clihub`. Version directories and receipts track ownership; an atomic `current` symlink activates an update. A failed preparation preserves the installed version. A root lock serializes changes across Neovim processes. Normal operations recover dead-owner locks, while ambiguous lock state is reported for inspection. Foreign files are never overwritten or removed.

Release discovery uses public, unauthenticated APIs. GitHub's hourly quota can be exhausted by repeated checks or a shared public IP. The error includes the upstream response; retry after the quota resets. Failed checks leave managed binaries usable and clear stale available-version information.

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
