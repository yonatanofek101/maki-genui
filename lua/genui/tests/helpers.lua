-- Test harness for the genui spec suites.
--
-- Each `lua/genui/tests/*_spec.lua` exports `return function(h) ... end` and
-- receives the harness `h` built by `Helpers.new()` (see `genui.tests.spec`).
-- Unlike `maki.test_helpers`, failures live on the harness instance, so
-- `/genui test` can run many times in one process without accumulating.
--
-- Everything here is pure Lua: no `maki.*` call is needed, so the pure exports
-- (`Render.component`, `Form._handle_key`, ...) can be exercised with an
-- explicit render context (`Helpers.rctx`) and a fake Buf (`Helpers.fake_buf`).

local Examples = require("genui.examples")

local Helpers = {}

-- Harness ------------------------------------------------------------------------

local function describe(v)
  if type(v) == "string" then
    return string.format("%q", v)
  end
  if type(v) ~= "table" then
    return tostring(v)
  end
  local keys = {}
  for k in pairs(v) do
    table.insert(keys, k)
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local parts = {}
  for _, k in ipairs(keys) do
    table.insert(parts, tostring(k) .. "=" .. describe(v[k]))
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

-- Returns nil when equal, else a "path: expected X, got Y" message.
local function deep_diff(actual, expected, path)
  if type(actual) ~= "table" or type(expected) ~= "table" then
    if actual ~= expected then
      return path .. ": expected " .. describe(expected) .. ", got " .. describe(actual)
    end
    return nil
  end
  for k, ev in pairs(expected) do
    local d = deep_diff(actual[k], ev, path .. "." .. tostring(k))
    if d then
      return d
    end
  end
  for k, av in pairs(actual) do
    if expected[k] == nil then
      return path .. "." .. tostring(k) .. ": unexpected " .. describe(av)
    end
  end
  return nil
end

-- Builds an independent harness. Fields: `passed`, `failed`, `failures`
-- (strings), `results` ({name, ok, err} in run order), `prefix` (set by the
-- runner per suite, prepended to case names).
function Helpers.new()
  local h = { passed = 0, failed = 0, failures = {}, results = {}, prefix = "" }

  function h.case(name, fn)
    local full = h.prefix .. name
    local ok, err = pcall(fn)
    if ok then
      h.passed = h.passed + 1
      table.insert(h.results, { name = full, ok = true })
    else
      h.failed = h.failed + 1
      local msg = full .. ": " .. tostring(err)
      table.insert(h.failures, msg)
      table.insert(h.results, { name = full, ok = false, err = tostring(err) })
    end
  end

  function h.eq(actual, expected, msg)
    if actual ~= expected then
      error((msg or "") .. "\nexpected: " .. describe(expected) .. "\n  actual: " .. describe(actual), 2)
    end
  end

  function h.ok(cond, msg)
    if not cond then
      error(msg or "expected truthy value", 2)
    end
  end

  function h.has(s, substr, msg)
    s = tostring(s)
    if not s:find(substr, 1, true) then
      error((msg or "") .. "\nexpected to contain: " .. describe(substr) .. "\n  actual: " .. describe(s), 2)
    end
  end

  function h.not_has(s, substr, msg)
    s = tostring(s)
    if s:find(substr, 1, true) then
      error((msg or "") .. "\nexpected NOT to contain: " .. describe(substr) .. "\n  actual: " .. describe(s), 2)
    end
  end

  function h.deep_eq(actual, expected, msg)
    local d = deep_diff(actual, expected, "value")
    if d then
      error((msg or "") .. "\n" .. d, 2)
    end
  end

  -- Asserts that `fn` raises; the message must contain `substr` when given.
  function h.raises(fn, substr, msg)
    local ok, err = pcall(fn)
    if ok then
      error((msg or "") .. "\nexpected an error", 2)
    end
    if substr and not tostring(err):find(substr, 1, true) then
      error((msg or "") .. "\nexpected error containing: " .. describe(substr) .. "\n  actual: " .. tostring(err), 2)
    end
  end

  function h.report()
    return { passed = h.passed, failed = h.failed, failures = h.failures }
  end

  return h
end

-- Width & markdown fakes ---------------------------------------------------------

local function is_wide(cp)
  return (cp >= 0x1100 and cp <= 0x115F)
    or (cp >= 0x2E80 and cp <= 0xA4CF)
    or (cp >= 0xAC00 and cp <= 0xD7A3)
    or (cp >= 0xF900 and cp <= 0xFAFF)
    or (cp >= 0xFE30 and cp <= 0xFE4F)
    or (cp >= 0xFF00 and cp <= 0xFF60)
    or (cp >= 0xFFE0 and cp <= 0xFFE6)
    or (cp >= 0x1F300 and cp <= 0x1F64F)
    or (cp >= 0x1F900 and cp <= 0x1F9FF)
    or (cp >= 0x20000 and cp <= 0x3FFFD)
end

-- Deterministic stand-in for `maki.ui.display_width`: ASCII and box-drawing
-- glyphs count 1, CJK/emoji count 2, invalid UTF-8 falls back to byte length.
function Helpers.display_width(s)
  s = tostring(s)
  if not utf8.len(s) then
    return #s
  end
  local w = 0
  for _, cp in utf8.codes(s) do
    if cp == 0 or (cp >= 0x300 and cp <= 0x36F) then
      -- NUL and combining marks take no cell
    elseif is_wide(cp) then
      w = w + 2
    else
      w = w + 1
    end
  end
  return w
end

-- Stand-in for `maki.ui.markdown`: one plain styled line per input line, no
-- wrapping or markup parsing (renderers must cut/wrap themselves).
function Helpers.markdown(text, _width)
  local lines = {}
  for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    table.insert(lines, { { line, "" } })
  end
  if #lines == 0 then
    lines = { { { "", "" } } }
  end
  return lines
end

-- RenderCtx (plan.md §2) with the fakes above. `opts` may carry `values`,
-- `expanded` and `mode` ("card"|"window").
function Helpers.rctx(width, opts)
  opts = opts or {}
  return {
    width = width or 80,
    markdown = Helpers.markdown,
    display_width = Helpers.display_width,
    values = opts.values,
    expanded = opts.expanded or {},
    mode = opts.mode or "card",
  }
end

-- StyledLine helpers ---------------------------------------------------------------

-- Plain text of one StyledLine (spans concatenated).
function Helpers.line_text(line)
  local parts = {}
  for _, span in ipairs(line or {}) do
    table.insert(parts, tostring(span[1]))
  end
  return table.concat(parts)
end

-- {StyledLine} -> {string}.
function Helpers.plain(lines)
  local out = {}
  for _, line in ipairs(lines or {}) do
    table.insert(out, Helpers.line_text(line))
  end
  return out
end

-- {StyledLine} -> one string joined by "\n" (handy with h.has).
function Helpers.text(lines)
  return table.concat(Helpers.plain(lines), "\n")
end

-- Display width of a StyledLine.
function Helpers.line_width(line)
  return Helpers.display_width(Helpers.line_text(line))
end

-- Widest line in a {StyledLine} list.
function Helpers.max_width(lines)
  local w = 0
  for _, line in ipairs(lines or {}) do
    w = math.max(w, Helpers.line_width(line))
  end
  return w
end

-- 1-based index of the first line whose text contains `substr`, or nil.
function Helpers.find_row(lines, substr)
  for i, line in ipairs(lines or {}) do
    if Helpers.line_text(line):find(substr, 1, true) then
      return i
    end
  end
  return nil
end

-- Returns the style name of the first span whose text contains `substr`.
function Helpers.style_of(lines, substr)
  for _, line in ipairs(lines or {}) do
    for _, span in ipairs(line) do
      if tostring(span[1]):find(substr, 1, true) then
        return span[2]
      end
    end
  end
  return nil
end

-- Fake Buf -------------------------------------------------------------------------

-- A recording Buf with the subset of `maki.ui.buf()` that result cards and
-- `maki.tool_view` use: `set_lines`/`get_lines`/`on("click"|"change")`, plus
-- test conveniences `lines()` (plain strings), `line(n)`, `len()`, `click(row)`
-- and `emit(event, ev)`. Every method accepts `:` call syntax.
function Helpers.fake_buf()
  local state = { lines = {}, handlers = {}, set_count = 0 }
  local buf = { _state = state }

  function buf:set_lines(new_lines)
    state.lines = new_lines or {}
    state.set_count = state.set_count + 1
    local on_change = state.handlers.change
    if on_change then
      on_change({})
    end
  end

  function buf:get_lines()
    return state.lines
  end

  function buf:lines()
    return Helpers.plain(state.lines)
  end

  function buf:line(n)
    local line = state.lines[n]
    if line == nil then
      return nil
    end
    return Helpers.line_text(line)
  end

  function buf:len()
    return #state.lines
  end

  function buf:on(event, handler)
    state.handlers[event] = handler
  end

  function buf:emit(event, ev)
    local handler = state.handlers[event]
    if handler == nil then
      return nil
    end
    return handler(ev or {})
  end

  -- Accepts a number or the real `Buf:click({ row = n })` shape.
  function buf:click(row)
    if type(row) == "table" then
      row = row.row
    end
    return self:emit("click", { row = row })
  end

  -- Number of `set_lines` calls so far (repaint counting).
  function buf:set_count()
    return state.set_count
  end

  return buf
end

-- Runs `fn(ui)` with `maki.ui.buf`, `maki.ui.markdown` and
-- `maki.ui.display_width` swapped for fakes when that is possible (the fields
-- may be read-only in the real runtime, in which case the swap is skipped and
-- `ui.swapped` is false). `ui.buf` is the single fake Buf every `maki.ui.buf()`
-- call returns, so a card built by `Result.card` can be inspected and clicked.
function Helpers.with_mock_ui(fn)
  local buf = Helpers.fake_buf()
  local ui = { buf = buf, markdown = Helpers.markdown, display_width = Helpers.display_width, swapped = false }

  local g = _G or {}
  local maki_ui = type(g.maki) == "table" and type(g.maki.ui) == "table" and g.maki.ui or nil
  local original = {}
  if maki_ui then
    local swapped = pcall(function()
      original.buf, original.markdown, original.display_width = maki_ui.buf, maki_ui.markdown, maki_ui.display_width
      maki_ui.buf = function()
        return buf
      end
      maki_ui.markdown = Helpers.markdown
      maki_ui.display_width = Helpers.display_width
    end)
    ui.swapped = swapped and maki_ui.buf ~= original.buf
  end

  local ok, err = pcall(fn, ui)

  if maki_ui and ui.swapped then
    pcall(function()
      maki_ui.buf, maki_ui.markdown, maki_ui.display_width = original.buf, original.markdown, original.display_width
    end)
  end
  if not ok then
    error(err, 0)
  end
end

-- Form helpers -----------------------------------------------------------------------

-- Folds `Form._handle_key` over `keys` ("<Tab>", "j", "<CR>", ...).
function Helpers.press(state, keys)
  local Form = require("genui.form")
  for _, key in ipairs(keys) do
    state = Form._handle_key(state, key)
  end
  return state
end

-- Fixtures ---------------------------------------------------------------------------

-- Raw `ui_render` inputs (design.md §1 scenarios 1-4 plus `report`), fresh
-- deep copies of `genui.examples` so a test may mutate them freely.
Helpers.fixtures = setmetatable({}, {
  __index = function(_, name)
    return Examples.get(name)
  end,
})

-- Same as `Helpers.fixtures[name]`, explicit form.
function Helpers.fixture(name)
  local spec = Examples.get(name)
  if spec == nil then
    error("unknown fixture " .. tostring(name))
  end
  return spec
end

-- Names of every example, for "fixtures cover all P0 components" style loops.
function Helpers.fixture_names()
  return Examples.list()
end

return Helpers
