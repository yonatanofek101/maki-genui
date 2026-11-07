-- Suite: every example in `genui.examples` is a valid `ui_render` input and the
-- set covers the whole P0 catalog, so `/genui demo <name>` never shows a
-- placeholder and the README snippets stay honest.

local Examples = require("genui.examples")
local Helpers = require("genui.tests.helpers")
local Schema = require("genui.schema")

local P0 = {
  "stack",
  "section",
  "text",
  "kv",
  "table",
  "choice",
  "input",
  "number",
  "confirm",
  "actions",
  "progress",
  "divider",
  "bars",
  "sparkline",
  "diff",
}

local function types_in(raw)
  local seen = {}
  local function walk(node)
    if type(node) ~= "table" then
      return
    end
    if type(node.type) == "string" then
      seen[node.type] = true
    end
    for _, child in ipairs(node.children or {}) do
      walk(child)
    end
  end
  walk(raw.root)
  return seen
end

return function(h)
  h.case("list() is ordered and matches specs", function()
    local names = Examples.list()
    h.ok(#names >= 20, "expected at least 20 examples, got " .. #names)
    for _, name in ipairs(names) do
      h.ok(Examples.specs[name] ~= nil, "missing spec for " .. name)
    end
    local n = 0
    for _ in pairs(Examples.specs) do
      n = n + 1
    end
    h.eq(n, #names, "specs and catalog disagree")
  end)

  h.case("get() returns a fresh deep copy", function()
    local a, b = Examples.get("form"), Examples.get("form")
    h.ok(a ~= b and a.root ~= b.root, "copies must not share tables")
    a.root.children[1].id = "changed"
    h.eq(Examples.specs.form.root.children[1].id, "env", "get() must not expose the original")
    h.eq(Examples.get("nope"), nil)
  end)

  h.case("required demo names exist", function()
    for _, name in ipairs({ "form", "table", "diff", "dashboard", "report" }) do
      h.ok(Examples.specs[name] ~= nil, "missing " .. name)
    end
  end)

  h.case("examples cover every P0 component", function()
    local covered = {}
    for _, name in ipairs(Examples.list()) do
      for t in pairs(types_in(Examples.specs[name])) do
        covered[t] = true
      end
    end
    for _, t in ipairs(P0) do
      h.ok(covered[t], "no example uses " .. t)
    end
  end)

  h.case("every P0 type is in Schema.CATALOG", function()
    for _, t in ipairs(P0) do
      h.ok(Schema.CATALOG[t] ~= nil, "CATALOG lacks " .. t)
    end
  end)

  for _, name in ipairs(Examples.list()) do
    h.case("validates without errors or warnings: " .. name, function()
      local raw = Helpers.fixture(name)
      local ok, errors, spec = Schema.validate(raw)
      h.ok(ok, "errors: " .. table.concat(errors or {}, "; "))
      h.ok(spec ~= nil, "no spec returned")
      h.eq(#(spec.warnings or {}), 0, "warnings: " .. table.concat(spec.warnings or {}, "; "))
      h.ok(spec.mode == "interactive" or spec.mode == "display" or spec.mode == "live", "mode " .. tostring(spec.mode))
      h.eq(type(spec.root.id), "string", "root must get an id")
    end)
  end

  h.case("mode auto resolves from inputs", function()
    local _, _, form = Schema.validate(Helpers.fixture("form"))
    h.eq(form.mode, "interactive")
    local _, _, report = Schema.validate(Helpers.fixture("report"))
    h.eq(report.mode, "display")
    local _, _, dash = Schema.validate(Helpers.fixture("dashboard"))
    h.eq(dash.mode, "live")
  end)

  h.case("form fixture exposes three input focusables", function()
    local _, _, spec = Schema.validate(Helpers.fixture("form"))
    local ids = {}
    for _, comp in ipairs(Schema.focusables(spec)) do
      table.insert(ids, comp.id)
    end
    h.deep_eq(ids, { "env", "migrate", "tag" })
  end)

  h.case("describe() has one line per example", function()
    local lines = Examples.describe()
    h.eq(#lines, #Examples.list())
    h.has(table.concat(lines, "\n"), "dashboard")
  end)
end
