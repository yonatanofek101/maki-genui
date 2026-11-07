-- Pure spec -> styled lines. Everything host-dependent (display width,
-- markdown) is injected through the RenderCtx so specs run without maki.ui.
--
-- Render.component(comp, rctx) -> lines, rows
--   lines: {StyledLine} fitted to rctx.width
--   rows:  {[line offset] = toggle key} for click handlers (card mode only)
local Display = require("genui.widgets.display")

local Render = {
  CARD_WIDTH = 80,
  STYLES = Display.STYLES,
}

Display.render_child = nil -- set below, once Render.component exists

local INDENT = Display.INDENT
local WARNINGS_SHOWN = 5

local function S(name)
  return Render.STYLES[name] or ""
end

local function fallback_width(s)
  return utf8.len(s) or #s
end

local function plain_markdown(text, width)
  local out = {}
  for _, l in ipairs(Display.wrap(text, width, nil)) do
    out[#out + 1] = { { l, "" } }
  end
  return out
end

-- opts: width?, values?, expanded?, mode? ("card"|"window"), action?,
-- markdown?, display_width? (the last two override the maki.ui defaults).
function Render.ctx(opts)
  opts = opts or {}
  local ui = type(maki) == "table" and maki.ui or nil
  local markdown = opts.markdown
  if type(markdown) ~= "function" then
    if ui and type(ui.markdown) == "function" then
      markdown = function(text, width)
        local ok, lines = pcall(ui.markdown, text, width)
        if ok and type(lines) == "table" and #lines > 0 then
          return lines
        end
        return plain_markdown(text, width)
      end
    else
      markdown = plain_markdown
    end
  end
  local display_width = opts.display_width
  if type(display_width) ~= "function" then
    if ui and type(ui.display_width) == "function" then
      display_width = ui.display_width
    else
      display_width = fallback_width
    end
  end
  return {
    width = math.max(math.floor(tonumber(opts.width) or Render.CARD_WIDTH), 8),
    markdown = markdown,
    display_width = display_width,
    values = opts.values,
    expanded = type(opts.expanded) == "table" and opts.expanded or {},
    mode = opts.mode == "window" and "window" or "card",
    action = opts.action,
  }
end

local function error_line(msg, rctx)
  return { { INDENT, "" }, { Display.fit(msg, math.max(rctx.width - #INDENT, 4), rctx), S("error") } }
end

-- Display rendering of ANY component. Inputs render their value in card mode
-- (rctx.values) or a placeholder in window mode. Never raises: a renderer
-- error becomes one visible line in the error style.
function Render.component(comp, rctx)
  rctx = rctx or Render.ctx()
  if type(comp) ~= "table" then
    return { { { INDENT .. "⚠ invalid component", S("warning") } } }, {}
  end
  if comp.hidden == true then
    return {}, {}
  end
  local fn = Display.renderers[comp.type] or Display.renderers.unknown
  local ok, lines, rows = pcall(fn, comp, rctx)
  if not ok then
    return { error_line("⚠ render error in " .. tostring(comp.type) .. ": " .. tostring(lines), rctx) }, {}
  end
  if type(lines) ~= "table" then
    lines = {}
  end
  if type(rows) ~= "table" then
    rows = {}
  end
  local out = {}
  for i, line in ipairs(lines) do
    out[i] = Display.clamp(line, rctx.width, rctx)
  end
  return out, rows
end

Display.render_child = Render.component

local STATUS_LINES = {
  cancelled = { "✗ Cancelled by user", "muted" },
  unavailable = { "⚠ No interactive UI attached; rendered as text", "warning" },
  error = { "✗ Error", "error" },
}

local FINAL_GLYPH = { done = { "✓", "success" }, error = { "✗", "error" }, cancelled = { "✗", "muted" } }

-- Title line + status line + component(root) + optional final line (closed
-- live widgets, st.final = {status, note}) + warnings footer.
function Render.card_lines(spec, st, rctx)
  rctx = rctx or Render.ctx()
  st = type(st) == "table" and st or {}
  spec = type(spec) == "table" and spec or {}
  local out, rows = {}, {}
  local function emit(line)
    out[#out + 1] = line
  end
  local width = rctx.width

  if type(spec.title) == "string" and spec.title ~= "" then
    emit({ { Display.fit(spec.title, width, rctx), S("title") } })
  end
  local status = STATUS_LINES[st.status]
  if status then
    emit({ { Display.fit(status[1], width, rctx), S(status[2]) } })
  elseif st.status == "submitted" and type(st.action) == "string" and st.action ~= "" then
    emit({ { Display.fit("✓ " .. st.action, width, rctx), S("success") } })
  end

  if type(spec.root) == "table" then
    local sub = {}
    for k, v in pairs(rctx) do
      sub[k] = v
    end
    if sub.values == nil then
      sub.values = st.values
    end
    if sub.action == nil then
      sub.action = st.action
    end
    local lines, crows = Render.component(spec.root, sub)
    local base = #out
    for i, l in ipairs(lines) do
      out[base + i] = l
    end
    for off, key in pairs(crows) do
      if type(off) == "number" then
        rows[base + off] = key
      end
    end
  else
    emit({ { INDENT .. "⚠ empty spec", S("warning") } })
  end

  if type(st.final) == "table" then
    local g = FINAL_GLYPH[st.final.status] or FINAL_GLYPH.done
    local text = g[1] .. " " .. Display.sv(st.final.status or "done")
    if not Display.is_null(st.final.note) and Display.sv(st.final.note) ~= "" then
      text = text .. ": " .. Display.sv(st.final.note)
    end
    emit({ { Display.fit(text, width, rctx), S(g[2]) } })
  end

  local warns = st.warnings
  if type(warns) ~= "table" then
    warns = spec.warnings
  end
  if type(warns) == "table" and #warns > 0 then
    for i, w in ipairs(warns) do
      if i > WARNINGS_SHOWN then
        emit({ { "⚠ … (+" .. (#warns - WARNINGS_SHOWN) .. " warnings)", S("warning") } })
        break
      end
      emit({ { Display.fit("⚠ " .. Display.sv(w), width, rctx), S("warning") } })
    end
  end
  return out, rows
end

---------------------------------------------------------------------------
-- Headless fallback: the spec as plain markdown (design.md §7)
---------------------------------------------------------------------------

local sv = Display.sv

local function md_label(comp)
  return "**" .. sv(comp.label ~= nil and comp.label or comp.id) .. "**"
end

local md_node

local function md_children(comp, out, depth)
  if type(comp.children) == "table" then
    for _, kid in ipairs(comp.children) do
      md_node(kid, out, depth)
    end
  end
end

md_node = function(comp, out, depth)
  if type(comp) ~= "table" or comp.hidden == true then
    return
  end
  local t = comp.type
  if t == "stack" or t == "row" then
    md_children(comp, out, depth)
  elseif t == "section" then
    out[#out + 1] = ""
    out[#out + 1] = string.rep("#", math.min(depth + 2, 6)) .. " " .. sv(comp.title)
    md_children(comp, out, depth + 1)
  elseif t == "text" then
    out[#out + 1] = sv(comp.text)
  elseif t == "kv" then
    local items = type(comp.items) == "table" and comp.items or {}
    if items[1] ~= nil then
      for _, it in ipairs(items) do
        if type(it) == "table" then
          out[#out + 1] = "- " .. sv(it.key ~= nil and it.key or it.label) .. ": " .. sv(it.value)
        end
      end
    else
      local keys = {}
      for k, _ in pairs(items) do
        keys[#keys + 1] = sv(k)
      end
      table.sort(keys)
      for _, k in ipairs(keys) do
        out[#out + 1] = "- " .. k .. ": " .. sv(items[k])
      end
    end
  elseif t == "table" then
    local layout = Display.table_layout(comp, 1000, nil)
    if #layout.cols > 0 then
      local head, sep = {}, {}
      for _, col in ipairs(layout.cols) do
        head[#head + 1] = col.label
        sep[#sep + 1] = "---"
      end
      out[#out + 1] = "| " .. table.concat(head, " | ") .. " |"
      out[#out + 1] = "| " .. table.concat(sep, " | ") .. " |"
      for ri, cells in ipairs(layout.rows) do
        if ri > 50 then
          out[#out + 1] = "… (+" .. (#layout.rows - 50) .. " rows)"
          break
        end
        out[#out + 1] = "| " .. table.concat(cells, " | ") .. " |"
      end
      if comp.select == "single" or comp.select == "multi" then
        out[#out + 1] = "(select " .. comp.select .. ", id " .. sv(comp.id) .. ")"
      end
    end
  elseif t == "bars" then
    if type(comp.items) == "table" then
      for _, it in ipairs(comp.items) do
        if type(it) == "table" then
          out[#out + 1] = "- " .. sv(it.label) .. ": " .. sv(it.value) .. sv(comp.unit)
        end
      end
    end
  elseif t == "sparkline" then
    local parts = {}
    if type(comp.values) == "table" then
      for i, v in ipairs(comp.values) do
        if i > 30 then
          parts[#parts + 1] = "…"
          break
        end
        parts[#parts + 1] = sv(v)
      end
    end
    out[#out + 1] = (comp.label ~= nil and (sv(comp.label) .. ": ") or "") .. table.concat(parts, ", ")
  elseif t == "progress" then
    local v = comp.value
    local text
    if type(v) == "table" then
      text = sv(v.done) .. "/" .. sv(v.total)
    else
      local n = tonumber(v) or 0
      text = Display.fmt_num(math.floor(math.max(0, math.min(n, 1)) * 100 + 0.5)) .. "%"
    end
    out[#out + 1] = (comp.label ~= nil and (sv(comp.label) .. ": ") or "")
      .. text
      .. " ("
      .. sv(comp.status or "running")
      .. ")"
  elseif t == "divider" then
    out[#out + 1] = comp.label ~= nil and ("--- " .. sv(comp.label) .. " ---") or "---"
  elseif t == "badge" then
    out[#out + 1] = "[" .. sv(comp.text) .. "]"
  elseif t == "checklist" then
    if type(comp.items) == "table" then
      for _, it in ipairs(comp.items) do
        if type(it) == "table" then
          out[#out + 1] = "- [" .. (it.done == true and "x" or " ") .. "] " .. sv(it.text)
        else
          out[#out + 1] = "- [ ] " .. sv(it)
        end
      end
    end
  elseif t == "diff" then
    local text = comp.text
    if type(text) ~= "string" or text == "" then
      text = Display.line_diff(sv(comp.before), sv(comp.after))
    end
    if comp.path ~= nil then
      out[#out + 1] = sv(comp.path)
    end
    out[#out + 1] = "```diff"
    out[#out + 1] = text
    out[#out + 1] = "```"
    if comp.decide == true then
      out[#out + 1] = "(accept/reject per hunk, id " .. sv(comp.id) .. ")"
    end
  elseif t == "choice" then
    out[#out + 1] = md_label(comp)
      .. (comp.multi == true and " (pick any)" or " (pick one)")
      .. " ["
      .. sv(comp.id)
      .. "]"
    if type(comp.options) == "table" then
      for _, opt in ipairs(comp.options) do
        if type(opt) == "table" then
          local line = "- " .. sv(opt.label ~= nil and opt.label or opt.value)
          if not Display.is_null(opt.description) and sv(opt.description) ~= "" then
            line = line .. " — " .. sv(opt.description)
          end
          out[#out + 1] = line
        else
          out[#out + 1] = "- " .. sv(opt)
        end
      end
    end
    if comp.other ~= false then
      out[#out + 1] = "- (or type your own answer)"
    end
  elseif t == "input" then
    local hint = comp.multiline == true and "text, multiline" or "text"
    if not Display.is_null(comp.placeholder) then
      hint = hint .. ", e.g. " .. sv(comp.placeholder)
    end
    out[#out + 1] = md_label(comp) .. " (" .. hint .. ") [" .. sv(comp.id) .. "]"
  elseif t == "number" then
    local hint = "number"
    if comp.min ~= nil or comp.max ~= nil then
      hint = hint .. " " .. sv(comp.min) .. "–" .. sv(comp.max)
    end
    out[#out + 1] = md_label(comp) .. " (" .. hint .. ") [" .. sv(comp.id) .. "]"
  elseif t == "confirm" then
    out[#out + 1] = md_label(comp) .. " (yes/no) [" .. sv(comp.id) .. "]"
  elseif t == "actions" then
    local parts = {}
    if type(comp.items) == "table" then
      for _, it in ipairs(comp.items) do
        if type(it) == "table" then
          parts[#parts + 1] = "[" .. sv(it.label ~= nil and it.label or it.action) .. "]"
        end
      end
    end
    out[#out + 1] = "Actions: " .. table.concat(parts, " ")
  else
    out[#out + 1] = "(unknown component " .. sv(comp.original ~= nil and comp.original or t) .. ")"
  end
end

function Render.to_markdown(spec)
  local out = {}
  if type(spec) ~= "table" then
    return "(ui)"
  end
  if type(spec.title) == "string" and spec.title ~= "" then
    out[#out + 1] = "# " .. spec.title
  end
  local ok, err = pcall(md_node, spec.root, out, 0)
  if not ok then
    out[#out + 1] = "(render error: " .. tostring(err) .. ")"
  end
  if #out == 0 then
    return "(ui)"
  end
  return table.concat(out, "\n")
end

---------------------------------------------------------------------------
-- Text primitives (shared with genui.form / genui.widgets.inputs)
---------------------------------------------------------------------------

function Render.fit(text, width, rctx)
  return Display.fit(text, math.floor(tonumber(width) or 0), rctx)
end

function Render.pad(line, width, style, rctx)
  return Display.pad(line, math.floor(tonumber(width) or 0), style, rctx)
end

function Render.wrap_text(text, width, rctx)
  return Display.wrap(text, width, rctx)
end

function Render.line_width(line, rctx)
  return Display.line_width(line, rctx)
end

function Render.clamp(line, width, rctx)
  return Display.clamp(line, math.floor(tonumber(width) or 0), rctx)
end

return Render
