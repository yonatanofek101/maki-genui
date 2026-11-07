-- genui: generative UI tools (ui_render / ui_update / ui_close) and the
-- /genui dev command. Handlers never raise; every failure is
-- { llm_output = "error: ...", is_error = true }.
local Schema, Registry = require("genui.schema"), require("genui.registry")
local Render, Result, Form = require("genui.render"), require("genui.result"), require("genui.form")

local Genui = { _handlers = {} }

-- design.md §6: repaint a live card in place by mutating the Buf returned as
-- the earlier tool's body. Flip to false if the host rejects cross-call
-- set_lines; ui_update then returns a fresh card as its own body.
Genui.LIVE_INPLACE = true
Genui.MAX_FINAL_FRAMES = 32

local RENDER_DESCRIPTION = [[Render a generative UI card in the chat from a component tree, and (for interactive
specs) wait for the user to fill it in. Use it instead of prose when you need
structured answers (forms, pickers, tables with row selection, diff review),
want to show structured data (key-value, tables, bar charts, collapsible
sections), or need a live progress dashboard you update with ui_update.
Rules: give every input component an `id` (it becomes the result key); keep
forms short (<= 8 inputs); tables <= 200 rows; put the recommended option first
with "(Recommended)". mode "auto" (default) blocks when any input exists,
otherwise shows a display card. Results come back as JSON: {"status":
"submitted"|"cancelled"|"display"|"live"|"unavailable", "values":{id: value},
"action": string|null}. "unavailable" means no interactive terminal is attached:
ask in prose instead. Components: stack, row, section, text, kv, table, bars,
sparkline, progress, divider, badge, checklist, diff, choice, input, number,
confirm, actions. See the schema description for props.]]

local UPDATE_DESCRIPTION =
  [[Patch a live widget rendered by ui_render(mode "live") in place. Give the widget id and either patch (array of {id, ...props} merged into the component with that id) or root (replace the whole tree). Fails if the widget is unknown or closed.]]

local CLOSE_DESCRIPTION =
  [[Finish a live widget: freeze its current rendering, drop it from the live registry, and optionally append a final status line.]]

-- Final frames of closed live widgets, so a reload inside this process still
-- restores the last dashboard instead of the first one. id -> {spec, state}.
local final_frames, final_order = {}, {}

local function remember_final(id, spec, st)
  if final_frames[id] == nil then
    final_order[#final_order + 1] = id
  end
  final_frames[id] = { spec = spec, state = st }
  while #final_order > Genui.MAX_FINAL_FRAMES do
    final_frames[table.remove(final_order, 1)] = nil
  end
end

local function is_nil(v)
  return v == nil or (maki and v == maki.NIL)
end

local function str(v)
  if type(v) == "string" then
    return v
  elseif type(v) == "number" then
    return tostring(v)
  end
  return nil
end

-- Sparse arrays encode as objects with null gaps; values must be dense before
-- they become state (question/init.lua:26-34).
local function dense(v, depth)
  depth = depth or 0
  if type(v) ~= "table" or depth > 8 then
    return v
  end
  if Schema._is_array(v) then
    local out = {}
    for _, x in ipairs(Schema._densify(v)) do
      out[#out + 1] = dense(x, depth + 1)
    end
    return out
  end
  local out = {}
  for k, x in pairs(v) do
    if not is_nil(x) then
      out[tostring(k)] = dense(x, depth + 1)
    end
  end
  return out
end

local function error_reply(errors)
  if type(errors) == "string" then
    errors = { errors }
  end
  local ok, out = pcall(Result.error_output, errors)
  if not ok or type(out) ~= "string" then
    out = "error: " .. table.concat(errors, "; ")
  end
  return { llm_output = out, is_error = true }
end

local function with_warnings(output, warnings)
  if type(warnings) ~= "table" or #warnings == 0 then
    return output
  end
  local lines = { output, "warnings:" }
  for i = 1, math.min(#warnings, 20) do
    lines[#lines + 1] = "- " .. tostring(warnings[i])
  end
  if #warnings > 20 then
    lines[#lines + 1] = string.format("- … %d more", #warnings - 20)
  end
  return table.concat(lines, "\n")
end

local function session_of(ctx)
  local ok, sid = pcall(function()
    if type(ctx) == "table" and type(ctx.session_id) ~= "function" then
      return ctx.session_id
    end
    return ctx:session_id()
  end)
  if ok and (type(sid) == "string" or type(sid) == "number") then
    return sid
  end
  return nil
end

local function view_opts(ctx)
  local ok, opts = pcall(Result.view_opts, ctx)
  if ok and type(opts) == "table" then
    return opts
  end
  return { width = 80, max_lines = 10, keep = "head" }
end

local function make_card(spec, st, ctx)
  local ok, buf, handle = pcall(Result.card, spec, st, view_opts(ctx))
  if ok then
    return buf, handle
  end
  if maki and maki.log then
    maki.log.warn("genui: card render failed: " .. tostring(buf))
  end
  return nil, nil
end

local function to_markdown(spec)
  local ok, md = pcall(Render.to_markdown, spec)
  if ok and type(md) == "string" then
    return md
  end
  return "(ui)"
end

-- Wrap a handler so a bug becomes a tool error instead of a crash.
local function guarded(name, fn)
  return function(input, ctx)
    local ok, reply = pcall(fn, input, ctx)
    if ok then
      if type(reply) ~= "table" then
        return error_reply(name .. ": handler returned " .. type(reply))
      end
      return reply
    end
    if maki and maki.log then
      maki.log.error("genui " .. name .. ": " .. tostring(reply))
    end
    return error_reply(name .. " failed: " .. tostring(reply))
  end
end

-- ui_render -------------------------------------------------------------------------

local function ui_render(input, ctx)
  local ok, errors, spec = Schema.validate(input)
  if not ok then
    return error_reply(errors)
  end
  spec.id = spec.id or Registry.new_id()
  if spec.mode == "live" and Registry.get(spec.id) then
    spec.warnings[#spec.warnings + 1] = string.format("widget %q already live; replaced", spec.id)
  end

  local res
  if spec.mode == "interactive" then
    local okf, r = pcall(Form.open, spec, { title = spec.title, ctx = ctx })
    if not okf then
      return error_reply("form failed: " .. tostring(r))
    end
    res = type(r) == "table" and r or { status = "unavailable" }
    if res.status ~= "submitted" and res.status ~= "cancelled" and res.status ~= "unavailable" then
      res.status = "unavailable"
    end
  else
    res = { status = spec.mode }
  end

  local st = {
    v = 1,
    widget = spec.id,
    mode = spec.mode,
    status = res.status,
    values = res.values ~= nil and dense(res.values) or nil,
    action = str(res.action),
    warnings = #spec.warnings > 0 and spec.warnings or nil,
    spec = spec.mode == "live" and Schema.strip(spec) or nil,
  }

  local buf, handle = make_card(spec, st, ctx)
  if spec.mode == "live" then
    Registry.put({
      id = spec.id,
      buf = buf,
      spec = spec,
      state = st,
      card = handle,
      session_id = session_of(ctx),
      created_at = os and os.time and os.time() or 0,
      closed = false,
    })
  end

  local okl, out = pcall(Result.llm_output, spec, st)
  if not okl or type(out) ~= "string" then
    out = maki.json.encode({ status = st.status, widget = st.widget, values = st.values, action = st.action })
      or ('{"status":"' .. st.status .. '"}')
    out = with_warnings(out, st.warnings)
  end
  if st.status == "unavailable" then
    out = out .. "\n\n" .. to_markdown(spec)
  end
  return { llm_output = out, state = st, body = buf, annotation = st.status }
end

-- ui_update -------------------------------------------------------------------------

local function unknown_widget(id)
  return error_reply(
    string.format("unknown widget %q (closed, evicted after reload, or never rendered); call ui_render again", id)
  )
end

local function ui_update(input, ctx)
  if type(input) ~= "table" then
    return error_reply("input must be an object")
  end
  local id = str(input.id)
  if not id or id == "" then
    return error_reply("id is required")
  end
  local entry = Registry.get(id)
  if not entry then
    return unknown_widget(id)
  end
  local has_patch, has_root = not is_nil(input.patch), not is_nil(input.root)
  if has_patch == has_root then
    return error_reply("give exactly one of patch or root")
  end

  local new_spec, warnings =
    Schema.apply_patch(entry.spec, has_patch and input.patch or nil, has_root and input.root or nil)
  local title = str(input.title)
  if title then
    new_spec.title = string.sub(title, 1, Schema.MAX_TITLE)
  elseif not is_nil(input.title) then
    warnings[#warnings + 1] = "title: expected a string (ignored)"
  end

  local patched = {}
  if has_root then
    patched = Schema.ids(new_spec)
  else
    local seen = {}
    for _, item in ipairs(Schema._densify(type(input.patch) == "table" and input.patch or {})) do
      local pid = type(item) == "table" and str(item.id) or nil
      if pid and not seen[pid] and Schema.find(new_spec, pid) then
        seen[pid] = true
        patched[#patched + 1] = pid
      end
    end
  end

  local st = entry.state or { v = 1, widget = id, mode = "live", status = "live" }
  st.spec = Schema.strip(new_spec)
  st.warnings = #warnings > 0 and warnings or nil
  entry.spec = new_spec
  entry.state = st

  local body = nil
  local repainted = false
  if Genui.LIVE_INPLACE and entry.card and type(entry.card.repaint) == "function" then
    local okr, err = pcall(entry.card.repaint, new_spec, st)
    repainted = okr
    if not okr and maki and maki.log then
      maki.log.warn("genui: in-place repaint failed, falling back to a fresh card: " .. tostring(err))
    end
  end
  if not repainted then
    local buf, handle = make_card(new_spec, st, ctx)
    if buf then
      entry.buf, entry.card = buf, handle
      body = buf
    end
  end

  local oku, out = pcall(Result.update_output, id, patched, warnings)
  if not oku or type(out) ~= "string" then
    out = with_warnings(maki.json.encode({ status = "updated", widget = id, patched = patched }) or "", warnings)
  end
  local reply = {
    llm_output = out,
    state = { widget = id, patched = patched, spec = body and st.spec or nil, status = "updated" },
  }
  if body then
    reply.body = body
  end
  return reply
end

-- ui_close --------------------------------------------------------------------------

local CLOSE_TONE = { done = "success", error = "error", cancelled = "dim" }
local CLOSE_GLYPH = { done = "✓", error = "✗", cancelled = "–" }

local function ui_close(input, ctx)
  if type(input) ~= "table" then
    return error_reply("input must be an object")
  end
  local id = str(input.id)
  if not id or id == "" then
    return error_reply("id is required")
  end
  local warnings = {}
  local status = str(input.status)
  if status ~= nil and CLOSE_TONE[status] == nil then
    warnings[#warnings + 1] = string.format("status: %q is not one of done|error|cancelled (using done)", status)
    status = nil
  end
  status = status or "done"
  local note = str(input.note)

  local entry = Registry.get(id)
  local reply_state = { widget = id, closed = true }
  if not entry then
    warnings[#warnings + 1] = string.format("widget %q is already closed or unknown", id)
  else
    local spec = Schema.apply_patch(entry.spec) -- deep copy, fresh warnings
    local st = entry.state or { v = 1, widget = id, mode = "live", status = "live" }
    if note or status ~= "done" then
      -- Append the status line as a normalized text component; wrap non-stack
      -- roots so the renderer sees a plain tree.
      local line = {
        type = "text",
        id = "_close",
        text = CLOSE_GLYPH[status] .. " " .. (note or status),
        tone = CLOSE_TONE[status],
        markdown = false,
      }
      local old = Schema.find(spec, "_close")
      if old then
        old.text, old.tone = line.text, line.tone
      elseif spec.root and spec.root.type == "stack" and type(spec.root.children) == "table" then
        spec.root.children[#spec.root.children + 1] = line
      else
        spec.root = { type = "stack", id = "_close_root", children = { spec.root, line } }
      end
    end
    st.status = "closed"
    st.close = { status = status, note = note }
    st.spec = Schema.strip(spec)
    entry.spec, entry.state = spec, st
    if entry.card and type(entry.card.repaint) == "function" then
      pcall(entry.card.repaint, spec, st)
    end
    remember_final(id, spec, st)
    Registry.remove(id)
    reply_state.spec = st.spec
  end

  local okc, out = pcall(Result.close_output, id, warnings)
  if not okc or type(out) ~= "string" then
    out = with_warnings(maki.json.encode({ status = "closed", widget = id }) or "", warnings)
  end
  return { llm_output = out, state = reply_state, annotation = status }
end

Genui._handlers.ui_render = guarded("ui_render", ui_render)
Genui._handlers.ui_update = guarded("ui_update", ui_update)
Genui._handlers.ui_close = guarded("ui_close", ui_close)

-- restore ---------------------------------------------------------------------------

local function ctx_state(ctx)
  local ok, st = pcall(function()
    if type(ctx) == "table" and type(ctx.state) ~= "function" then
      return ctx.state
    end
    return ctx:state()
  end)
  if ok and type(st) == "table" then
    return st
  end
  return nil
end

local function restore_markdown(output, is_error, ctx)
  local ok, ToolView = pcall(require, "maki.tool_view")
  if not ok then
    return nil
  end
  local okr, buf = pcall(ToolView.restore_markdown, output, is_error, view_opts(ctx))
  if okr then
    return buf
  end
  return nil
end

function Genui._restore(input, output, is_error, ctx)
  local ok, buf = pcall(function()
    local st = ctx_state(ctx)
    if not st or type(st.widget) ~= "string" or is_error then
      return restore_markdown(output, is_error, ctx)
    end
    local spec
    local entry = st.mode == "live" and Registry.get(st.widget) or nil
    if entry and entry.spec then
      -- the plugin still holds a newer frame: render it and adopt the new Buf
      spec = entry.spec
      st = entry.state or st
      local nbuf, handle = make_card(spec, st, ctx)
      if nbuf then
        entry.buf, entry.card = nbuf, handle
      end
      return nbuf
    end
    local final = final_frames[st.widget]
    if final and st.mode == "live" then
      spec, st = final.spec, final.state
    elseif type(st.spec) == "table" and type(st.spec.root) == "table" then
      spec = st.spec
      spec.warnings = spec.warnings or {}
    else
      local okv, _, fresh = Schema.validate(input)
      if not okv then
        return restore_markdown(output, is_error, ctx)
      end
      spec = fresh
      spec.id = st.widget
    end
    local nbuf = make_card(spec, st, ctx)
    return nbuf or restore_markdown(output, is_error, ctx)
  end)
  if ok then
    return buf
  end
  if maki and maki.log then
    maki.log.warn("genui: restore failed: " .. tostring(buf))
  end
  return restore_markdown(output, is_error, ctx)
end

-- ui_update/ui_close carry no body unless the fallback card was used.
local function restore_secondary(input, output, is_error, ctx)
  local ok, buf = pcall(function()
    local st = ctx_state(ctx)
    if not st or type(st.spec) ~= "table" or type(st.spec.root) ~= "table" then
      return nil
    end
    local spec = st.spec
    spec.warnings = spec.warnings or {}
    local nbuf = make_card(spec, { v = 1, widget = st.widget, mode = "live", status = st.status or "live" }, ctx)
    return nbuf
  end)
  if ok then
    return buf
  end
  return nil
end

-- headers ---------------------------------------------------------------------------

local function render_header(input)
  local title = type(input) == "table" and str(input.title) or nil
  local rtype = type(input) == "table" and type(input.root) == "table" and str(input.root.type) or nil
  return "ui: " .. (title or rtype or "card")
end

local function update_header(input)
  return "ui_update: " .. (type(input) == "table" and str(input.id) or "?")
end

local function close_header(input)
  return "ui_close: " .. (type(input) == "table" and str(input.id) or "?")
end

-- /genui command --------------------------------------------------------------------

local function plain_lines(text_lines)
  local out = {}
  for _, l in ipairs(text_lines) do
    if type(l) == "string" then
      out[#out + 1] = { { l, "" } }
    else
      out[#out + 1] = l
    end
  end
  return out
end

local function flash(msg)
  if maki and maki.ui and maki.ui.flash then
    pcall(maki.ui.flash, msg)
  elseif maki and maki.log then
    maki.log.info(msg)
  end
end

-- Scratch float showing styled lines; q/Esc/Enter/close end it. Buf may be given.
local function show_float(title, lines, buf)
  local okb, b = pcall(function()
    if buf then
      return buf
    end
    local nb = maki.ui.buf({ scratch = true })
    nb:set_lines(plain_lines(lines))
    return nb
  end)
  if not okb then
    flash("genui: " .. tostring(b))
    return
  end
  local n = #lines
  if buf then
    local okn, len = pcall(function()
      return buf:len()
    end)
    n = okn and tonumber(len) or 20
  end
  local rows = 40
  pcall(function()
    rows = maki.ui.terminal_size().rows or rows
  end)
  local height = math.max(3, math.min(n + 2, math.floor(rows * 0.75)))
  local okw, win = pcall(maki.ui.open_win, b, {
    title = " " .. title .. " ",
    width = "80%",
    height = height,
    border = "rounded",
    footer = { { "q", "close" } },
    focus = true,
  })
  if not okw or not win then
    flash("genui: " .. tostring(win))
    return
  end
  local okl, err = pcall(function()
    while true do
      local ev = win:recv()
      if not ev or ev.type == "close" then
        return
      end
      if ev.type == "key" and (ev.key == "q" or ev.key == "<Esc>" or ev.key == "<CR>" or ev.key == "<C-c>") then
        return
      end
    end
  end)
  pcall(win.close, win)
  if not okl then
    flash("genui: " .. tostring(err))
  end
end

local function stub_ctx()
  return {
    tool_output_lines = function()
      return { other = 10 }
    end,
    session_id = function()
      return nil
    end,
    state = function()
      return nil
    end,
    restore_reason = function()
      return nil
    end,
  }
end

local function cmd_test()
  local ok, res = pcall(function()
    return require("genui.tests.spec").run()
  end)
  local lines
  if not ok then
    lines = { "spec runner failed: " .. tostring(res) }
  elseif type(res) ~= "table" then
    lines = { "spec runner returned " .. type(res) }
  else
    local summary = res.summary
      or string.format("%d passed, %d failed", tonumber(res.passed) or 0, tonumber(res.failed) or 0)
    if type(res.lines) == "table" and #res.lines > 0 then
      lines = {}
      for _, l in ipairs(res.lines) do
        lines[#lines + 1] = tostring(l)
      end
    else
      lines = { summary }
      for _, f in ipairs(res.failures or {}) do
        lines[#lines + 1] = "✗ " .. tostring(f)
      end
    end
    if maki and maki.log then
      maki.log.info("genui test: " .. summary)
      for _, f in ipairs(res.failures or {}) do
        maki.log.warn("genui test failure: " .. tostring(f))
      end
    end
    local oks, styled = pcall(function()
      return require("genui.tests.spec").styled_lines(res)
    end)
    if oks and type(styled) == "table" and #styled > 0 then
      lines = styled
    end
  end
  show_float("genui test", lines)
end

local function cmd_demo(name)
  local ok, Examples = pcall(require, "genui.examples")
  local specs = ok and type(Examples) == "table" and Examples.specs or {}
  local raw = specs[name]
  if raw == nil and ok and type(Examples.get) == "function" then
    local okg, got = pcall(Examples.get, name)
    raw = okg and got or nil
  end
  if type(raw) ~= "table" then
    local names = {}
    for k in pairs(specs) do
      names[#names + 1] = k
    end
    table.sort(names)
    flash("genui demo: unknown example " .. tostring(name) .. "; have: " .. table.concat(names, ", "))
    return
  end
  local reply = Genui._handlers.ui_render(Schema.strip(raw), stub_ctx())
  local lines = {}
  for l in string.gmatch(tostring(reply.llm_output or "") .. "\n", "(.-)\n") do
    lines[#lines + 1] = l
  end
  if maki and maki.log then
    maki.log.info("genui demo " .. name .. ": " .. tostring(reply.llm_output))
  end
  if reply.body then
    show_float("genui demo " .. name .. " (card)", lines, reply.body)
  else
    show_float("genui demo " .. name, lines)
  end
end

local function cmd_list()
  local lines = {}
  for _, e in ipairs(Registry.list()) do
    local st = e.state or {}
    lines[#lines + 1] = string.format(
      "%-12s %-8s %-10s session=%s  ids=%s",
      e.id,
      tostring(st.mode or "?"),
      tostring(st.status or "?"),
      tostring(e.session_id or "-"),
      table.concat(Schema.ids(e.spec), ",")
    )
  end
  if #lines == 0 then
    lines[1] = "no live widgets"
  end
  show_float("genui live widgets", lines)
end

local function cmd_close(id)
  local reply = Genui._handlers.ui_close({ id = id }, stub_ctx())
  flash("genui close: " .. tostring(reply.llm_output))
end

local USAGE = "/genui test | demo <form|table|diff|dashboard|report> | list | close <id>"

local function genui_command(opts)
  local fargs = type(opts) == "table" and opts.fargs or {}
  local sub = fargs[1]
  if sub == "test" then
    cmd_test()
  elseif sub == "demo" then
    if not fargs[2] then
      flash(USAGE)
    else
      cmd_demo(fargs[2])
    end
  elseif sub == "list" then
    cmd_list()
  elseif sub == "close" then
    if not fargs[2] then
      flash(USAGE)
    else
      cmd_close(fargs[2])
    end
  else
    flash(USAGE)
  end
end

-- setup -----------------------------------------------------------------------------

local did_setup = false

function Genui.setup(opts)
  if did_setup then
    return
  end
  did_setup = true
  opts = opts or {}
  Genui.live_actions = opts.live_actions == true
  if opts.live_inplace ~= nil then
    Genui.LIVE_INPLACE = opts.live_inplace and true or false
  end

  maki.api.register_tool({
    name = "ui_render",
    description = RENDER_DESCRIPTION,
    schema = Schema.TOOL_SCHEMAS.ui_render,
    audiences = { "main" },
    timeout = false,
    header = render_header,
    handler = Genui._handlers.ui_render,
    restore = Genui._restore,
  })
  maki.api.register_tool({
    name = "ui_update",
    description = UPDATE_DESCRIPTION,
    schema = Schema.TOOL_SCHEMAS.ui_update,
    audiences = { "main" },
    timeout = false,
    header = update_header,
    handler = Genui._handlers.ui_update,
    restore = restore_secondary,
  })
  maki.api.register_tool({
    name = "ui_close",
    description = CLOSE_DESCRIPTION,
    schema = Schema.TOOL_SCHEMAS.ui_close,
    audiences = { "main" },
    timeout = false,
    header = close_header,
    handler = Genui._handlers.ui_close,
    restore = restore_secondary,
  })

  maki.api.register_command({
    name = "/genui",
    description = "genui dev: test | demo <name> | list | close <id>",
    nargs = "*",
    handler = function(cmd_opts)
      local ok, err = pcall(genui_command, cmd_opts)
      if not ok then
        flash("genui: " .. tostring(err))
      end
    end,
  })

  maki.api.create_autocmd({ "SessionEnd", "SessionReset" }, {
    callback = function(ev)
      local sid = type(ev) == "table" and type(ev.data) == "table" and ev.data.session_id or nil
      if sid ~= nil then
        Registry.clear_session(sid)
      end
    end,
  })
end

return Genui
