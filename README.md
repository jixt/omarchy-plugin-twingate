# Twingate for Omarchy

A bar widget for the [Omarchy](https://omarchy.org/) shell that shows
[Twingate](https://www.twingate.com/) VPN status and gives you a panel to
connect/disconnect, switch accounts, browse resources, and sync Kubernetes
configs.

> **Prerequisite:** the [`twingate`](https://www.twingate.com/download) CLI
> must already be installed and set up (signed in to at least one account)
> before this widget will show anything useful. See [Requirements](#requirements)
> below.

## Disclaimer

This is an independent, personal project with no affiliation to, endorsement
by, or partnership with Twingate. I built it for my own use and I'm sharing
it in case it's useful to others — "Twingate" is used only to describe what
the widget talks to, and remains a trademark of its respective owner.

## Features

- Bar icon with a status-dot badge (green = online, amber = authenticating,
  gray = offline/disconnected/error)
- One-click connect/disconnect
- Main / Kubernetes / Hidden tabs, each with a searchable, full resource list
  and its own actions (open in browser, copy address, sync `kubeconfig`,
  authenticate a locked resource)
- Star any resource to pin it to a Favorites strip above the tabs
- Account list showing every configured account, with one-click switching,
  per-account removal (`twingate account logout`, with a confirmation
  dialog), and an in-panel "Add account" flow
- Installed Twingate CLI version shown in the panel footer

## Requirements

- The [`twingate`](https://www.twingate.com/download) CLI **installed and
  already set up** — signed in to at least one account
  (`twingate account add`) — before installing this plugin. The widget
  doesn't install, configure, or authenticate Twingate for you.
- `omarchy-launch-browser` (ships with Omarchy) — used to open a resource
  link when you click one in the panel

No credentials are stored or handled by this plugin — it only shells out to
the `twingate` CLI, which manages its own auth.

## Installation

```bash
omarchy plugin add https://github.com/jixt/omarchy-plugin-twingate --enable
```

## Usage

Click the Twingate icon in the bar to open the panel:

- Toggle the switch at the top to connect/disconnect
- Click an account row to switch to it, or use "Remove account"/"+ Add
  account" to manage which accounts are configured
- Switch between the Main, K8s, and Hidden tabs, search, and click a resource
  to open it in your browser or a Kubernetes resource to sync its
  `kubeconfig`
- Click the star on any resource to pin it to the Favorites strip

The bar icon refreshes status every 5 seconds. Accounts, resources, and the
CLI version refresh whenever the panel is opened.

## Configuration

No settings UI, but favorites (which resources you've starred) are saved to
`~/.local/state/jixt.twingate/favorites.json` so they survive a panel close
or shell restart. Everything else — accounts, resources, status — comes
straight from the local `twingate` CLI on every refresh.

## Removal

```bash
omarchy plugin remove jixt.twingate
```

## Privileges

Runs unsandboxed with your user permissions, same as any other Omarchy shell
plugin. It only ever runs `twingate` and the `omarchy-launch-browser` helper
listed above — no elevated privileges are requested or required, and it does
not install or update packages.

## License

MIT — see [LICENSE](LICENSE).
