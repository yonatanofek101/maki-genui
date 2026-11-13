-- Interactive form: pure state machine (initial_state / handle_key / render) plus
-- the blocking window loop (`Form.open`), modelled on plugins/question/question_form.lua.
local Render = require("genui.render")
local Inputs = require("genui.widgets.inputs")

local Form = { MODE = { NAV = "nav", EDIT = "edit", DONE = "done" } }
local MODE = Form.MODE
local S = Render.STYLES

Form.CHROME = 3 -- border (2) + reserved_bottom (1), as in question_form.lua
Form.MAX_HEIGHT_RATIO = 0.75
Form.MIN_WIDTH = 20

Form.FOOTER_NAV = {
  { "Tab", "next" },
  { "↑↓", "move" },
  { "Space", "toggle" },
  { "Enter", "select" },
  { "Esc", "cancel" },
}
Form.FOOTER_EDIT = {
  { "Enter", "next" },
  { "M-Enter", "newline" },
  { "Tab", "next field" },
  { "Esc", "cancel" },
}
Form.FOOTER_BY_TYPE = {
  diff = { { "a / r", "accept / reject" }, { "Space", "cycle" }, { "Tab", "next" }, { "Esc", "cancel" } },
  actions = { { "Enter", "press" }, { "← →", "move" }, { "Tab", "next" }, { "Esc", "cancel" } },
  submit_row = { { "Enter", "press" }, { "← →", "move" }, { "S-Tab", "back" }, { "Esc", "cancel" } },
  number = { { "← → + -", "step" }, { "↑↓", "move" }, { "Enter", "next" }, { "Esc", "cancel" } },
  confirm = { { "Space y n", "toggle" }, { "Enter", "next" }, { "Tab", "next" }, { "Esc", "cancel" } },
}

local SUBMIT_ITEMS = {
  { action = "submit", label = "Submit", style = "primary" },
  { action = "cancel", label = "Cancel" },
}

-- ---------------------------------------------------------------------------
-- focus ring

local function is_input(comp)
  local t = comp.type
  if t == "table" then
    return comp.select ~= nil and comp.select ~= "none"
  elseif t == "diff" then
    return comp.decide == true
  elseif t == "submit_row" then
    return false
  end
  return Inputs.widgets[t] ~= nil
end

local function comp_key(state, comp)
  return state.ids[comp] or comp.id
end

local function build_ring(state)
  local ring = {}
  local has_actions = false
  local anon = 0
  local function visit(comp)
    if type(comp) ~= "table" or comp.hidden then
      return
    end
    if is_input(comp) then
      local id = comp.id
      if type(id) ~= "string" or id == "" then
        anon = anon + 1
        id = "_anon" .. tostring(anon)
      end
      state.ids[comp] = id
      local widget = Inputs.widgets[comp.type]
      local ws = state.widgets[id]
      if not ws then
        ws = widget.init(comp)
        state.widgets[id] = ws
      end
      if comp.type == "actions" then
        has_actions = true
        for i, item in ipairs(comp.items or {}) do
          local action = item.action
          if type(action) ~= "string" or action == "" then
            action = tostring(item.label or ("action" .. tostring(i)))
          end
          ring[#ring + 1] = { comp = comp, widget = widget, ws = ws, id = id, index = i, action = action }
        end
      else
        ring[#ring + 1] = { comp = comp, widget = widget, ws = ws, id = id }
      end
    end
    if type(comp.children) == "table" then
      for _, child in ipairs(comp.children) do
        visit(child)
      end
    end
  end
  visit(state.spec and state.spec.root or nil)
  if not has_actions then
    local sr = { type = "submit_row", id = "__submit", items = SUBMIT_ITEMS }
    local widget = Inputs.widgets.submit_row
    local ws = widget.init(sr)
    state.widgets[sr.id] = ws
    state.ids[sr] = sr.id
    state.submit_row = sr
    for i, item in ipairs(SUBMIT_ITEMS) do
      ring[#ring + 1] =
        { comp = sr, widget = widget, ws = ws, id = sr.id, index = i, action = item.action, implicit = true }
    end
  end
  return ring
end

local function entry_at(state)
  return state.focusables[state.focus]
end

local function set_focus(state, idx)
  local n = #state.focusables
  if n == 0 then
    state.mode = MODE.NAV
    return
  end
  local old = entry_at(state)
  idx = ((idx - 1) % n) + 1
  if old and old.widget.blur then
    old.widget.blur(old.ws, old.comp)
  end
  state.focus = idx
  local e = state.focusables[idx]
  if e.widget.focus then
    e.widget.focus(e.ws, e.comp, e)
  end
  state.mode = e.widget.edit_on_focus and MODE.EDIT or MODE.NAV
end

-- ---------------------------------------------------------------------------
-- state

function Form._initial_state(spec, opts)
  opts = opts or {}
  local state = {
    spec = spec,
    title = opts.title or (spec and spec.title) or nil,
    focus = 1,
    focusables = {},
    widgets = {},
    ids = {},
    mode = MODE.NAV,
    errors = {},
    top = 1,
    rows = {},
    view_h = nil,
    flash = nil,
    done = nil,
    submit_row = nil,
  }
  state.focusables = build_ring(state)
  set_focus(state, 1)
  return state
end

local function count_keys(t)
  local n = 0
  for _ in pairs(t) do
    n = n + 1
  end
  return n
end

function Form._validate(state)
  local errors = {}
  local seen = {}
  for _, e in ipairs(state.focusables) do
    if not e.implicit and e.comp.type ~= "actions" and not seen[e.id] then
      seen[e.id] = true
      if e.widget.validate then
        local err = e.widget.validate(e.ws, e.comp)
        if err then
          errors[e.id] = err
        end
      end
    end
  end
  state.errors = errors
  return errors
end

function Form._values(state)
  local values = {}
  local seen = {}
  for _, e in ipairs(state.focusables) do
    if not e.implicit and e.comp.type ~= "actions" and not seen[e.id] then
      seen[e.id] = true
      local v = e.widget.value(e.ws, e.comp)
      if v ~= nil then
        values[e.id] = v
      end
    end
  end
  return values
end

function Form._submit(state, action)
  if state.done then
    return state
  end
  if action == "cancel" then
    state.done = { status = "cancelled" }
    state.mode = MODE.DONE
    return state
  end
  local cur = entry_at(state)
  if cur and cur.widget.blur then
    cur.widget.blur(cur.ws, cur.comp)
  end
  local errors = Form._validate(state)
  local first = nil
  for i, e in ipairs(state.focusables) do
    if errors[e.id] then
      first = i
      break
    end
  end
  if first then
    set_focus(state, first)
    local n = count_keys(errors)
    state.flash = "fix " .. tostring(n) .. (n == 1 and " field" or " fields")
    return state
  end
  state.done = { status = "submitted", values = Form._values(state), action = action }
  state.mode = MODE.DONE
  return state
end

local function page(state, dir)
  local n = #state.focusables
  if n == 0 then
    return
  end
  local h = state.view_h
  local top = state.top or 1
  if not h or h <= 0 or count_keys(state.rows) == 0 then
    set_focus(state, dir > 0 and n or 1)
    return
  end
  if dir > 0 then
    local bottom = top + h - 1
    for i = state.focus + 1, n do
      if (state.rows[i] or 0) > bottom then
        set_focus(state, i)
        return
      end
    end
    set_focus(state, n)
  else
    for i = state.focus - 1, 1, -1 do
      if (state.rows[i] or 0) < top then
        set_focus(state, i)
        return
      end
    end
    set_focus(state, 1)
  end
end

function Form._handle_key(state, key)
  if state.done then
    return state
  end
  state.flash = nil
  local e = entry_at(state)
  local res = "ignored"
  if e then
    res = e.widget.handle_key(e.ws, e.comp, key)
  end
  if res == "consumed" then
    return state
  elseif res == "next" then
    set_focus(state, state.focus + 1)
  elseif res == "prev" then
    set_focus(state, state.focus - 1)
  elseif res == "submit" then
    Form._submit(state, e and e.action or nil)
  elseif res == "cancel" then
    state.done = { status = "cancelled" }
    state.mode = MODE.DONE
  elseif res == "edit_on" then
    state.mode = MODE.EDIT
  elseif res == "edit_off" then
    state.mode = MODE.NAV
  elseif key == "<Tab>" or key == "<Down>" then
    set_focus(state, state.focus + 1)
  elseif key == "<S-Tab>" or key == "<Up>" then
    set_focus(state, state.focus - 1)
  elseif key == "<Esc>" or key == "<C-c>" then
    state.done = { status = "cancelled" }
    state.mode = MODE.DONE
  elseif key == "<CR>" then
    Form._submit(state, nil)
  elseif key == "<PageDown>" then
    page(state, 1)
  elseif key == "<PageUp>" then
    page(state, -1)
  end
  return state
end

function Form._handle_paste(state, text)
  if state.done or type(text) ~= "string" or text == "" then
    return state
  end
  local e = entry_at(state)
  if e and e.widget.handle_paste then
    e.widget.handle_paste(e.ws, e.comp, text)
  end
  return state
end

-- ---------------------------------------------------------------------------
-- render

local function window_ctx(rctx, width)
  local ctx = {}
  if type(rctx) == "table" then
    for k, v in pairs(rctx) do
      ctx[k] = v
    end
  else
    local base = Render.ctx({ width = width, mode = "window" })
    for k, v in pairs(base) do
      ctx[k] = v
    end
  end
  ctx.width = width
  ctx.mode = "window"
  ctx.expanded = ctx.expanded or {}
  return ctx
end

function Form._render(state, width, height, rctx)
  width = math.max(tonumber(width) or Render.CARD_WIDTH, Form.MIN_WIDTH)
  local ctx = window_ctx(rctx, width)
  local lines = {}
  local rows = {}
  local focus_row = 1
  local focused_entry = entry_at(state)

  local function add_lines(ls)
    for _, l in ipairs(ls) do
      lines[#lines + 1] = l
    end
  end

  local function render_widget(comp)
    local id = comp_key(state, comp)
    local ws = state.widgets[id]
    local widget = Inputs.widgets[comp.type]
    if not ws or not widget then
      return
    end
    local focused = focused_entry ~= nil and focused_entry.comp == comp
    local ls, off = widget.render(ws, comp, ctx, focused, state.errors[id])
    local base = #lines
    add_lines(ls)
    local row = base + math.max(off or 1, 1)
    for i, e in ipairs(state.focusables) do
      if e.comp == comp then
        rows[i] = row
      end
    end
    if focused then
      focus_row = row
    end
  end

  local visit
  local function visit_children(comp)
    local children = comp.children
    if type(children) ~= "table" then
      return
    end
    for i, child in ipairs(children) do
      local before = #lines
      visit(child)
      if i < #children and #lines > before then
        lines[#lines + 1] = {}
      end
    end
  end

  visit = function(comp)
    if type(comp) ~= "table" or comp.hidden then
      return
    end
    if is_input(comp) then
      render_widget(comp)
    elseif comp.type == "section" then
      lines[#lines + 1] = { { "▾ " .. tostring(comp.title or ""), S.section } }
      visit_children(comp)
    elseif comp.type == "stack" or comp.type == "row" then
      visit_children(comp)
    else
      local ok, ls = pcall(Render.component, comp, ctx)
      if ok and type(ls) == "table" then
        add_lines(ls)
      else
        lines[#lines + 1] = { { "  ⚠ " .. tostring(comp.type), S.warning } }
      end
    end
  end

  visit(state.spec and state.spec.root or nil)

  if state.submit_row then
    if #lines > 0 then
      lines[#lines + 1] = {}
    end
    render_widget(state.submit_row)
  end
  if state.flash then
    lines[#lines + 1] = { { "  ⚠ " .. state.flash, S.warning } }
  end

  -- viewport: keep the focus row visible, honour PageUp/PageDown scrolling
  local total = #lines
  local top = state.top or 1
  height = tonumber(height)
  if height and height > 0 and total > height then
    if focus_row < top then
      top = focus_row
    elseif focus_row > top + height - 1 then
      top = focus_row - height + 1
    end
    top = math.max(1, math.min(top, total - height + 1))
    local sliced = {}
    for i = top, math.min(total, top + height - 1) do
      sliced[#sliced + 1] = lines[i]
    end
    lines = sliced
    focus_row = focus_row - top + 1
  else
    top = 1
  end
  state.top = top
  state.rows = rows
  state.view_h = height

  local footer = Form.FOOTER_NAV
  if state.mode == MODE.EDIT then
    footer = Form.FOOTER_EDIT
  elseif focused_entry and Form.FOOTER_BY_TYPE[focused_entry.comp.type] then
    footer = Form.FOOTER_BY_TYPE[focused_entry.comp.type]
  end

  return { lines = lines, focus_row = math.max(focus_row, 1), footer = footer, reserved_top = 0 }
end

-- ---------------------------------------------------------------------------
-- window loop

-- Host bindings, swappable by tests (`Form._io.open_win = fake`).
Form._io = {
  buf = function()
    return maki.ui.buf({ scratch = true })
  end,
  open_win = function(buf, cfg)
    return maki.ui.open_win(buf, cfg)
  end,
  terminal_size = function()
    return maki.ui.terminal_size()
  end,
}

local function terminal_rows()
  local ok, size = pcall(function()
    return Form._io.terminal_size()
  end)
  if ok and type(size) == "table" and type(size.rows) == "number" and size.rows > 0 then
    return size.rows
  end
  return 24
end

local function max_height()
  return math.max(math.floor(terminal_rows() * Form.MAX_HEIGHT_RATIO), Form.CHROME + 3)
end

function Form.open(spec, opts)
  opts = opts or {}
  local state = Form._initial_state(spec, opts)
  local ok_buf, buf = pcall(function()
    return Form._io.buf()
  end)
  if not ok_buf or buf == nil then
    return { status = "unavailable" }
  end
  local max_h = max_height()
  local title = " " .. tostring(state.title or "Form") .. " "
  local ok_win, win = pcall(function()
    return Form._io.open_win(buf, {
      title = title,
      height = max_h,
      width = "100%",
      border = "rounded",
      reserved_bottom = 1,
      focus = true,
      needs_input = true,
      split = "below",
    })
  end)
  if not ok_win or win == nil then
    return { status = "unavailable" }
  end

  local got_event = false
  local function loop()
    local width = tonumber(win.width) or Render.CARD_WIDTH
    while true do
      local w = math.max(width - 1, Form.MIN_WIDTH)
      local r = Form._render(state, w, max_h - Form.CHROME, Render.ctx({ width = w, mode = "window" }))
      win:set_config({
        height = math.min(#r.lines + Form.CHROME, max_h),
        reserved_top = r.reserved_top,
        footer = r.footer,
      })
      buf:set_lines(r.lines)
      win:set_cursor(r.focus_row)

      local ev = win:recv()
      if ev == nil then
        if got_event then
          return { status = "cancelled" }
        end
        return { status = "unavailable" }
      end
      got_event = true
      if ev.type == "close" then
        return { status = "cancelled" }
      elseif ev.type == "resize" then
        width = tonumber(ev.width) or tonumber(win.width) or width
        max_h = max_height()
      elseif ev.type == "paste" then
        Form._handle_paste(state, ev.text or "")
      elseif ev.type == "key" then
        Form._handle_key(state, ev.key)
        if state.done then
          return state.done
        end
      end
    end
  end

  local ok, res = pcall(loop)
  pcall(function()
    if win.is_open == nil or win:is_open() then
      win:close()
    end
  end)
  if not ok then
    error(res, 0)
  end
  return res
end

Form._is_input = is_input
Form._set_focus = set_focus

return Form
