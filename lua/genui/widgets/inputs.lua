-- Input widgets for the interactive form window (design.md §4, plan.md §3).
--
-- Widget = {
--   init: (comp) -> ws,
--   handle_key: (ws, comp, key) -> "consumed"|"next"|"prev"|"submit"|"cancel"|"edit_on"|"edit_off"|"ignored",
--   handle_paste: ((ws, comp, text) -> ())?,
--   blur: ((ws, comp) -> ())?,                 -- focus leaves the widget (commit pending edits)
--   focus: ((ws, comp, entry) -> ())?,         -- focus lands on a ring entry of this widget
--   edit_on_focus: boolean?,                   -- text-entry footer while focused (input)
--   render: (ws, comp, rctx, focused, err) -> lines, cursor_offset,
--   value: (ws, comp) -> Value?,
--   validate: (ws, comp) -> string?,
-- }
local TextInput = require("maki.text_input")
local Render = require("genui.render")
local Display = require("genui.widgets.display")
local Schema = require("genui.schema")

local Inputs = { widgets = {} }
local W = Inputs.widgets
local S = Render.STYLES

local INDENT = "  "
local POINTER = "▸ "
local OTHER_LABEL = "Type your own answer"
local NEWLINE_KEYS = { ["<M-CR>"] = true, ["<S-CR>"] = true, ["<C-CR>"] = true, ["<C-j>"] = true }

-- ---------------------------------------------------------------------------
-- helpers

local function dw(rctx, s)
  if rctx and rctx.display_width then
    return rctx.display_width(s)
  end
  return utf8.len(s) or #s
end

local function fit(rctx, text, width)
  if width <= 0 then
    return ""
  end
  if dw(rctx, text) <= width then
    return text
  end
  local out = Render.fit(text, width, rctx)
  if dw(rctx, out) <= width then
    return out
  end
  -- Render.fit stub returned the text unchanged: hard cut by codepoints.
  local n = 0
  local last = 0
  for pos in utf8.codes(text) do
    n = n + 1
    if n > width - 1 then
      break
    end
    last = pos
  end
  if last == 0 then
    return "…"
  end
  local stop = (utf8.offset(text, 2, last) or (#text + 1)) - 1
  return text:sub(1, stop) .. "…"
end

local function trim(s)
  return (s:match("^%s*(.-)%s*$"))
end

local function error_line(err)
  return { { INDENT .. "✗ " .. err, S.error } }
end

local function label_line(comp, focused, suffix)
  local style = focused and S.focus or S.label
  local line = { { INDENT .. tostring(comp.label or ""), style } }
  if suffix then
    line[#line + 1] = { suffix, S.hint }
  end
  return line
end

local function is_required(comp, default)
  if comp.required == nil then
    return default
  end
  return comp.required and true or false
end

local function opt_of(o)
  if type(o) == "table" then
    local label = o.label or o.value or ""
    return { value = o.value or label, label = tostring(label), description = o.description }
  end
  return { value = tostring(o), label = tostring(o) }
end

local function has_any(t)
  return next(t) ~= nil
end

-- ---------------------------------------------------------------------------
-- choice

local Choice = {}
W.choice = Choice

local function choice_options(comp)
  local out = {}
  for _, o in ipairs(comp.options or {}) do
    out[#out + 1] = opt_of(o)
  end
  return out
end

local function choice_has_other(comp)
  return comp.other ~= false
end

function Choice.init(comp)
  local ws = { cursor = 1, selected = {}, other_text = nil, other_input = nil, editing = false }
  local defaults = {}
  if type(comp.default) == "table" then
    for _, d in ipairs(comp.default) do
      defaults[tostring(d)] = true
    end
  elseif comp.default ~= nil then
    defaults[tostring(comp.default)] = true
  end
  if has_any(defaults) then
    local opts = choice_options(comp)
    for _, o in ipairs(opts) do
      if defaults[o.value] or defaults[o.label] then
        ws.selected[o.value] = true
        if not comp.multi then
          break
        end
      end
    end
    if not comp.multi and not has_any(ws.selected) and choice_has_other(comp) then
      for d in pairs(defaults) do
        ws.other_text = d
        break
      end
    end
  end
  return ws
end

local function choice_rows(comp)
  local n = #(comp.options or {})
  if choice_has_other(comp) then
    n = n + 1
  end
  return n
end

local function choice_select(ws, comp, value)
  if comp.multi then
    if ws.selected[value] then
      ws.selected[value] = nil
    else
      ws.selected[value] = true
    end
  else
    ws.selected = { [value] = true }
    ws.other_text = nil
  end
end

local function choice_start_edit(ws)
  ws.editing = true
  ws.other_input = TextInput.new()
  if ws.other_text then
    ws.other_input:insert_text(ws.other_text)
  end
end

local function choice_commit_edit(ws, comp)
  local text = ws.other_input and trim(ws.other_input:value()) or ""
  ws.editing = false
  ws.other_input = nil
  if text == "" then
    ws.other_text = nil
    return false
  end
  ws.other_text = text
  if not comp.multi then
    ws.selected = {}
  end
  return true
end

function Choice.handle_key(ws, comp, key)
  local n = choice_rows(comp)
  local opts = comp.options or {}
  local on_other = choice_has_other(comp) and ws.cursor == n
  if ws.editing then
    if key == "<CR>" then
      if ws.other_input:char_before_cursor() == "\\" then
        ws.other_input:handle_key("<BS>")
        ws.other_input:split_line()
        return "consumed"
      end
      local had = choice_commit_edit(ws, comp)
      if had and not comp.multi then
        return "next"
      end
      return "edit_off"
    elseif NEWLINE_KEYS[key] then
      ws.other_input:split_line()
      return "consumed"
    elseif key == "<Esc>" then
      ws.editing = false
      ws.other_input = nil
      return "edit_off"
    elseif key == "<Tab>" or key == "<S-Tab>" then
      choice_commit_edit(ws, comp)
      return "ignored"
    elseif key == "<Up>" or key == "<Down>" then
      local r = ws.other_input:handle_key(key)
      if r ~= TextInput.Result.IGNORED then
        return "consumed"
      end
      choice_commit_edit(ws, comp)
      if key == "<Up>" then
        if ws.cursor > 1 then
          ws.cursor = ws.cursor - 1
          return "edit_off"
        end
        return "prev"
      end
      return "next"
    end
    if ws.other_input:handle_key(key) ~= TextInput.Result.IGNORED then
      return "consumed"
    end
    return "ignored"
  end

  if key == "<Up>" then
    if ws.cursor > 1 then
      ws.cursor = ws.cursor - 1
      return "consumed"
    end
    return "prev"
  elseif key == "<Down>" then
    if ws.cursor < n then
      ws.cursor = ws.cursor + 1
      return "consumed"
    end
    return "next"
  elseif key == "<Home>" then
    ws.cursor = 1
    return "consumed"
  elseif key == "<End>" then
    ws.cursor = math.max(n, 1)
    return "consumed"
  elseif key == "<Space>" or key == "<CR>" then
    if on_other then
      choice_start_edit(ws)
      return "edit_on"
    end
    local o = opts[ws.cursor]
    if not o then
      return "ignored"
    end
    choice_select(ws, comp, opt_of(o).value)
    if key == "<CR>" and not comp.multi then
      return "next"
    end
    return "consumed"
  end
  return "ignored"
end

function Choice.handle_paste(ws, comp, text)
  if ws.editing and ws.other_input then
    ws.other_input:insert_text(text)
  end
end

function Choice.blur(ws, comp)
  if ws.editing then
    choice_commit_edit(ws, comp)
  end
end

function Choice.value(ws, comp)
  local opts = choice_options(comp)
  if comp.multi then
    local out = {}
    for _, o in ipairs(opts) do
      if ws.selected[o.value] then
        out[#out + 1] = o.value
      end
    end
    if ws.other_text then
      out[#out + 1] = ws.other_text
    end
    if #out == 0 then
      return nil
    end
    return out
  end
  for _, o in ipairs(opts) do
    if ws.selected[o.value] then
      return o.value
    end
  end
  return ws.other_text
end

function Choice.validate(ws, comp)
  local v = Choice.value(ws, comp)
  local count = 0
  if type(v) == "table" then
    count = #v
  elseif v ~= nil then
    count = 1
  end
  if count == 0 then
    if is_required(comp, true) then
      return comp.multi and "select at least one option" or "select an option"
    end
    return nil
  end
  if comp.multi then
    if type(comp.min_selected) == "number" and count < comp.min_selected then
      return "select at least " .. tostring(comp.min_selected)
    end
    if type(comp.max_selected) == "number" and count > comp.max_selected then
      return "select at most " .. tostring(comp.max_selected)
    end
  end
  return nil
end

function Choice.render(ws, comp, rctx, focused, err)
  local width = rctx.width
  local lines = {}
  local cursor_offset = 1
  lines[#lines + 1] = label_line(comp, focused, comp.multi and "  (multiple answers)" or nil)
  local opts = choice_options(comp)
  local n = choice_rows(comp)
  for i, o in ipairs(opts) do
    local cur = focused and ws.cursor == i
    local checked = ws.selected[o.value] == true
    local mark
    if comp.multi then
      mark = checked and "[x] " or "[ ] "
    else
      mark = checked and "(•) " or "( ) "
    end
    local prefix = INDENT .. (cur and POINTER or "  ") .. mark
    local line = { { prefix, cur and S.selected or (checked and S.success or S.value) } }
    local avail = width - dw(rctx, prefix)
    local label = fit(rctx, o.label, avail)
    line[#line + 1] = { label, cur and S.selected or (checked and S.success or S.value) }
    if o.description and o.description ~= "" then
      local rest = avail - dw(rctx, label) - 3
      if rest > 4 then
        line[#line + 1] = { " - " .. fit(rctx, tostring(o.description), rest), S.muted }
      end
    end
    lines[#lines + 1] = line
    if cur then
      cursor_offset = #lines
    end
  end
  if choice_has_other(comp) then
    local cur = focused and ws.cursor == n
    if ws.editing and ws.other_input then
      local r = ws.other_input:render(INDENT .. "  ❯ ", 6, width)
      cursor_offset = #lines + r.cursor_row
      for _, ln in ipairs(r.lines) do
        lines[#lines + 1] = ln
      end
    else
      local prefix = INDENT .. (cur and POINTER or "  ") .. "→ "
      local style = cur and S.selected or (ws.other_text and S.success or S.muted)
      local line = { { prefix, style }, { OTHER_LABEL, style } }
      if ws.other_text then
        local rest = width - dw(rctx, prefix) - dw(rctx, OTHER_LABEL) - 3
        if rest > 4 then
          line[#line + 1] = { " - " .. fit(rctx, ws.other_text, rest), S.muted }
        end
      end
      lines[#lines + 1] = line
      if cur then
        cursor_offset = #lines
      end
    end
  end
  if err then
    lines[#lines + 1] = error_line(err)
  end
  return lines, cursor_offset
end

-- ---------------------------------------------------------------------------
-- input (text)

local Input = { edit_on_focus = true }
W.input = Input

function Input.init(comp)
  local ws = { ti = TextInput.new(), pattern_v = nil, pattern_src = nil }
  if comp.default ~= nil and comp.default ~= "" then
    ws.ti:insert_text(tostring(comp.default))
  end
  return ws
end

function Input.handle_key(ws, comp, key)
  local multiline = comp.multiline == true
  if key == "<CR>" then
    if multiline and ws.ti:char_before_cursor() == "\\" then
      ws.ti:handle_key("<BS>")
      ws.ti:split_line()
      return "consumed"
    end
    return "next"
  elseif NEWLINE_KEYS[key] then
    if multiline then
      ws.ti:split_line()
      return "consumed"
    end
    return "ignored"
  elseif key == "<Up>" or key == "<Down>" then
    if multiline and ws.ti:handle_key(key) ~= TextInput.Result.IGNORED then
      return "consumed"
    end
    return key == "<Up>" and "prev" or "next"
  elseif key == "<Tab>" or key == "<S-Tab>" or key == "<Esc>" then
    return "ignored"
  end
  if ws.ti:handle_key(key) ~= TextInput.Result.IGNORED then
    return "consumed"
  end
  return "ignored"
end

function Input.handle_paste(ws, comp, text)
  if comp.multiline then
    ws.ti:insert_text(text)
  else
    ws.ti:insert_text((text:gsub("[\r\n]+", " ")))
  end
end

function Input.value(ws, comp)
  return ws.ti:value()
end

local function pattern_validator(ws, comp)
  local pat = comp.pattern
  if type(pat) ~= "string" or pat == "" then
    return nil
  end
  if ws.pattern_src ~= pat then
    ws.pattern_src = pat
    local ok, v = pcall(Schema.compile_pattern, pat)
    ws.pattern_v = ok and v or nil
  end
  return ws.pattern_v
end

function Input.validate(ws, comp)
  local v = ws.ti:value()
  local t = trim(v)
  if t == "" then
    if is_required(comp, false) then
      return "required"
    end
    return nil
  end
  local len = utf8.len(v) or #v
  if type(comp.min_len) == "number" and len < comp.min_len then
    return "at least " .. tostring(comp.min_len) .. " characters"
  end
  if type(comp.max_len) == "number" and len > comp.max_len then
    return "at most " .. tostring(comp.max_len) .. " characters"
  end
  local pv = pattern_validator(ws, comp)
  if pv then
    local ok, res = pcall(function()
      return pv:validate(v)
    end)
    if ok and res ~= nil then
      return comp.pattern_hint or ("must match " .. tostring(comp.pattern))
    end
  end
  return nil
end

function Input.render(ws, comp, rctx, focused, err)
  local width = rctx.width
  local lines = {}
  lines[#lines + 1] = label_line(comp, focused, is_required(comp, false) and "  (required)" or nil)
  local cursor_offset = 2
  if focused then
    local r = ws.ti:render(INDENT .. "❯ ", 4, width)
    cursor_offset = #lines + r.cursor_row
    for _, ln in ipairs(r.lines) do
      lines[#lines + 1] = ln
    end
    if ws.ti:is_empty() and comp.placeholder and comp.placeholder ~= "" then
      local last = lines[#lines]
      last[#last + 1] = { " " .. fit(rctx, tostring(comp.placeholder), width - 6), S.muted }
    end
  else
    local v = ws.ti:value()
    if v == "" then
      local ph = comp.placeholder and tostring(comp.placeholder) or ""
      lines[#lines + 1] = { { INDENT .. "❯ ", S.muted }, { fit(rctx, ph, width - 4), S.muted } }
    else
      local first = true
      for ln in (v .. "\n"):gmatch("(.-)\n") do
        local prefix = first and (INDENT .. "❯ ") or (INDENT .. "  ")
        first = false
        lines[#lines + 1] = { { prefix, S.muted }, { fit(rctx, ln, width - 4), S.value } }
      end
    end
  end
  if err then
    lines[#lines + 1] = error_line(err)
  end
  return lines, cursor_offset
end

-- ---------------------------------------------------------------------------
-- number

local Number = {}
W.number = Number

local function fmt_number(n)
  if n == math.floor(n) then
    return string.format("%.0f", n)
  end
  local s = string.format("%.6f", n)
  s = s:gsub("0+$", "")
  s = s:gsub("%.$", "")
  return s
end

function Number.init(comp)
  local ws = { text = "" }
  if type(comp.default) == "number" then
    ws.text = fmt_number(comp.default)
  elseif type(comp.default) == "string" and tonumber(comp.default) then
    ws.text = comp.default
  end
  return ws
end

local function number_clamp(comp, n)
  if type(comp.min) == "number" and n < comp.min then
    n = comp.min
  end
  if type(comp.max) == "number" and n > comp.max then
    n = comp.max
  end
  return n
end

local function number_step(ws, comp, dir)
  local step = type(comp.step) == "number" and comp.step or 1
  local cur = tonumber(ws.text)
  if cur == nil then
    if type(comp.default) == "number" then
      cur = comp.default
    elseif type(comp.min) == "number" then
      cur = comp.min
    else
      cur = 0
    end
    cur = cur - dir * step
  end
  local n = number_clamp(comp, cur + dir * step)
  if comp.integer then
    n = math.floor(n + 0.5)
  end
  ws.text = fmt_number(n)
end

function Number.handle_key(ws, comp, key)
  if key == "<Up>" or key == "+" then
    number_step(ws, comp, 1)
    return "consumed"
  elseif key == "<Down>" then
    number_step(ws, comp, -1)
    return "consumed"
  elseif key == "-" then
    if ws.text == "" then
      ws.text = "-"
      return "consumed"
    end
    number_step(ws, comp, -1)
    return "consumed"
  elseif key == "<BS>" then
    if ws.text ~= "" then
      ws.text = ws.text:sub(1, -2)
    end
    return "consumed"
  elseif key == "<C-u>" or key == "<C-w>" then
    ws.text = ""
    return "consumed"
  elseif key == "<CR>" then
    return "next"
  elseif #key == 1 and (key:match("%d") or (key == "." and not comp.integer)) then
    local candidate = ws.text .. key
    if candidate:match("^%-?%d*%.?%d*$") then
      ws.text = candidate
    end
    return "consumed"
  end
  return "ignored"
end

function Number.handle_paste(ws, comp, text)
  local t = trim(text)
  if t:match("^%-?%d*%.?%d*$") then
    ws.text = t
  end
end

function Number.value(ws, comp)
  return tonumber(ws.text)
end

function Number.validate(ws, comp)
  if trim(ws.text) == "" then
    if is_required(comp, false) then
      return "required"
    end
    return nil
  end
  local n = tonumber(ws.text)
  if n == nil then
    return "not a number"
  end
  if comp.integer and n ~= math.floor(n) then
    return "must be an integer"
  end
  if type(comp.min) == "number" and n < comp.min then
    return "must be ≥ " .. fmt_number(comp.min)
  end
  if type(comp.max) == "number" and n > comp.max then
    return "must be ≤ " .. fmt_number(comp.max)
  end
  return nil
end

function Number.render(ws, comp, rctx, focused, err)
  local lines = {}
  local label = INDENT .. tostring(comp.label or "")
  local line = { { label, focused and S.focus or S.label }, { "  ❯ ", S.muted } }
  if focused then
    line[#line + 1] = { ws.text, S.value }
    line[#line + 1] = { " ", "cursor" }
  else
    line[#line + 1] = { ws.text ~= "" and ws.text or "–", ws.text ~= "" and S.value or S.muted }
  end
  local range = nil
  if type(comp.min) == "number" and type(comp.max) == "number" then
    range = "(" .. fmt_number(comp.min) .. "–" .. fmt_number(comp.max) .. ")"
  elseif type(comp.min) == "number" then
    range = "(≥ " .. fmt_number(comp.min) .. ")"
  elseif type(comp.max) == "number" then
    range = "(≤ " .. fmt_number(comp.max) .. ")"
  end
  if range then
    line[#line + 1] = { "   " .. range, S.hint }
  end
  lines[#lines + 1] = line
  if err then
    lines[#lines + 1] = error_line(err)
  end
  return lines, 1
end

-- ---------------------------------------------------------------------------
-- confirm

local Confirm = {}
W.confirm = Confirm

function Confirm.init(comp)
  return { value = comp.default == true }
end

function Confirm.handle_key(ws, comp, key)
  if key == "<Space>" or key == "<Left>" or key == "<Right>" or key == "h" or key == "l" then
    ws.value = not ws.value
    return "consumed"
  elseif key == "y" or key == "Y" then
    ws.value = true
    return "consumed"
  elseif key == "n" or key == "N" then
    ws.value = false
    return "consumed"
  elseif key == "<CR>" then
    return "next"
  elseif key == "<Up>" then
    return "prev"
  elseif key == "<Down>" then
    return "next"
  end
  return "ignored"
end

function Confirm.value(ws, comp)
  return ws.value == true
end

function Confirm.validate(ws, comp)
  return nil
end

function Confirm.render(ws, comp, rctx, focused, err)
  local lines = {}
  local label = INDENT .. (focused and POINTER or "  ") .. tostring(comp.label or "")
  local yes_style = ws.value and S.selected or S.muted
  local no_style = (not ws.value) and S.selected or S.muted
  lines[#lines + 1] = {
    { label, focused and S.focus or S.label },
    { "   ", "" },
    { ws.value and "[ Yes ]" or "  Yes  ", yes_style },
    { "   ", "" },
    { ws.value and "  No  " or "[ No ]", no_style },
  }
  if err then
    lines[#lines + 1] = error_line(err)
  end
  return lines, 1
end

-- ---------------------------------------------------------------------------
-- actions (and the implicit submit row, which reuses it)

local Actions = {}
W.actions = Actions

function Actions.init(comp)
  return { cursor = 1 }
end

function Actions.focus(ws, comp, entry)
  ws.cursor = entry.index or 1
end

function Actions.handle_key(ws, comp, key)
  if key == "<CR>" or key == "<Space>" then
    return "submit"
  elseif key == "<Left>" or key == "<Up>" then
    return "prev"
  elseif key == "<Right>" or key == "<Down>" then
    return "next"
  end
  return "ignored"
end

function Actions.value(ws, comp)
  return nil
end

function Actions.validate(ws, comp)
  return nil
end

local function button_style(item, active)
  if active then
    return S.selected
  end
  if item.style == "primary" then
    return S.label
  elseif item.style == "danger" then
    return S.error
  end
  return S.value
end

function Actions.render(ws, comp, rctx, focused, err)
  local line = { { INDENT .. (focused and POINTER or "  "), focused and S.selected or "" } }
  for i, item in ipairs(comp.items or {}) do
    local active = focused and ws.cursor == i
    local label = tostring(item.label or item.action or "?")
    line[#line + 1] = { "[ " .. label .. " ]", button_style(item, active) }
    line[#line + 1] = { "   ", "" }
  end
  local lines = { line }
  if err then
    lines[#lines + 1] = error_line(err)
  end
  return lines, 1
end

W.submit_row = Actions

-- ---------------------------------------------------------------------------
-- table (row selection)

local Table = {}
W.table = Table

local function table_columns(comp)
  local cols = {}
  for i, c in ipairs(comp.columns or {}) do
    if type(c) == "table" then
      cols[#cols + 1] =
        { key = c.key or tostring(i), label = c.label or c.key or tostring(i), align = c.align or "left" }
    else
      cols[#cols + 1] = { key = tostring(c), label = tostring(c), align = "left" }
    end
  end
  return cols
end

local function cell_text(row, col, idx)
  local v
  if type(row) == "table" then
    if row[col.key] ~= nil then
      v = row[col.key]
    else
      v = row[idx]
    end
  else
    v = idx == 1 and row or nil
  end
  if v == nil then
    return ""
  end
  if type(v) == "number" then
    return fmt_number(v)
  end
  return tostring(v)
end

local function table_row_key(comp, cols, row, i)
  if comp.key then
    for ci, c in ipairs(cols) do
      if c.key == comp.key or c.label == comp.key then
        local t = cell_text(row, c, ci)
        if t ~= "" then
          return t
        end
      end
    end
    if type(row) == "table" and row[comp.key] ~= nil then
      return tostring(row[comp.key])
    end
  end
  return tostring(i)
end

function Table.init(comp)
  local ws = { cursor = 1, selected = {}, top = 1, keys = {} }
  local cols = table_columns(comp)
  for i, row in ipairs(comp.rows or {}) do
    ws.keys[i] = table_row_key(comp, cols, row, i)
  end
  return ws
end

local function table_max_rows(comp)
  local m = type(comp.max_rows) == "number" and comp.max_rows or 20
  return math.max(1, math.floor(m))
end

local function table_pick(ws, comp)
  local k = ws.keys[ws.cursor]
  if not k then
    return
  end
  if comp.select == "multi" then
    if ws.selected[k] then
      ws.selected[k] = nil
    else
      ws.selected[k] = true
    end
  else
    ws.selected = { [k] = true }
  end
end

function Table.handle_key(ws, comp, key)
  local n = #ws.keys
  if key == "<Up>" then
    if ws.cursor > 1 then
      ws.cursor = ws.cursor - 1
      return "consumed"
    end
    return "prev"
  elseif key == "<Down>" then
    if ws.cursor < n then
      ws.cursor = ws.cursor + 1
      return "consumed"
    end
    return "next"
  elseif key == "<Home>" then
    ws.cursor = 1
    return "consumed"
  elseif key == "<End>" then
    ws.cursor = math.max(n, 1)
    return "consumed"
  elseif key == "<Space>" then
    table_pick(ws, comp)
    return "consumed"
  elseif key == "<CR>" then
    table_pick(ws, comp)
    return "next"
  elseif key == "a" and comp.select == "multi" then
    local all = true
    for _, k in ipairs(ws.keys) do
      if not ws.selected[k] then
        all = false
        break
      end
    end
    ws.selected = {}
    if not all then
      for _, k in ipairs(ws.keys) do
        ws.selected[k] = true
      end
    end
    return "consumed"
  end
  return "ignored"
end

function Table.value(ws, comp)
  if comp.select == "multi" then
    local out = {}
    for _, k in ipairs(ws.keys) do
      if ws.selected[k] then
        out[#out + 1] = k
      end
    end
    if #out == 0 then
      return nil
    end
    return out
  end
  for _, k in ipairs(ws.keys) do
    if ws.selected[k] then
      return k
    end
  end
  return nil
end

function Table.validate(ws, comp)
  if not is_required(comp, false) then
    return nil
  end
  local v = Table.value(ws, comp)
  if v == nil or (type(v) == "table" and #v == 0) then
    return "select a row"
  end
  return nil
end

-- Column layout: Display.table_layout when Lane B provides it, else a plain fit.
local function table_layout(comp, width, rctx)
  local ok, layout = pcall(Display.table_layout, comp, width, rctx)
  if ok and type(layout) == "table" and layout.cols and #layout.cols > 0 and layout.rows then
    return layout
  end
  local cols = table_columns(comp)
  local rows = {}
  local widths = {}
  for ci, c in ipairs(cols) do
    widths[ci] = dw(rctx, c.label)
  end
  for ri, row in ipairs(comp.rows or {}) do
    local cells = {}
    for ci, c in ipairs(cols) do
      local t = cell_text(row, c, ci)
      cells[ci] = t
      widths[ci] = math.max(widths[ci], dw(rctx, t))
    end
    rows[ri] = cells
  end
  local ncols = math.max(#cols, 1)
  local cap = math.max(4, math.floor((width - 2 * ncols) / ncols))
  for ci, c in ipairs(cols) do
    c.width = math.min(widths[ci], cap)
  end
  return { cols = cols, rows = rows }
end

local function pad_cell(rctx, text, w, align)
  local t = fit(rctx, text, w)
  local gap = w - dw(rctx, t)
  if gap <= 0 then
    return t
  end
  if align == "right" then
    return string.rep(" ", gap) .. t
  end
  return t .. string.rep(" ", gap)
end

function Table.render(ws, comp, rctx, focused, err)
  local width = rctx.width
  local lines = {}
  local cursor_offset = 1
  local marker_w = 6 -- "▸ [x] "
  local layout = table_layout(comp, width - marker_w - 2, rctx)
  local multi = comp.select == "multi"
  if comp.label and comp.label ~= "" then
    lines[#lines + 1] = label_line(comp, focused, multi and "  (select rows)" or "  (select a row)")
  end
  local head = { { INDENT .. string.rep(" ", marker_w - 2), "" } }
  for _, c in ipairs(layout.cols) do
    head[#head + 1] = { pad_cell(rctx, tostring(c.label or c.key or ""), c.width or 4, c.align) .. "  ", S.label }
  end
  lines[#lines + 1] = head

  local n = #layout.rows
  local max_rows = table_max_rows(comp)
  if ws.cursor < ws.top then
    ws.top = ws.cursor
  elseif ws.cursor > ws.top + max_rows - 1 then
    ws.top = ws.cursor - max_rows + 1
  end
  ws.top = math.max(1, math.min(ws.top, math.max(1, n - max_rows + 1)))
  local last = math.min(n, ws.top + max_rows - 1)
  if ws.top > 1 then
    lines[#lines + 1] = { { INDENT .. "  ▲ " .. tostring(ws.top - 1) .. " more", S.hint } }
  end
  for ri = ws.top, last do
    local cells = layout.rows[ri] or {}
    local key = ws.keys[ri]
    local cur = focused and ri == ws.cursor
    local checked = key ~= nil and ws.selected[key] == true
    local mark
    if multi then
      mark = checked and "[x] " or "[ ] "
    else
      mark = checked and "(•) " or "( ) "
    end
    local style = cur and S.selected or (checked and S.success or S.value)
    local line = { { INDENT .. (cur and POINTER or "  ") .. mark, style } }
    for ci, c in ipairs(layout.cols) do
      line[#line + 1] = { pad_cell(rctx, tostring(cells[ci] or ""), c.width or 4, c.align) .. "  ", style }
    end
    lines[#lines + 1] = line
    if cur then
      cursor_offset = #lines
    end
  end
  if last < n then
    lines[#lines + 1] = { { INDENT .. "  ▼ " .. tostring(n - last) .. " more", S.hint } }
  end
  if err then
    lines[#lines + 1] = error_line(err)
  end
  return lines, cursor_offset
end

-- ---------------------------------------------------------------------------
-- diff (per-hunk decisions)

local Diff = {}
W.diff = Diff

local function diff_hunks(comp)
  local text = comp.text
  if (type(text) ~= "string" or text == "") and type(comp.before) == "string" and type(comp.after) == "string" then
    local ok, t = pcall(Display.line_diff, comp.before, comp.after)
    text = ok and t or ""
  end
  if type(text) ~= "string" then
    return {}
  end
  local ok, parsed = pcall(Display.parse_diff, text)
  if ok and type(parsed) == "table" and type(parsed.hunks) == "table" then
    return parsed.hunks
  end
  return {}
end

function Diff.init(comp)
  return { cursor = 1, decisions = {}, hunks = diff_hunks(comp) }
end

local function cycle(d)
  if d == nil then
    return "accept"
  elseif d == "accept" then
    return "reject"
  end
  return nil
end

function Diff.handle_key(ws, comp, key)
  local n = #ws.hunks
  if key == "a" then
    ws.decisions[ws.cursor] = "accept"
    return "consumed"
  elseif key == "r" then
    ws.decisions[ws.cursor] = "reject"
    return "consumed"
  elseif key == "<Space>" then
    ws.decisions[ws.cursor] = cycle(ws.decisions[ws.cursor])
    return "consumed"
  elseif key == "<CR>" then
    ws.decisions[ws.cursor] = "accept"
    if ws.cursor < n then
      ws.cursor = ws.cursor + 1
      return "consumed"
    end
    return "next"
  elseif key == "<Up>" then
    if ws.cursor > 1 then
      ws.cursor = ws.cursor - 1
      return "consumed"
    end
    return "prev"
  elseif key == "<Down>" then
    if ws.cursor < n then
      ws.cursor = ws.cursor + 1
      return "consumed"
    end
    return "next"
  elseif key == "A" then
    for i = 1, n do
      ws.decisions[i] = "accept"
    end
    return "consumed"
  elseif key == "R" then
    for i = 1, n do
      ws.decisions[i] = "reject"
    end
    return "consumed"
  end
  return "ignored"
end

function Diff.value(ws, comp)
  local out = {}
  for i = 1, #ws.hunks do
    if ws.decisions[i] then
      out[tostring(i)] = ws.decisions[i]
    end
  end
  return out
end

function Diff.validate(ws, comp)
  local undecided = 0
  for i = 1, #ws.hunks do
    if not ws.decisions[i] then
      undecided = undecided + 1
    end
  end
  if undecided > 0 then
    return "decide every hunk (" .. tostring(undecided) .. " undecided: a accept, r reject)"
  end
  return nil
end

local function nr(v)
  if v == nil then
    return "    "
  end
  return string.format("%4.0f", v)
end

function Diff.render(ws, comp, rctx, focused, err)
  local width = rctx.width
  local lines = {}
  local cursor_offset = 1
  local max_lines = type(comp.max_lines) == "number" and comp.max_lines or 200
  local title = (comp.label ~= nil and comp.label ~= "" and comp.label) or comp.path
  if title then
    lines[#lines + 1] = label_line({ label = title }, focused)
  end
  if #ws.hunks == 0 then
    lines[#lines + 1] = { { INDENT .. "(no hunks)", S.muted } }
  end
  local budget = max_lines
  for i, h in ipairs(ws.hunks) do
    local cur = focused and ws.cursor == i
    local d = ws.decisions[i]
    local tag = d == "accept" and "[accept]" or (d == "reject" and "[reject]" or "[  ?   ]")
    local tag_style = d == "accept" and S.success or (d == "reject" and S.error or S.warning)
    local prefix = INDENT .. (cur and POINTER or "  ")
    local header = fit(rctx, tostring(h.header or ("hunk " .. tostring(i))), width - dw(rctx, prefix) - 10)
    local gap = math.max(1, width - dw(rctx, prefix) - dw(rctx, header) - 8)
    lines[#lines + 1] = {
      { prefix, cur and S.selected or S.section },
      { header, cur and S.selected or S.section },
      { string.rep(" ", gap), "" },
      { tag, tag_style },
    }
    if cur then
      cursor_offset = #lines
    end
    for _, ln in ipairs(h.lines or {}) do
      if budget <= 0 then
        break
      end
      budget = budget - 1
      local kind = ln.kind or " "
      local style = kind == "-" and S.diff_old or (kind == "+" and S.diff_new or S.value)
      local sign = kind == " " and " " or kind
      lines[#lines + 1] = {
        { INDENT .. "  " .. nr(ln.old_nr) .. " " .. nr(ln.new_nr) .. " ", "diff_line_nr" },
        { sign .. " " .. fit(rctx, tostring(ln.text or ""), width - 18), style },
      }
    end
    if budget <= 0 and i < #ws.hunks then
      lines[#lines + 1] = { { INDENT .. "… (more hunks not shown; use a/r on each)", S.muted } }
    end
  end
  if err then
    lines[#lines + 1] = error_line(err)
  end
  return lines, cursor_offset
end

Inputs._fit = fit
Inputs._opt_of = opt_of

return Inputs
