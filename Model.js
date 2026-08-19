// Column arithmetic for the Scrolling Columns widget, kept Qt-free so it can
// be unit tested under node (test/model.test.js). Everything here is pure:
// no hyprctl, no file access, no QML types.

// Hyprland clamps column_width at MIN_COLUMN_WIDTH = 0.05, so twenty columns
// is the hard ceiling regardless of what a user configures.
var HARD_MAX_COLUMNS = 20
var MIN_COLUMN_WIDTH = 0.05

// One column is what fullscreen_on_one_column already gives you, so the
// shipped floor is two. Still configurable, for very small displays.
function bounds(minColumns, maxColumns) {
  var lo = Math.round(Number(minColumns))
  if (!(lo >= 1)) lo = 1
  lo = Math.min(lo, HARD_MAX_COLUMNS)

  var hi = Math.round(Number(maxColumns))
  if (!(hi >= lo + 1)) hi = lo + 1
  hi = Math.min(hi, HARD_MAX_COLUMNS)

  return { min: lo, max: hi }
}

function clampColumns(n, minColumns, maxColumns) {
  var b = bounds(minColumns, maxColumns)
  var v = Math.round(Number(n))
  if (!(v >= 1)) v = b.min
  return Math.max(b.min, Math.min(b.max, v))
}

// Hyprland subtracts gaps and borders from each column's own allotment, so a
// bare 1/n already fits edge to edge at any gap setting. usableWidth below 1
// deliberately leaves slack -- see the README on why edge peek is off -- and
// only while the tape overflows, since at or under the target there is no
// neighbouring column for the slack to reveal.
function columnWidth(n, usableWidth, overflowing) {
  var span = overflowing ? Number(usableWidth) : 1.0
  if (!(span > 0)) span = 1.0
  var count = Math.max(1, Math.round(Number(n)))
  return Math.max(MIN_COLUMN_WIDTH, Math.min(1, span / count))
}

function columnWidthText(n, usableWidth, overflowing) {
  return columnWidth(n, usableWidth, overflowing).toFixed(3)
}

// Wraps at both ends of [min, max] rather than running off to 1.
function cycleNext(current, step, minColumns, maxColumns) {
  var b = bounds(minColumns, maxColumns)
  var next = clampColumns(current, b.min, b.max) + Math.round(Number(step) || 0)
  if (next > b.max) return b.min
  if (next < b.min) return b.max
  return next
}

// A workspace with no entry follows the default and keeps following it if the
// default later changes; one with an entry is pinned to that number.
function isPinned(map, id) {
  if (!map || Number(id) < 0) return false
  return map[String(id)] !== undefined
}

function storedColumns(map, id, fallback, minColumns, maxColumns) {
  var b = bounds(minColumns, maxColumns)
  var safeFallback = clampColumns(fallback, b.min, b.max)
  if (Number(id) < 0 || !map) return safeFallback
  var value = map[String(id)]
  if (value === undefined || value === null) return safeFallback
  var n = Number(value)
  if (!(n >= 1)) return safeFallback
  return clampColumns(n, b.min, b.max)
}

function withWorkspace(map, id, n) {
  var next = {}
  var source = map || {}
  for (var key in source) next[key] = source[key]
  next[String(id)] = n
  return next
}

function withoutWorkspace(map, id) {
  var next = {}
  var source = map || {}
  var drop = String(id)
  for (var key in source) {
    if (key !== drop) next[key] = source[key]
  }
  return next
}

// The probe reports layout and column count from one sample. Both are read
// together on purpose: dwindle reports a different count for the same windows,
// so acting on a fresh layout with a stale count misreads the workspace.
function parseProbe(text) {
  var parsed = null
  try {
    parsed = JSON.parse(String(text || ""))
  } catch (e) {
    return null
  }
  if (!parsed || typeof parsed !== "object") return null
  return {
    layout: String(parsed.layout || ""),
    columns: Number(parsed.columns) || 0
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    HARD_MAX_COLUMNS: HARD_MAX_COLUMNS,
    MIN_COLUMN_WIDTH: MIN_COLUMN_WIDTH,
    bounds: bounds,
    clampColumns: clampColumns,
    columnWidth: columnWidth,
    columnWidthText: columnWidthText,
    cycleNext: cycleNext,
    isPinned: isPinned,
    parseProbe: parseProbe,
    storedColumns: storedColumns,
    withWorkspace: withWorkspace,
    withoutWorkspace: withoutWorkspace
  }
}
