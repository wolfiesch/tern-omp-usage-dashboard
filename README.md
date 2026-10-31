# OMP Usage for Tern

View provider quotas for every account in a native Tern pane. Open **Open OMP usage** from the command palette, press **Ctrl+Alt+U**, or click the gauge summary in Tern's status bar.

The status bar shows each Anthropic (Claude) and OpenAI account's weekly usage separately, for example `Claude green 87% · hill 4%  Codex green 91% · hill 3% 30d`, followed by the alert counts for all providers. The percentage is the used share of the account-wide 7-day bucket; an account without one shows its longest account-wide window, with that window named. Accounts are named by the shortest unique part of their email's local part. Exhausted accounts show in the error tone, low ones in the warning tone, and stale ones muted.

- Separate accounts and plans, including multiple accounts at the same provider.
- Header chips count providers, accounts, and exhausted, low, login-required, stale and no-data accounts.
- One aligned row per quota bucket: remaining bar, amount left, and reset or regeneration countdown. Saved resets appear as a chip.
- Explicit login-required, no-data and stale states. Unknown usage is never shown as zero.
- Anthropic and OpenAI get framed panels, side by side in wide panes and stacked in narrow ones. Other providers sit below as collapsed rows with their warning counts visible.
- Expand **Details** on an account for organization/plan identifiers, fetch time and provider or quota notes.
- Press **r** or click **Refresh** for a new snapshot.

## Install

Requires Tern's native plugin API and an OMP version with `omp usage --json`. Verified on macOS with Tern 0.9.5 and OMP 18.12.3.

Install from GitHub:

```sh
tern plugin install github.com/wolfiesch/tern-omp-usage-dashboard
tern plugin list
```

Or clone the repository and link it in place, in bash/zsh/fish:

```sh
git clone https://github.com/wolfiesch/tern-omp-usage-dashboard.git
cd tern-omp-usage-dashboard
tern plugin link .
tern plugin list
```

`tern plugin list` should show `omp-usage … ready`. Open **Open OMP usage** from the command palette or press **Ctrl+Alt+U**.

No OMP extension, configuration edit or OMP-session restart is needed. A linked source directory must remain in place. To update an installed copy, run `tern plugin install github.com/wolfiesch/tern-omp-usage-dashboard --force`; for a linked clone, `git pull` then `tern plugin reload`. To disable this plugin without deleting the source:

```sh
tern plugin unlink omp-usage
```

## Data and refresh

One collector runs in Tern's session daemon, shared by all dashboard panes and windows attached to that daemon. It invokes OMP directly with argument arrays, without a shell, every 60 seconds after the previous request completes. A request times out after 30 seconds. Overlapping refresh requests are coalesced; after a plugin reload, the collector waits out any surviving request's deadline before launching another.

OMP remains responsible for account discovery, OAuth refresh and provider APIs. The plugin only invokes the read-only usage command. It never redeems saved resets, changes accounts or signs in. Reports include API-key accounts when OMP returns them; coverage is limited to what OMP exposes.

The dashboard retains the last successful snapshot on errors and labels it stale. Each account's provider fetch time is displayed separately: a newly collected snapshot does not make an old provider response fresh. Reports older than ten minutes, or with an unknown fetch time, are stale. The status bar reports an offline collector after fifteen seconds without a heartbeat.

Distinct quota IDs are preserved even when their labels or durations match. Shared aliases remain visible with shared-quota notes; they are never added together. Counts of exhausted accounts mean at least one bucket is exhausted, not necessarily every model or bucket for that account. Percentages from different plans are never averaged.

## Privacy and scope

The detail pane displays local account identities. Treat screenshots accordingly. Raw provider responses, endpoints, credential-disable exceptions and process stderr are not displayed or saved by this plugin. Only the status-line text (aggregate counts plus abbreviated account names and their weekly percentages), a fixed diagnostic message on failure, collector heartbeat and request deadline are persisted in Tern's plugin data. Native pane content is replicated through Tern to attached clients like other Tern panes.

The status bar summarizes the local daemon's OMP accounts. A dashboard runs on the current Tern host; remote hosts require their own installation. There is no cross-host quota aggregation.

OMP is resolved from `TERN_OMP_BIN`, then the existing `~/.local/bin/omp`, then Tern's process `PATH`. The selected executable's directory, `~/.local/bin` and `~/.bun/bin` are added to the subprocess search path so GUI-launched Tern can also run OMP development launchers. No login shell is invoked. Set an absolute `TERN_OMP_BIN` in Tern's launch environment if its installation differs; no shell expression or arguments belong in that value. After changing the daemon's environment, restart it deliberately, preserving active work.

## Development

- `usage.luau`: pure account normalization, quota arithmetic and freshness summaries.
- `collector.luau`: single-flight collection and retained-data lifecycle.
- `host.luau`: one collector plus native dashboard blocks.
- `view.luau`: native themed UI, with no provider access.
- `window.luau`: palette command, shortcut and cached status summary.

From this directory, with the Luau CLI installed:

```sh
luau tests/usage.test.luau tests/collector.test.luau
luau-analyze usage.luau view.luau collector.luau
```

The focused regressions cover account separation, ambiguous quota buckets, missing data, amount precedence, provider caveats, staleness, malformed payloads, overlapping refreshes, reload deadlines and failure recovery. For integration changes, also load the real plugin in Tern and inspect its surface: unit checks do not verify native rendering.

The dashboard's styles target Tern's native renderer classes (`.sf-card-head`, `.sf-tbl-row.head`), which the plugin API does not document. A Tern update that renames them reverts the larger provider headings and shows table column headers again; the dashboard keeps working.

## Compatibility

This plugin uses the id `omp-usage`, as does [jmazzola/tern-plugin-omp-usage](https://github.com/jmazzola/tern-plugin-omp-usage), a separate plugin that draws a usage line above the omp composer. Plugin ids must be unique, so install only one of them.

## License

[MIT](LICENSE)
