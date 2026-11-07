-- Schema suite: validate / normalize / apply_patch / focusables / strip.
local Schema = require("genui.schema")

local function form_input()
  return {
    title = "Deploy",
    root = {
      type = "stack",
      children = {
        { type = "choice", id = "env", label = "Environment", options = { "staging", "prod" } },
        { type = "confirm", id = "migrate", label = "Run migrations?" },
        { type = "input", id = "tag", label = "Release tag", pattern = "^v\\d+" },
      },
    },
  }
end

local function every_p0()
  return {
    root = {
      type = "stack",
      children = {
        { type = "section", title = "S", children = { { type = "text", text = "hello" } } },
        { type = "kv", items = { b = "2", a = 1 } },
        {
          type = "table",
          columns = { "file", { key = "line", align = "right" } },
          rows = { { "a.rs", 12 }, { file = "b.rs", line = 40 } },
        },
        { type = "bars", items = { { label = "core", value = 91 }, { label = "net", value = "42" } } },
        { type = "sparkline", values = { 1, "2", 3, "x" } },
        { type = "progress", value = { done = 2, total = 4 } },
        { type = "progress", value = 40 },
        { type = "divider", label = "d" },
        { type = "badge", text = "b" },
        { type = "checklist", items = { "one", { text = "two", done = true } } },
        { type = "diff", text = "@@ -1 +1 @@\n-a\n+b" },
        { type = "choice", id = "c", label = "C", options = { { label = "x", description = "d" } } },
        { type = "input", id = "i", label = "I" },
        { type = "number", id = "n", label = "N", min = 10, max = 1, default = "3" },
        { type = "confirm", id = "y", label = "Y" },
        { type = "actions", items = { { action = "go", label = "Go" }, "stop" } },
      },
    },
  }
end

local function join(list)
  return table.concat(list or {}, "\n")
end

return function(h)
  h.case("rejects missing root", function()
    local ok, errors = Schema.validate({})
    h.eq(ok, false)
    h.has(join(errors), "root")
  end)

  h.case("rejects non-object root and bad mode", function()
    local ok, errors = Schema.validate({ root = "x" })
    h.eq(ok, false)
    h.has(join(errors), "root must be an object")
    ok, errors = Schema.validate({ root = { type = "stack" }, mode = "sideways" })
    h.eq(ok, false)
    h.has(join(errors), "mode")
  end)

  h.case("rejects non-array children naming the path", function()
    local ok, errors = Schema.validate({ root = { type = "stack", children = { type = "text", text = "x" } } })
    h.eq(ok, false)
    h.has(join(errors), "root.children must be an array")
  end)

  h.case("rejects non-string type naming the path", function()
    local ok, errors = Schema.validate({ root = { type = "stack", children = { { type = "text" }, { type = 3 } } } })
    h.eq(ok, false)
    h.has(join(errors), "root.children[2].type must be a string")
  end)

  h.case("rejects duplicate ids", function()
    local ok, errors = Schema.validate({
      root = {
        type = "stack",
        children = { { type = "text", id = "a", text = "1" }, { type = "text", id = "a", text = "2" } },
      },
    })
    h.eq(ok, false)
    h.has(join(errors), 'root.children[2].id: duplicate id "a"')
  end)

  h.case("never raises on garbage input", function()
    for _, bad in ipairs({ 1, "s", true, { root = 1 }, { root = {} }, { root = { type = "stack", children = 5 } } }) do
      local ok, errors, spec = Schema.validate(bad)
      h.eq(ok, false)
      h.ok(#errors > 0, "errors listed")
      h.eq(spec, nil)
    end
    local ok = Schema.validate({ root = { type = "stack", children = { { type = "text", text = "x" } }, mode = "" } })
    h.ok(ok, "empty mode treated as auto")
  end)

  h.case("accepts every P0 component with defaults filled", function()
    local ok, errors, spec = Schema.validate(every_p0())
    h.eq(ok, true, join(errors))
    local kids = spec.root.children
    h.eq(#kids, 16)
    h.eq(kids[1].collapsed, false)
    h.eq(kids[1].children[1].tone, "plain")
    h.eq(kids[1].children[1].markdown, true)
    h.deep_eq(kids[2].items, { { key = "a", value = 1 }, { key = "b", value = "2" } })
    h.eq(kids[3].select, "none")
    h.eq(kids[3].max_rows, 20)
    h.eq(kids[3].columns[1].key, "file")
    h.eq(kids[3].columns[2].align, "right")
    h.eq(kids[3].columns[2].label, "line")
    h.eq(kids[3].rows[1][2], 12)
    h.eq(kids[3].rows[2].line, 40)
    h.eq(kids[4].items[2].value, 42)
    h.deep_eq(kids[5].values, { 1, 2, 3 })
    h.deep_eq(kids[6].value, { done = 2, total = 4 })
    h.eq(kids[6].status, "running")
    h.eq(kids[7].value, 0.4)
    h.eq(kids[9].tone, "plain")
    h.deep_eq(kids[10].items, { { text = "one", done = false }, { text = "two", done = true } })
    h.eq(kids[11].decide, false)
    h.eq(kids[11].max_lines, 200)
    h.eq(kids[12].multi, false)
    h.eq(kids[12].other, true)
    h.eq(kids[12].required, true)
    h.deep_eq(kids[12].options[1], { value = "x", label = "x", description = "d" })
    h.eq(kids[13].multiline, false)
    h.eq(kids[13].required, false)
    h.eq(kids[14].step, 1)
    h.eq(kids[14].integer, false)
    h.eq(kids[14].min, 1)
    h.eq(kids[14].max, 10)
    h.eq(kids[14].default, 3)
    h.eq(kids[15].default, false)
    h.deep_eq(kids[16].items[2], { action = "stop", label = "stop", style = "default" })
    h.has(join(spec.warnings), "non-numeric")
    h.has(join(spec.warnings), "min > max")
  end)

  h.case("auto ids are c1..cN preorder and stable", function()
    local input = {
      root = {
        type = "stack",
        children = {
          { type = "section", title = "a", children = { { type = "text", text = "t" } } },
          { type = "text", id = "named", text = "u" },
          { type = "text", text = "v" },
        },
      },
    }
    local _, _, s1 = Schema.validate(input)
    local _, _, s2 = Schema.validate(input)
    h.eq(s1.root.id, "c1")
    h.eq(s1.root.children[1].id, "c2")
    h.eq(s1.root.children[1].children[1].id, "c3")
    h.eq(s1.root.children[2].id, "named")
    h.eq(s1.root.children[3].id, "c4")
    h.eq(s1.root._auto_id, true)
    h.eq(s1.root.children[2]._auto_id, nil)
    h.deep_eq(Schema.ids(s1), Schema.ids(s2))
  end)

  h.case("explicit ids never collide with auto ids", function()
    local _, _, spec = Schema.validate({
      root = { type = "stack", children = { { type = "text", text = "a" }, { type = "text", id = "c2", text = "b" } } },
    })
    h.eq(spec.root.id, "c1")
    h.eq(spec.root.children[1].id, "c3")
    h.eq(spec.root.children[2].id, "c2")
  end)

  h.case("unknown type becomes a placeholder with a warning", function()
    local ok, _, spec = Schema.validate({ root = { type = "stack", children = { { type = "slider", min = 0 } } } })
    h.eq(ok, true)
    h.eq(spec.root.children[1].type, "unknown")
    h.eq(spec.root.children[1].original, "slider")
    h.has(join(spec.warnings), 'root.children[1]: unknown component "slider"')
  end)

  h.case("unknown and mistyped props warn and default", function()
    local _, _, spec = Schema.validate({
      root = { type = "text", text = 42, tone = "loud", markdown = "false", bogus = 1 },
    })
    local w = join(spec.warnings)
    h.eq(spec.root.text, "42")
    h.eq(spec.root.tone, "plain")
    h.eq(spec.root.markdown, false)
    h.eq(spec.root.bogus, nil)
    h.has(w, "root.tone")
    h.has(w, "root.bogus: unknown prop")
  end)

  h.case("mode auto resolves both ways; explicit modes kept", function()
    local _, _, s = Schema.validate(form_input())
    h.eq(s.mode, "interactive")
    _, _, s = Schema.validate({ root = { type = "text", text = "x" } })
    h.eq(s.mode, "display")
    _, _, s = Schema.validate({ root = { type = "choice", label = "l", options = { "a" } }, mode = "display" })
    h.eq(s.mode, "display")
    _, _, s = Schema.validate({ root = { type = "text", text = "x" }, mode = "live" })
    h.eq(s.mode, "live")
    _, _, s = Schema.validate({ root = { type = "choice", label = "l", options = { "a" }, hidden = true } })
    h.eq(s.mode, "display", "hidden inputs do not make a form")
    _, _, s = Schema.validate({ root = { type = "table", columns = { "a" }, rows = { { "1" } } } })
    h.eq(s.mode, "display", "select=none table is display-only")
    h.eq(#s.warnings, 0, "no id warning for a display table")
    h.deep_eq(Schema.input_ids(s), {})
    _, _, s = Schema.validate({ root = { type = "table", columns = { "a" }, rows = { { "1" } }, select = "multi" } })
    h.eq(s.mode, "interactive")
    h.has(table.concat(s.warnings, "\n"), "input component without id")
    _, _, s = Schema.validate({ root = { type = "diff", text = "@@ -1 +1 @@\n-a\n+b" } })
    h.eq(s.mode, "display", "decide=false diff is display-only")
    _, _, s = Schema.validate({ root = { type = "diff", text = "@@ -1 +1 @@\n-a\n+b", decide = true } })
    h.eq(s.mode, "interactive")
  end)

  h.case("input without id gets an auto id and a warning", function()
    local _, _, spec = Schema.validate({ root = { type = "input", label = "Name" } })
    h.eq(spec.root.id, "c1")
    h.has(join(spec.warnings), "input component without id")
  end)

  h.case("title and widget id are normalized", function()
    local _, _, spec = Schema.validate({ title = string.rep("x", 70), id = 12, root = { type = "text", text = "t" } })
    h.ok(#spec.title <= 64, "title cut")
    h.eq(spec.id, "12")
    h.has(join(spec.warnings), "title cut")
  end)

  h.case("caps: rows > 500 cut, options > 100 cut, nodes > MAX_NODES dropped", function()
    local rows = {}
    for i = 1, 600 do
      rows[i] = { tostring(i) }
    end
    local _, _, spec = Schema.validate({ root = { type = "table", columns = { "n" }, rows = rows } })
    h.eq(#spec.root.rows, 500)
    h.has(join(spec.warnings), "600 items cut to 500")
    local kids = {}
    for i = 1, Schema.MAX_NODES + 10 do
      kids[i] = { type = "text", text = "t" }
    end
    _, _, spec = Schema.validate({ root = { type = "stack", children = kids } })
    h.eq(#spec.root.children, Schema.MAX_NODES - 1)
    h.has(join(spec.warnings), "exceeds")
  end)

  h.case("sparse arrays and nulls are densified", function()
    local kids = { [1] = { type = "text", text = "a" }, [3] = { type = "text", text = "b" } }
    if maki and maki.NIL then
      kids[2] = maki.NIL
    end
    local ok, _, spec = Schema.validate({ root = { type = "stack", children = kids } })
    h.eq(ok, true)
    h.eq(#spec.root.children, 2)
    h.eq(spec.root.children[2].text, "b")
  end)

  h.case("table rows: empty rows dropped, bad key warned", function()
    local _, _, spec = Schema.validate({
      root = { type = "table", columns = { "a" }, rows = { {}, { "x" }, 7 }, key = "zzz" },
    })
    h.eq(#spec.root.rows, 2)
    h.eq(spec.root.key, nil)
    local w = join(spec.warnings)
    h.has(w, "rows[1]: empty row")
    h.has(w, 'key: "zzz" is not a column')
  end)

  h.case("choice defaults: multi list vs single string", function()
    local _, _, s =
      Schema.validate({ root = { type = "choice", label = "l", options = { "a", "b" }, default = { "a" } } })
    h.eq(s.root.default, "a")
    _, _, s =
      Schema.validate({ root = { type = "choice", label = "l", options = { "a" }, multi = true, default = "a" } })
    h.deep_eq(s.root.default, { "a" })
    _, _, s = Schema.validate({ root = { type = "choice", label = "l", options = {} } })
    h.eq(s.root.other, true)
    h.has(join(s.warnings), "at least one option")
  end)

  h.case("focusables respect table.select, diff.decide and hidden", function()
    local _, _, spec = Schema.validate({
      root = {
        type = "stack",
        children = {
          { type = "table", id = "t0", columns = { "a" }, rows = { { "1" } } },
          { type = "table", id = "t1", columns = { "a" }, rows = { { "1" } }, select = "multi" },
          { type = "diff", id = "d0", text = "@@ -1 +1 @@\n-a\n+b" },
          { type = "diff", id = "d1", text = "@@ -1 +1 @@\n-a\n+b", decide = true },
          { type = "input", id = "hid", label = "x", hidden = true },
          {
            type = "section",
            title = "s",
            hidden = true,
            children = { { type = "confirm", id = "inside", label = "c" } },
          },
          { type = "confirm", id = "ok", label = "ok" },
          { type = "actions", id = "acts", items = { { action = "go", label = "Go" } } },
        },
      },
    })
    local ids = {}
    for _, c in ipairs(Schema.focusables(spec)) do
      ids[#ids + 1] = c.id
    end
    h.deep_eq(ids, { "t1", "d1", "ok", "acts" })
  end)

  h.case("find and walk", function()
    local _, _, spec = Schema.validate(form_input())
    h.eq(Schema.find(spec, "tag").type, "input")
    h.eq(Schema.find(spec, "nope"), nil)
    local seen = {}
    Schema.walk(spec.root, function(comp, parent, depth)
      seen[#seen + 1] = comp.id .. ":" .. depth .. ":" .. tostring(parent and parent.id)
    end)
    h.deep_eq(seen, { "c1:0:nil", "env:1:c1", "migrate:1:c1", "tag:1:c1" })
    h.deep_eq(Schema.input_ids(spec), { "env", "migrate", "tag" })
  end)

  h.case("compile_pattern returns a validator for good regex, nil for bad", function()
    if not (maki and maki.json and maki.json.schema_validator) then
      return
    end
    local v = Schema.compile_pattern("^v\\d+")
    h.ok(v ~= nil, "valid pattern compiles")
    h.eq(v:validate("v12"), nil)
    h.ok(v:validate("x") ~= nil, "mismatch reported")
    h.eq(Schema.compile_pattern("("), nil)
    h.eq(Schema.compile_pattern(""), nil)
    h.eq(Schema.compile_pattern(5), nil)
    local _, _, spec = Schema.validate({ root = { type = "input", id = "i", label = "l", pattern = "(" } })
    h.eq(spec.root.pattern, nil)
    h.has(join(spec.warnings), "invalid regex")
  end)

  h.case("apply_patch merges props, warns on unknown id, never mutates input", function()
    local _, _, spec = Schema.validate({
      id = "build",
      mode = "live",
      root = {
        type = "stack",
        children = {
          { type = "progress", id = "p", label = "tests", value = 0 },
          { type = "text", id = "log", text = "" },
        },
      },
    })
    local before = Schema.strip(spec)
    local new_spec, warnings = Schema.apply_patch(spec, {
      { id = "p", value = 0.6 },
      { id = "log", text = "412/700 passed" },
      { id = "ghost", text = "x" },
      { id = "p", bogus = 1 },
    })
    h.eq(Schema.find(new_spec, "p").value, 0.6)
    h.eq(Schema.find(new_spec, "log").text, "412/700 passed")
    h.eq(Schema.find(spec, "p").value, 0, "input spec untouched")
    h.eq(Schema.find(spec, "log").text, "")
    h.deep_eq(Schema.strip(spec), before)
    local w = join(warnings)
    h.has(w, 'patch[3]: unknown component id "ghost"')
    h.has(w, "patch[4].bogus: unknown prop")
    h.ok(new_spec ~= spec and new_spec.root ~= spec.root, "new tables")
  end)

  h.case("apply_patch root replaces and re-normalizes; bad root is a warning", function()
    local _, _, spec = Schema.validate({ root = { type = "text", id = "t", text = "a" } })
    local new_spec, warnings =
      Schema.apply_patch(spec, nil, { type = "stack", children = { { type = "text", text = "b" } } })
    h.eq(new_spec.root.type, "stack")
    h.eq(new_spec.root.children[1].id, "c2")
    h.eq(#warnings, 0)
    h.eq(spec.root.type, "text")
    local same, w2 = Schema.apply_patch(spec, nil, { type = "stack", children = 3 })
    h.eq(same.root.type, "text")
    h.has(join(w2), "children must be an array")
  end)

  h.case("apply_patch append keeps the last lines; hidden and children patches", function()
    local _, _, spec = Schema.validate({
      root = { type = "stack", id = "root", children = { { type = "text", id = "log", text = "l1" } } },
    })
    local s2 = Schema.apply_patch(spec, { { id = "log", append = "l2" }, { id = "log", hidden = true } })
    h.eq(Schema.find(s2, "log").text, "l1\nl2")
    h.eq(Schema.find(s2, "log").hidden, true)
    local s3 = Schema.apply_patch(spec, { { id = "root", children = { { type = "badge", text = "new" } } } })
    h.eq(#s3.root.children, 1)
    h.eq(s3.root.children[1].type, "badge")
    h.eq(s3.root.children[1].id, "c1")
    h.eq(Schema.find(s3, "log"), nil)
    local s4, w4 = Schema.apply_patch(spec, "nope")
    h.eq(s4.root.children[1].text, "l1")
    h.has(join(w4), "patch must be an array")
  end)

  h.case("strip removes _auto_id everywhere and copies", function()
    local _, _, spec = Schema.validate(form_input())
    local stripped = Schema.strip(spec)
    local found = false
    Schema.walk(stripped.root, function(c)
      if c._auto_id ~= nil then
        found = true
      end
    end)
    h.eq(found, false)
    h.eq(spec.root._auto_id, true, "original keeps the flag")
    h.ok(stripped.root ~= spec.root, "copy")
  end)

  h.case("TOOL_SCHEMAS compile with maki.json.schema_validator", function()
    if not (maki and maki.json and maki.json.schema_validator) then
      return
    end
    for name, schema in pairs(Schema.TOOL_SCHEMAS) do
      local v, err = maki.json.schema_validator(schema)
      h.ok(v ~= nil, name .. ": " .. tostring(err))
    end
    h.ok(#Schema._json_errors("ui_render", {}) > 0, "missing root reported")
    h.eq(#Schema._json_errors("ui_render", { root = { type = "text" } }), 0)
  end)

  h.case("fixtures from helpers validate", function()
    local names = { "form", "table", "diff", "dashboard", "report" }
    for _, name in ipairs(names) do
      local okf, fx = pcall(function()
        return require("genui.tests.helpers").fixtures[name]
      end)
      if okf and type(fx) == "table" then
        local ok, errors = Schema.validate(fx)
        h.eq(ok, true, name .. ": " .. join(errors))
      end
    end
  end)
end
