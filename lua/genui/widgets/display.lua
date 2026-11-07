-- Display renderers: pure functions from a normalized component (+ RenderCtx)
-- to styled lines, plus a row -> toggle-key map for click targets.
--
-- Every renderer here is called through `Render.component`, which pcall-guards
-- it and clamps the result to `rctx.width`; still, each renderer fits its own
-- lines so columns line up before the safety net runs. Nothing here touches
-- `maki.ui` directly: widths and markdown come from `rctx` so specs run without
-- a host. Container renderers reach child components through
-- `Display.render_child`, which `genui.render` installs (no require cycle).
local Display = { renderers = {} }
local R = Display.renderers

local INDENT = "  "
local ELLIPSIS = "…"
local BAR_CELLS = 30
local SPARK = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local EIGHTHS = { "▏", "▎", "▍", "▌", "▋", "▊", "▉" }
local TEXT_MAX_LINES = 400
local DIFF_MAX_LINES = 200
local TABLE_MAX_ROWS = 20
local TABLE_HARD_CAP = 500
local BARS_CAP = 50
local SPARK_CAP = 200
local MAX_KEY_WIDTH = 24
local MIN_COL_WIDTH = 3
local LCS_CELL_CAP = 250000
local NO_ANSWER = "(no answer)"

-- Semantic style names -> theme style names (maki-ui/src/theme.rs named_styles!).
-- Unknown names fall back silently host-side, so a theme change never breaks a card.
Display.STYLES = {
  label = "bold",
  value = "",
  muted = "dim",
  focus = "item_selected",
  selected = "selected",
  error = "error",
  success = "success",
  warning = "warning",
  section = "section",
  border = "table_border",
  bar_fill = "accent",
  bar_empty = "dim",
  diff_old = "diff_old",
  diff_new = "diff_new",
  hint = "dim",
  title = "heading",
  rule = "horizontal_rule",
  path = "path",
  line_nr = "diff_line_nr",
  hunk = "section",
  spinner = "spinner",
  done = "todo_completed",
  pending = "todo_pending",
}

local TONES = { plain = "", info = "heading", success = "success", warning = "warning", error = "error", dim = "dim" }

local function S(name)
  return Display.STYLES[name] or ""
end

---------------------------------------------------------------------------
-- Text primitives (re-exported by genui.render as fit/pad/wrap_text)
---------------------------------------------------------------------------

local function fallback_width(s)
  return utf8.len(s) or #s
end

local function host_width()
  local ui = type(maki) == "table" and maki.ui or nil
  if ui and type(ui.display_width) == "function" then
    return ui.display_width
  end
  return fallback_width
end

local function is_null(v)
  return v == nil or (type(maki) == "table" and v == maki.NIL)
end

local function fmt_num(n)
  if n ~= n then
    return "NaN"
  elseif n == math.huge then
    return "∞"
  elseif n == -math.huge then
    return "-∞"
  elseif n == math.floor(n) and math.abs(n) < 1e15 then
    return string.format("%d", n)
  end
  return tostring(n)
end
Display.fmt_num = fmt_num

-- Any value -> display string. Never raises; tables go through the JSON
-- encoder when the host offers one.
local function sv(v)
  if is_null(v) then
    return v == nil and "" or "null"
  end
  local t = type(v)
  if t == "string" then
    return (v:gsub("\t", "  "):gsub("\r", ""))
  elseif t == "number" then
    return fmt_num(v)
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "table" then
    local json = type(maki) == "table" and maki.json or nil
    if json and type(json.encode) == "function" then
      local ok, s = pcall(json.encode, v)
      if ok and type(s) == "string" then
        return s
      end
    end
    return "[table]"
  end
  return tostring(v)
end
Display.sv = sv

local function dw(s, rctx)
  if type(s) ~= "string" then
    s = sv(s)
  end
  local f = rctx and rctx.display_width or nil
  if type(f) ~= "function" then
    f = host_width()
  end
  local ok, w = pcall(f, s)
  if ok and type(w) == "number" then
    return w
  end
  return fallback_width(s)
end
Display.width = dw

local function split_lines(s)
  local out = {}
  local pos = 1
  while true do
    local i = s:find("\n", pos, true)
    if not i then
      out[#out + 1] = s:sub(pos)
      break
    end
    out[#out + 1] = s:sub(pos, i - 1)
    pos = i + 1
  end
  return out
end
Display.split_lines = split_lines

-- First `cols` cells of `text`, no ellipsis. Always consumes at least one
-- character when the text is non-empty so callers make progress.
local function take(text, cols, rctx)
  local out, used = {}, 0
  for ch in text:gmatch(utf8.charpattern) do
    local w = dw(ch, rctx)
    if used + w > cols and #out > 0 then
      break
    end
    out[#out + 1] = ch
    used = used + w
    if used >= cols then
      break
    end
  end
  return table.concat(out), used
end

-- Cut to `cols` display cells, ending with "…" when something was dropped.
local function cut(text, cols, rctx)
  text = sv(text)
  if cols <= 0 then
    return ""
  end
  if dw(text, rctx) <= cols then
    return text
  end
  if cols == 1 then
    return ELLIPSIS
  end
  local head = take(text, cols - 1, rctx)
  if dw(head, rctx) > cols - 1 then
    head = ""
  end
  return head .. ELLIPSIS
end
Display.fit = cut

local function spaces(n)
  return n > 0 and string.rep(" ", n) or ""
end

local function pad_right(text, cols, rctx)
  return text .. spaces(cols - dw(text, rctx))
end

local function pad_left(text, cols, rctx)
  return spaces(cols - dw(text, rctx)) .. text
end

local function span_text(sp)
  if type(sp) == "string" then
    return sp
  elseif type(sp) == "table" then
    return sv(sp[1])
  end
  return ""
end

local function span_style(sp)
  if type(sp) == "table" then
    local st = sp[2]
    if type(st) == "string" or type(st) == "table" then
      return st
    end
  end
  return ""
end

local function line_width(line, rctx)
  local w = 0
  if type(line) == "table" then
    for _, sp in ipairs(line) do
      w = w + dw(span_text(sp), rctx)
    end
  end
  return w
end
Display.line_width = line_width

-- Normalize whatever a markdown/highlight renderer returned into {{text, style}} lines.
local function normalize_line(line)
  if type(line) == "string" then
    return { { line, "" } }
  end
  local out = {}
  if type(line) == "table" then
    for _, sp in ipairs(line) do
      out[#out + 1] = { span_text(sp), span_style(sp) }
    end
  end
  return out
end
Display.normalize_line = normalize_line

-- Clamp a styled line to `cols`, cutting inside the span the limit falls in so
-- the ellipsis wears the style of the text it replaced (list_picker idiom).
local function clamp(line, cols, rctx)
  local out, used = {}, 0
  for _, sp in ipairs(normalize_line(line)) do
    local w = dw(sp[1], rctx)
    if used + w <= cols then
      out[#out + 1] = sp
      used = used + w
    else
      local head = cut(sp[1], cols - used, rctx)
      if #head > 0 then
        out[#out + 1] = { head, sp[2] }
      end
      break
    end
  end
  return out
end
Display.clamp = clamp

-- Pad (or clamp) a line to exactly `cols` cells; the filler takes `style`.
local function pad_line(line, cols, style, rctx)
  local norm = clamp(line, cols, rctx)
  local w = line_width(norm, rctx)
  if w < cols then
    norm[#norm + 1] = { spaces(cols - w), style or "" }
  end
  return norm
end
Display.pad = pad_line

-- Word wrap by display width; explicit newlines are kept, over-long words are
-- hard-cut. Always returns at least one line.
local function wrap(text, width, rctx)
  text = sv(text)
  width = math.max(math.floor(tonumber(width) or 1), 1)
  local out = {}
  for _, para in ipairs(split_lines(text)) do
    local cur, curw, emitted = {}, 0, false
    local function flush()
      out[#out + 1] = table.concat(cur, " ")
      cur, curw, emitted = {}, 0, true
    end
    for word in para:gmatch("%S+") do
      local ww = dw(word, rctx)
      if curw > 0 and curw + 1 + ww > width then
        flush()
      end
      while ww > width do
        if curw > 0 then
          flush()
        end
        local head = take(word, width, rctx)
        out[#out + 1] = head
        emitted = true
        word = word:sub(#head + 1)
        ww = dw(word, rctx)
      end
      if ww > 0 then
        cur[#cur + 1] = word
        curw = curw + (curw > 0 and 1 or 0) + ww
      end
    end
    if #cur > 0 then
      flush()
    elseif not emitted then
      out[#out + 1] = ""
    end
  end
  return out
end
Display.wrap = wrap

---------------------------------------------------------------------------
-- Shared renderer helpers
---------------------------------------------------------------------------

local function inner_width(rctx)
  return math.max((rctx.width or 80) - #INDENT, 4)
end

local function muted_line(text, rctx)
  return { { INDENT, "" }, { cut(text, inner_width(rctx), rctx), S("muted") } }
end

local function visible_children(comp)
  local out = {}
  if type(comp.children) == "table" then
    for _, kid in ipairs(comp.children) do
      if type(kid) == "table" and kid.hidden ~= true then
        out[#out + 1] = kid
      end
    end
  end
  return out
end

local function with_width(rctx, width)
  local sub = {}
  for k, v in pairs(rctx) do
    sub[k] = v
  end
  sub.width = width
  return sub
end

local function render_child(comp, rctx)
  local fn = Display.render_child
  if type(fn) ~= "function" then
    fn = require("genui.render").component
    Display.render_child = fn
  end
  return fn(comp, rctx)
end

-- Explicit lookup: `a and b or nil` would turn a `false` value into nil.
local function value_of(rctx, id)
  if type(rctx.values) ~= "table" or id == nil then
    return nil
  end
  return rctx.values[id]
end

local function positive_int(v, default)
  local n = tonumber(v)
  if n and n == n and n >= 1 then
    return math.floor(n)
  end
  return default
end

local function append_block(out, rows, lines, krows)
  local base = #out
  for i, l in ipairs(lines) do
    out[base + i] = l
  end
  if type(krows) == "table" then
    for off, key in pairs(krows) do
      if type(off) == "number" then
        rows[base + off] = key
      end
    end
  end
end

local function placeholder(comp, rctx)
  local label = comp.label ~= nil and sv(comp.label) or ""
  return { muted_line("[" .. tostring(comp.type) .. "] " .. label, rctx) }, {}
end

---------------------------------------------------------------------------
-- Containers
---------------------------------------------------------------------------

function R.stack(comp, rctx)
  local out, rows = {}, {}
  local prev_section_open = false
  for _, kid in ipairs(visible_children(comp)) do
    local lines, krows = render_child(kid, rctx)
    if #lines > 0 then
      local is_section = kid.type == "section"
      if #out > 0 and ((is_section and #lines > 1) or prev_section_open) then
        out[#out + 1] = {}
      end
      append_block(out, rows, lines, krows)
      prev_section_open = is_section and #lines > 1
    end
  end
  return out, rows
end

function R.row(comp, rctx)
  local kids = visible_children(comp)
  if #kids == 0 then
    return {}, {}
  end
  local gap = positive_int(comp.gap, 2)
  local width = rctx.width or 80
  local col_w = math.floor((width - gap * (#kids - 1)) / #kids)
  if #kids == 1 or width < 40 or col_w < 12 then
    return R.stack(comp, rctx)
  end
  local cols, height = {}, 0
  for i, kid in ipairs(kids) do
    local lines, krows = render_child(kid, with_width(rctx, col_w))
    cols[i] = { lines = lines, rows = krows or {} }
    height = math.max(height, #lines)
  end
  local out, rows = {}, {}
  for li = 1, height do
    local line = {}
    for i, c in ipairs(cols) do
      local src = c.lines[li] or {}
      local cell = i < #cols and pad_line(src, col_w, "", rctx) or clamp(src, col_w, rctx)
      for _, sp in ipairs(cell) do
        line[#line + 1] = sp
      end
      if i < #cols then
        line[#line + 1] = { spaces(gap), "" }
      end
      if c.rows[li] ~= nil and rows[li] == nil then
        rows[li] = c.rows[li]
      end
    end
    out[li] = line
  end
  return out, rows
end

-- Card: "▸ Title (n lines)" collapsed / "▾ Title" expanded; the header row
-- toggles. The toggle is a pure flip relative to `comp.collapsed`, so replayed
-- clicks land on the same state. Window: always open, no row map.
function R.section(comp, rctx)
  local title = comp.title ~= nil and sv(comp.title) or ""
  local key = "sec:" .. tostring(comp.id)
  local toggled = type(rctx.expanded) == "table" and rctx.expanded[key] == true
  local open = rctx.mode == "window" or ((comp.collapsed == true) == toggled)
  local lines, krows = R.stack(comp, rctx)
  local out, rows = {}, {}
  local arrow = open and "▾ " or "▸ "
  local suffix = open and "" or (" (" .. #lines .. (#lines == 1 and " line)" or " lines)"))
  local title_w = math.max((rctx.width or 80) - 2 - dw(suffix, rctx), 1)
  local head = { { arrow .. cut(title, title_w, rctx), S("section") } }
  if suffix ~= "" then
    head[#head + 1] = { suffix, S("hint") }
  end
  out[1] = head
  if rctx.mode ~= "window" then
    rows[1] = key
  end
  if open then
    append_block(out, rows, lines, krows)
  end
  return out, rows
end

---------------------------------------------------------------------------
-- Leaves
---------------------------------------------------------------------------

function R.text(comp, rctx)
  local text = sv(comp.text)
  if text == "" then
    return {}, {}
  end
  local tone = TONES[comp.tone] or ""
  local inner = inner_width(rctx)
  local md_lines
  if comp.markdown ~= false and type(rctx.markdown) == "function" then
    local ok, res = pcall(rctx.markdown, text, inner)
    if ok and type(res) == "table" and #res > 0 then
      md_lines = res
    end
  end
  if not md_lines then
    md_lines = {}
    for _, l in ipairs(wrap(text, inner, rctx)) do
      md_lines[#md_lines + 1] = { { l, "" } }
    end
  end
  local out = {}
  local total = #md_lines
  local limit = math.min(total, TEXT_MAX_LINES)
  for i = 1, limit do
    local line = { { INDENT, "" } }
    for _, sp in ipairs(normalize_line(md_lines[i])) do
      local st = sp[2]
      if tone ~= "" and (st == nil or st == "") then
        st = tone
      end
      line[#line + 1] = { sp[1], st }
    end
    out[#out + 1] = clamp(line, rctx.width, rctx)
  end
  if total > limit then
    out[#out + 1] = muted_line("… (+" .. (total - limit) .. " lines)", rctx)
  end
  return out, {}
end

local function kv_items(raw)
  local items = {}
  if type(raw) ~= "table" then
    return items
  end
  if raw[1] ~= nil then
    for _, it in ipairs(raw) do
      if type(it) == "table" then
        local key = it.key
        if key == nil then
          key = it.label
        end
        if key == nil then
          key = it[1]
        end
        local value = it.value
        if value == nil and it[2] ~= nil then
          value = it[2]
        end
        items[#items + 1] = { key = sv(key), value = value }
      else
        items[#items + 1] = { key = sv(it), value = "" }
      end
    end
    return items
  end
  local keys = {}
  for k, _ in pairs(raw) do
    keys[#keys + 1] = sv(k)
  end
  table.sort(keys)
  for _, k in ipairs(keys) do
    local v = raw[k]
    if v == nil then
      v = raw[tonumber(k)]
    end
    items[#items + 1] = { key = k, value = v }
  end
  return items
end

function R.kv(comp, rctx)
  local items = kv_items(comp.items)
  if #items == 0 then
    return { muted_line("(empty)", rctx) }, {}
  end
  local kw = 0
  for _, it in ipairs(items) do
    kw = math.max(kw, dw(it.key, rctx))
  end
  kw = math.min(kw, MAX_KEY_WIDTH)
  local explicit = positive_int(comp.key_width, nil)
  if explicit then
    kw = math.min(explicit, MAX_KEY_WIDTH * 2)
  end
  kw = math.min(kw, math.max(math.floor((rctx.width or 80) / 2), 1))
  local vw = math.max((rctx.width or 80) - #INDENT - kw - 2, 4)
  local out = {}
  for _, it in ipairs(items) do
    local key = pad_right(cut(it.key, kw, rctx), kw, rctx)
    local vlines = split_lines(sv(it.value))
    for j, vl in ipairs(vlines) do
      if j == 1 then
        out[#out + 1] = { { INDENT, "" }, { key, S("label") }, { "  ", "" }, { cut(vl, vw, rctx), S("value") } }
      else
        out[#out + 1] = { { INDENT .. spaces(kw + 2), "" }, { cut(vl, vw, rctx), S("value") } }
      end
    end
  end
  return out, {}
end

-- Column sizing shared by the card and the window widget. `width` is the
-- space available to the columns themselves (caller subtracts indent/markers).
function Display.table_layout(comp, width, rctx)
  width = math.max(math.floor(tonumber(width) or 0), 0)
  local cols = {}
  local raw_cols = type(comp.columns) == "table" and comp.columns or {}
  for i, c in ipairs(raw_cols) do
    if type(c) == "table" then
      local key = c.key
      if key == nil then
        key = c.label
      end
      if key == nil then
        key = i
      end
      local col = { key = key, label = sv(c.label ~= nil and c.label or key) }
      if c.align == "right" or c.align == "left" then
        col.align = c.align
      end
      col.fixed = positive_int(c.width, nil)
      cols[#cols + 1] = col
    else
      cols[#cols + 1] = { key = sv(c), label = sv(c) }
    end
  end
  local raw_rows = type(comp.rows) == "table" and comp.rows or {}
  if #cols == 0 and type(raw_rows[1]) == "table" then
    local first = raw_rows[1]
    if first[1] ~= nil then
      for i = 1, #first do
        cols[i] = { key = i, label = tostring(i) }
      end
    else
      local keys = {}
      for k, _ in pairs(first) do
        keys[#keys + 1] = sv(k)
      end
      table.sort(keys)
      for _, k in ipairs(keys) do
        cols[#cols + 1] = { key = k, label = k }
      end
    end
  end
  local rows, dropped = {}, 0
  for ri, r in ipairs(raw_rows) do
    if ri > TABLE_HARD_CAP then
      dropped = #raw_rows - TABLE_HARD_CAP
      break
    end
    local cells = {}
    for ci, col in ipairs(cols) do
      local v
      if type(r) == "table" then
        v = r[col.key]
        if v == nil and type(col.key) == "string" then
          v = r[tonumber(col.key)]
        end
        if v == nil then
          v = r[ci]
        end
      elseif ci == 1 then
        v = r
      end
      cells[ci] = split_lines(sv(v))[1]
    end
    rows[#rows + 1] = cells
  end
  for ci, col in ipairs(cols) do
    if not col.align then
      local numeric, any = true, false
      for _, cells in ipairs(rows) do
        local c = cells[ci]
        if c ~= "" then
          any = true
          if not tonumber(c) then
            numeric = false
            break
          end
        end
      end
      col.align = (any and numeric) and "right" or "left"
    end
    local w = dw(col.label, rctx)
    for _, cells in ipairs(rows) do
      w = math.max(w, dw(cells[ci], rctx))
    end
    if col.fixed then
      w = col.fixed
    end
    col.width = math.max(math.min(w, width), 1)
  end
  local gaps = math.max(#cols - 1, 0) * 2
  local total = 0
  for _, col in ipairs(cols) do
    total = total + col.width
  end
  while total + gaps > width do
    local wi, ww = nil, 0
    for ci, col in ipairs(cols) do
      if col.width > ww then
        wi, ww = ci, col.width
      end
    end
    if not wi or ww <= MIN_COL_WIDTH then
      break
    end
    cols[wi].width = ww - 1
    total = total - 1
  end
  return { cols = cols, rows = rows, width = total + gaps, dropped = dropped }
end

-- Identity of a row for selection values: the `key` column's cell, else the
-- 1-based index as a string (string keys keep the JSON round-trip dense).
function Display.row_key(comp, layout, ri)
  local cells = layout.rows[ri]
  if type(comp.key) == "string" and cells then
    for ci, col in ipairs(layout.cols) do
      if sv(col.key) == comp.key then
        return cells[ci]
      end
    end
  end
  return tostring(ri)
end

-- `last` skips the right padding of a left-aligned final column, so rows carry
-- no trailing whitespace into scrollback.
local function align_cell(text, w, align, rctx, last)
  local s = cut(text, w, rctx)
  if align == "right" then
    return pad_left(s, w, rctx)
  end
  if last then
    return s
  end
  return pad_right(s, w, rctx)
end

R["table"] = function(comp, rctx)
  local sel = comp.select
  if sel ~= "single" and sel ~= "multi" then
    sel = "none"
  end
  local value = value_of(rctx, comp.id)
  local show_marks = sel ~= "none" and rctx.mode ~= "window" and not is_null(value)
  local mark_w = show_marks and 4 or 0
  local width = rctx.width or 80
  local layout = Display.table_layout(comp, width - #INDENT - mark_w, rctx)
  if #layout.cols == 0 then
    return { muted_line("(empty table)", rctx) }, {}
  end
  local out, rows = {}, {}
  local header = { { INDENT .. spaces(mark_w), "" } }
  for ci, col in ipairs(layout.cols) do
    if ci > 1 then
      header[#header + 1] = { "  ", "" }
    end
    header[#header + 1] = { align_cell(col.label, col.width, col.align, rctx, ci == #layout.cols), S("label") }
  end
  out[1] = header
  local picked = {}
  if show_marks then
    if type(value) == "table" then
      for _, k in ipairs(value) do
        picked[sv(k)] = true
      end
    else
      picked[sv(value)] = true
    end
  end
  local max_rows = positive_int(comp.max_rows, TABLE_MAX_ROWS)
  local key = "tbl:" .. tostring(comp.id)
  local total = #layout.rows
  local expanded = type(rctx.expanded) == "table" and rctx.expanded[key] == true
  local limit = (expanded or rctx.mode == "window") and total or math.min(total, max_rows)
  for ri = 1, limit do
    local cells = layout.rows[ri]
    local line = { { INDENT, "" } }
    if show_marks then
      local on = picked[Display.row_key(comp, layout, ri)] == true
      local glyph
      if sel == "multi" then
        glyph = on and "[x] " or "[ ] "
      else
        glyph = on and "(•) " or "( ) "
      end
      line[#line + 1] = { glyph, on and S("success") or S("muted") }
    end
    for ci, col in ipairs(layout.cols) do
      if ci > 1 then
        line[#line + 1] = { "  ", "" }
      end
      line[#line + 1] = { align_cell(cells[ci], col.width, col.align, rctx, ci == #layout.cols), S("value") }
    end
    out[#out + 1] = line
  end
  if total == 0 then
    out[#out + 1] = muted_line("(no rows)", rctx)
  end
  if total > limit then
    out[#out + 1] = { { INDENT .. spaces(mark_w) .. "▼ " .. (total - limit) .. " more", S("hint") } }
    rows[#out] = key
  elseif expanded and total > max_rows then
    out[#out + 1] = { { INDENT .. spaces(mark_w) .. "▲ show fewer", S("hint") } }
    rows[#out] = key
  end
  if layout.dropped > 0 then
    out[#out + 1] = muted_line("… (+" .. layout.dropped .. " rows not shown)", rctx)
  end
  return out, rows
end

-- value: 0..1 | {done, total}. Returns fraction, done?, total?.
local function progress_value(v)
  if type(v) == "table" then
    local done, total = tonumber(v.done), tonumber(v.total)
    if not done or done ~= done then
      done = 0
    end
    if not total or total ~= total or total <= 0 then
      return done > 0 and 1 or 0, done, total or 0
    end
    return math.max(0, math.min(done / total, 1)), done, total
  end
  local n = tonumber(v)
  if not n or n ~= n then
    return 0, nil, nil
  end
  return math.max(0, math.min(n, 1)), nil, nil
end

function R.progress(comp, rctx)
  local frac, done, total = progress_value(comp.value)
  local status = comp.status
  if status ~= "done" and status ~= "error" then
    status = "running"
  end
  local icon
  if status == "running" then
    icon = { "⠋ ", "spinner:" .. S("spinner") }
  elseif status == "done" then
    icon = { "✓ ", S("success") }
  else
    icon = { "✗ ", S("error") }
  end
  local label = comp.label ~= nil and sv(comp.label) or ""
  local pct = string.format("%3d%%", math.floor(frac * 100 + 0.5))
  local tail = done ~= nil and ("  (" .. fmt_num(done) .. "/" .. fmt_num(total) .. ")") or ""
  local width = rctx.width or 80
  local fixed = #INDENT + 2 + 1 + #pct + dw(tail, rctx)
  local label_w = dw(label, rctx)
  local label_cost = label_w > 0 and label_w + 1 or 0
  local bar_cells = BAR_CELLS
  local room = width - fixed - label_cost
  if room < bar_cells then
    bar_cells = math.max(room, 5)
    local over = fixed + label_cost + bar_cells - width
    if over > 0 and label_w > 0 then
      label = cut(label, math.max(label_w - over, 3), rctx)
    end
  end
  local filled = math.floor(frac * bar_cells + 0.5)
  local line = { { INDENT, "" }, icon }
  if label ~= "" then
    line[#line + 1] = { label .. " ", S("label") }
  end
  line[#line + 1] = { string.rep("█", filled), S("bar_fill") }
  line[#line + 1] = { string.rep("░", bar_cells - filled), S("bar_empty") }
  line[#line + 1] = { " " .. pct, S("value") }
  if tail ~= "" then
    line[#line + 1] = { tail, S("muted") }
  end
  return { clamp(line, width, rctx) }, {}
end

function R.divider(comp, rctx)
  local w = math.max(rctx.width or 80, 1)
  local label = comp.label ~= nil and sv(comp.label) or ""
  if label == "" then
    return { { { string.rep("─", w), S("rule") } } }, {}
  end
  label = cut(label, math.max(w - 8, 1), rctx)
  local lw = dw(label, rctx)
  local left = math.max(math.floor((w - lw - 2) / 2), 1)
  local right = math.max(w - lw - 2 - left, 1)
  return {
    {
      { string.rep("─", left) .. " ", S("rule") },
      { label, S("label") },
      { " " .. string.rep("─", right), S("rule") },
    },
  }, {}
end

function R.bars(comp, rctx)
  local items = {}
  if type(comp.items) == "table" then
    for i, it in ipairs(comp.items) do
      if i > BARS_CAP then
        break
      end
      local v, label
      if type(it) == "table" then
        v = tonumber(it.value)
        label = sv(it.label)
      else
        v = tonumber(it)
        label = ""
      end
      if not v or v ~= v then
        v = 0
      end
      items[#items + 1] = { label = label, value = v }
    end
  end
  if #items == 0 then
    return { muted_line("(no data)", rctx) }, {}
  end
  local unit = comp.unit ~= nil and sv(comp.unit) or ""
  local max = tonumber(comp.max)
  if not max or max ~= max or max <= 0 then
    max = 0
    for _, it in ipairs(items) do
      max = math.max(max, it.value)
    end
  end
  if max <= 0 then
    max = 1
  end
  local width = rctx.width or 80
  local label_w, val_w = 0, 0
  for _, it in ipairs(items) do
    it.text = fmt_num(it.value) .. unit
    label_w = math.max(label_w, dw(it.label, rctx))
    val_w = math.max(val_w, dw(it.text, rctx))
  end
  label_w = math.min(label_w, math.max(math.floor(width / 4), 4))
  local bar_w = math.max(width - #INDENT - label_w - 2 - val_w, 4)
  local out = {}
  for _, it in ipairs(items) do
    local frac = math.max(0, math.min(it.value / max, 1))
    local cells = frac * bar_w
    local full = math.floor(cells)
    local rem = math.floor((cells - full) * 8 + 0.5)
    if rem >= 8 then
      full, rem = full + 1, 0
    end
    full = math.min(full, bar_w)
    local bar = string.rep("█", full) .. ((rem > 0 and full < bar_w) and EIGHTHS[rem] or "")
    local bar_len = full + ((rem > 0 and full < bar_w) and 1 or 0)
    local line = {
      { INDENT, "" },
      { pad_right(cut(it.label, label_w, rctx), label_w, rctx), S("label") },
      { " ", "" },
      { bar, S("bar_fill") },
      { spaces(bar_w - bar_len) .. " ", "" },
      { pad_left(it.text, val_w, rctx), S("value") },
    }
    out[#out + 1] = clamp(line, width, rctx)
  end
  return out, {}
end

function R.sparkline(comp, rctx)
  local vals = {}
  if type(comp.values) == "table" then
    for i, v in ipairs(comp.values) do
      if i > SPARK_CAP then
        break
      end
      local n = tonumber(v)
      if n and n == n and n ~= math.huge and n ~= -math.huge then
        vals[#vals + 1] = n
      end
    end
  end
  local label = comp.label ~= nil and sv(comp.label) or ""
  if #vals == 0 then
    return { muted_line((label ~= "" and label .. " " or "") .. "(no data)", rctx) }, {}
  end
  local width = rctx.width or 80
  if label ~= "" then
    label = cut(label, math.max(math.floor(width / 3), 1), rctx)
  end
  local prefix_w = #INDENT + (label ~= "" and dw(label, rctx) + 1 or 0)
  local room = math.max(width - prefix_w, 1)
  local lo, hi = math.huge, -math.huge
  for _, n in ipairs(vals) do
    lo = math.min(lo, n)
    hi = math.max(hi, n)
  end
  local glyphs = {}
  for i = math.max(#vals - room + 1, 1), #vals do
    local lvl = 4
    if hi > lo then
      lvl = math.floor((vals[i] - lo) / (hi - lo) * 7 + 0.5) + 1
    end
    glyphs[#glyphs + 1] = SPARK[math.max(1, math.min(lvl, 8))]
  end
  local line = { { INDENT, "" } }
  if label ~= "" then
    line[#line + 1] = { label .. " ", S("label") }
  end
  line[#line + 1] = { table.concat(glyphs), S("bar_fill") }
  local range = " " .. fmt_num(lo) .. "–" .. fmt_num(hi)
  if #glyphs + dw(range, rctx) <= room then
    line[#line + 1] = { range, S("muted") }
  end
  return { line }, {}
end

---------------------------------------------------------------------------
-- Diff
---------------------------------------------------------------------------

local function count_lines(s)
  return #split_lines(s)
end

-- Unified diff text -> { hunks = {{header, old_start, new_start, lines = {{kind, text, old_nr?, new_nr?}}}},
--                        header = {string}, path = string? }
function Display.parse_diff(text)
  local res = { hunks = {}, header = {} }
  if type(text) ~= "string" then
    return res
  end
  local cur, old_nr, new_nr
  for _, raw in ipairs(split_lines(text)) do
    local line = (raw:gsub("\r$", ""))
    local os_, oc, ns, nc = line:match("^@@%s*%-(%d+),?(%d*)%s+%+(%d+),?(%d*)%s*@@")
    if os_ then
      old_nr, new_nr = tonumber(os_), tonumber(ns)
      cur = {
        header = line,
        old_start = old_nr,
        new_start = new_nr,
        old_count = tonumber(oc) or 1,
        new_count = tonumber(nc) or 1,
        context = (line:match("@@[^@]*@@%s?(.*)$") or ""),
        lines = {},
      }
      res.hunks[#res.hunks + 1] = cur
    elseif cur then
      local kind = line:sub(1, 1)
      local body = line:sub(2)
      if kind == "-" then
        cur.lines[#cur.lines + 1] = { kind = "-", text = body, old_nr = old_nr }
        old_nr = old_nr + 1
      elseif kind == "+" then
        cur.lines[#cur.lines + 1] = { kind = "+", text = body, new_nr = new_nr }
        new_nr = new_nr + 1
      elseif kind == "\\" then
        cur.lines[#cur.lines + 1] = { kind = "\\", text = body }
      else
        if kind ~= " " then
          body = line
        end
        cur.lines[#cur.lines + 1] = { kind = " ", text = body, old_nr = old_nr, new_nr = new_nr }
        old_nr = old_nr + 1
        new_nr = new_nr + 1
      end
    else
      res.header[#res.header + 1] = line
      local p = line:match("^%+%+%+ [ab]/(.+)$") or line:match("^%+%+%+ (.+)$")
      if p and p ~= "/dev/null" then
        res.path = (p:gsub("\t.*$", ""))
      end
    end
  end
  -- A bare +/- listing without "@@" markers: treat it as one unnumbered hunk.
  if #res.hunks == 0 then
    local lines, seen = {}, false
    for _, line in ipairs(res.header) do
      local kind = line:sub(1, 1)
      if (kind == "+" or kind == "-") and not line:match("^[%+%-][%+%-][%+%-]") then
        seen = true
        lines[#lines + 1] = { kind = kind, text = line:sub(2) }
      elseif not line:match("^diff ") and not line:match("^index ") and not line:match("^[%+%-][%+%-][%+%-] ") then
        lines[#lines + 1] = { kind = " ", text = kind == " " and line:sub(2) or line }
      end
    end
    if seen then
      res.hunks[1] =
        { header = "@@ @@", old_start = 1, new_start = 1, old_count = 0, new_count = 0, context = "", lines = lines }
      res.header = {}
    end
  end
  return res
end

-- Unified diff of two texts: common prefix/suffix stripped, LCS on the middle
-- (falls back to "all removed, all added" above LCS_CELL_CAP cells).
function Display.line_diff(before, after)
  local a, b = split_lines(sv(before)), split_lines(sv(after))
  if #a > 0 and a[#a] == "" then
    a[#a] = nil
  end
  if #b > 0 and b[#b] == "" then
    b[#b] = nil
  end
  local n, m = #a, #b
  local pre = 0
  while pre < n and pre < m and a[pre + 1] == b[pre + 1] do
    pre = pre + 1
  end
  local suf = 0
  while suf < n - pre and suf < m - pre and a[n - suf] == b[m - suf] do
    suf = suf + 1
  end
  local ops = {}
  for i = 1, pre do
    ops[#ops + 1] = " " .. a[i]
  end
  local an, bn = n - pre - suf, m - pre - suf
  if an > 0 and bn > 0 and an * bn <= LCS_CELL_CAP then
    local W = bn + 1
    local L = table.create and table.create((an + 1) * W, 0) or {}
    local function at(i, j)
      return L[(i - 1) * W + j] or 0
    end
    for i = an, 1, -1 do
      for j = bn, 1, -1 do
        local v
        if a[pre + i] == b[pre + j] then
          v = at(i + 1, j + 1) + 1
        else
          v = math.max(at(i + 1, j), at(i, j + 1))
        end
        L[(i - 1) * W + j] = v
      end
    end
    local i, j = 1, 1
    while i <= an and j <= bn do
      if a[pre + i] == b[pre + j] then
        ops[#ops + 1] = " " .. a[pre + i]
        i, j = i + 1, j + 1
      elseif at(i + 1, j) >= at(i, j + 1) then
        ops[#ops + 1] = "-" .. a[pre + i]
        i = i + 1
      else
        ops[#ops + 1] = "+" .. b[pre + j]
        j = j + 1
      end
    end
    while i <= an do
      ops[#ops + 1] = "-" .. a[pre + i]
      i = i + 1
    end
    while j <= bn do
      ops[#ops + 1] = "+" .. b[pre + j]
      j = j + 1
    end
  else
    for i = 1, an do
      ops[#ops + 1] = "-" .. a[pre + i]
    end
    for j = 1, bn do
      ops[#ops + 1] = "+" .. b[pre + j]
    end
  end
  for i = n - suf + 1, n do
    ops[#ops + 1] = " " .. a[i]
  end
  if #ops == 0 then
    return ""
  end
  return "@@ -1," .. n .. " +1," .. m .. " @@\n" .. table.concat(ops, "\n")
end

local DECISION_STYLE = { accept = "success", reject = "error" }

function R.diff(comp, rctx)
  local text = comp.text
  if type(text) ~= "string" or text == "" then
    if not is_null(comp.before) or not is_null(comp.after) then
      text = Display.line_diff(sv(comp.before), sv(comp.after))
    else
      text = ""
    end
  end
  local parsed = Display.parse_diff(text)
  local width = rctx.width or 80
  local inner = inner_width(rctx)
  local out, rows = {}, {}
  local path = comp.path ~= nil and sv(comp.path) or parsed.path
  if path and path ~= "" then
    out[#out + 1] = { { INDENT, "" }, { cut(path, inner, rctx), S("path") } }
  end
  if #parsed.hunks == 0 then
    out[#out + 1] = muted_line("(empty diff)", rctx)
    return out, rows
  end
  local decisions = {}
  local value = value_of(rctx, comp.id)
  if type(value) == "table" then
    for k, d in pairs(value) do
      if type(d) == "table" then
        d = d.decision
      end
      decisions[tostring(k)] = d
    end
  end
  local show_decisions = comp.decide == true or next(decisions) ~= nil
  local max_old, max_new = 0, 0
  for _, hunk in ipairs(parsed.hunks) do
    for _, dl in ipairs(hunk.lines) do
      max_old = math.max(max_old, dl.old_nr or 0)
      max_new = math.max(max_new, dl.new_nr or 0)
    end
  end
  local ow, nw = #tostring(max_old), #tostring(max_new)
  local text_w = math.max(width - #INDENT - ow - 2 - nw - 3, 4)
  local budget = positive_int(comp.max_lines, DIFF_MAX_LINES)
  local truncated = 0
  for hi, hunk in ipairs(parsed.hunks) do
    local key = "hunk:" .. tostring(comp.id) .. ":" .. hi
    local in_card = rctx.mode ~= "window"
    local collapsed = in_card and type(rctx.expanded) == "table" and rctx.expanded[key] == true
    local marker, mstyle = "", ""
    if show_decisions then
      local d = decisions[tostring(hi)]
      if d == "accept" or d == "reject" then
        marker, mstyle = "[" .. d .. "]", S(DECISION_STYLE[d])
      else
        marker, mstyle = "[ ? ]", S("warning")
      end
    end
    local arrow = in_card and (collapsed and "▸ " or "▾ ") or ""
    local counts = ""
    if collapsed then
      local minus, plus = 0, 0
      for _, dl in ipairs(hunk.lines) do
        if dl.kind == "-" then
          minus = minus + 1
        elseif dl.kind == "+" then
          plus = plus + 1
        end
      end
      counts = " (−" .. minus .. " +" .. plus .. ")"
    end
    local mw = dw(marker, rctx)
    local head_w = width - #INDENT - dw(arrow, rctx) - dw(counts, rctx) - (mw > 0 and mw + 1 or 0)
    local htext = cut(hunk.header, math.max(head_w, 4), rctx)
    local line = { { INDENT .. arrow, S("hunk") }, { htext, S("hunk") } }
    if counts ~= "" then
      line[#line + 1] = { counts, S("hint") }
    end
    if mw > 0 then
      line[#line + 1] = { spaces(head_w - dw(htext, rctx) + 1), "" }
      line[#line + 1] = { marker, mstyle }
    end
    out[#out + 1] = clamp(line, width, rctx)
    if in_card then
      rows[#out] = key
    end
    if not collapsed then
      for _, dl in ipairs(hunk.lines) do
        if budget <= 0 then
          truncated = truncated + 1
        else
          budget = budget - 1
          local nr = pad_left(dl.old_nr and tostring(dl.old_nr) or "", ow, rctx)
            .. "  "
            .. pad_left(dl.new_nr and tostring(dl.new_nr) or "", nw, rctx)
          local style, sign = S("value"), " "
          if dl.kind == "-" then
            style, sign = S("diff_old"), "-"
          elseif dl.kind == "+" then
            style, sign = S("diff_new"), "+"
          elseif dl.kind == "\\" then
            style, sign = S("muted"), "\\"
          end
          out[#out + 1] = {
            { INDENT, "" },
            { nr, S("line_nr") },
            { " " .. sign .. " ", style },
            { cut(sv(dl.text), text_w, rctx), style },
          }
        end
      end
    end
  end
  if truncated > 0 then
    out[#out + 1] = muted_line("… (+" .. truncated .. " lines)", rctx)
  end
  return out, rows
end

---------------------------------------------------------------------------
-- P1 display leaves
---------------------------------------------------------------------------

function R.badge(comp, rctx)
  local text = comp.text ~= nil and sv(comp.text) or ""
  local style = TONES[comp.tone] or S("label")
  if style == "" then
    style = S("label")
  end
  return { { { INDENT, "" }, { " ● " .. cut(text, math.max(inner_width(rctx) - 4, 1), rctx) .. " ", style } } }, {}
end

function R.checklist(comp, rctx)
  local out = {}
  if type(comp.items) == "table" then
    for _, it in ipairs(comp.items) do
      local text, done
      if type(it) == "table" then
        text, done = sv(it.text ~= nil and it.text or it.label), it.done == true
      else
        text, done = sv(it), false
      end
      local glyph = done and "[✓] " or "[ ] "
      out[#out + 1] = {
        { INDENT, "" },
        { glyph .. cut(text, math.max(inner_width(rctx) - 4, 1), rctx), done and S("done") or S("pending") },
      }
    end
  end
  if #out == 0 then
    out[1] = muted_line("(empty checklist)", rctx)
  end
  return out, {}
end

function R.unknown(comp, rctx)
  local orig = comp.original
  if orig == nil then
    orig = comp.type
  end
  return { { { INDENT, "" }, { cut("⚠ unknown component " .. sv(orig), inner_width(rctx), rctx), S("warning") } } }, {}
end

---------------------------------------------------------------------------
-- Inputs in their submitted state (card mode). Window mode is rendered by
-- genui.widgets.inputs; here they get a placeholder line.
---------------------------------------------------------------------------

-- "  Label  ✓ value" on one line when the single answer fits, else the label
-- line followed by one "    ✓ value" line per answer (question card idiom).
local function answer_lines(label, answers, rctx)
  local width = rctx.width or 80
  local inner = inner_width(rctx)
  label = cut(label, math.max(math.floor(width / 2), 4), rctx)
  local lw = dw(label, rctx)
  if #answers == 0 then
    return { { { INDENT, "" }, { label, S("label") }, { "  " .. cut(NO_ANSWER, inner - lw - 2, rctx), S("muted") } } }
  end
  if #answers == 1 and not answers[1]:find("\n", 1, true) and lw + 4 + dw(answers[1], rctx) <= inner then
    return { { { INDENT, "" }, { label, S("label") }, { "  ✓ ", S("success") }, { answers[1], S("success") } } }
  end
  local out = { { { INDENT, "" }, { label, S("label") } } }
  for _, ans in ipairs(answers) do
    for j, piece in ipairs(split_lines(ans)) do
      out[#out + 1] = {
        { INDENT .. (j == 1 and "  ✓ " or "    "), S("success") },
        { cut(piece, inner - 4, rctx), S("success") },
      }
    end
  end
  return out
end

local function option_label(options, v)
  if type(options) == "table" then
    for _, opt in ipairs(options) do
      if type(opt) == "table" then
        local val = opt.value
        if val == nil then
          val = opt.label
        end
        if val ~= nil and sv(val) == v then
          return sv(opt.label ~= nil and opt.label or val)
        end
      elseif sv(opt) == v then
        return v
      end
    end
  end
  return v
end

function R.choice(comp, rctx)
  if rctx.mode == "window" then
    return placeholder(comp, rctx)
  end
  local label = comp.label ~= nil and sv(comp.label) or ""
  local value = value_of(rctx, comp.id)
  local answers = {}
  if type(value) == "table" then
    for _, v in ipairs(value) do
      if not is_null(v) then
        answers[#answers + 1] = option_label(comp.options, sv(v))
      end
    end
  elseif not is_null(value) then
    answers[1] = option_label(comp.options, sv(value))
  end
  return answer_lines(label, answers, rctx), {}
end

function R.input(comp, rctx)
  if rctx.mode == "window" then
    return placeholder(comp, rctx)
  end
  local label = comp.label ~= nil and sv(comp.label) or ""
  local value = value_of(rctx, comp.id)
  local answers = {}
  if not is_null(value) and sv(value) ~= "" then
    answers[1] = sv(value)
  end
  return answer_lines(label, answers, rctx), {}
end

function R.number(comp, rctx)
  if rctx.mode == "window" then
    return placeholder(comp, rctx)
  end
  local label = comp.label ~= nil and sv(comp.label) or ""
  local value = value_of(rctx, comp.id)
  local answers = {}
  if not is_null(value) and sv(value) ~= "" then
    answers[1] = sv(value)
  end
  return answer_lines(label, answers, rctx), {}
end

function R.confirm(comp, rctx)
  if rctx.mode == "window" then
    return placeholder(comp, rctx)
  end
  local label = comp.label ~= nil and sv(comp.label) or ""
  local value = value_of(rctx, comp.id)
  local answers = {}
  if type(value) == "boolean" then
    answers[1] = value and "Yes" or "No"
  elseif type(value) == "string" and value ~= "" then
    answers[1] = value
  end
  return answer_lines(label, answers, rctx), {}
end

-- The pressed action is reported on the card's status line (Render.card_lines),
-- so the button row itself is spent information in scrollback.
function R.actions(comp, rctx)
  if rctx.mode == "window" then
    local parts = {}
    if type(comp.items) == "table" then
      for _, it in ipairs(comp.items) do
        if type(it) == "table" then
          parts[#parts + 1] = "[ " .. sv(it.label ~= nil and it.label or it.action) .. " ]"
        end
      end
    end
    return { muted_line(table.concat(parts, "   "), rctx) }, {}
  end
  return {}, {}
end

Display.INDENT = INDENT
Display.ELLIPSIS = ELLIPSIS
Display.count_lines = count_lines
Display.is_null = is_null

return Display
