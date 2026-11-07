-- Lane B spec: display renderers, card lines, result formats.
-- Pure: every case passes an explicit RenderCtx (Helpers.rctx) and hand-built
-- normalized components, so nothing here depends on schema.lua or maki.ui.
local Helpers = require("genui.tests.helpers")
local Render = require("genui.render")
local Display = require("genui.widgets.display")
local Result = require("genui.result")

local function text(lines)
  return Helpers.text(lines)
end

local function plain(lines)
  return Helpers.plain(lines)
end

-- One of every P0/P1 display component (normalized shape, explicit ids).
local function display_tree()
  return {
    type = "stack",
    id = "root",
    children = {
      {
        type = "section",
        id = "sec",
        title = "Coverage by module",
        children = {
          {
            type = "bars",
            id = "bars",
            unit = "%",
            max = 100,
            items = { { label = "core", value = 91 }, { label = "net", value = 42 } },
          },
        },
      },
      {
        type = "kv",
        id = "kv",
        items = { { key = "Branch", value = "main" }, { key = "Commit", value = "a1b2c3d  fix: wrap spans" } },
      },
      {
        type = "table",
        id = "tbl",
        columns = { "file", "line", "text" },
        rows = { { "src/a.rs", 12, "let x = foo(" }, { "src/b.rs", 40, "foo(bar)" }, { "src/c.rs", 7, "x" } },
        max_rows = 2,
      },
      { type = "progress", id = "p1", label = "tests", value = { done = 280, total = 700 } },
      { type = "progress", id = "p2", label = "build", value = 1, status = "done" },
      { type = "divider", id = "div", label = "diff" },
      {
        type = "diff",
        id = "diff",
        text = "--- a/x.rs\n+++ b/x.rs\n@@ -10,4 +10,5 @@ fn main()\n let x = 1;\n-let y = foo(x);\n+let y = foo(x, 2);\n+let z = 3;\n ok\n@@ -30,2 +31,2 @@\n a\n-b\n+c",
      },
      { type = "sparkline", id = "spark", label = "latency", values = { 1, 5, 3, 8, 2, 9, 4 } },
      { type = "text", id = "txt", text = "Hello **world** 日本語テキスト and a 🎉 party", tone = "info" },
      { type = "badge", id = "badge", text = "beta", tone = "warning" },
      { type = "checklist", id = "cl", items = { { text = "a", done = true }, { text = "b" } } },
      { type = "unknown", id = "unk", original = "slider" },
      {
        type = "row",
        id = "row",
        children = {
          { type = "kv", id = "kv2", items = { b = 2, a = 1 } },
          { type = "badge", id = "badge2", text = "x" },
        },
      },
    },
  }
end

-- design.md §1 scenario 1 as a normalized spec (what Schema.validate yields).
local function form_spec()
  return {
    title = "Deploy",
    id = "w1",
    mode = "interactive",
    warnings = {},
    root = {
      type = "stack",
      id = "c1",
      _auto_id = true,
      children = {
        {
          type = "choice",
          id = "env",
          label = "Environment",
          options = {
            { value = "staging", label = "staging (Recommended)" },
            { value = "prod", label = "prod", description = "needs approval" },
          },
        },
        { type = "confirm", id = "migrate", label = "Run migrations?" },
        { type = "input", id = "tag", label = "Release tag", pattern = "^v\\d+" },
        { type = "actions", id = "acts", items = { { action = "deploy", label = "Deploy" } } },
      },
    },
  }
end

return function(h)
  -- Width discipline ---------------------------------------------------------------

  h.case("every display renderer fits 40/80/120", function()
    for _, w in ipairs({ 40, 80, 120 }) do
      local lines = Render.component(display_tree(), Helpers.rctx(w))
      h.ok(#lines > 20, "renders many lines at " .. w)
      for i, line in ipairs(lines) do
        local lw = Helpers.line_width(line)
        h.ok(lw <= w, "line " .. i .. " at width " .. w .. " is " .. lw .. ": " .. Helpers.line_text(line))
      end
    end
  end)

  h.case("fit cuts by display cells with an ellipsis (CJK/emoji)", function()
    local r = Helpers.rctx(80)
    h.eq(Render.fit("hello", 10, r), "hello")
    h.eq(Render.fit("hello world", 8, r), "hello w…")
    h.eq(Render.fit("日本語テキスト", 7, r), "日本語…")
    h.eq(Render.fit("ab", 1, r), "…")
    h.eq(Render.fit("ab", 0, r), "")
    h.eq(Helpers.display_width(Render.fit("🎉🎉🎉", 5, r)), 5)
  end)

  h.case("wrap_text wraps words and hard-cuts long ones", function()
    local r = Helpers.rctx(80)
    h.deep_eq(Render.wrap_text("the quick brown fox", 9, r), { "the quick", "brown fox" })
    h.deep_eq(Render.wrap_text("abcdefghij", 4, r), { "abcd", "efgh", "ij" })
    h.deep_eq(Render.wrap_text("a\n\nb", 10, r), { "a", "", "b" })
  end)

  h.case("pad fills to width and clamps overflow", function()
    local r = Helpers.rctx(80)
    local padded = Render.pad({ { "ab", "bold" } }, 5, "dim", r)
    h.eq(Helpers.line_text(padded), "ab   ")
    h.eq(padded[2][2], "dim")
    h.eq(Helpers.line_text(Render.pad({ { "abcdefgh", "" } }, 5, nil, r)), "abcd…")
  end)

  -- Containers ---------------------------------------------------------------------

  h.case("section collapsed/expanded via rows map", function()
    local comp = {
      type = "section",
      id = "s",
      title = "Details",
      children = { { type = "text", id = "t", text = "line one\nline two", markdown = false } },
    }
    local lines, rows = Render.component(comp, Helpers.rctx(80))
    h.eq(#lines, 3, "expanded by default")
    h.has(Helpers.line_text(lines[1]), "▾ Details")
    h.eq(rows[1], "sec:s")
    local toggled = { ["sec:s"] = true }
    lines, rows = Render.component(comp, Helpers.rctx(80, { expanded = toggled }))
    h.eq(#lines, 1, "collapsed after toggle")
    h.has(Helpers.line_text(lines[1]), "▸ Details (2 lines)")
    h.eq(rows[1], "sec:s")
    comp.collapsed = true
    lines = Render.component(comp, Helpers.rctx(80))
    h.eq(#lines, 1, "collapsed prop honoured")
    lines = Render.component(comp, Helpers.rctx(80, { expanded = toggled }))
    h.eq(#lines, 3, "collapsed prop + toggle = open")
    lines, rows = Render.component(comp, Helpers.rctx(80, { mode = "window" }))
    h.eq(#lines, 3, "window mode always open")
    h.eq(rows[1], nil, "no click rows in window mode")
  end)

  h.case("stack skips hidden children and keeps row offsets", function()
    local comp = {
      type = "stack",
      id = "st",
      children = {
        { type = "text", id = "a", text = "top", markdown = false },
        { type = "text", id = "h", text = "hidden", hidden = true },
        { type = "section", id = "s", title = "S", children = { { type = "text", id = "b", text = "in" } } },
      },
    }
    local lines, rows = Render.component(comp, Helpers.rctx(80))
    h.not_has(text(lines), "hidden")
    local row = Helpers.find_row(lines, "▾ S")
    h.eq(rows[row], "sec:s")
  end)

  h.case("row lays two children side by side and stacks when narrow", function()
    local comp = {
      type = "row",
      id = "r",
      children = {
        { type = "text", id = "a", text = "left", markdown = false },
        { type = "text", id = "b", text = "right", markdown = false },
      },
    }
    local lines = Render.component(comp, Helpers.rctx(80))
    h.eq(#lines, 1)
    h.has(Helpers.line_text(lines[1]), "left")
    h.has(Helpers.line_text(lines[1]), "right")
    lines = Render.component(comp, Helpers.rctx(30))
    h.eq(#lines, 2, "narrow row becomes a stack")
  end)

  -- Leaves ---------------------------------------------------------------------------

  h.case("kv object form sorted by key, key column aligned", function()
    local lines =
      Render.component({ type = "kv", id = "k", items = { zeta = 1, alpha = "x", mid = true } }, Helpers.rctx(80))
    local p = plain(lines)
    h.eq(#p, 3)
    h.has(p[1], "alpha")
    h.has(p[2], "mid")
    h.has(p[3], "zeta")
    h.eq(p[1], "  alpha  x")
    h.eq(p[3], "  zeta   1")
    h.eq(Helpers.style_of(lines, "alpha"), Render.STYLES.label)
  end)

  h.case("kv array form keeps order and handles multi-line values", function()
    local lines = Render.component(
      { type = "kv", id = "k", items = { { key = "b", value = "1\n2" }, { key = "a", value = maki and maki.NIL } } },
      Helpers.rctx(80)
    )
    local p = plain(lines)
    h.eq(p[1], "  b  1")
    h.eq(p[2], "     2")
    h.has(p[3], "a")
  end)

  h.case("table honours max_rows with '▼ n more' and right-aligns numbers", function()
    local comp = display_tree().children[3]
    local lines, rows = Render.component(comp, Helpers.rctx(80))
    local p = plain(lines)
    h.eq(#p, 4, "header + 2 rows + more")
    h.has(p[4], "▼ 1 more")
    h.eq(rows[4], "tbl:tbl")
    h.has(p[2], "  12  ")
    h.has(p[3], "  40  ")
    -- numeric column right-aligned: "12" and "40" end at the same column
    local c2 = p[2]:find("12", 1, true)
    local c3 = p[3]:find("40", 1, true)
    h.eq(c2, c3, "right-aligned numbers")
    h.eq(p[1]:sub(1, 2), "  ")
    h.has(p[1], "file")
    lines = Render.component(comp, Helpers.rctx(80, { expanded = { ["tbl:tbl"] = true } }))
    p = plain(lines)
    h.eq(#p, 5, "expanded: header + 3 rows + collapse hint")
    h.has(p[5], "▲")
  end)

  h.case("table shows selection markers from values and shrinks to width", function()
    local comp = {
      type = "table",
      id = "hits",
      select = "multi",
      key = "file",
      columns = { { key = "file", label = "File" }, { key = "text", label = "Text" } },
      rows = {
        { file = "src/a.rs", text = string.rep("long text ", 20) },
        { file = "src/b.rs", text = "short" },
      },
    }
    local lines = Render.component(comp, Helpers.rctx(40, { values = { hits = { "src/b.rs" } } }))
    local p = plain(lines)
    h.has(p[2], "[ ] src/a.rs")
    h.has(p[3], "[x] src/b.rs")
    h.has(p[2], "…")
    for _, l in ipairs(lines) do
      h.ok(Helpers.line_width(l) <= 40, "fits 40: " .. Helpers.line_text(l))
    end
    local layout = Display.table_layout(comp, 60, Helpers.rctx(80))
    h.eq(#layout.cols, 2)
    h.eq(layout.cols[1].align, "left")
    h.ok(layout.width <= 60, "layout width " .. layout.width)
    h.eq(Display.row_key(comp, layout, 2), "src/b.rs")
  end)

  h.case("bars scale to max with eighth blocks", function()
    local r = Helpers.rctx(40)
    local comp =
      { type = "bars", id = "b", items = { { label = "a", value = 50 }, { label = "b", value = 100 } }, max = 100 }
    local p = plain(Render.component(comp, r))
    local full_b = select(2, p[2]:gsub("█", ""))
    local full_a = select(2, p[1]:gsub("█", ""))
    h.ok(full_b > 0, "bar b has blocks")
    h.eq(full_a * 2, full_b, "50% is half of 100%")
    h.has(p[1], "50")
    h.has(p[2], "100")
    -- explicit max above the data keeps every bar short of full
    comp.max = 200
    p = plain(Render.component(comp, r))
    h.eq(select(2, p[2]:gsub("█", "")), full_b / 2, "max=200 halves the 100 bar")
    -- negative / NaN / missing values never raise and render an empty bar
    comp.items = { { label = "neg", value = -5 }, { label = "nan", value = 0 / 0 }, { label = "none" } }
    comp.max = nil
    p = plain(Render.component(comp, r))
    h.eq(#p, 3)
    h.not_has(p[1], "█")
  end)

  h.case("sparkline uses 8 levels and cuts from the left", function()
    local vals = {}
    for i = 1, 100 do
      vals[i] = i
    end
    local comp = { type = "sparkline", id = "s", values = vals }
    local lines = Render.component(comp, Helpers.rctx(40))
    local t = Helpers.line_text(lines[1])
    h.ok(Helpers.display_width(t) <= 40)
    h.has(t, "█", "latest (max) value survives the cut")
    h.not_has(t, "▁", "earliest (min) values cut away")
    lines = Render.component({ type = "sparkline", id = "s", values = { 1, 2, 3, 4, 5, 6, 7, 8 } }, Helpers.rctx(80))
    t = Helpers.line_text(lines[1])
    for _, g in ipairs({ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }) do
      h.has(t, g, "level glyph")
    end
    lines = Render.component({ type = "sparkline", id = "s", values = { 3, 3, 3 } }, Helpers.rctx(80))
    h.has(Helpers.line_text(lines[1]), "▄▄▄", "flat series sits mid-level")
  end)

  h.case("progress renders both value forms; spinner only while running", function()
    local r = Helpers.rctx(80)
    local lines = Render.component({ type = "progress", id = "p", label = "tests", value = 0.4 }, r)
    local t = Helpers.line_text(lines[1])
    h.has(t, "tests")
    h.has(t, " 40%")
    h.has(t, "█")
    h.has(t, "░")
    h.ok(tostring(lines[1][2][2]):find("spinner:", 1, true), "running has a spinner: styled glyph")
    lines = Render.component({ type = "progress", id = "p", value = { done = 280, total = 700 }, status = "done" }, r)
    t = Helpers.line_text(lines[1])
    h.has(t, "(280/700)")
    h.has(t, " 40%")
    h.has(t, "✓")
    h.ok(not text(lines):find("⠋", 1, true), "done has no spinner glyph")
    for _, sp in ipairs(lines[1]) do
      h.ok(not tostring(sp[2]):find("spinner:", 1, true), "done has no spinner style")
    end
    lines = Render.component({ type = "progress", id = "p", value = 7, status = "error" }, r)
    t = Helpers.line_text(lines[1])
    h.has(t, "100%", "values above 1 clamp")
    h.has(t, "✗")
    lines = Render.component({ type = "progress", id = "p", value = { done = 0, total = 0 } }, r)
    h.has(Helpers.line_text(lines[1]), "  0%")
  end)

  h.case("divider centres its label and spans the width", function()
    local lines = Render.component({ type = "divider", id = "d", label = "diff" }, Helpers.rctx(40))
    local t = Helpers.line_text(lines[1])
    h.eq(Helpers.display_width(t), 40)
    h.has(t, "─ diff ─")
    lines = Render.component({ type = "divider", id = "d" }, Helpers.rctx(20))
    h.eq(Helpers.line_text(lines[1]), string.rep("─", 20))
  end)

  h.case("text honours tone, markdown=false wrapping and the 400-line cap", function()
    local lines = Render.component({ type = "text", id = "t", text = "warn here", tone = "warning" }, Helpers.rctx(80))
    h.eq(Helpers.style_of(lines, "warn here"), "warning")
    lines =
      Render.component({ type = "text", id = "t", text = string.rep("word ", 30), markdown = false }, Helpers.rctx(40))
    h.ok(#lines >= 4, "wrapped into several lines")
    local big = {}
    for i = 1, 450 do
      big[i] = "l" .. i
    end
    lines =
      Render.component({ type = "text", id = "t", text = table.concat(big, "\n"), markdown = false }, Helpers.rctx(80))
    h.eq(#lines, 401)
    h.has(Helpers.line_text(lines[401]), "+50 lines")
    lines = Render.component({ type = "text", id = "t", text = "" }, Helpers.rctx(80))
    h.eq(#lines, 0, "empty text renders nothing")
  end)

  h.case("badge, checklist and unknown render one line each", function()
    local r = Helpers.rctx(80)
    h.has(text(Render.component({ type = "badge", id = "b", text = "beta", tone = "success" }, r)), "● beta")
    local p = plain(
      Render.component({ type = "checklist", id = "c", items = { { text = "a", done = true }, { text = "b" } } }, r)
    )
    h.eq(p[1], "  [✓] a")
    h.eq(p[2], "  [ ] b")
    local lines = Render.component({ type = "unknown", id = "u", original = "slider" }, r)
    h.has(Helpers.line_text(lines[1]), "⚠ unknown component slider")
    h.eq(Helpers.style_of(lines, "unknown"), "warning")
  end)

  -- Diff -------------------------------------------------------------------------------

  h.case("parse_diff handles 2 hunks with correct old/new numbers", function()
    local parsed = Display.parse_diff(display_tree().children[7].text)
    h.eq(#parsed.hunks, 2)
    h.eq(parsed.path, "x.rs")
    local h1 = parsed.hunks[1]
    h.eq(h1.old_start, 10)
    h.eq(h1.new_start, 10)
    h.eq(h1.context, "fn main()")
    h.eq(#h1.lines, 5)
    h.deep_eq(h1.lines[1], { kind = " ", text = "let x = 1;", old_nr = 10, new_nr = 10 })
    h.deep_eq(h1.lines[2], { kind = "-", text = "let y = foo(x);", old_nr = 11 })
    h.deep_eq(h1.lines[3], { kind = "+", text = "let y = foo(x, 2);", new_nr = 11 })
    h.deep_eq(h1.lines[4], { kind = "+", text = "let z = 3;", new_nr = 12 })
    h.deep_eq(h1.lines[5], { kind = " ", text = "ok", old_nr = 12, new_nr = 13 })
    local h2 = parsed.hunks[2]
    h.eq(h2.old_start, 30)
    h.eq(h2.new_start, 31)
    h.deep_eq(h2.lines[2], { kind = "-", text = "b", old_nr = 31 })
    h.deep_eq(h2.lines[3], { kind = "+", text = "c", new_nr = 32 })
    h.eq(#Display.parse_diff("").hunks, 0)
    h.eq(#Display.parse_diff(nil).hunks, 0)
    h.eq(#Display.parse_diff("-a\n+b").hunks, 1, "bare +/- listing becomes one hunk")
  end)

  h.case("line_diff yields -b/+c and a parseable hunk", function()
    local d = Display.line_diff("a\nb", "a\nc")
    h.has(d, "@@ -1,2 +1,2 @@")
    h.has(d, "\n a\n")
    h.has(d, "\n-b\n")
    h.has(d, "\n+c")
    h.eq(Display.line_diff("same", "same"), "@@ -1,1 +1,1 @@\n same")
    h.eq(Display.line_diff("", ""), "")
    local parsed = Display.parse_diff(d)
    h.eq(parsed.hunks[1].lines[2].old_nr, 2)
    h.eq(parsed.hunks[1].lines[3].new_nr, 2)
  end)

  h.case("diff card: styles, decisions, hunk collapse rows, max_lines", function()
    local comp = display_tree().children[7]
    comp.decide = true
    local lines, rows = Render.component(comp, Helpers.rctx(80, { values = { diff = { ["1"] = "accept" } } }))
    local p = plain(lines)
    h.has(p[1], "x.rs")
    h.has(p[2], "▾ @@ -10,4 +10,5 @@ fn main()")
    h.has(p[2], "[accept]")
    h.eq(rows[2], "hunk:diff:1")
    h.eq(Helpers.style_of(lines, "let y = foo(x);"), Render.STYLES.diff_old)
    h.eq(Helpers.style_of(lines, "let y = foo(x, 2);"), Render.STYLES.diff_new)
    h.has(p[4], "11     - let y = foo(x);")
    h.has(p[5], "    11 + let y = foo(x, 2);")
    local hdr2 = Helpers.find_row(lines, "@@ -30,2")
    h.has(p[hdr2], "[ ? ]")
    h.eq(rows[hdr2], "hunk:diff:2")
    lines = Render.component(comp, Helpers.rctx(80, { expanded = { ["hunk:diff:1"] = true } }))
    p = plain(lines)
    h.has(p[2], "▸ @@ -10,4")
    h.has(p[2], "(−1 +2)")
    h.has(p[3], "▾ @@ -30,2", "second hunk still open")
    comp.max_lines = 3
    lines = Render.component(comp, Helpers.rctx(80))
    h.has(text(lines), "… (+5 lines)")
    lines = Render.component({ type = "diff", id = "d", before = "a\nb", after = "a\nc" }, Helpers.rctx(80))
    h.has(text(lines), "- b")
    h.has(text(lines), "+ c")
    lines = Render.component({ type = "diff", id = "d", text = "" }, Helpers.rctx(80))
    h.has(text(lines), "(empty diff)")
  end)

  -- Inputs in the card -----------------------------------------------------------------

  h.case("inputs render submitted values in card mode, placeholders in window mode", function()
    local spec = form_spec()
    local values = { env = "staging", migrate = true, tag = "v1.4" }
    local lines = Render.component(spec.root, Helpers.rctx(80, { values = values }))
    local p = plain(lines)
    h.eq(p[1], "  Environment  ✓ staging (Recommended)", "option value mapped to its label")
    h.eq(p[2], "  Run migrations?  ✓ Yes")
    h.eq(p[3], "  Release tag  ✓ v1.4")
    h.eq(#p, 3, "actions row is not repeated in the card")
    lines = Render.component(spec.root, Helpers.rctx(80))
    h.has(Helpers.line_text(lines[1]), "(no answer)")
    lines = Render.component(spec.root, Helpers.rctx(80, { mode = "window" }))
    h.has(text(lines), "[choice] Environment")
    h.has(text(lines), "[ Deploy ]")
    local multi = { type = "choice", id = "m", label = "Pick", multi = true, options = { "a", "b", "c" } }
    p = plain(Render.component(multi, Helpers.rctx(80, { values = { m = { "a", "typed other" } } })))
    h.eq(p[1], "  Pick")
    h.eq(p[2], "    ✓ a")
    h.eq(p[3], "    ✓ typed other")
  end)

  -- Robustness ---------------------------------------------------------------------------

  h.case("never raises on garbage components", function()
    local r = Helpers.rctx(80)
    local garbage = {
      { type = "table", id = "t" },
      { type = "table", id = "t", columns = "nope", rows = 5 },
      { type = "kv", id = "k", items = "str" },
      { type = "bars", id = "b", items = { 1, "x", {} } },
      { type = "sparkline", id = "s", values = { "a", {} } },
      { type = "progress", id = "p", value = "lots" },
      { type = "progress", id = "p", value = { done = -3, total = -1 } },
      { type = "diff", id = "d" },
      { type = "section", id = "s", children = "no" },
      { type = "text", id = "t", text = { nested = true } },
      { type = "text", id = "t", text = string.rep("x", 5000) },
      { type = "text", id = "t", text = "\xff\xfe bad utf8 \xc3" },
      { type = "choice", id = "c", options = nil },
      { type = "kv", id = "k", items = { { key = "n", value = maki and maki.NIL } } },
      { type = 42 },
      {},
      { type = "stack", id = "s", children = { "string child", 7, { type = "divider" } } },
    }
    for i, comp in ipairs(garbage) do
      local ok, lines = pcall(Render.component, comp, r)
      h.ok(ok, "component " .. i .. " raised: " .. tostring(lines))
      for _, line in ipairs(lines) do
        h.ok(Helpers.line_width(line) <= 80, "garbage " .. i .. " overflows")
      end
    end
    local ok = pcall(Render.component, "not a table", r)
    h.ok(ok)
    local lines = Render.component({ type = "kv", id = "k", items = { { key = "n", value = maki and maki.NIL } } }, r)
    h.has(text(lines), "null")
  end)

  h.case("renderer error becomes a visible error line", function()
    local saved = Display.renderers.badge
    Display.renderers.badge = function()
      error("boom")
    end
    local ok, lines = pcall(Render.component, { type = "badge", id = "b", text = "x" }, Helpers.rctx(80))
    Display.renderers.badge = saved
    h.ok(ok)
    h.has(text(lines), "render error in badge")
    h.eq(Helpers.style_of(lines, "render error"), Render.STYLES.error)
  end)

  -- Card lines ----------------------------------------------------------------------------

  h.case("card_lines: title, status line, root, warnings; rows shifted", function()
    local spec = form_spec()
    spec.root.children[1] = {
      type = "section",
      id = "s",
      title = "Sec",
      children = { { type = "text", id = "t", text = "x", markdown = false } },
    }
    local st = { status = "submitted", action = "deploy", values = { migrate = false }, warnings = { "w1" } }
    local lines, rows = Render.card_lines(spec, st, Helpers.rctx(80))
    local p = plain(lines)
    h.eq(p[1], "Deploy")
    h.eq(p[2], "✓ deploy")
    h.eq(p[3], "▾ Sec")
    h.eq(rows[3], "sec:s")
    h.eq(p[4], "  x")
    h.eq(p[5], "", "blank line after an open section")
    h.eq(p[6], "  Run migrations?  ✓ No", "false renders as No, not (no answer)")
    h.eq(p[7], "  Release tag  (no answer)")
    h.eq(p[#p], "⚠ w1")
    p = plain(Render.card_lines(spec, { status = "cancelled" }, Helpers.rctx(80)))
    h.has(p[2], "Cancelled")
    p = plain(Render.card_lines(spec, { status = "unavailable" }, Helpers.rctx(80)))
    h.has(p[2], "No interactive UI")
    p = plain(Render.card_lines({}, nil, Helpers.rctx(80)))
    h.has(p[1], "empty spec")
  end)

  -- to_markdown ----------------------------------------------------------------------------

  h.case("to_markdown of the form fixture lists labels and options", function()
    local md = Render.to_markdown(form_spec())
    h.has(md, "# Deploy")
    h.has(md, "**Environment**")
    h.has(md, "- staging (Recommended)")
    h.has(md, "- prod — needs approval")
    h.has(md, "**Run migrations?** (yes/no)")
    h.has(md, "**Release tag** (text)")
    h.has(md, "[Deploy]")
    local okf, raw = pcall(Helpers.fixture, "form")
    if okf and type(raw) == "table" then
      local md2 = Render.to_markdown(raw)
      h.has(md2, "**Environment**")
      h.has(md2, "staging")
    end
    local md3 = Render.to_markdown({ root = display_tree() })
    h.has(md3, "## Coverage by module")
    h.has(md3, "| file | line | text |")
    h.has(md3, "```diff")
    h.has(md3, "- Branch: main")
    h.eq(Render.to_markdown(nil), "(ui)")
  end)

  -- Result: llm_output ------------------------------------------------------------------------

  h.case("llm_output matches design.md §3.1 byte-for-byte", function()
    local spec = form_spec()
    spec.root.children[#spec.root.children + 1] =
      { type = "table", id = "hits", select = "multi", columns = { "a" }, rows = {} }
    spec.root.children[#spec.root.children + 1] = { type = "diff", id = "d", text = "", decide = true }
    local st = {
      status = "submitted",
      action = "deploy",
      values = {
        env = "staging",
        migrate = true,
        tag = "v1.4",
        hits = { "a.rs:12" },
        d = { ["1"] = "accept", ["2"] = "reject" },
      },
    }
    h.eq(
      Result.llm_output(spec, st),
      '{"status":"submitted","action":"deploy","values":{"env":"staging","migrate":true,"tag":"v1.4","hits":["a.rs:12"],"d":{"1":"accept","2":"reject"}}}'
    )
    h.eq(Result.llm_output(spec, { status = "cancelled" }), '{"status":"cancelled"}')
    h.eq(Result.llm_output({ id = "w3" }, { status = "display", widget = "w3" }), '{"status":"display","widget":"w3"}')
    local live = {
      id = "build",
      root = {
        type = "stack",
        id = "c1",
        _auto_id = true,
        children = { { type = "progress", id = "p", value = 0 }, { type = "text", id = "log", text = "" } },
      },
    }
    h.eq(
      Result.llm_output(live, { status = "live", widget = "build" }),
      '{"status":"live","widget":"build","ids":["p","log"]}'
    )
    h.eq(
      Result.llm_output(spec, { status = "unavailable" }),
      '{"status":"unavailable","reason":"no interactive UI attached"}'
    )
    h.eq(
      Result.llm_output(spec, { status = "cancelled", warnings = { 'children[1]: unknown component "slider"' } }),
      '{"status":"cancelled"}\nwarnings:\n- children[1]: unknown component "slider"'
    )
    h.eq(
      Result.llm_output(spec, { status = "submitted", values = { tag = 'q"\n' } }),
      '{"status":"submitted","values":{"tag":"q\\"\\n"}}'
    )
    h.eq(
      Result.llm_output(spec, { status = "submitted", values = { n = 1.5, m = 3, z = maki and maki.NIL } }),
      '{"status":"submitted","values":{"m":3,"n":1.5,"z":null}}'
    )
  end)

  h.case("llm_output truncates long strings and caps the line at 4096 bytes", function()
    local spec = form_spec()
    local out = Result.llm_output(spec, { status = "submitted", values = { tag = string.rep("x", 1000) } })
    h.has(out, string.rep("x", 500) .. '…"')
    h.not_has(out, string.rep("x", 501))
    local many = {}
    for i = 1, 400 do
      many[i] = "value number " .. i .. " " .. string.rep("y", 40)
    end
    out = Result.llm_output(spec, { status = "submitted", values = { hits = many } })
    h.ok(#out <= 4096, "capped: " .. #out)
    h.has(out, '"status":"submitted"')
    local wide = {}
    for i = 1, 300 do
      wide["k" .. i] = string.rep("z", 400)
    end
    out = Result.llm_output(spec, { status = "submitted", values = wide })
    h.ok(#out <= 4096, "capped with many keys: " .. #out)
    h.has(out, '"truncated":true')
  end)

  h.case("update/close/error outputs", function()
    h.eq(Result.update_output("build", { "p", "log" }), '{"status":"updated","widget":"build","patched":["p","log"]}')
    h.eq(
      Result.update_output("build", {}, { "unknown id x" }),
      '{"status":"updated","widget":"build","patched":[]}\nwarnings:\n- unknown id x'
    )
    h.eq(Result.close_output("build"), '{"status":"closed","widget":"build"}')
    h.eq(Result.error_output({ "a", "b", "c", "d", "e", "f" }), "error: a; b; c; d; e")
    h.eq(Result.error_output({}), "error: unknown error")
    h.eq(Result.error_output("x"), "error: x")
  end)

  h.case("state builder densifies arrays and strips _auto_id", function()
    local spec = form_spec()
    spec.mode = "live"
    local sparse = { "a" }
    sparse[3] = "c"
    local st = Result.state(spec, { status = "live", values = { picks = sparse, fn = print } })
    h.eq(st.v, 1)
    h.eq(st.widget, "w1")
    h.eq(st.status, "live")
    h.deep_eq(st.values.picks, { "a", "c" })
    h.eq(st.values.fn, nil)
    h.eq(st.spec.root._auto_id, nil)
    h.eq(st.spec.root.children[1].id, "env")
    h.eq(Result.state(form_spec(), { status = "cancelled" }).spec, nil, "no spec outside live mode")
  end)

  -- Result: card -----------------------------------------------------------------------------

  h.case("card click replay is idempotent and repaint keeps toggles", function()
    Helpers.with_mock_ui(function(ui)
      local spec = {
        title = "T",
        id = "w",
        mode = "display",
        warnings = {},
        root = {
          type = "stack",
          id = "r",
          children = {
            { type = "section", id = "s", title = "Sec", children = { { type = "text", id = "t", text = "body" } } },
            { type = "kv", id = "k", items = { { key = "a", value = 1 } } },
          },
        },
      }
      local buf, handle = Result.card(spec, { status = "display" }, { width = 80, max_lines = 50, keep = "head" })
      h.ok(buf ~= nil)
      h.eq(type(handle.repaint), "function")
      local function click(row)
        if ui.swapped then
          buf:click(row)
        else
          buf:click({ row = row })
        end
      end
      local function snapshot()
        return table.concat(Helpers.plain(buf:get_lines()), "\n")
      end
      local zero = snapshot()
      h.has(zero, "▾ Sec")
      h.has(zero, "body")
      local sec_row = Helpers.find_row(buf:get_lines(), "▾ Sec")
      click(sec_row)
      local once = snapshot()
      h.has(once, "▸ Sec (1 line)")
      h.not_has(once, "body")
      h.eq(handle.card_state.expanded["sec:s"], true)
      click(sec_row)
      h.eq(snapshot(), zero, "two clicks == zero clicks")
      h.eq(handle.card_state.expanded["sec:s"], false)
      -- a click outside the row map falls through to the view toggle, never raises
      click(0)
      click(999)
      -- repaint with a patched spec keeps the expanded flags
      click(sec_row)
      spec.root.children[2].items[1].value = 2
      handle.repaint(spec, { status = "live" })
      local after = snapshot()
      h.has(after, "▸ Sec")
      h.has(after, "a  2")
    end)
  end)

  h.case("restore prefers the state's embedded spec", function()
    Helpers.with_mock_ui(function()
      local spec = { id = "w", root = { type = "text", id = "t", text = "first frame" } }
      local st = { status = "closed", spec = { id = "w", root = { type = "text", id = "t", text = "last frame" } } }
      local buf = Result.restore(spec, st, { width = 80, max_lines = 10, keep = "head" })
      local shown = table.concat(Helpers.plain(buf:get_lines()), "\n")
      h.has(shown, "last frame")
      h.not_has(shown, "first frame")
    end)
  end)

  h.case("view_opts floors max_lines at 10 and fixes width 80", function()
    local opts = Result.view_opts({
      tool_output_lines = function()
        return { other = 4 }
      end,
    })
    h.eq(opts.width, 80)
    h.eq(opts.max_lines, 10)
    h.eq(opts.keep, "head")
    opts = Result.view_opts({
      tool_output_lines = function()
        return { other = 30 }
      end,
    })
    h.eq(opts.max_lines, 30)
    h.eq(Result.view_opts(nil).max_lines, 10)
  end)
end
