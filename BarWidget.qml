import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// How many columns fill the screen in Hyprland's scrolling layout.
//
// Hyprland stores a width on every column, so a workspace you have already
// set stays set through focus changes and config reloads. What is *global*
// is only the width handed to the next new column: ScrollingAlgorithm's
// defaultColumnWidth() reads the bare `scrolling:column_width` config value
// with no workspace context. So the real work here is re-pointing that one
// number at the active workspace whenever focus moves -- the click target is
// just how you pick the number.
BarWidget {
  id: root
  moduleName: "scttymn.scrolling-columns"

  // One column is what fullscreen_on_one_column already gives you, so the
  // floor is two: below that the widget is just a worse way to fullscreen.
  readonly property var columnBounds: Model.bounds(root.setting("minColumns", 2),
                                                   root.setting("maxColumns", 6))
  readonly property int minColumns: root.columnBounds.min
  readonly property int maxColumns: root.columnBounds.max
  readonly property int fallbackColumns: root.clampColumns(Number(root.setting("defaultColumns", 2)))
  readonly property int probeIntervalMs: Math.max(500, Number(root.setting("probeIntervalMs", 2000)))
  readonly property bool hideOnDwindle: root.setting("hideOnDwindle", false) === true

  // Hyprland's fullscreen_on_one_column defaults to true, so a lone window
  // spans the screen no matter what column count is set -- which reads as the
  // widget being ignored. This ships the opposite default on purpose: a
  // workspace set to N columns should keep them at 1/N whatever is open.
  // Applied alongside column_width so the two never disagree.
  readonly property bool fullscreenOnOneColumn: root.setting("fullscreenOnOneColumn", false) === true

  // Columns span the full screen by default. Hyprland subtracts gaps and
  // borders from each column's own allotment, so 1/N already fits edge to
  // edge at any gap setting. See the README on why edge peek is off.
  readonly property real usableWidth: Number(root.setting("usableWidth", 1.0))

  function clampColumns(n) {
    return Model.clampColumns(n, root.minColumns, root.maxColumns)
  }

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string stateHome: (Quickshell.env("XDG_STATE_HOME") || (home + "/.local/state")) + "/omarchy"

  // ------------------------------------------------------------- workspace

  readonly property var focusedWorkspace: Hyprland.focusedWorkspace
  readonly property int workspaceId: focusedWorkspace ? focusedWorkspace.id : -1

  // tiledLayout is per workspace and flips under SUPER + L without any
  // workspace change, so it is polled rather than derived from focus alone.
  property string tiledLayout: ""
  readonly property bool scrolling: tiledLayout === "scrolling"

  // Peek costs margin on every workspace but only pays off on one that has
  // somewhere to scroll, so the slack is applied only while the tape
  // overflows. At or under the target count the columns run flush.
  property int columnCount: 0
  readonly property bool overflowing: root.columnCount > root.columns

  // Nothing may act on the compositor until the store has been read. The
  // FileView loads asynchronously, so the first probe would otherwise see
  // `columns` still falling back to defaultColumns, read the startup state as
  // a transition into scrolling, and resize every existing column to the
  // default -- silently discarding the count on every shell restart.
  property bool ready: false
  property bool recovered: false

  Timer {
    // The store may legitimately not exist yet on a fresh install, in which
    // case onLoaded never fires; fall back to the defaults after a beat.
    interval: 750
    running: true
    repeat: false
    onTriggered: root.ready = true
  }

  // -1 unknown, 0 flush, 1 peeking. Re-applying on every probe would fight a
  // column the user resized by hand, so width is only rewritten when this
  // actually flips.
  property int appliedPeekState: -1

  function syncPeek() {
    if (!root.scrolling) return
    var wanted = root.overflowing ? 1 : 0
    if (wanted === root.appliedPeekState) return
    root.appliedPeekState = wanted
    setDefaultWidth(root.columns)
    resizeExistingColumns(root.columns)
  }

  // Columns, not windows: promote and consume_or_expel change how many
  // columns exist without opening or closing anything, so the count is
  // derived from distinct column origins rather than from toplevel count.
  readonly property string probeScript:
    'ws=$(hyprctl activeworkspace -j) || exit 0; '
    + 'opts=$(hyprctl -j --batch "getoption scrolling:column_width ; '
    + 'getoption scrolling:fullscreen_on_one_column" | tr -d "\\n"); '
    + 'hyprctl clients -j | jq -c --argjson ws "$ws" --arg opts "$opts" '
    + "'{ id: $ws.id, layout: $ws.tiledLayout, opts: $opts, columns: ("
    + "[ .[] | select(.workspace.id == $ws.id and .floating == false and .mapped == true) | .at[0] ]"
    + " | unique | length) }'"

  Process {
    id: layoutProbe
    running: false
    command: ["bash", "-c", root.probeScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyProbe(text)
    }
  }

  function probe() {
    if (!layoutProbe.running) layoutProbe.running = true
  }

  function applyProbe(output) {
    var parsed = Model.parseProbe(output)
    if (!parsed) return
    // Layout and column count come from one sample and must both land before
    // anything reacts to either. Assigning the layout first let the scrolling
    // transition run against a stale count -- and dwindle reports a different
    // count for the same windows (four windows tile into three distinct
    // column origins), so a three-column workspace saw 3 === 3, ran "fit all"
    // against four real columns, and squeezed them all onto the screen.
    var wasScrolling = root.scrolling
    root.columnCount = parsed.columns
    root.tiledLayout = parsed.layout

    // Track the layout before the store arrives, but touch nothing.
    if (!root.ready) return

    // First probe with the store in hand: this is the recovery step. The
    // store holds the intent, Hyprland holds whatever survived, and they can
    // legitimately disagree -- a reload resets the config, and a restart of
    // the shell leaves columns at whatever width they had. Assert both once,
    // then leave existing columns alone unless something actually changes.
    if (!root.recovered) {
      root.recovered = true
      if (root.scrolling && root.workspaceId >= 0) {
        root.setDefaultWidth(root.columns)
        root.resizeExistingColumns(root.columns)
      }
      return
    }

    // A workspace becoming scrolling has to re-assert width and anchor:
    // syncPeek only fires on a peek transition, which never happens with edge
    // peek off, so the toggle would otherwise inherit whatever dwindle left.
    if (root.scrolling && !wasScrolling && root.workspaceId >= 0) {
      root.appliedPeekState = -1
      root.setDefaultWidth(root.columns)
      root.resizeExistingColumns(root.columns)
    }

    root.syncPeek()
    root.correctDrift(parsed.opts)
  }

  // Hyprland is the live source of truth, and anything set through eval is
  // discarded by `hyprctl reload` -- which Omarchy triggers for theme changes
  // and toggles. Rather than keeping a copy in Hyprland's own config
  // directory, the widget reads back what actually took and re-applies when
  // it does not match. Existing columns are untouched by a reload (verified:
  // they keep their own widths), so only the default for the next new column
  // needs correcting.
  function correctDrift(optsText) {
    if (!root.scrolling || root.workspaceId < 0) return
    var live = Model.parseOptions(optsText)
    if (!live) return
    if (Model.optionsMatch(live, root.widthText(root.columns), root.fullscreenOnOneColumn)) return
    root.setDefaultWidth(root.columns)
  }

  // A toplevel opening or closing is the common way to cross the threshold,
  // and it is reactive, so it beats waiting up to a full poll interval. The
  // timer stays as the backstop for the changes it cannot see: SUPER + L, and
  // promote/consume rearranging columns at a constant window count.
  readonly property int toplevelCount: {
    var ws = root.focusedWorkspace
    return ws && ws.toplevels ? ws.toplevels.values.length : 0
  }
  onToplevelCountChanged: root.probe()

  Timer {
    interval: root.probeIntervalMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.probe()
  }

  // ----------------------------------------------------------------- state

  // Bumped on every rewrite so the `columns` binding re-reads the map; a
  // nested var object mutating in place would not re-evaluate on its own.
  property int revision: 0

  FileView {
    id: store
    path: root.stateHome + "/scttymn.scrolling-columns.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onAdapterUpdated: root.revision++
    onLoaded: { root.revision++; root.ready = true }

    JsonAdapter {
      property var workspaces: ({})
    }
  }

  function storedColumns(id) {
    root.revision
    if (id < 0) return root.fallbackColumns
    var map = store.adapter ? store.adapter.workspaces : null
    return Model.storedColumns(map, id, root.fallbackColumns, root.minColumns, root.maxColumns)
  }

  readonly property int columns: storedColumns(workspaceId)

  // A workspace that has never been set follows fallbackColumns and keeps
  // following it if that setting later changes; one that has been set is
  // pinned. Resetting clears the entry rather than writing today's default
  // value, so the two stay distinguishable.
  readonly property bool pinned: {
    root.revision
    if (root.workspaceId < 0 || !store.adapter) return false
    return Model.isPinned(store.adapter.workspaces, root.workspaceId)
  }

  function rememberColumns(id, n) {
    if (id < 0 || !store.adapter) return
    store.adapter.workspaces = Model.withWorkspace(store.adapter.workspaces, id, n)
    store.writeAdapter()
    root.revision++
  }

  function forgetColumns(id) {
    if (id < 0 || !store.adapter) return
    store.adapter.workspaces = Model.withoutWorkspace(store.adapter.workspaces, id)
    store.writeAdapter()
    root.revision++
  }

  // ----------------------------------------------------------------- apply

  function widthText(n) {
    return Model.columnWidthText(n, root.usableWidth, root.overflowing)
  }

  // `hyprctl keyword` is rejected outright by the Lua parser ("keyword can't
  // work with non-legacy parsers. Use eval."), so every write goes through
  // eval, and every dispatch through the hl.dsp.* form.
  function scrollingConfig(widthText) {
    return "hl.config({ scrolling = { column_width = " + widthText
      + ", fullscreen_on_one_column = " + (root.fullscreenOnOneColumn ? "true" : "false") + " } })"
  }

  // One place to write: Hyprland itself. An earlier version also wrote a lua
  // file into ~/.local/state/omarchy/toggles/hypr/, which Hyprland sources
  // wholesale, purely so a reload would not lose the width. That bought a
  // torn-write hazard across monitors, a filename that breaks every toggle on
  // the system if it contains a dot, and a file left behind on uninstall --
  // all to avoid a correction the probe now makes within one interval.
  function setDefaultWidth(n) {
    if (!root.bar) return
    root.bar.run("hyprctl eval " + Util.shellQuote(root.scrollingConfig(root.widthText(n)))
      + " >/dev/null 2>&1")
  }

  function setColumns(n) {
    var clamped = root.clampColumns(n)
    if (clamped === root.fallbackColumns) root.forgetColumns(root.workspaceId)
    else root.rememberColumns(root.workspaceId, clamped)
    // Changing the target can itself cross the threshold, so the width used
    // here is whatever Model.columnWidth decides for the new count.
    root.appliedPeekState = (root.columnCount > clamped) ? 1 : 0
    setDefaultWidth(clamped)
    resizeExistingColumns(clamped)
    root.probe()
  }

  function cycleColumns(step) {
    // A dwindle workspace has no columns to count, and the widget shows no
    // number there, so a click or scroll would rewrite the stored count and
    // push a new column_width with nothing on screen to show for it. Middle
    // click still switches the layout; that is the useful gesture here.
    if (!root.scrolling) return
    setColumns(Model.cycleNext(root.columns, step, root.minColumns, root.maxColumns))
  }

  // Focus moved to another workspace: hand the compositor that workspace's
  // width so the next window opened there lands at the right size. Existing
  // columns already carry their own widths and must not be touched.
  onWorkspaceIdChanged: {
    root.appliedPeekState = -1
    root.probe()
    if (root.workspaceId >= 0) setDefaultWidth(root.columns)
  }

  // Retuning the edge peek in shell.json should land immediately rather than
  // waiting for the next count change, so this re-applies the current count
  // at the new width. shell.json hot-reloads, so editing the setting is the
  // whole interaction.
  onFullscreenOnOneColumnChanged: {
    if (root.workspaceId >= 0) root.setDefaultWidth(root.columns)
  }

  onUsableWidthChanged: {
    if (root.workspaceId < 0) return
    root.appliedPeekState = -1
    setDefaultWidth(root.columns)
    resizeExistingColumns(root.columns)
    root.probe()
  }

  // ------------------------------------------------------------------- ui

  // The layout is what the icon reports: columns plus the count while
  // scrolling, an uneven masonry block on dwindle -- which is what nested
  // dwindle splits actually look like, where a uniform grid is not. Both
  // The columns glyph is the Font Awesome one rather than the Material
  // set's, which measures 10x7 at the bar's 13px and reads as squashed
  // beside neighbours that are all about 11 tall. These two are 12x11
  // and 10x11. A count is dropped on dwindle rather than greyed out,
  // since a column count means nothing there.
  readonly property string scrollingGlyph: ""
  readonly property string dwindleGlyph: "󰕮"
  readonly property string glyph: root.scrolling ? root.scrollingGlyph : root.dwindleGlyph

  visible: !root.hideOnDwindle || root.scrolling
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The layout toggle writes state and reloads Hyprland, so give it a beat
  // before re-reading rather than showing a stale dimmed state for a full poll.
  Timer {
    id: probeSoon
    interval: 400
    repeat: false
    onTriggered: root.probe()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    // The glyph and the count are drawn separately so the icon can sit at
    // Style.bar.iconFont -- the size every BarIconButton on the bar uses --
    // while the number stays at the smaller body size. WidgetButton's single
    // label would otherwise force both to one size, leaving this icon visibly
    // smaller than the stock widgets beside it.
    labelVisible: false
    hasVisualContent: true
    fixedWidth: content.implicitWidth + button.scaledHorizontalMargin * 2

    tooltipText: {
      if (!root.scrolling)
        return "Workspace " + root.workspaceId + " is tiled \u00b7 middle click or SUPER + L for scrolling"
      var count = root.columns === 1 ? "1 column" : root.columns + " columns"
      return count + " on workspace " + root.workspaceId
        + (root.pinned ? "" : " (default)")
        + (root.overflowing
            ? " \u00b7 " + root.columnCount + " open"
              + (Model.isPeeking(root.usableWidth, root.overflowing) ? ", peeking" : "")
            : "")
    }

    Row {
      id: content
      anchors.centerIn: parent
      // space(1) leaves only 2px between the icon's ink and the digit's, which
      // reads as the two colliding rather than as icon-plus-count.
      spacing: root.scrolling ? Style.space(2) : 0

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.glyph
        color: button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.bar.iconFont
        renderType: Text.NativeRendering
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        visible: root.scrolling
        text: root.columns
        color: button.foreground
        font.family: button.fontFamily
        // A count at body size stands nearly as tall as the icon and competes
        // with it; the icon is the subject and the number annotates it.
        font.pixelSize: Style.font.bodySmall
        renderType: Text.NativeRendering
      }
    }

    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycleColumns(-1)
      else if (b === Qt.MiddleButton) {
        root.bar.run("omarchy-hyprland-workspace-layout-toggle")
        probeSoon.restart()
      }
      else root.cycleColumns(1)
    }

    onWheelMoved: function(delta) {
      root.cycleColumns(delta > 0 ? 1 : -1)
    }
  }
}
