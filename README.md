# Twingate for Omarchy

<img src="preview.png" alt="Twingate for Omarchy preview" width="100%">

A bar widget for the [Omarchy](https://omarchy.org/) shell that shows [Twingate](https://www.twingate.com/) VPN status and gives you a panel to connect/disconnect, switch accounts, browse resources, and sync Kubernetes configs.

> **Prerequisite:** the [`twingate`](https://www.twingate.com/download) CLI must already be installed and set up (signed in to at least one account) before this widget will show anything useful. See [Requirements](#requirements) below.

## Disclaimer

This is an independent, personal project with no affiliation to, endorsement by, or partnership with Twingate. I built it for my own use and I'm sharing it in case it's useful to others — "Twingate" is used only to describe what the widget talks to, and remains a trademark of its respective owner.

## Features

- Bar icon with a status-dot badge (green = online, amber = authenticating, gray = offline/disconnected/error)
- Left-click opens the panel, right-click toggles the connection, middle-click refreshes resources
- One-click connect/disconnect, and a full keyboard-navigable panel
- Main / Kubernetes / Hidden tabs, each with a searchable, full resource list and its own actions (open in browser, copy address, sync `kubeconfig`, authenticate a locked resource)
- Star any resource to pin it to a Favorites strip above the tabs
- Account list showing every configured account, with one-click switching, per-account removal (`twingate account logout`, with a confirmation dialog), and an in-panel "Add account" flow
- Installed Twingate CLI version shown in the panel footer
- A clear notice if the `twingate` CLI isn't installed, and a `diagnostics` command for troubleshooting

## Requirements

- The [`twingate`](https://www.twingate.com/download) CLI **installed and already set up** — signed in to at least one account (`twingate account add`) — before installing this plugin. The widget doesn't install, configure, or authenticate Twingate for you.
- `omarchy-launch-browser` (ships with Omarchy) — used to open a resource link when you click one in the panel
- `wl-copy` (ships with `wl-clipboard`, standard on most Wayland setups) — used to copy a resource's address
- `xdg-terminal-exec` and `uwsm-app` (ship with Omarchy) — used to open a floating terminal for connect/disconnect, account switching, add account, and resource authentication

No credentials are stored or handled by this plugin — it only shells out to the `twingate` CLI, which manages its own auth.

## Installation

```bash
omarchy plugin add https://github.com/jixt/omarchy-plugin-twingate --enable
```

## Usage

### Bar icon

- **Left-click** opens the panel
- **Right-click** toggles connect/disconnect (opens a floating terminal for sudo, and opens the panel with a "Check the terminal" notice)
- **Middle-click** refreshes the resource list

### Panel

- Toggle the switch at the top to connect/disconnect (a floating terminal opens so you can answer a sudo prompt if needed)
- Click the **?** button next to the switch for a keyboard/mouse shortcuts reference, right inside the panel
- Click an account row to switch to it (a floating terminal opens for sudo), or use "Remove account"/"+ Add account" to manage which accounts are configured
- Switch between the Main, K8s, and Hidden tabs, search, and click a resource to open it in your browser or a Kubernetes resource to sync its `kubeconfig`
- Authenticate a locked resource to open a terminal that shows the OAuth URL (Twingate's desktop notification often never reaches the session)
- Click the star on any resource to pin it to the Favorites strip

While connect/disconnect or account switch is waiting on the terminal, the panel shows a full-panel **"Check the terminal"** notice. **Hide** (or Escape) only dismisses that notice — the terminal stays open until the command finishes.

### Keyboard

With the panel open and the search field not focused:

| Key | Action |
|-----|--------|
| `j` / `k` or arrow keys | Move the cursor across accounts, favorites, and the active resource list |
| `t` | Toggle connect/disconnect |
| `r` | Refresh |
| Enter / Space | Activate the highlighted row (open in browser / sync `kubeconfig` — same as a click) |
| `c` | Copy the highlighted resource's address |
| `a` | Authenticate the highlighted row, if it's locked |
| `s` | Focus the search field |
| `h` | Toggle the keyboard/mouse shortcuts reference (same as the **?** button) |
| Escape | Dismiss the confirm dialog, then the terminal notice, then the shortcuts reference, then the details view, then close the panel |

The bar icon refreshes status every 5 seconds by default (configurable, see Configuration below). Accounts, resources, and the CLI version refresh whenever the panel is opened or manually refreshed.

### Global keybinding (optional)

No keybinding is set up by default. To add one, check which `SUPER + CTRL + <key>` combos are still free (`omarchy menu keybindings --print`), then add a line like this to `~/.config/hypr/bindings.lua` (it hot-reloads on save):

```lua
o.bind("SUPER + CTRL + G", "Toggle Twingate", "omarchy-shell shell toggle jixt.twingate")
```

Use `omarchy-shell shell toggle jixt.twingate` — **not** `omarchy-shell jixt.twingate toggle`. The bar renders once per monitor, so this plugin (like every bar widget) has a separate instance on each one; a direct `jixt.twingate toggle` call only ever reaches whichever instance's `IpcHandler` happened to claim that name first, opening the panel on the same fixed monitor regardless of where you actually are. Routing through `shell toggle` (the same mechanism the built-in Bluetooth/Network bindings use) opens the panel on whichever monitor is actually focused.

## Configuration

The refresh interval (5–3600 seconds, default 5) is configurable through the plugin's settings.

Favorites (which resources you've starred) are saved to `~/.local/state/jixt.twingate/favorites.json` so they survive a panel close or shell restart. The panel also caches the last successful account/resource snapshot to `~/.local/state/jixt.twingate/snapshot.json`, so reopening it (even right after a shell restart) shows that data instantly instead of a blank panel while it refreshes in the background; the cache is cleared on sign-out. Everything else — accounts, resources, status — comes straight from the local `twingate` CLI on every refresh.

## What it runs

Most `twingate` probes (status, account list, resources, version, and similar) run through a wrapper that bounds their output (so a huge or hanging response can't affect the rest of the shell), disables colored output where the result is parsed, and is force-killed if they run too long.

Interactive actions that need a TTY — connect/disconnect, account switch, add account, and resource authentication — skip that wrapper and run in a floating terminal instead (`setsid` + `uwsm-app` + `xdg-terminal-exec` with Omarchy's `org.omarchy.terminal` app-id, so the window floats centered rather than tiling in the background). Beyond `twingate` itself, this plugin also runs:

- `which twingate` — detects whether the CLI is installed
- `wl-copy` — copies a resource's address to the clipboard
- `omarchy-launch-browser` — opens a resource link
- `xdg-terminal-exec` / `uwsm-app` — opens a floating terminal for the interactive flows above

## Troubleshooting

- **"Twingate CLI is not installed or not on PATH."** — install the [`twingate`](https://www.twingate.com/download) CLI; the panel picks it up automatically on the next refresh, no restart needed.
- **Connect/disconnect fails or times out** — a floating terminal opens for the command so you can type a sudo password if asked. If it fails, that window stays open with the error until you press Enter; the panel shows "Command failed" or times out after 90 seconds. You can also run `twingate status -v` yourself to see the daemon's own output.
- **A terminal opened for connect, disconnect, account switch, or authenticate** — expected. Connect/disconnect/switch restart the daemon through `sudo`, and a typed password needs a TTY; authenticate opens a terminal so you can see/copy the OAuth URL. Enter the sudo prompt (or scan/touch) in that window; for authenticate, finish the browser flow using the printed URL. The panel updates once the action finishes.
- **Panel shows "Check the terminal"** — normal while a terminal sudo/TTY flow is in flight. Use **Hide** or Escape to dismiss the notice without cancelling the terminal command.
- **Resource list looks empty** — normal for a few seconds right after connecting, switching accounts, or logging in/out, while the daemon restarts; if it stays empty, check that the signed-in account actually has resources assigned.
- **Status looks stuck** — periodic checks time out after 10 seconds; connect/disconnect/account-switch wait up to 90 seconds, and resource authentication up to 120 seconds, so a genuinely hung action clears its in-panel busy state within that window.
- **Diagnostics** — run `omarchy-shell jixt.twingate diagnostics` for a JSON dump of whether the CLI is installed, the current state, resource count, the last error, and the active settings. Other useful IPC commands: `omarchy-shell jixt.twingate connect|disconnect|refresh|status`.

## Removal

```bash
omarchy plugin remove jixt.twingate
```

## Privileges

Runs unsandboxed with your user permissions, same as any other Omarchy shell plugin. It only ever runs `twingate` and the small set of helpers listed above (`which`, `wl-copy`, `omarchy-launch-browser`, `xdg-terminal-exec` / `uwsm-app`) — the plugin itself never calls `sudo` or requests elevated privileges, and it does not install or update packages.

That said, `twingate connect`/`disconnect`/`account switch` are not privilege-free under the hood: the CLI re-execs itself through `sudo` one layer down (`sudo twingate-classic service-start --auth-mode user` / `sudo twingate-classic service-stop`) to manage the system service. That's Twingate's own design, not something this plugin arranges. Those actions open a floating terminal so the sudo prompt can be answered with a password, a fingerprint, or a security key. The panel waits for the new status/account to show up (or times out after 90 seconds).

### Skipping the authentication prompt (optional, at your own risk)

If you'd rather the toggle never prompt at all, you can grant your user passwordless `sudo` for exactly those two commands with a sudoers drop-in:

```
# /etc/sudoers.d/twingate — install with mode 0440, owned by root:root,
# and validate with `visudo -cf /etc/sudoers.d/twingate` before trusting it.
<user> ALL=(root) NOPASSWD: /usr/bin/twingate-classic service-start --auth-mode user, /usr/bin/twingate-classic service-stop
```

**Do this only if you understand the trade-off, and only at your own risk.** It doesn't grant broad `sudo` access — it's scoped to those exact two commands — but it does remove the one thing that requires *you, physically,* to be present for a connect/disconnect: once it's in place, **any process running as your user can silently start or stop your VPN connection**, with no password, no fingerprint, no security-key touch, and nothing that looks any different in the logs from you doing it yourself. For a Zero Trust client, that's a real (if narrow) hole, not a cosmetic one. This plugin does not install this rule for you, and removing it later is just deleting the file.

Editing `sudoers` incorrectly can lock you out of elevated access or weaken your system’s security. The developer of this plugin is **not responsible** for any damage, lockout, unauthorized access, or other consequences that result from adding, changing, or removing this rule — you are solely responsible for validating it (`visudo -cf …`) and for what happens after you install it.

## License

MIT — see [LICENSE](LICENSE).
