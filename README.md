# Scrolling Columns

An [Omarchy](https://omarchy.org/) bar widget that sets how many columns fill the
screen in Hyprland's scrolling layout — tracked **per workspace**.

![Scrolling Columns in the Omarchy bar](preview.png)

## Why per workspace

Hyprland stores a width on every column, so a workspace you have already set
stays set through focus changes and config reloads. What is *global* is only the
width handed to the next new column — `ScrollingAlgorithm::defaultColumnWidth()`
reads `scrolling:column_width` with no workspace context.

So the widget's real job is re-pointing that one global at the active workspace
whenever focus moves. The click target is just how you pick the number.

## Requirements

- **Omarchy Quattro** with the Omarchy shell (the widget is a Quickshell bar
  widget)
- **Hyprland** with its `scrolling` layout — toggle a workspace into it with
  `SUPER + L`
- `hyprctl`, `jq`, and `bash`, all of which ship with Omarchy. The widget
  shells out to `hyprctl` to read and apply compositor state, pipes it through
  `jq`, and runs `omarchy-hyprland-workspace-layout-toggle` on middle click.

No other external dependencies, and nothing is installed or downloaded at
runtime.

## Install

```bash
omarchy plugin add https://github.com/scttymn/omarchy-scrolling-columns.git --enable
```

### Removing

```bash
omarchy plugin remove scttymn.scrolling-columns
```

That removes the plugin and its bar entry. It leaves behind the one file it
wrote, so delete that too if you want it gone completely:

```bash
rm -f ~/.local/state/omarchy/scttymn.scrolling-columns.json
hyprctl reload
```

The reload returns `scrolling:column_width` to Omarchy's default of two
columns. Nothing is written into your Hyprland config.

Requires the scrolling layout on the workspace you want to affect — toggle it
with `SUPER + L`. On tiled (dwindle) workspaces the widget shows a grid icon
with no count, since a column count means nothing there.

## Use

| Gesture | Effect |
| --- | --- |
| Left click / wheel up | +1 column (wraps) |
| Right click / wheel down | −1 column (wraps) |
| Middle click | Toggle the workspace between scrolling and dwindle |

The count cycles between `minColumns` and `maxColumns` and wraps at both ends.
On a tiled (dwindle) workspace there is no count to change, so left click,
right click and the wheel do nothing — only middle click is live there.

Setting a workspace to the default count *unpins* it rather than storing an
identical override, so it keeps following `defaultColumns` if you change that
later. The tooltip shows which state you are in.

## Fullscreen

Hyprland's scrolling layout does not lift a fullscreen window out of the row.
It resizes that column to the full width of the monitor and scrolls the tape so
the column sits at the leading edge — `hyprctl clients` reports
`fullscreenHandler: "scrolling"` while it is up. The other columns keep their
order and spacing and simply slide.

The consequence is that leaving fullscreen strands the row somewhere you never
put it: the formerly-fullscreen column ends up leading, so a workspace showing
columns one to three comes back showing two to four.

The widget puts it back. Because the column stays part of the row, the original
offset is still encoded in the surviving columns *while* you are fullscreen —
the leftmost survivor, plus one column pitch for each column that precedes the
fullscreen one. That is the only workable moment to read it: panning emits no
Hyprland event, so anything recorded earlier is stale, and Hyprland repositions
the row within about 14ms of announcing the change.

This covers both a fullscreen dispatcher and an application's own fullscreen
button. The dispatcher accepts `layout_aware = false`, which avoids the whole
behaviour by using Hyprland's default handler, but a client's fullscreen
request never goes through a dispatcher and has no equivalent opt-out.

One case is deliberately left alone: if the fullscreen column was already the
leading one, the shift that moved it to the edge was the row's entire offset,
so nothing survives to recover — and nothing needs to, since a column that led
before leads again after.

## Settings

Set them in `~/.config/omarchy/shell.json`, or with `omarchy bar set`:

```bash
omarchy bar set scttymn.scrolling-columns defaultColumns 3
```

| Key | Default | Meaning |
| --- | --- | --- |
| `defaultColumns` | `2` | Column count for workspaces with no explicit setting. Matches stock Omarchy, which ships `column_width = 0.49` — two columns |
| `minColumns` | `2` | Lower bound for the cycle. One column is what `fullscreen_on_one_column` already does, so two is the floor |
| `maxColumns` | `6` | Upper bound for the cycle |
| `usableWidth` † | `1.0` | Fraction of the screen the columns span. Below `1.0` leaves slack at the edges while the tape overflows — see *Edge peek* below |
| `fullscreenOnOneColumn` | `false` | Keeps a lone window at the column width. Set `true` for Hyprland's stock behaviour, where one window spans the whole screen — see below |
| `hideOnDwindle` | `false` | Hide the widget entirely on tiled workspaces instead of showing the tiled icon |

† `usableWidth` is config-file only — it is deliberately kept out of the
settings form, for the reason below.

### Single window filling the screen

Hyprland's `scrolling:fullscreen_on_one_column` defaults to `true`, so a lone
window spans the whole screen no matter what column width is set. This plugin
ships the opposite, because a workspace set to three columns should keep them
at a third whatever happens to be open — otherwise closing windows silently
undoes the setting.

To get Hyprland's behaviour back:

```bash
omarchy bar set scttymn.scrolling-columns fullscreenOnOneColumn true
```

The plugin applies this alongside `column_width`, so the two can never
disagree, and re-applies both when Hyprland discards them on a reload.

### Edge peek

`usableWidth` below `1.0` shrinks columns so a sliver of the neighbouring column
shows. It is off by default because it does not pay for itself: the slack has to
land somewhere, and at either end of the tape it becomes dead space rather than a
neighbour. With 4 columns and 3 fitting you are always near an end. Columns
either tile the screen exactly (no peek, no cut columns) or they do not (peek,
dead space at the ends) — there is no setting that gives both. It may be worth
enabling on a much longer tape, where you are mid-scroll most of the time.

## Suggested keybindings

The widget sets the column *count*; these pan and reorder the tape. Add to
`~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + code:34", "Pan columns backward", hl.dsp.layout("move -col"))
o.bind("SUPER + code:35", "Pan columns forward", hl.dsp.layout("move +col"))
o.bind("SUPER + SHIFT + code:34", "Swap column left", hl.dsp.layout("swapcol l"))
o.bind("SUPER + SHIFT + code:35", "Swap column right", hl.dsp.layout("swapcol r"))
o.bind("SUPER + SHIFT + mouse_down", "Pan columns forward", hl.dsp.layout("move +col"))
o.bind("SUPER + SHIFT + mouse_up", "Pan columns backward", hl.dsp.layout("move -col"))
```

`code:34` and `code:35` are `[` and `]`; Omarchy addresses punctuation by keycode.

## What it writes

Plugins run unsandboxed inside the `omarchy-shell` process, so here is everything
this one touches:

- `~/.local/state/omarchy/scttymn.scrolling-columns.json` — the per-workspace
  column counts. This is the only file it writes.
- It shells out to `hyprctl eval` and `hyprctl dispatch` to apply widths, and to
  `omarchy-hyprland-workspace-layout-toggle` on middle click.

Nothing is written into your Hyprland config directory. Hyprland holds the
live state and the JSON is write-behind persistence: it is loaded to recover
your counts, while the widget reads back what Hyprland actually has and
re-applies when the two drift — which is what happens on `hyprctl reload`,
since anything set through `eval` is discarded there. Existing columns keep
their own widths across a reload, so only the default for the next new column
needs correcting.

## Multiple monitors

A bar surface exists per monitor, so each display gets its own instance of the
widget. They all watch the same focused workspace and issue the same commands
with the same values, which is redundant but not incorrect — `hyprctl` calls
here are idempotent, the reload file is written atomically, and only the
instance you actually click writes the per-workspace state.

Expect one extra `hyprctl` poll every `probeIntervalMs` per additional
display. This has been reasoned through rather than tested on real hardware;
if you run multiple monitors and see the widgets disagree, please open an
issue.

## How it stays in sync

The widget is event driven — it does not poll. Hyprland announces everything
it reacts to: `configreloaded` fires the instant a layout toggle or a
`hyprctl reload` re-evaluates the config, which is exactly when a width set
through `eval` is discarded, and `openwindow`/`closewindow`/`movewindow` cover
every change to the column count.

The one blind spot is `promote` and `consume_or_expel`, which rearrange
columns through `layoutmsg` and emit nothing. That leaves only the tooltip's
live count stale; the number on the bar is your setting, not a measurement.

## Development

Column arithmetic lives in `Model.js`, kept Qt-free so it can be tested without
running a desktop:

```bash
npm test
```

`BarWidget.qml` handles everything that needs Qt or a compositor.

## License

MIT — see [LICENSE](LICENSE).
