-- Component (normalized; every node has a string id, auto ids look like "c12")
-- type Comp = { type: string, id: string, hidden: boolean?, children: {Comp}?,
--               -- per-type props exactly as CATALOG lists them, defaults filled in --
--               _auto_id: boolean? }   -- stripped before JSON (state/llm_output)
--
-- type Spec = { title: string?, id: string, mode: "interactive"|"display"|"live",
--               root: Comp, warnings: {string} }   -- JSON-serializable, no back refs
--
-- type Value = string | number | boolean | {string} | {[string]: "accept"|"reject"}
-- type Values = {[string]: Value}                   -- keyed by input component id
--
-- type FormResult = { status: "submitted"|"cancelled"|"unavailable",
--                     values: Values?, action: string? }
--
-- type GenuiState = { v: number, widget: string, mode: string,   -- design.md §3.5
--                     status: string, values: Values?, action: string?,
--                     warnings: {string}?, spec: Spec? }
--
-- type CardState = { expanded: {[string]: boolean} }   -- click toggles only
--
-- type StyledSpan = { string, string | {fg: string?, bg: string?, bold: boolean?, dim: boolean?} }
-- type StyledLine = { StyledSpan }                      -- what Buf:set_lines takes
--
-- type RenderCtx = { width: number, markdown: (string, number) -> {StyledLine},
--                    display_width: (string) -> number, values: Values?,
--                    expanded: {[string]: boolean}, mode: "card"|"window" }
--
-- type RegistryEntry = { id: string, buf: any, spec: Spec, state: GenuiState,
--                        card: CardHandle, session_id: string?, created_at: number, closed: boolean }

local Schema = {}

-- Caps: a model can send anything; nothing here may blow up the card or the context.
Schema.MAX_NODES = 500 -- components per spec; extra children are dropped with a warning
Schema.MAX_DEPTH = 32
Schema.MAX_STRING = 20000 -- bytes per string prop
Schema.MAX_ARRAY = 500 -- default per-array cap (table rows, children, ...)
Schema.MAX_TITLE = 60
Schema.MAX_APPEND_LINES = 200

local MODES = { auto = true, interactive = true, display = true, live = true }

local function is_nil(v)
  return v == nil or (maki and v == maki.NIL)
end

-- A JSON object decoded from the model: a table that is not a sequence.
local function is_array(t)
  if type(t) ~= "table" then
    return false
  end
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
      return false
    end
    n = n + 1
  end
  if n == 0 then
    return true -- `{}`: ambiguous; callers decide
  end
  local max = 0
  for k in pairs(t) do
    if k > max then
      max = k
    end
  end
  return max <= math.max(10, n * 2)
end

local function is_object(t)
  if type(t) ~= "table" then
    return false
  end
  local n = 0
  for k in pairs(t) do
    n = n + 1
    if type(k) ~= "string" then
      return false
    end
  end
  return true
end

-- Sequence without holes and without JSON nulls, in index order.
local function densify(t)
  local out = {}
  local max = 0
  for k in pairs(t) do
    if type(k) == "number" and k > max then
      max = k
    end
  end
  for i = 1, max do
    local v = t[i]
    if not is_nil(v) then
      out[#out + 1] = v
    end
  end
  return out
end

local function deep_copy(v)
  if type(v) ~= "table" then
    return v
  end
  if maki and maki.deepcopy then
    return maki.deepcopy(v)
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = deep_copy(x)
  end
  return out
end

local function cut(s, max)
  if #s > max then
    return string.sub(s, 1, max) .. "…", true
  end
  return s, false
end

local function fmt(...)
  return string.format(...)
end

-- Per-type catalog. `props` lists every accepted prop with its coercion type,
-- default and (for strings) enum. `id`, `hidden`, `type` and `children` are
-- universal and handled by the normalizer, not listed here.
local function P(t, extra)
  local p = { type = t }
  if extra then
    for k, v in pairs(extra) do
      p[k] = v
    end
  end
  return p
end

local TONES = { "plain", "info", "success", "warning", "error", "dim" }

Schema.CATALOG = {
  stack = { props = {}, container = true },
  row = { props = { gap = P("number", { default = 2, min = 0, max = 8 }) }, container = true },
  section = {
    props = { title = P("string", { required = true, default = "" }), collapsed = P("boolean", { default = false }) },
    container = true,
  },
  text = {
    props = {
      text = P("string", { required = true, default = "" }),
      tone = P("string", { default = "plain", enum = TONES }),
      markdown = P("boolean", { default = true }),
    },
  },
  kv = { props = { items = P("any", { required = true }), key_width = P("number", { min = 1, max = 24 }) } },
  table = {
    props = {
      columns = P("array", { required = true, max = 32 }),
      rows = P("array", { required = true, max = 500 }),
      select = P("string", { default = "none", enum = { "none", "single", "multi" } }),
      key = P("string"),
      max_rows = P("number", { default = 20, min = 1, max = 500 }),
    },
    input = true,
    focusable = true,
  },
  bars = { props = { items = P("array", { required = true, max = 50 }), max = P("number"), unit = P("string") } },
  sparkline = { props = { values = P("array", { required = true, max = 200, keep = "tail" }), label = P("string") } },
  progress = {
    props = {
      label = P("string"),
      value = P("any", { required = true }),
      status = P("string", { default = "running", enum = { "running", "done", "error" } }),
    },
  },
  divider = { props = { label = P("string") } },
  badge = {
    props = {
      text = P("string", { required = true, default = "" }),
      tone = P("string", { default = "plain", enum = TONES }),
    },
  },
  checklist = { props = { items = P("array", { required = true, max = 200 }) } },
  diff = {
    props = {
      text = P("string"),
      before = P("string"),
      after = P("string"),
      path = P("string"),
      decide = P("boolean", { default = false }),
      max_lines = P("number", { default = 200, min = 1, max = 2000 }),
    },
    input = true,
    focusable = true,
  },
  choice = {
    props = {
      label = P("string", { required = true, default = "" }),
      options = P("array", { required = true, max = 100 }),
      multi = P("boolean", { default = false }),
      other = P("boolean", { default = true }),
      default = P("any"),
      required = P("boolean", { default = true }),
    },
    input = true,
    focusable = true,
  },
  input = {
    props = {
      label = P("string", { required = true, default = "" }),
      placeholder = P("string"),
      default = P("string"),
      multiline = P("boolean", { default = false }),
      required = P("boolean", { default = false }),
      min_len = P("number", { min = 0 }),
      max_len = P("number", { min = 0 }),
      pattern = P("string"),
      pattern_hint = P("string"),
    },
    input = true,
    focusable = true,
  },
  number = {
    props = {
      label = P("string", { required = true, default = "" }),
      default = P("number"),
      min = P("number"),
      max = P("number"),
      step = P("number", { default = 1 }),
      integer = P("boolean", { default = false }),
    },
    input = true,
    focusable = true,
  },
  confirm = {
    props = { label = P("string", { required = true, default = "" }), default = P("boolean", { default = false }) },
    input = true,
    focusable = true,
  },
  actions = { props = { items = P("array", { required = true, max = 8 }) }, input = true, focusable = true },
  unknown = { props = {} },
}

local ROOT_DESCRIPTION = table.concat({
  "Component tree. Every component: {type, id?, hidden?}. Containers (children: Component[]):",
  "stack{children}; row{children, gap=2}; section{title, collapsed=false, children}.",
  "Display: text{text, tone=plain|info|success|warning|error|dim, markdown=true};",
  "kv{items: [{key,value}] | {key: value}, key_width?};",
  "table{columns: (string|{key,label?,align?:left|right,width?})[], rows: (object|array)[], select=none|single|multi, key?, max_rows=20};",
  "bars{items: [{label,value}], max?, unit?}; sparkline{values: number[], label?};",
  "progress{label?, value: 0..1 | {done,total}, status=running|done|error}; divider{label?};",
  "badge{text, tone}; checklist{items: [{text,done}]};",
  "diff{text: unified diff | (before, after, path?), decide=false, max_lines=200}.",
  "Inputs (value keyed by id): choice{label, options: (string|{value?,label,description?})[], multi=false, other=true, default?, required=true};",
  "input{label, placeholder?, default?, multiline=false, required=false, min_len?, max_len?, pattern? (ECMA regex), pattern_hint?};",
  "number{label, default?, min?, max?, step=1, integer=false}; confirm{label, default=false};",
  "actions{items: [{action, label, style?:primary|danger|default}]} (buttons; the pressed action is returned; without it a Submit/Cancel row is added).",
  "Unknown types render as a placeholder with a warning.",
}, " ")

Schema.TOOL_SCHEMAS = {
  ui_render = {
    type = "object",
    required = { "root" },
    properties = {
      title = { type = "string", description = "Card/window title, <= 60 chars" },
      id = {
        type = "string",
        description = "Widget id for ui_update/ui_close (live mode). Auto-generated if absent.",
      },
      mode = {
        type = "string",
        enum = { "auto", "interactive", "display", "live" },
        default = "auto",
        description = "auto: interactive when any input component exists, else display. live: patchable with ui_update.",
      },
      -- No `properties`: maki parses that shape as an open object and keeps
      -- every key. A declared property list makes it drop the rest.
      root = {
        type = "object",
        description = ROOT_DESCRIPTION,
      },
    },
  },
  ui_update = {
    type = "object",
    required = { "id" },
    properties = {
      id = { type = "string", description = "Widget id given to or returned by ui_render(mode=live)" },
      patch = {
        type = "array",
        description = "Array of {id, ...props} merged into the component with that id. {id, append: string} appends a line to a text component.",
        -- Open object for the same reason: a `properties` list would strip
        -- every prop the patch carries. ui_update checks `id` itself.
        items = { type = "object", description = "One {id, ...props} patch item" },
      },
      root = { type = "object", description = "Replace the whole component tree" },
      title = { type = "string" },
    },
  },
  ui_close = {
    type = "object",
    required = { "id" },
    properties = {
      id = { type = "string" },
      status = { type = "string", enum = { "done", "error", "cancelled" } },
      note = { type = "string", description = "Final status line appended to the card" },
    },
  },
}

-- Hard (structural) errors abort normalization of the offending subtree; they
-- are collected on `counter.errors` so a reply can list the first few at once.
local function hard(counter, msg)
  counter.errors[#counter.errors + 1] = msg
end

-- Coerce one prop value. Returns the value to store (nil = absent).
local function coerce(def, v, path, warnings)
  if is_nil(v) then
    return nil
  end
  local t = def.type
  if t == "any" then
    return v
  elseif t == "string" then
    if type(v) == "number" then
      v = tostring(v)
    elseif type(v) ~= "string" then
      warnings[#warnings + 1] = fmt("%s: expected a string, got %s (ignored)", path, type(v))
      return nil
    end
    local s, was_cut = cut(v, Schema.MAX_STRING)
    if was_cut then
      warnings[#warnings + 1] = fmt("%s: string cut to %d bytes", path, Schema.MAX_STRING)
    end
    if def.enum then
      for _, e in ipairs(def.enum) do
        if e == s then
          return s
        end
      end
      warnings[#warnings + 1] =
        fmt("%s: %q is not one of %s (using %q)", path, s, table.concat(def.enum, "|"), tostring(def.default))
      return nil
    end
    return s
  elseif t == "number" then
    if type(v) == "string" then
      v = tonumber(v)
    end
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
      warnings[#warnings + 1] = fmt("%s: expected a number (ignored)", path)
      return nil
    end
    if def.min and v < def.min then
      v = def.min
    end
    if def.max and v > def.max then
      v = def.max
    end
    return v
  elseif t == "boolean" then
    if type(v) == "boolean" then
      return v
    end
    if v == "true" or v == 1 then
      return true
    end
    if v == "false" or v == 0 then
      return false
    end
    warnings[#warnings + 1] = fmt("%s: expected a boolean (ignored)", path)
    return nil
  elseif t == "array" then
    if type(v) ~= "table" or not is_array(v) then
      warnings[#warnings + 1] = fmt("%s: expected an array (ignored)", path)
      return nil
    end
    local arr = densify(v)
    local max = def.max or Schema.MAX_ARRAY
    if #arr > max then
      warnings[#warnings + 1] = fmt("%s: %d items cut to %d", path, #arr, max)
      if def.keep == "tail" then
        local tail = {}
        for i = #arr - max + 1, #arr do
          tail[#tail + 1] = arr[i]
        end
        arr = tail
      else
        for i = #arr, max + 1, -1 do
          arr[i] = nil
        end
      end
    end
    return arr
  elseif t == "object" then
    if type(v) ~= "table" or is_array(v) and next(v) ~= nil then
      warnings[#warnings + 1] = fmt("%s: expected an object (ignored)", path)
      return nil
    end
    return v
  end
  return v
end

local function scalar_string(v)
  if type(v) == "string" then
    return v
  elseif type(v) == "number" or type(v) == "boolean" then
    return tostring(v)
  end
  return nil
end

local function scalar_value(v)
  if type(v) == "string" or type(v) == "number" or type(v) == "boolean" then
    return v
  elseif is_nil(v) then
    return ""
  elseif type(v) == "table" and maki and maki.json then
    local s = maki.json.encode(v)
    return s or tostring(v)
  end
  return tostring(v)
end

-- Per-type second pass: item shapes, cross-prop rules. Runs after `coerce`
-- filled every prop. Mutates `comp`; soft problems go to `warnings`.
local FINISH = {}

FINISH.section = function(comp, path, warnings)
  if #comp.children == 0 then
    warnings[#warnings + 1] = fmt("%s: section has no children", path)
  end
end

FINISH.kv = function(comp, path, warnings)
  local items = comp.items
  local out = {}
  if type(items) == "table" and is_object(items) and next(items) ~= nil then
    local keys = {}
    for k in pairs(items) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
      out[#out + 1] = { key = k, value = scalar_value(items[k]) }
    end
  elseif type(items) == "table" then
    for i, it in ipairs(densify(items)) do
      if type(it) == "table" and scalar_string(it.key) then
        out[#out + 1] = { key = scalar_string(it.key), value = scalar_value(it.value) }
      elseif type(it) == "table" and not is_array(it) and next(it) ~= nil then
        -- {"Branch": "main"} one-pair object inside the array
        local k = next(it)
        out[#out + 1] = { key = tostring(k), value = scalar_value(it[k]) }
      else
        warnings[#warnings + 1] = fmt("%s.items[%d]: expected {key, value} (dropped)", path, i)
      end
    end
  elseif not is_nil(items) then
    warnings[#warnings + 1] = fmt("%s.items: expected an array or object (ignored)", path)
  end
  if #out > Schema.MAX_ARRAY then
    warnings[#warnings + 1] = fmt("%s.items: %d items cut to %d", path, #out, Schema.MAX_ARRAY)
    for i = #out, Schema.MAX_ARRAY + 1, -1 do
      out[i] = nil
    end
  end
  comp.items = out
end

FINISH.table = function(comp, path, warnings)
  local cols = {}
  for i, c in ipairs(comp.columns or {}) do
    local s = scalar_string(c)
    if s then
      cols[#cols + 1] = { key = s, label = s, align = "left" }
    elseif type(c) == "table" then
      local key = scalar_string(c.key) or scalar_string(c.label)
      if key then
        local col = { key = key, label = scalar_string(c.label) or key, align = "left" }
        if c.align == "right" then
          col.align = "right"
        elseif not is_nil(c.align) and c.align ~= "left" then
          warnings[#warnings + 1] = fmt("%s.columns[%d].align: expected left|right", path, i)
        end
        local w = tonumber(c.width)
        if w and w >= 1 then
          col.width = math.floor(w)
        end
        cols[#cols + 1] = col
      else
        warnings[#warnings + 1] = fmt("%s.columns[%d]: needs key or label (dropped)", path, i)
      end
    else
      warnings[#warnings + 1] = fmt("%s.columns[%d]: expected a string or object (dropped)", path, i)
    end
  end
  comp.columns = cols
  if #cols == 0 then
    warnings[#warnings + 1] = fmt("%s.columns: at least one column is required", path)
  end
  local rows = {}
  for i, r in ipairs(comp.rows or {}) do
    if type(r) ~= "table" then
      local s = scalar_string(r)
      if s then
        rows[#rows + 1] = { s }
      else
        warnings[#warnings + 1] = fmt("%s.rows[%d]: expected an object or array (dropped)", path, i)
      end
    elseif is_array(r) and next(r) ~= nil then
      local cells = {}
      for _, cell in ipairs(densify(r)) do
        cells[#cells + 1] = scalar_value(cell)
      end
      if #cells == 0 then
        warnings[#warnings + 1] = fmt("%s.rows[%d]: empty row (dropped)", path, i)
      else
        rows[#rows + 1] = cells
      end
    else
      local obj, n = {}, 0
      for k, cell in pairs(r) do
        obj[tostring(k)] = scalar_value(cell)
        n = n + 1
      end
      if n == 0 then
        warnings[#warnings + 1] = fmt("%s.rows[%d]: empty row (dropped)", path, i)
      else
        rows[#rows + 1] = obj
      end
    end
  end
  comp.rows = rows
  if comp.key then
    local found = false
    for _, c in ipairs(cols) do
      if c.key == comp.key then
        found = true
      end
    end
    if not found then
      warnings[#warnings + 1] = fmt("%s.key: %q is not a column (rows keyed by index)", path, comp.key)
      comp.key = nil
    end
  end
  comp.max_rows = math.floor(comp.max_rows or 20)
end

FINISH.bars = function(comp, path, warnings)
  local items = {}
  for i, it in ipairs(comp.items or {}) do
    local v = type(it) == "table" and tonumber(it.value) or nil
    local label = type(it) == "table" and scalar_string(it.label) or nil
    if v and v == v and label then
      items[#items + 1] = { label = label, value = v }
    else
      warnings[#warnings + 1] = fmt("%s.items[%d]: expected {label, value: number} (dropped)", path, i)
    end
  end
  comp.items = items
end

FINISH.sparkline = function(comp, path, warnings)
  local vals = {}
  local dropped = 0
  for _, v in ipairs(comp.values or {}) do
    local n = tonumber(v)
    if n and n == n then
      vals[#vals + 1] = n
    else
      dropped = dropped + 1
    end
  end
  if dropped > 0 then
    warnings[#warnings + 1] = fmt("%s.values: %d non-numeric values dropped", path, dropped)
  end
  comp.values = vals
end

FINISH.progress = function(comp, path, warnings)
  local v = comp.value
  if type(v) == "table" then
    local done, total = tonumber(v.done), tonumber(v.total)
    if done and total and total > 0 then
      comp.value = { done = math.max(0, math.min(done, total)), total = total }
      return
    end
    warnings[#warnings + 1] = fmt("%s.value: expected {done, total} (using 0)", path)
    comp.value = 0
    return
  end
  local n = tonumber(v)
  if not n or n ~= n then
    if not is_nil(v) then
      warnings[#warnings + 1] = fmt("%s.value: expected a number 0..1 (using 0)", path)
    end
    comp.value = 0
    return
  end
  if n > 1 and n <= 100 then
    n = n / 100 -- percent given instead of a fraction
  end
  comp.value = math.max(0, math.min(1, n))
end

FINISH.checklist = function(comp, path, warnings)
  local items = {}
  for i, it in ipairs(comp.items or {}) do
    local s = scalar_string(it)
    if s then
      items[#items + 1] = { text = s, done = false }
    elseif type(it) == "table" and scalar_string(it.text) then
      items[#items + 1] = { text = scalar_string(it.text), done = it.done == true or it.done == "true" }
    else
      warnings[#warnings + 1] = fmt("%s.items[%d]: expected {text, done} (dropped)", path, i)
    end
  end
  comp.items = items
end

FINISH.diff = function(comp, path, warnings)
  if not comp.text and not (comp.before and comp.after) then
    warnings[#warnings + 1] = fmt("%s: diff needs text or before+after", path)
    comp.text = comp.text or ""
  end
  comp.max_lines = math.floor(comp.max_lines or 200)
end

FINISH.choice = function(comp, path, warnings)
  local opts = {}
  local seen = {}
  for i, o in ipairs(comp.options or {}) do
    local label, value, desc
    local s = scalar_string(o)
    if s then
      label, value = s, s
    elseif type(o) == "table" then
      label = scalar_string(o.label) or scalar_string(o.value)
      value = scalar_string(o.value) or label
      desc = scalar_string(o.description)
    end
    if not label then
      warnings[#warnings + 1] =
        fmt("%s.options[%d]: expected a string or {label, value?, description?} (dropped)", path, i)
    elseif seen[value] then
      warnings[#warnings + 1] = fmt("%s.options[%d]: duplicate value %q (dropped)", path, i, value)
    else
      seen[value] = true
      opts[#opts + 1] = { value = value, label = label, description = desc }
    end
  end
  comp.options = opts
  if #opts == 0 then
    warnings[#warnings + 1] = fmt("%s.options: at least one option is required (free text enabled)", path)
    comp.other = true
  end
  local d = comp.default
  if is_nil(d) then
    comp.default = nil
  elseif comp.multi then
    local list = {}
    if type(d) == "table" then
      for _, x in ipairs(densify(d)) do
        local s2 = scalar_string(x)
        if s2 then
          list[#list + 1] = s2
        end
      end
    elseif scalar_string(d) then
      list[1] = scalar_string(d)
    end
    comp.default = list
  else
    if type(d) == "table" then
      d = densify(d)[1]
    end
    comp.default = scalar_string(d)
    if comp.default == nil and not is_nil(d) then
      warnings[#warnings + 1] = fmt("%s.default: expected a string (ignored)", path)
    end
  end
end

FINISH.input = function(comp, path, warnings)
  if comp.pattern and maki and maki.json and maki.json.schema_validator then
    if not Schema.compile_pattern(comp.pattern) then
      warnings[#warnings + 1] = fmt("%s.pattern: invalid regex %q (ignored)", path, comp.pattern)
      comp.pattern = nil
    end
  end
  if comp.min_len and comp.max_len and comp.min_len > comp.max_len then
    warnings[#warnings + 1] = fmt("%s: min_len > max_len (max_len ignored)", path)
    comp.max_len = nil
  end
  if comp.min_len then
    comp.min_len = math.floor(comp.min_len)
  end
  if comp.max_len then
    comp.max_len = math.floor(comp.max_len)
  end
end

FINISH.number = function(comp, path, warnings)
  if comp.min and comp.max and comp.min > comp.max then
    warnings[#warnings + 1] = fmt("%s: min > max (swapped)", path)
    comp.min, comp.max = comp.max, comp.min
  end
  if (comp.step or 1) <= 0 then
    warnings[#warnings + 1] = fmt("%s.step: must be > 0 (using 1)", path)
    comp.step = 1
  end
  if comp.default then
    if comp.integer then
      comp.default = math.floor(comp.default + 0.5)
    end
    if comp.min and comp.default < comp.min then
      comp.default = comp.min
    end
    if comp.max and comp.default > comp.max then
      comp.default = comp.max
    end
  end
end

FINISH.actions = function(comp, path, warnings)
  local items = {}
  local seen = {}
  for i, it in ipairs(comp.items or {}) do
    local action = type(it) == "table" and scalar_string(it.action) or scalar_string(it)
    if not action or action == "" then
      warnings[#warnings + 1] = fmt("%s.items[%d]: expected {action, label} (dropped)", path, i)
    elseif seen[action] then
      warnings[#warnings + 1] = fmt("%s.items[%d]: duplicate action %q (dropped)", path, i, action)
    else
      seen[action] = true
      local label = type(it) == "table" and scalar_string(it.label) or nil
      local style = type(it) == "table" and it.style or nil
      if style ~= "primary" and style ~= "danger" then
        if not is_nil(style) and style ~= "default" then
          warnings[#warnings + 1] = fmt("%s.items[%d].style: expected primary|danger|default", path, i)
        end
        style = "default"
      end
      items[#items + 1] = { action = action, label = label or action, style = style }
    end
  end
  comp.items = items
  if #items == 0 then
    warnings[#warnings + 1] = fmt("%s.items: at least one action is required", path)
  end
end

-- Reserve every explicit id in the raw tree so auto ids never collide with an
-- id the model gave to a later node (keeps `c1..cN` deterministic).
local function reserve_ids(raw, used_ids, depth)
  if type(raw) ~= "table" or depth > Schema.MAX_DEPTH then
    return
  end
  local id = scalar_string(raw.id)
  if id and id ~= "" and used_ids[id] == nil then
    used_ids[id] = "reserved"
  end
  if type(raw.children) == "table" then
    for _, child in pairs(raw.children) do
      reserve_ids(child, used_ids, depth + 1)
    end
  end
end

local function next_auto_id(used_ids, counter)
  local cand
  repeat
    counter.n = (counter.n or 0) + 1
    cand = "c" .. counter.n
  until not used_ids[cand]
  return cand
end

-- counter = { n = number, nodes = number, errors = {string}, depth = number? }
function Schema._normalize_component(raw, path, used_ids, counter, warnings)
  counter.errors = counter.errors or {}
  counter.nodes = (counter.nodes or 0) + 1
  local depth = counter.depth or 0
  if type(raw) ~= "table" or (is_array(raw) and next(raw) ~= nil) then
    hard(counter, fmt("%s must be an object", path))
    return { type = "unknown", id = next_auto_id(used_ids, counter), original = type(raw), _auto_id = true }
  end
  local comp = {}
  -- type
  local rtype = raw.type
  if is_nil(rtype) then
    hard(counter, fmt("%s.type is required", path))
    rtype = "unknown"
  elseif type(rtype) ~= "string" then
    hard(counter, fmt("%s.type must be a string", path))
    rtype = "unknown"
  end
  local def = Schema.CATALOG[rtype]
  if not def or rtype == "unknown" then
    if def == nil then
      warnings[#warnings + 1] = fmt("%s: unknown component %q (rendered as placeholder)", path, rtype)
    end
    comp.type = "unknown"
    comp.original = rtype
    def = Schema.CATALOG.unknown
  else
    comp.type = rtype
  end
  -- id
  local id = scalar_string(raw.id)
  if id == "" then
    id = nil
  end
  if not is_nil(raw.id) and id == nil then
    warnings[#warnings + 1] = fmt("%s.id: expected a string (auto id used)", path)
  end
  if id then
    if used_ids[id] == true then
      hard(counter, fmt("%s.id: duplicate id %q", path, id))
      id = nil
    else
      used_ids[id] = true
    end
  end
  if not id then
    id = next_auto_id(used_ids, counter)
    used_ids[id] = true
    comp._auto_id = true
  end
  comp.id = id
  -- hidden
  if not is_nil(raw.hidden) then
    local h = coerce({ type = "boolean" }, raw.hidden, path .. ".hidden", warnings)
    if h then
      comp.hidden = true
    end
  end
  -- props
  for name, pdef in pairs(def.props) do
    local v = coerce(pdef, raw[name], path .. "." .. name, warnings)
    if v == nil then
      if pdef.required and is_nil(raw[name]) then
        warnings[#warnings + 1] = fmt("%s.%s is required", path, name)
      end
      if pdef.default ~= nil then
        v = deep_copy(pdef.default)
      elseif pdef.required and pdef.type == "array" then
        v = {}
      end
    end
    comp[name] = v
  end
  -- unknown props
  if comp.type ~= "unknown" then
    for k in pairs(raw) do
      if
        type(k) == "string"
        and k ~= "type"
        and k ~= "id"
        and k ~= "hidden"
        and k ~= "children"
        and k ~= "_auto_id"
      then
        if def.props[k] == nil then
          warnings[#warnings + 1] = fmt("%s.%s: unknown prop for %s (dropped)", path, k, comp.type)
        end
      end
    end
  end
  -- children
  if def.container then
    local kids = raw.children
    if is_nil(kids) then
      kids = {}
    end
    if type(kids) ~= "table" or not is_array(kids) then
      hard(counter, fmt("%s.children must be an array", path))
      kids = {}
    end
    kids = densify(kids)
    comp.children = {}
    if depth + 1 > Schema.MAX_DEPTH then
      warnings[#warnings + 1] = fmt("%s.children: nesting deeper than %d dropped", path, Schema.MAX_DEPTH)
      kids = {}
    end
    for i, child in ipairs(kids) do
      if counter.nodes >= Schema.MAX_NODES then
        warnings[#warnings + 1] =
          fmt("%s.children: spec exceeds %d components, %d dropped", path, Schema.MAX_NODES, #kids - i + 1)
        break
      end
      counter.depth = depth + 1
      comp.children[#comp.children + 1] =
        Schema._normalize_component(child, fmt("%s.children[%d]", path, i), used_ids, counter, warnings)
      counter.depth = depth
    end
  elseif not is_nil(raw.children) and comp.type ~= "unknown" then
    warnings[#warnings + 1] = fmt("%s.children: %s is not a container (dropped)", path, comp.type)
  end
  local finish = FINISH[comp.type]
  if finish then
    finish(comp, path, warnings)
  end
  -- actions report `action`, not a keyed value, so they need no id
  if comp._auto_id and comp.type ~= "actions" and Schema.is_input(comp) then
    warnings[#warnings + 1] = fmt("%s: input component without id; result key is %q", path, comp.id)
  end
  return comp
end

local validator_cache = {}

local function tool_validator(name)
  local v = validator_cache[name]
  if v ~= nil then
    return v or nil
  end
  local ok, res = pcall(function()
    if maki and maki.json and maki.json.schema_validator then
      return (maki.json.schema_validator(Schema.TOOL_SCHEMAS[name]))
    end
    return nil
  end)
  validator_cache[name] = ok and res or false
  return validator_cache[name] or nil
end

function Schema._json_errors(name, input)
  local v = tool_validator(name)
  if not v then
    return {}
  end
  local ok, errs = pcall(function()
    return v:validate(input)
  end)
  if ok and type(errs) == "table" then
    local out = {}
    for _, e in ipairs(errs) do
      out[#out + 1] = tostring(e)
    end
    return out
  end
  return {}
end

local function normalize_root(raw_root, warnings, used_ids, counter)
  used_ids = used_ids or {}
  counter = counter or { n = 0 }
  counter.errors = counter.errors or {}
  counter.nodes = 0
  counter.depth = 0
  reserve_ids(raw_root, used_ids, 0)
  local root = Schema._normalize_component(raw_root, "root", used_ids, counter, warnings)
  return root, counter.errors
end

-- An input is a component whose value comes back in `values`: choice, input,
-- number, confirm, actions, table with select ~= "none", diff with decide.
function Schema.is_input(comp)
  if type(comp) ~= "table" then
    return false
  end
  local def = Schema.CATALOG[comp.type]
  if not def or not def.input then
    return false
  end
  if comp.type == "table" then
    return comp.select ~= nil and comp.select ~= "none"
  elseif comp.type == "diff" then
    return comp.decide == true
  end
  return true
end

local function has_input(root)
  local found = false
  local function visit(comp)
    if type(comp) ~= "table" or comp.hidden or found then
      return
    end
    if Schema.is_input(comp) then
      found = true
      return
    end
    if type(comp.children) == "table" then
      for _, child in ipairs(comp.children) do
        visit(child)
      end
    end
  end
  visit(root)
  return found
end

function Schema.validate(input)
  local ok, a, b, c = pcall(function()
    local errors, warnings = {}, {}
    if type(input) ~= "table" or is_nil(input) then
      return false, { "input must be an object" }, nil
    end
    local raw_root = input.root
    if is_nil(raw_root) then
      errors[#errors + 1] = "root is required"
    elseif type(raw_root) ~= "table" or (is_array(raw_root) and next(raw_root) ~= nil) then
      errors[#errors + 1] = "root must be an object"
    end
    local mode = input.mode
    if is_nil(mode) or mode == "" then
      mode = "auto"
    elseif type(mode) ~= "string" or not MODES[mode] then
      errors[#errors + 1] = fmt("mode must be one of auto|interactive|display|live, got %s", tostring(mode))
    end
    if #errors > 0 then
      return false, errors, nil
    end
    local spec = { warnings = warnings }
    local title = scalar_string(input.title)
    if title then
      local t, was_cut = cut(title, Schema.MAX_TITLE)
      if was_cut then
        warnings[#warnings + 1] = fmt("title cut to %d chars", Schema.MAX_TITLE)
      end
      spec.title = (string.gsub(t, "[\r\n]+", " "))
    elseif not is_nil(input.title) then
      warnings[#warnings + 1] = "title: expected a string (ignored)"
    end
    local id = scalar_string(input.id)
    if id and id ~= "" then
      spec.id = (string.sub(id, 1, 64))
    elseif not is_nil(input.id) then
      warnings[#warnings + 1] = "id: expected a string (auto id used)"
    end
    local root, hard_errors = normalize_root(raw_root, warnings)
    if #hard_errors > 0 then
      return false, hard_errors, nil
    end
    spec.root = root
    if mode == "auto" then
      mode = has_input(root) and "interactive" or "display"
    end
    spec.mode = mode
    return true, {}, spec
  end)
  if not ok then
    return false, { "internal: " .. tostring(a) }, nil
  end
  return a, b, c
end

function Schema.walk(root, fn)
  local function visit(comp, parent, depth)
    if type(comp) ~= "table" then
      return
    end
    fn(comp, parent, depth)
    if type(comp.children) == "table" then
      for _, child in ipairs(comp.children) do
        visit(child, comp, depth + 1)
      end
    end
  end
  visit(root, nil, 0)
end

function Schema.find(spec, id)
  if type(spec) ~= "table" or id == nil then
    return nil
  end
  local found = nil
  Schema.walk(spec.root, function(comp)
    if found == nil and comp.id == id then
      found = comp
    end
  end)
  return found
end

function Schema.focusables(spec)
  local out = {}
  if type(spec) ~= "table" then
    return out
  end
  local function visit(comp)
    if type(comp) ~= "table" or comp.hidden then
      return
    end
    local def = Schema.CATALOG[comp.type]
    if def and def.focusable and Schema.is_input(comp) then
      out[#out + 1] = comp
    end
    if type(comp.children) == "table" then
      for _, child in ipairs(comp.children) do
        visit(child)
      end
    end
  end
  visit(spec.root)
  return out
end

local pattern_cache = {}

function Schema.compile_pattern(pat)
  if type(pat) ~= "string" or pat == "" then
    return nil
  end
  local cached = pattern_cache[pat]
  if cached ~= nil then
    return cached or nil
  end
  local ok, v = pcall(function()
    if not (maki and maki.json and maki.json.schema_validator) then
      return nil
    end
    local validator, err = maki.json.schema_validator({ type = "string", pattern = pat })
    if not validator or err then
      return nil
    end
    -- some engines only fail at match time
    local probe = validator:validate("")
    if probe ~= nil and type(probe) ~= "table" then
      return nil
    end
    return validator
  end)
  local result = ok and v or nil
  pattern_cache[pat] = result or false
  return result
end

local function strip_rec(t)
  if type(t) ~= "table" then
    return t
  end
  t._auto_id = nil
  for _, v in pairs(t) do
    if type(v) == "table" then
      strip_rec(v)
    end
  end
  return t
end

function Schema.strip(spec)
  local copy = deep_copy(spec)
  return strip_rec(copy)
end

local function all_ids(spec)
  local ids = {}
  Schema.walk(spec.root, function(comp)
    ids[comp.id] = true
  end)
  return ids
end

local function ids_under(comp)
  local ids = {}
  Schema.walk(comp, function(c)
    ids[c.id] = true
  end)
  return ids
end

local function append_text(comp, line)
  local text = comp.text or ""
  local s = scalar_string(line) or ""
  text = (text == "" and s) or (text .. "\n" .. s)
  local lines = {}
  for l in string.gmatch(text .. "\n", "(.-)\n") do
    lines[#lines + 1] = l
  end
  if #lines > Schema.MAX_APPEND_LINES then
    local tail = {}
    for i = #lines - Schema.MAX_APPEND_LINES + 1, #lines do
      tail[#tail + 1] = lines[i]
    end
    lines = tail
  end
  comp.text = table.concat(lines, "\n")
end

-- Returns a NEW spec and the warnings produced; `spec.warnings` on the copy
-- holds the same list so a repaint can show them.
function Schema.apply_patch(spec, patch, root)
  local warnings = {}
  local new_spec = deep_copy(spec)
  new_spec.warnings = warnings
  if not is_nil(root) then
    if type(root) ~= "table" or (is_array(root) and next(root) ~= nil) then
      warnings[#warnings + 1] = "root must be an object (ignored)"
    else
      local new_root, hard_errors = normalize_root(root, warnings)
      if #hard_errors > 0 then
        for _, e in ipairs(hard_errors) do
          warnings[#warnings + 1] = e .. " (root replace ignored)"
        end
      else
        new_spec.root = new_root
      end
    end
  end
  if is_nil(patch) then
    return new_spec, warnings
  end
  if type(patch) ~= "table" or not is_array(patch) then
    warnings[#warnings + 1] = "patch must be an array (ignored)"
    return new_spec, warnings
  end
  for i, item in ipairs(densify(patch)) do
    local ppath = fmt("patch[%d]", i)
    local id = type(item) == "table" and scalar_string(item.id) or nil
    if not id then
      warnings[#warnings + 1] = fmt("%s: id is required (skipped)", ppath)
    else
      local comp = Schema.find(new_spec, id)
      if not comp then
        warnings[#warnings + 1] = fmt("%s: unknown component id %q (skipped)", ppath, id)
      else
        local def = Schema.CATALOG[comp.type] or Schema.CATALOG.unknown
        for k, v in pairs(item) do
          local kpath = ppath .. "." .. tostring(k)
          if k == "id" or type(k) ~= "string" then
            -- key
          elseif k == "hidden" then
            local h = coerce({ type = "boolean" }, v, kpath, warnings)
            if h ~= nil then
              comp.hidden = h or nil
            end
          elseif k == "append" and comp.type == "text" then
            append_text(comp, v)
          elseif k == "children" and def.container then
            if type(v) ~= "table" or not is_array(v) then
              warnings[#warnings + 1] = fmt("%s: children must be an array (ignored)", kpath)
            else
              local used = all_ids(new_spec)
              for old in pairs(ids_under(comp)) do
                if old ~= comp.id then
                  used[old] = nil
                end
              end
              local counter = { n = 0, errors = {}, nodes = 0, depth = 1 }
              for _, child in ipairs(densify(v)) do
                reserve_ids(child, used, 1)
              end
              local kids = {}
              for j, child in ipairs(densify(v)) do
                kids[#kids + 1] = Schema._normalize_component(child, fmt("%s[%d]", kpath, j), used, counter, warnings)
              end
              if #counter.errors > 0 then
                for _, e in ipairs(counter.errors) do
                  warnings[#warnings + 1] = e .. " (children ignored)"
                end
              else
                comp.children = kids
              end
            end
          elseif k == "type" then
            warnings[#warnings + 1] = fmt("%s: type cannot be patched (use root)", kpath)
          elseif def.props[k] then
            local pdef = def.props[k]
            local nv = coerce(pdef, v, kpath, warnings)
            if nv == nil and pdef.default ~= nil then
              nv = deep_copy(pdef.default)
            elseif nv == nil and pdef.required and pdef.type == "array" then
              nv = {}
            end
            comp[k] = nv
          else
            warnings[#warnings + 1] = fmt("%s: unknown prop for %s (dropped)", kpath, comp.type)
          end
        end
        local finish = FINISH[comp.type]
        if finish then
          -- re-run item normalization on the merged component; arrays were
          -- coerced above, so finish sees the same shapes as validate does
          local okf, err = pcall(finish, comp, ppath, warnings)
          if not okf then
            warnings[#warnings + 1] = fmt("%s: %s", ppath, tostring(err))
          end
        end
      end
    end
  end
  return new_spec, warnings
end

-- Ids of input components (the keys a result may carry), preorder.
function Schema.input_ids(spec)
  local out = {}
  if type(spec) ~= "table" then
    return out
  end
  Schema.walk(spec.root, function(comp)
    if Schema.is_input(comp) then
      out[#out + 1] = comp.id
    end
  end)
  return out
end

-- All component ids, preorder (what ui_update may patch).
function Schema.ids(spec)
  local out = {}
  if type(spec) ~= "table" then
    return out
  end
  Schema.walk(spec.root, function(comp)
    out[#out + 1] = comp.id
  end)
  return out
end

Schema._densify = densify
Schema._is_array = is_array

return Schema
