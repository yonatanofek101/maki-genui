-- Lane C: form loop + input widgets (pure state/handle_key/render, plus a mocked Form.open).
local Helpers = require("genui.tests.helpers")
local Form = require("genui.form")
local Schema = require("genui.schema")

local function spec_of(root, extra)
  local spec = { id = "w1", mode = "interactive", warnings = {}, root = root }
  if extra then
    for k, v in pairs(extra) do
      spec[k] = v
    end
  end
  return spec
end

-- Hand-built NormalizedSpec (plan.md §0.2): the design.md §1.1 deploy form.
local function deploy_form()
  return spec_of({
    type = "stack",
    id = "c1",
    children = {
      {
        type = "choice",
        id = "env",
        label = "Environment",
        options = {
          { value = "staging", label = "staging (Recommended)" },
          { value = "prod", label = "prod", description = "needs approval" },
        },
        multi = false,
        other = true,
        required = true,
      },
      { type = "confirm", id = "migrate", label = "Run migrations?", default = false },
      {
        type = "input",
        id = "tag",
        label = "Release tag",
        pattern = "^v\\d+",
        pattern_hint = "v<number>",
        required = false,
        multiline = false,
      },
    },
  }, { title = "Deploy" })
end

local function single(comp)
  return spec_of({ type = "stack", id = "c1", children = { comp } })
end

local function text_of(lines)
  return table.concat(Helpers.plain(lines), "\n")
end

local function press(state, keys)
  return Helpers.press(state, keys)
end

local function render(state, width, height)
  width = width or 80
  return Form._render(state, width, height, Helpers.rctx(width))
end

local function fake_win(events, width)
  local win = { width = width or 80, height = 20, visible = true, closed = false, configs = {}, cursors = {} }
  local i = 0
  function win:recv()
    i = i + 1
    return events[i]
  end
  function win:set_config(cfg)
    self.configs[#self.configs + 1] = cfg
  end
  function win:set_cursor(row)
    self.cursors[#self.cursors + 1] = row
  end
  function win:is_open()
    return not self.closed
  end
  function win:close()
    self.closed = true
  end
  return win
end

-- Runs fn with Form._io swapped for fakes; returns the fake win used.
local function with_fake_io(events, fn)
  local saved = Form._io
  local buf = Helpers.fake_buf()
  local win = fake_win(events)
  Form._io = {
    buf = function()
      return buf
    end,
    open_win = function()
      return win
    end,
    terminal_size = function()
      return { cols = 100, rows = 30 }
    end,
  }
  local ok, err = pcall(fn, win, buf)
  Form._io = saved
  if not ok then
    error(err, 0)
  end
  return win, buf
end

return function(h)
  -- ring ---------------------------------------------------------------------

  h.case("initial_state: deploy form yields 3 input focusables + implicit submit row", function()
    local st = Form._initial_state(deploy_form())
    local inputs = 0
    for _, e in ipairs(st.focusables) do
      if not e.implicit then
        inputs = inputs + 1
      end
    end
    h.eq(inputs, 3, "input focusables")
    h.eq(#st.focusables, 5, "3 inputs + Submit + Cancel")
    h.eq(st.focusables[1].id, "env")
    h.eq(st.focusables[2].id, "migrate")
    h.eq(st.focusables[3].id, "tag")
    h.eq(st.focusables[4].action, "submit")
    h.eq(st.focusables[5].action, "cancel")
    h.eq(st.focus, 1)
    h.eq(st.mode, Form.MODE.NAV)
    h.ok(st.submit_row ~= nil, "implicit submit row present")
  end)

  h.case("initial_state: Schema.validate(fixtures.form) gives the same ring", function()
    local ok, errors, spec = Schema.validate(Helpers.fixture("form"))
    h.ok(ok, "Schema.validate ok: " .. table.concat(errors or {}, "; "))
    local st = Form._initial_state(spec)
    local ids = {}
    for _, e in ipairs(st.focusables) do
      if not e.implicit then
        ids[#ids + 1] = e.id
      end
    end
    h.deep_eq(ids, { "env", "migrate", "tag" })
  end)

  h.case("hidden inputs are skipped; table only with select, diff only with decide", function()
    local st = Form._initial_state(spec_of({
      type = "stack",
      id = "c1",
      children = {
        { type = "confirm", id = "a", label = "A", hidden = true },
        { type = "table", id = "t0", columns = { "k" }, rows = { { "x" } }, select = "none" },
        { type = "table", id = "t1", columns = { "k" }, rows = { { "x" } }, select = "single" },
        { type = "diff", id = "d0", text = "", decide = false },
        { type = "diff", id = "d1", text = "", decide = true },
      },
    }))
    local ids = {}
    for _, e in ipairs(st.focusables) do
      if not e.implicit then
        ids[#ids + 1] = e.id
      end
    end
    h.deep_eq(ids, { "t1", "d1" })
  end)

  h.case("<Tab> cycles and wraps; <S-Tab> reverses", function()
    local st = Form._initial_state(deploy_form())
    st = press(st, { "<Tab>" })
    h.eq(st.focus, 2)
    st = press(st, { "<Tab>", "<Tab>", "<Tab>", "<Tab>" })
    h.eq(st.focus, 1, "wraps after the Cancel button")
    st = press(st, { "<S-Tab>" })
    h.eq(st.focus, 5, "S-Tab from first wraps to Cancel")
    st = press(st, { "<S-Tab>" })
    h.eq(st.focus, 4)
  end)

  h.case("<Down> at the last choice row hops to the next focusable; <Up> at the first hops back", function()
    local st = Form._initial_state(deploy_form())
    st = press(st, { "<Down>", "<Down>" })
    h.eq(st.focus, 1)
    h.eq(st.widgets.env.cursor, 3, "cursor on the 'other' row")
    st = press(st, { "<Down>" })
    h.eq(st.focus, 2, "hopped to confirm")
    st = press(st, { "<Up>" })
    h.eq(st.focus, 1, "confirm <Up> hops back")
  end)

  -- choice -------------------------------------------------------------------

  h.case("choice single: <CR> selects and advances; <Space> selects without advancing", function()
    local st = Form._initial_state(deploy_form())
    st = press(st, { "<Down>", "<CR>" })
    h.eq(Form._values(st).env, "prod")
    h.eq(st.focus, 2)
    st = press(st, { "<S-Tab>", "<Up>", "<Space>" })
    h.eq(Form._values(st).env, "staging")
    h.eq(st.focus, 1)
  end)

  h.case("choice multi: <Space> toggles, value is an array in option order", function()
    local st = Form._initial_state(single({
      type = "choice",
      id = "langs",
      label = "Languages",
      options = { "lua", "rust", "go" },
      multi = true,
      other = false,
    }))
    st = press(st, { "<Space>", "<Down>", "<Down>", "<Space>" })
    h.deep_eq(Form._values(st).langs, { "lua", "go" })
    st = press(st, { "<Space>" })
    h.deep_eq(Form._values(st).langs, { "lua" })
    st = press(st, { "<Up>", "<Up>", "<Space>" })
    h.eq(Form._values(st).langs, nil, "nothing selected -> no value")
    h.eq(st.focus, 1, "multi <Space> never advances")
  end)

  h.case("choice 'other': <CR> enters EDIT, typed text becomes the value, single advances", function()
    local st = Form._initial_state(deploy_form())
    st = press(st, { "<Down>", "<Down>", "<CR>" })
    h.eq(st.mode, Form.MODE.EDIT)
    local r = render(st)
    h.deep_eq(r.footer, Form.FOOTER_EDIT)
    st = press(st, { "c", "a", "n", "a", "r", "y" })
    h.eq(st.mode, Form.MODE.EDIT, "typing stays in EDIT")
    st = press(st, { "<CR>" })
    h.eq(Form._values(st).env, "canary")
    h.eq(st.focus, 2, "single choice advances after the other text")
    h.eq(st.mode, Form.MODE.NAV)
    h.has(text_of(render(st).lines), "canary")
  end)

  h.case("choice 'other': <Esc> leaves EDIT without cancelling the form", function()
    local st = Form._initial_state(deploy_form())
    st = press(st, { "<Down>", "<Down>", "<Space>", "x", "<Esc>" })
    h.eq(st.mode, Form.MODE.NAV)
    h.eq(st.done, nil)
    h.eq(Form._values(st).env, nil)
  end)

  h.case("choice: defaults preselect, render marks cursor, selection and descriptions", function()
    local spec = deploy_form()
    spec.root.children[1].default = "prod"
    local st = Form._initial_state(spec)
    h.eq(Form._values(st).env, "prod")
    local txt = text_of(render(st).lines)
    h.has(txt, "Environment")
    h.has(txt, "▸ ( ) staging (Recommended)")
    h.has(txt, "(•) prod - needs approval")
    h.has(txt, "→ Type your own answer")
    h.has(txt, "[ Submit ]")
    h.has(txt, "[ Cancel ]")
  end)

  -- input --------------------------------------------------------------------

  h.case("input: typing edits, <CR> advances, value is the text", function()
    local st = Form._initial_state(deploy_form())
    st = press(st, { "<Tab>", "<Tab>" })
    h.eq(st.focus, 3)
    h.eq(st.mode, Form.MODE.EDIT, "input is always in text-entry mode while focused")
    st = press(st, { "v", "1", "<CR>" })
    h.eq(Form._values(st).tag, "v1")
    h.eq(st.focus, 4)
    h.eq(st.mode, Form.MODE.NAV)
  end)

  h.case("input: multiline <M-CR> splits, <CR> still advances, <Up>/<Down> move inside then hop", function()
    local st = Form._initial_state(single({ type = "input", id = "notes", label = "Notes", multiline = true }))
    st = press(st, { "a", "<M-CR>", "b" })
    h.eq(Form._values(st).notes, "a\nb")
    st = press(st, { "<Up>" })
    h.eq(st.focus, 1, "<Up> moved inside the text")
    st = press(st, { "<Up>" })
    h.eq(st.focus, 3, "<Up> at the first line hops to the previous focusable (Cancel)")
    st = press(st, { "<Tab>", "<CR>" })
    h.eq(st.focus, 2, "<CR> advances")
  end)

  h.case("input: placeholder shows while empty, paste inserts (newlines flattened for single-line)", function()
    local st = Form._initial_state(single({ type = "input", id = "q", label = "Q", placeholder = "type here" }))
    h.has(text_of(render(st).lines), "type here")
    st = Form._handle_paste(st, "hello\nworld")
    h.eq(Form._values(st).q, "hello world")
    h.not_has(text_of(render(st).lines), "type here")
  end)

  -- number -------------------------------------------------------------------

  h.case("number: <Right>/<Left> step, clamp, typed digits filtered, arrows move", function()
    local st = Form._initial_state(single({
      type = "number",
      id = "replicas",
      label = "Replicas",
      default = 3,
      min = 1,
      max = 10,
      step = 1,
      integer = true,
    }))
    h.eq(Form._values(st).replicas, 3)
    st = press(st, { "<Right>" })
    h.eq(Form._values(st).replicas, 4)
    st = press(st, { "<Up>" })
    h.eq(st.focus, 3, "<Up> wraps to the last focusable, it does not step")
    h.eq(Form._values(st).replicas, 4)
    st = press(st, { "<Right>", "<Right>", "<Right>", "<Right>", "<Right>", "<Right>", "<Right>" })
    h.eq(Form._values(st).replicas, 10, "clamped at max")
    st = press(st, { "<C-u>", "9", "9" })
    h.eq(Form._values(st).replicas, 99)
    h.eq(Form._validate(st).replicas, "must be ≤ 10")
    st = press(st, { "<Left>" })
    h.eq(Form._values(st).replicas, 10, "stepping clamps back into range")
    st = press(st, { "<C-u>", "x", ".", "2" })
    h.eq(Form._values(st).replicas, 2, "letters and '.' (integer) are dropped")
    h.has(text_of(render(st).lines), "(1–10)")
    st = press(st, { "<CR>" })
    h.eq(st.focus, 2, "<CR> advances")
  end)

  h.case("number: '-' starts a negative value when empty, float steps keep decimals", function()
    local st = Form._initial_state(single({ type = "number", id = "n", label = "N", step = 0.5 }))
    st = press(st, { "-", "2" })
    h.eq(Form._values(st).n, -2)
    st = press(st, { "<Right>" })
    h.eq(Form._values(st).n, -1.5)
    st = press(st, { "<Down>" })
    h.eq(Form._values(st).n, -1.5, "<Down> moves focus, it does not step")
    h.eq(Form._validate(st).n, nil)
  end)

  -- confirm ------------------------------------------------------------------

  h.case("confirm: y/n set, <Space> toggles, <CR> advances", function()
    local st = Form._initial_state(single({ type = "confirm", id = "ok", label = "Proceed?", default = false }))
    h.eq(Form._values(st).ok, false)
    st = press(st, { "y" })
    h.eq(Form._values(st).ok, true)
    h.has(text_of(render(st).lines), "[ Yes ]")
    st = press(st, { "n" })
    h.eq(Form._values(st).ok, false)
    h.has(text_of(render(st).lines), "[ No ]")
    st = press(st, { "<Space>" })
    h.eq(Form._values(st).ok, true)
    st = press(st, { "<CR>" })
    h.eq(st.focus, 2)
  end)

  -- table --------------------------------------------------------------------

  h.case("table multi: <Space> toggles rows, value = keys from the key column", function()
    local st = Form._initial_state(single({
      type = "table",
      id = "hits",
      columns = { "file", "line", "text" },
      rows = {
        { file = "src/a.rs", line = 12, text = "let x = foo(" },
        { file = "src/b.rs", line = 40, text = "foo(bar)" },
        { file = "src/c.rs", line = 7, text = "foo()" },
      },
      select = "multi",
      key = "file",
      max_rows = 20,
    }))
    st = press(st, { "<Space>", "<Down>", "<Down>", "<Space>" })
    h.deep_eq(Form._values(st).hits, { "src/a.rs", "src/c.rs" })
    local txt = text_of(render(st).lines)
    h.has(txt, "[x]")
    h.has(txt, "src/b.rs")
    st = press(st, { "<Down>" })
    h.eq(st.focus, 2, "<Down> on the last row hops to Submit")
  end)

  h.case("table single: <CR> picks and advances; default key is the 1-based index; viewport hints", function()
    local rows = {}
    for i = 1, 30 do
      rows[i] = { "row" .. i }
    end
    local st = Form._initial_state(single({
      type = "table",
      id = "t",
      columns = { "name" },
      rows = rows,
      select = "single",
      max_rows = 5,
    }))
    st = press(st, { "<Down>", "<Down>", "<CR>" })
    h.eq(Form._values(st).t, "3")
    h.eq(st.focus, 2)
    st = press(st, { "<S-Tab>" })
    for _ = 1, 10 do
      st = press(st, { "<Down>" })
    end
    local txt = text_of(render(st).lines)
    h.has(txt, "▲")
    h.has(txt, "▼ 17 more")
    h.has(txt, "row13")
  end)

  -- diff ---------------------------------------------------------------------

  h.case("diff decide: a/r set decisions keyed by hunk index; undecided blocks submit", function()
    local st = Form._initial_state(single({ type = "diff", id = "d", text = "", decide = true }))
    -- inject hunks so the test does not depend on Display.parse_diff
    st.widgets.d.hunks = {
      {
        header = "@@ -1,2 +1,2 @@",
        lines = { { kind = "-", text = "a", old_nr = 1 }, { kind = "+", text = "b", new_nr = 1 } },
      },
      { header = "@@ -9,1 +9,1 @@", lines = { { kind = " ", text = "c", old_nr = 9, new_nr = 9 } } },
    }
    st = press(st, { "a", "<Tab>", "<CR>" })
    h.eq(st.done, nil, "undecided hunk blocks submit")
    h.eq(st.focus, 1, "focus moves back to the diff")
    h.has(st.errors.d, "1 undecided")
    h.has(text_of(render(st).lines), "✗")
    st = press(st, { "<Down>", "r" })
    h.deep_eq(Form._values(st).d, { ["1"] = "accept", ["2"] = "reject" })
    st = press(st, { "<Space>" })
    h.eq(Form._values(st).d["2"], nil, "<Space> cycles reject -> undecided")
    st = press(st, { "<Space>", "<Space>", "<Space>" })
    h.eq(Form._values(st).d["2"], nil, "cycle: undecided -> accept -> reject -> undecided")
    st = press(st, { "<CR>" })
    h.eq(Form._values(st).d["2"], "accept", "<CR> accepts + advances")
    h.eq(st.focus, 2)
    st = press(st, { "<CR>" })
    h.eq(st.done and st.done.status, "submitted")
    h.deep_eq(st.done.values.d, { ["1"] = "accept", ["2"] = "accept" })
    local txt =
      text_of(render(Form._initial_state(single({ type = "diff", id = "d", text = "", decide = true }))).lines)
    h.has(txt, "(no hunks)")
  end)

  -- validation / submit ------------------------------------------------------

  h.case("_validate reports required / min_len / pattern errors keyed by id", function()
    local st = Form._initial_state(spec_of({
      type = "stack",
      id = "c1",
      children = {
        { type = "choice", id = "env", label = "Env", options = { "a" }, required = true, other = false },
        { type = "input", id = "name", label = "Name", required = true },
        { type = "input", id = "code", label = "Code", min_len = 3 },
        { type = "input", id = "tag", label = "Tag", pattern = "^v\\d+", pattern_hint = "v<number>" },
      },
    }))
    st.widgets.code.ti:insert_text("ab")
    st.widgets.tag.ti:insert_text("1.0")
    local errors = Form._validate(st)
    h.eq(errors.env, "select an option")
    h.eq(errors.name, "required")
    h.eq(errors.code, "at least 3 characters")
    if Schema.compile_pattern("^v\\d+") then
      h.eq(errors.tag, "v<number>")
    else
      h.eq(errors.tag, nil, "pattern not checkable without maki.json.schema_validator")
    end
  end)

  h.case("_submit: moves focus to the first invalid field, flashes, renders inline errors; never closes", function()
    local st = Form._initial_state(deploy_form())
    st = press(st, { "<Tab>", "<Tab>", "<Tab>", "<CR>" })
    h.eq(st.done, nil)
    h.eq(st.focus, 1, "env is required and first")
    h.eq(st.flash, "fix 1 field")
    local r = render(st)
    local txt = text_of(r.lines)
    h.has(txt, "✗ select an option")
    h.has(txt, "⚠ fix 1 field")
    st = press(st, { "<CR>" })
    h.eq(st.flash, nil, "flash clears on the next key")
    st = press(st, { "<Tab>", "<Tab>", "<CR>" })
    h.eq(st.done and st.done.status, "submitted")
    h.deep_eq(st.done.values, { env = "staging", migrate = false, tag = "" })
    h.eq(st.done.action, "submit")
    h.eq(st.mode, Form.MODE.DONE)
  end)

  h.case("<Esc> cancels; keys after done are ignored", function()
    local st = press(Form._initial_state(deploy_form()), { "<Esc>" })
    h.deep_eq(st.done, { status = "cancelled" })
    st = press(st, { "<Tab>" })
    h.eq(st.focus, 1)
    local st2 = press(Form._initial_state(single({ type = "input", id = "x", label = "X" })), { "a", "<Esc>" })
    h.eq(st2.done and st2.done.status, "cancelled", "<Esc> inside a text input cancels the form")
  end)

  h.case("Cancel button cancels without validating", function()
    local st = press(Form._initial_state(deploy_form()), { "<S-Tab>", "<CR>" })
    h.deep_eq(st.done, { status = "cancelled" })
  end)

  -- actions ------------------------------------------------------------------

  h.case("actions replace the implicit row; each item is a focusable; <CR> submits with its action", function()
    local spec = spec_of({
      type = "stack",
      id = "c1",
      children = {
        { type = "confirm", id = "ok", label = "Ready?", default = true },
        {
          type = "actions",
          id = "acts",
          items = {
            { action = "deploy", label = "Deploy", style = "primary" },
            { action = "dry_run", label = "Dry run" },
            { action = "cancel", label = "Cancel", style = "danger" },
          },
        },
      },
    })
    local st = Form._initial_state(spec)
    h.eq(st.submit_row, nil, "no implicit row with actions")
    h.eq(#st.focusables, 4)
    local txt = text_of(render(st).lines)
    h.has(txt, "[ Deploy ]")
    h.not_has(txt, "[ Submit ]")
    st = press(st, { "<Tab>", "<Right>", "<CR>" })
    h.eq(st.done and st.done.action, "dry_run")
    h.deep_eq(st.done.values, { ok = true })
    h.eq(st.done.values.acts, nil, "actions carry no value")
    local st2 = press(Form._initial_state(spec), { "<S-Tab>", "<CR>" })
    h.eq(st2.done and st2.done.status, "cancelled", "a model-defined action named 'cancel' cancels")
    local st3 = press(Form._initial_state(spec), { "<Tab>", "<Left>" })
    h.eq(st3.focus, 1, "<Left> on the first button moves to the previous focusable")
  end)

  -- render / viewport --------------------------------------------------------

  h.case("_render: focus_row stays within [1, height] for a 40-line form in a 12-row window", function()
    local children = {}
    for i = 1, 20 do
      children[i] = { type = "confirm", id = "c" .. i, label = "Question " .. i }
    end
    local st = Form._initial_state(spec_of({ type = "stack", id = "root", children = children }))
    local full = render(st, 80, nil)
    h.ok(#full.lines >= 40, "unsliced form has >= 40 lines, got " .. #full.lines)
    for i = 1, 25 do
      local r = render(st, 80, 12)
      h.eq(#r.lines, 12, "sliced to the viewport")
      h.ok(r.focus_row >= 1 and r.focus_row <= 12, "focus_row " .. r.focus_row .. " at step " .. i)
      h.has(Helpers.plain(r.lines)[r.focus_row], "▸", "focus row shows the pointer at step " .. i)
      st = press(st, { "<Tab>" })
    end
    st = press(st, { "<PageUp>" })
    local r = render(st, 80, 12)
    h.ok(r.focus_row >= 1 and r.focus_row <= 12)
    h.eq(r.reserved_top, 0)
    h.eq(text_of(r.lines):find("Question 1", 1, true) ~= nil, true)
  end)

  h.case("_render: display components go through Render.component; sections expanded; footers per widget", function()
    local st = Form._initial_state(spec_of({
      type = "stack",
      id = "c1",
      children = {
        { type = "section", id = "s", title = "Context", children = { { type = "text", id = "t", text = "hello" } } },
        { type = "divider", id = "dv" },
        { type = "confirm", id = "ok", label = "Go?" },
      },
    }))
    local r = render(st)
    local txt = text_of(r.lines)
    h.has(txt, "▾ Context")
    h.deep_eq(r.footer, Form.FOOTER_BY_TYPE.confirm)
    st = press(st, { "<Tab>" })
    h.deep_eq(render(st).footer, Form.FOOTER_BY_TYPE.submit_row)
    local lines = render(st, 40).lines
    h.ok(Helpers.max_width(lines) <= 40, "widget lines fit 40 cols, widest " .. Helpers.max_width(lines))
  end)

  -- Form.open (mocked host) --------------------------------------------------

  h.case("Form.open: first recv() == nil -> unavailable, window closed", function()
    local res
    local win = with_fake_io({}, function()
      res = Form.open(deploy_form(), { title = "Deploy" })
    end)
    h.deep_eq(res, { status = "unavailable" })
    h.eq(win.closed, true)
  end)

  h.case("Form.open: scripted keys submit; window repainted, cursor set, closed afterwards", function()
    local events = {
      { type = "resize", width = 60, height = 20 },
      { type = "key", key = "<CR>" }, -- env = staging
      { type = "key", key = "y" }, -- migrate = true
      { type = "key", key = "<Tab>" },
      { type = "paste", text = "v7" },
      { type = "key", key = "<CR>" }, -- to Submit
      { type = "key", key = "<CR>" }, -- press Submit
      { type = "key", key = "<Esc>" }, -- never reached
    }
    local res
    local win, buf = with_fake_io(events, function()
      res = Form.open(deploy_form(), { title = "Deploy" })
    end)
    h.eq(res.status, "submitted")
    h.deep_eq(res.values, { env = "staging", migrate = true, tag = "v7" })
    h.eq(res.action, "submit")
    h.eq(win.closed, true)
    h.ok(#win.configs >= 7, "set_config per frame")
    h.ok(#win.cursors >= 7, "set_cursor per frame")
    h.ok(buf:len() > 0, "buffer holds the last frame")
    h.ok(win.configs[#win.configs].footer ~= nil, "footer hints set")
  end)

  h.case("Form.open: close event -> cancelled; recv nil after events -> cancelled", function()
    local res
    with_fake_io({ { type = "close" } }, function()
      res = Form.open(deploy_form())
    end)
    h.deep_eq(res, { status = "cancelled" })
    with_fake_io({ { type = "key", key = "<Tab>" } }, function()
      res = Form.open(deploy_form())
    end)
    h.deep_eq(res, { status = "cancelled" })
  end)

  h.case("Form.open: a loop error closes the window and re-raises", function()
    local win = fake_win({ { type = "key", key = "<Tab>" } })
    function win:set_lines() end
    function win:set_cursor()
      error("boom")
    end
    local saved = Form._io
    Form._io = {
      buf = function()
        return Helpers.fake_buf()
      end,
      open_win = function()
        return win
      end,
      terminal_size = function()
        return { cols = 80, rows = 24 }
      end,
    }
    local ok, err = pcall(Form.open, deploy_form())
    Form._io = saved
    h.eq(ok, false)
    h.has(tostring(err), "boom")
    h.eq(win.closed, true)
  end)
end
