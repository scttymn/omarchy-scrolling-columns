const test = require("node:test")
const assert = require("node:assert")
const M = require("../Model.js")

test("bounds keeps max above min and honours Hyprland's ceiling", () => {
  assert.deepStrictEqual(M.bounds(2, 6), { min: 2, max: 6 })
  // A max at or below min would make the cycle degenerate.
  assert.deepStrictEqual(M.bounds(4, 4), { min: 4, max: 5 })
  assert.deepStrictEqual(M.bounds(4, 2), { min: 4, max: 5 })
  // column_width clamps at 0.05, so twenty columns is the hard ceiling.
  assert.deepStrictEqual(M.bounds(1, 999), { min: 1, max: 20 })
  assert.deepStrictEqual(M.bounds(0, 6), { min: 1, max: 6 })
})

test("clampColumns floors at minColumns rather than 1", () => {
  assert.strictEqual(M.clampColumns(1, 2, 6), 2)
  assert.strictEqual(M.clampColumns(4, 2, 6), 4)
  assert.strictEqual(M.clampColumns(9, 2, 6), 6)
  // Garbage from a hand-edited state file must not escape the bounds.
  assert.strictEqual(M.clampColumns("nonsense", 2, 6), 2)
  assert.strictEqual(M.clampColumns(null, 2, 6), 2)
  assert.strictEqual(M.clampColumns(-3, 2, 6), 2)
  assert.strictEqual(M.clampColumns(3.4, 2, 6), 3)
})

test("columnWidth is a bare 1/n unless the tape overflows", () => {
  // Hyprland takes gaps out of each column's allotment, so 1/n fits exactly.
  assert.strictEqual(M.columnWidth(3, 0.94, false), 1 / 3)
  assert.strictEqual(M.columnWidth(4, 0.94, false), 0.25)
  // Edge peek only applies while there is a neighbour to reveal.
  assert.strictEqual(M.columnWidth(4, 0.94, true), 0.94 / 4)
  // Never below Hyprland's MIN_COLUMN_WIDTH.
  assert.strictEqual(M.columnWidth(50, 1, false), 0.05)
  // A nonsense span falls back to full width rather than collapsing.
  assert.strictEqual(M.columnWidth(2, 0, true), 0.5)
})

test("columnWidthText renders three decimals for hyprctl", () => {
  assert.strictEqual(M.columnWidthText(3, 1, false), "0.333")
  assert.strictEqual(M.columnWidthText(4, 1, false), "0.250")
  assert.strictEqual(M.columnWidthText(2, 1, false), "0.500")
})

test("cycleNext wraps at both ends of the range", () => {
  assert.strictEqual(M.cycleNext(2, 1, 2, 5), 3)
  assert.strictEqual(M.cycleNext(5, 1, 2, 5), 2, "past max wraps to min")
  assert.strictEqual(M.cycleNext(2, -1, 2, 5), 5, "below min wraps to max")
  // A count left over from a larger maxColumns is clamped before stepping.
  assert.strictEqual(M.cycleNext(9, 1, 2, 5), 2)
})

test("storedColumns falls back for unset or unusable entries", () => {
  const map = { "3": 4, "7": "bad" }
  assert.strictEqual(M.storedColumns(map, 3, 2, 2, 6), 4)
  assert.strictEqual(M.storedColumns(map, 9, 2, 2, 6), 2, "unset follows default")
  assert.strictEqual(M.storedColumns(map, 7, 2, 2, 6), 2, "unparseable follows default")
  assert.strictEqual(M.storedColumns(null, 3, 2, 2, 6), 2)
  assert.strictEqual(M.storedColumns(map, -1, 2, 2, 6), 2, "no workspace yet")
  // A stored value below the floor is raised, not trusted.
  assert.strictEqual(M.storedColumns({ "1": 1 }, 1, 3, 2, 6), 2)
  // An out-of-range default is itself clamped.
  assert.strictEqual(M.storedColumns({}, 1, 99, 2, 6), 6)
})

test("pinning distinguishes an explicit entry from following the default", () => {
  assert.strictEqual(M.isPinned({ "3": 2 }, 3), true)
  assert.strictEqual(M.isPinned({ "3": 2 }, 4), false)
  assert.strictEqual(M.isPinned({}, 3), false)
  assert.strictEqual(M.isPinned(null, 3), false)
})

test("workspace map updates do not mutate the original", () => {
  const map = { "1": 2, "3": 4 }
  const added = M.withWorkspace(map, 5, 3)
  assert.deepStrictEqual(added, { "1": 2, "3": 4, "5": 3 })
  assert.deepStrictEqual(map, { "1": 2, "3": 4 }, "input untouched")

  const removed = M.withoutWorkspace(map, 3)
  assert.deepStrictEqual(removed, { "1": 2 })
  assert.deepStrictEqual(map, { "1": 2, "3": 4 }, "input untouched")

  assert.deepStrictEqual(M.withoutWorkspace(map, 99), map, "removing an absent id is a copy")
  assert.deepStrictEqual(M.withWorkspace(null, 1, 2), { "1": 2 })
})

test("parseProbe reads layout and count together, or nothing", () => {
  assert.deepStrictEqual(
    M.parseProbe('{"layout":"scrolling","columns":4}'),
    { layout: "scrolling", columns: 4 })
  // Dwindle reports a different count for the same windows; both fields have
  // to come from one sample or the transition logic misreads the workspace.
  assert.deepStrictEqual(
    M.parseProbe('{"layout":"dwindle","columns":3}'),
    { layout: "dwindle", columns: 3 })
  assert.strictEqual(M.parseProbe("not json"), null)
  assert.strictEqual(M.parseProbe(""), null)
  assert.strictEqual(M.parseProbe(null), null)
  assert.deepStrictEqual(M.parseProbe("{}"), { layout: "", columns: 0 })
})

test("isPeeking needs slack, not merely an overflowing tape", () => {
  // Overflowing only decides whether usableWidth is allowed to apply; at the
  // default of 1 nothing is held back, so nothing is peeking.
  assert.strictEqual(M.isPeeking(1, true), false)
  assert.strictEqual(M.isPeeking(1.0, true), false)
  assert.strictEqual(M.isPeeking(0.94, true), true)
  // Slack configured but the tape fits: no neighbour to reveal.
  assert.strictEqual(M.isPeeking(0.94, false), false)
  assert.strictEqual(M.isPeeking(1, false), false)
})

test("bounds applies the hard ceiling that the QML properties rely on", () => {
  // The widget derives minColumns/maxColumns from bounds precisely so a
  // configured 500 cannot disagree with what the model will actually clamp to.
  const b = M.bounds(2, 500)
  assert.strictEqual(b.max, M.HARD_MAX_COLUMNS)
  assert.strictEqual(M.clampColumns(500, 2, 500), M.HARD_MAX_COLUMNS)
})
