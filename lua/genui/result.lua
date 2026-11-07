-- Result side of a ui_render call: the compact JSON the model reads, the
-- transcript card (ToolView + click map) and the restore/live helpers.
--
-- The JSON line is assembled by hand so key order is deterministic
-- (design.md §3.1 formats are byte-for-byte): status, action, values / widget,
-- ids / reason. Values are ordered by the spec's input order, unknown keys
-- sorted after them.
local Render = require("genui.render")
local Display = require("genui.widgets.display")

local Result = {}

Result.MAX_STRING = 500
Result.MAX_BYTES = 4096
Result.MAX_WARNINGS = 10
Result.MAX_ERRORS = 5
Result.CARD_WIDTH = Render.CARD_WIDTH
Result.MIN_CARD_LINES = 10
Result.UNAVAILABLE_REASON = "no interactive UI attached"

local is_null = Display.is_null
local ELLIPSIS = "…"

---------------------------------------------------------------------------
-- Deterministic JSON
---------------------------------------------------------------------------

local ESCAPES =
  { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function json_str(s)
  s = tostring(s)
  -- Explicit byte ranges: `%c` is locale-dependent and may match C1 bytes
  -- inside UTF-8 sequences (the ellipsis, for one).
  local out = s:gsub('[%z\1-\31\127"\\]', function(c)
    return ESCAPES[c] or string.format("\\u%04x", c:byte())
  end)
  return '"' .. out .. '"'
end

local function json_num(n)
  if n ~= n or n == math.huge or n == -math.huge then
    return "null"
  end
  if n == math.floor(n) and math.abs(n) < 1e15 then
    return string.format("%d", n)
  end
  return string.format("%.14g", n)
end

-- Cut a string to `n` characters (codepoints), appending "…" when cut.
local function cut_str(s, n)
  local len = utf8.len(s)
  if not len then
    if #s <= n then
      return s
    end
    return s:sub(1, n) .. ELLIPSIS
  end
  if len <= n then
    return s
  end
  local byte_end = utf8.offset(s, n + 1)
  if not byte_end then
    return s
  end
  return s:sub(1, byte_end - 1) .. ELLIPSIS
end
Result._cut_str = cut_str

local function is_array(t)
  if t[1] == nil then
    return next(t) == nil
  end
  local n = 0
  for k, _ in pairs(t) do
    if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
      return false
    end
    n = n + 1
  end
  return n == #t
end

local function sorted_keys(t)
  local keys = {}
  for k, _ in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then
      return na < nb
    end
    return tostring(a) < tostring(b)
  end)
  return keys
end

local encode

-- limits: { str = chars per string, arr = items per array, depth = nesting }
encode = function(v, limits, depth)
  depth = depth or 0
  if is_null(v) then
    return "null"
  end
  local t = type(v)
  if t == "string" then
    return json_str(cut_str(v, limits.str))
  elseif t == "number" then
    return json_num(v)
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "table" then
    if depth > 8 then
      return '"…"'
    end
    if is_array(v) then
      local parts = {}
      for i, item in ipairs(v) do
        if i > limits.arr then
          parts[#parts + 1] = json_str("… (+" .. (#v - limits.arr) .. " more)")
          break
        end
        parts[#parts + 1] = encode(item, limits, depth + 1)
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local parts = {}
    for _, k in ipairs(sorted_keys(v)) do
      parts[#parts + 1] = json_str(k) .. ":" .. encode(v[k], limits, depth + 1)
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return json_str(tostring(v))
end
Result._encode = function(v, limits)
  return encode(v, limits or { str = Result.MAX_STRING, arr = 1000 })
end

-- Preorder ids of the spec (all, and the explicit ones), without Schema.
local function collect_ids(spec)
  local all, explicit = {}, {}
  local function walk(comp)
    if type(comp) ~= "table" then
      return
    end
    if comp.id ~= nil then
      all[#all + 1] = tostring(comp.id)
      if comp._auto_id ~= true then
        explicit[#explicit + 1] = tostring(comp.id)
      end
    end
    if type(comp.children) == "table" then
      for _, kid in ipairs(comp.children) do
        walk(kid)
      end
    end
  end
  walk(type(spec) == "table" and spec.root or nil)
  return all, explicit
end

local function encode_values(spec, values, limits)
  if type(values) ~= "table" then
    return "{}"
  end
  local parts, seen = {}, {}
  local all = collect_ids(spec)
  for _, id in ipairs(all) do
    if values[id] ~= nil and not seen[id] then
      seen[id] = true
      parts[#parts + 1] = json_str(id) .. ":" .. encode(values[id], limits, 1)
    end
  end
  for _, k in ipairs(sorted_keys(values)) do
    local id = tostring(k)
    if not seen[id] then
      seen[id] = true
      parts[#parts + 1] = json_str(id) .. ":" .. encode(values[k], limits, 1)
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function warnings_suffix(warns)
  if type(warns) ~= "table" or #warns == 0 then
    return ""
  end
  local lines = { "", "warnings:" }
  for i, w in ipairs(warns) do
    if i > Result.MAX_WARNINGS then
      lines[#lines + 1] = "- … (+" .. (#warns - Result.MAX_WARNINGS) .. " more)"
      break
    end
    lines[#lines + 1] = "- " .. cut_str((Display.sv(w):gsub("\n", " ")), 200)
  end
  return table.concat(lines, "\n")
end
Result._warnings_suffix = warnings_suffix

local LIMIT_LEVELS = {
  { str = 500, arr = 1000 },
  { str = 120, arr = 50 },
  { str = 40, arr = 10 },
}

-- One JSON line per design.md §3.1, then optional warnings. Strings > 500
-- chars are cut, and the line is re-encoded with tighter limits (finally
-- without values) until it fits in MAX_BYTES.
function Result.llm_output(spec, st)
  st = type(st) == "table" and st or {}
  spec = type(spec) == "table" and spec or {}
  local status = type(st.status) == "string" and st.status or "error"
  local widget = st.widget
  if is_null(widget) then
    widget = spec.id
  end

  local function build(limits, omit_values)
    local parts = { '"status":' .. json_str(status) }
    if status == "submitted" then
      if type(st.action) == "string" and st.action ~= "" then
        parts[#parts + 1] = '"action":' .. json_str(cut_str(st.action, limits.str))
      end
      if omit_values then
        parts[#parts + 1] = '"truncated":true'
      else
        parts[#parts + 1] = '"values":' .. encode_values(spec, st.values, limits)
      end
    elseif status == "display" or status == "closed" then
      parts[#parts + 1] = '"widget":' .. json_str(Display.sv(widget))
    elseif status == "live" then
      parts[#parts + 1] = '"widget":' .. json_str(Display.sv(widget))
      local all, explicit = collect_ids(spec)
      local ids = #explicit > 0 and explicit or all
      parts[#parts + 1] = '"ids":' .. encode(ids, limits, 1)
    elseif status == "unavailable" then
      parts[#parts + 1] = '"reason":' .. json_str(Result.UNAVAILABLE_REASON)
    elseif status == "error" and type(st.error) == "string" then
      parts[#parts + 1] = '"error":' .. json_str(cut_str(st.error, limits.str))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end

  local line
  for _, limits in ipairs(LIMIT_LEVELS) do
    line = build(limits, false)
    if #line <= Result.MAX_BYTES then
      break
    end
  end
  if #line > Result.MAX_BYTES then
    line = build(LIMIT_LEVELS[#LIMIT_LEVELS], true)
  end

  local warns = st.warnings
  if type(warns) ~= "table" then
    warns = spec.warnings
  end
  return line .. warnings_suffix(warns)
end

function Result.update_output(id, patched, warnings)
  local ids = {}
  if type(patched) == "table" then
    for _, p in ipairs(patched) do
      ids[#ids + 1] = Display.sv(p)
    end
  end
  local line = '{"status":"updated","widget":'
    .. json_str(Display.sv(id))
    .. ',"patched":'
    .. encode(ids, LIMIT_LEVELS[1], 1)
    .. "}"
  return line .. warnings_suffix(warnings)
end

function Result.close_output(id, warnings)
  return '{"status":"closed","widget":' .. json_str(Display.sv(id)) .. "}" .. warnings_suffix(warnings)
end

function Result.error_output(errors)
  if type(errors) == "string" then
    errors = { errors }
  end
  local parts = {}
  if type(errors) == "table" then
    for i, e in ipairs(errors) do
      if i > Result.MAX_ERRORS then
        break
      end
      parts[#parts + 1] = (Display.sv(e):gsub("\n", " "))
    end
  end
  if #parts == 0 then
    parts[1] = "unknown error"
  end
  return "error: " .. table.concat(parts, "; ")
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

-- JSON-safe deep copy: densifies integer-keyed tables, drops functions and
-- `_auto_id`, keeps maki.NIL (encodes as null).
local function sanitize(v, depth)
  depth = depth or 0
  local t = type(v)
  if t == "table" then
    if depth > 32 then
      return nil
    end
    if is_array(v) then
      local out = {}
      for _, item in ipairs(v) do
        local s = sanitize(item, depth + 1)
        if s ~= nil then
          out[#out + 1] = s
        end
      end
      return out
    end
    local out = {}
    local ints = {}
    for k, item in pairs(v) do
      if type(k) == "number" and k >= 1 and k == math.floor(k) then
        ints[#ints + 1] = k
      elseif k ~= "_auto_id" and (type(k) == "string" or type(k) == "number" or type(k) == "boolean") then
        local s = sanitize(item, depth + 1)
        if s ~= nil then
          out[tostring(k)] = s
        end
      end
    end
    if #ints > 0 then
      table.sort(ints)
      if next(out) == nil then
        local arr = {}
        for _, k in ipairs(ints) do
          local s = sanitize(v[k], depth + 1)
          if s ~= nil then
            arr[#arr + 1] = s
          end
        end
        return arr
      end
      for _, k in ipairs(ints) do
        local s = sanitize(v[k], depth + 1)
        if s ~= nil then
          out[tostring(k)] = s
        end
      end
    end
    return out
  elseif t == "function" or t == "thread" then
    return nil
  elseif t == "userdata" then
    return is_null(v) and v or nil
  end
  return v
end
Result.sanitize = sanitize

-- GenuiState (design.md §3.5) from a FormResult / display status. The spec is
-- embedded (stripped) only for live widgets so a reload shows the last frame.
function Result.state(spec, res)
  spec = type(spec) == "table" and spec or {}
  res = type(res) == "table" and res or {}
  local mode = spec.mode or "display"
  local st = {
    v = 1,
    widget = spec.id,
    mode = mode,
    status = type(res.status) == "string" and res.status or mode,
    values = res.values ~= nil and sanitize(res.values) or nil,
    action = type(res.action) == "string" and res.action or nil,
    warnings = (type(spec.warnings) == "table" and #spec.warnings > 0) and sanitize(spec.warnings) or nil,
  }
  if mode == "live" then
    st.spec = sanitize(spec)
  end
  return st
end

---------------------------------------------------------------------------
-- Card
---------------------------------------------------------------------------

function Result.view_opts(ctx)
  local lines = nil
  if ctx and type(ctx.tool_output_lines) == "function" then
    local ok, res = pcall(ctx.tool_output_lines, ctx)
    if ok and type(res) == "table" then
      lines = res
    end
  end
  local other = lines and tonumber(lines.other) or 0
  return { width = Result.CARD_WIDTH, max_lines = math.max(other, Result.MIN_CARD_LINES), keep = "head" }
end

-- Minimal stand-in when maki.tool_view is not requireable (harness without
-- the bundled lib): same surface the card uses.
local function plain_view(buf)
  local self = { buf = buf, lines = {} }
  function self:clear()
    self.lines = {}
  end
  function self:append(line)
    self.lines[#self.lines + 1] = line
  end
  function self:finish()
    self.buf:set_lines(self.lines)
  end
  function self:visible_count()
    return #self.lines
  end
  function self:toggle() end
  return self
end

local function new_view(buf, opts)
  local ok, ToolView = pcall(require, "maki.tool_view")
  if ok and type(ToolView) == "table" and type(ToolView.new) == "function" then
    local okv, view = pcall(ToolView.new, buf, opts)
    if okv and view then
      return view
    end
  end
  return plain_view(buf)
end

-- buf, handle. handle = { buf, view, card_state = {expanded}, repaint(spec?, st?),
-- lines() }. Clicks on a mapped row flip one key in card_state.expanded and
-- re-render from (spec, st, card_state): pure, so replayed clicks on restore
-- land on the same frame. Other rows fall through to ToolView:toggle().
function Result.card(spec, st, opts)
  opts = opts or Result.view_opts(nil)
  local width = tonumber(opts.width) or Result.CARD_WIDTH
  local buf = maki.ui.buf()
  local view = new_view(buf, opts)
  local card_state = { expanded = {} }
  local cur_spec, cur_st = spec, st
  local rows = {}

  local function render()
    local st_values, st_action = nil, nil
    if type(cur_st) == "table" then
      st_values, st_action = cur_st.values, cur_st.action
    end
    local rctx = Render.ctx({
      width = width,
      values = st_values,
      action = st_action,
      expanded = card_state.expanded,
      mode = "card",
    })
    local ok, lines, new_rows = pcall(Render.card_lines, cur_spec, cur_st, rctx)
    if not ok then
      lines = { { { "⚠ card render failed: " .. tostring(lines), Render.STYLES.error } } }
      new_rows = {}
    end
    rows = new_rows or {}
    view:clear()
    for _, line in ipairs(lines) do
      view:append(line)
    end
    view:finish()
  end

  render()

  buf:on("click", function(ev)
    local row = type(ev) == "table" and tonumber(ev.row) or 0
    local key = nil
    if row and row > 0 and row <= view:visible_count() then
      key = rows[row]
    end
    if key then
      card_state.expanded[key] = not card_state.expanded[key]
      render()
    else
      view:toggle()
    end
  end)

  local handle = {
    buf = buf,
    view = view,
    card_state = card_state,
    repaint = function(new_spec, new_st)
      if type(new_spec) == "table" then
        cur_spec = new_spec
      end
      if type(new_st) == "table" then
        cur_st = new_st
      end
      render()
    end,
    rows = function()
      return rows
    end,
    lines = function()
      return buf:get_lines()
    end,
  }
  return buf, handle
end

-- Restore after reload: prefer the state's embedded spec (live widgets keep
-- their last patched tree), else the re-validated spec from the input.
function Result.restore(spec, st, opts)
  local use = spec
  if type(st) == "table" and type(st.spec) == "table" and type(st.spec.root) == "table" then
    use = st.spec
  end
  return Result.card(use, st, opts)
end

-- Live frame repaint for a RegistryEntry: set_lines in place, expanded flags kept.
function Result.repaint(entry)
  if type(entry) ~= "table" or type(entry.card) ~= "table" or type(entry.card.repaint) ~= "function" then
    return false, "no card handle"
  end
  local ok, err = pcall(entry.card.repaint, entry.spec, entry.state)
  if not ok then
    return false, tostring(err)
  end
  return true
end

return Result
