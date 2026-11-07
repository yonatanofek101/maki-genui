-- In-process test runner for maki-genui (`/genui test`).
--
-- There is no Lua binary on the dev machine and packages have no external spec
-- runner, so the suites run inside maki: `require("genui.tests.spec").run()`.
-- Each suite below is a module exporting `return function(h) ... end`; it gets
-- a fresh harness (`genui.tests.helpers`) and registers cases with `h.case`.
-- A suite that cannot be required is reported as skipped, never as a crash.

local Helpers = require("genui.tests.helpers")

local Spec = {}

-- Suite modules in dependency order (plan.md §1 ownership: A, A, B, C).
Spec.SUITES = {
  { name = "schema", module = "genui.tests.schema_spec" },
  { name = "registry", module = "genui.tests.registry_spec" },
  { name = "render", module = "genui.tests.render_spec" },
  { name = "form", module = "genui.tests.form_spec" },
  { name = "examples", module = "genui.tests.examples_spec" },
}

local function looks_missing(err)
  local s = tostring(err):lower()
  return s:find("not found", 1, true) ~= nil
    or s:find("cannot find", 1, true) ~= nil
    or s:find("no such", 1, true) ~= nil
    or s:find("unknown module", 1, true) ~= nil
    or s:find("could not resolve", 1, true) ~= nil
end

-- Runs every suite. Returns
--   { passed, failed, failures = {string}, skipped = {string}, suites = {{name, passed, failed, skipped?}},
--     results = {{name, ok, err?}}, lines = {string} }
-- `lines` is the ready-to-display report (one line per case, then skipped
-- suites, then the summary); `summary` is its last line.
function Spec.run(opts)
  opts = opts or {}
  local h = Helpers.new()
  local skipped, suites = {}, {}

  for _, suite in ipairs(opts.suites or Spec.SUITES) do
    local ok, mod = pcall(require, suite.module)
    local entry = { name = suite.name, passed = 0, failed = 0 }
    if not ok then
      if looks_missing(mod) then
        entry.skipped = "module " .. suite.module .. " not found"
      else
        -- The file exists but failed to load: that is a real failure.
        h.prefix = suite.name .. ": "
        h.case("(load)", function()
          error(mod, 0)
        end)
        entry.failed = 1
      end
    elseif type(mod) ~= "function" then
      h.prefix = suite.name .. ": "
      h.case("(load)", function()
        error("suite must return a function(h), got " .. type(mod), 0)
      end)
      entry.failed = 1
    else
      local before_pass, before_fail = h.passed, h.failed
      h.prefix = suite.name .. ": "
      local ran, err = pcall(mod, h)
      if not ran then
        h.case("(suite body)", function()
          error(err, 0)
        end)
      end
      entry.passed = h.passed - before_pass
      entry.failed = h.failed - before_fail
    end
    if entry.skipped then
      table.insert(skipped, suite.name .. " (" .. entry.skipped .. ")")
    end
    table.insert(suites, entry)
  end
  h.prefix = ""

  local out = h.report()
  out.skipped = skipped
  out.suites = suites
  out.results = h.results
  out.lines = Spec.format(out)
  out.summary = out.lines[#out.lines]
  return out
end

-- Formats a `run()` result as display lines: "✓ name" / "✗ name" (+ indented
-- error), "- skipped suite", then "N passed, M failed[, K skipped]".
function Spec.format(res)
  local lines = {}
  for _, r in ipairs(res.results or {}) do
    if r.ok then
      table.insert(lines, "✓ " .. r.name)
    else
      table.insert(lines, "✗ " .. r.name)
      for err_line in (tostring(r.err) .. "\n"):gmatch("(.-)\n") do
        if err_line ~= "" then
          table.insert(lines, "    " .. err_line)
        end
      end
    end
  end
  for _, s in ipairs(res.skipped or {}) do
    table.insert(lines, "- skipped: " .. s)
  end
  if #lines > 0 then
    table.insert(lines, "")
  end
  local summary = string.format("%d passed, %d failed", res.passed or 0, res.failed or 0)
  if res.skipped and #res.skipped > 0 then
    summary = summary .. string.format(", %d skipped", #res.skipped)
  end
  table.insert(lines, summary)
  return lines
end

-- Styled lines for a scratch float: failures in `error`, passes in `success`,
-- the summary in `bold`.
function Spec.styled_lines(res)
  local styled = {}
  for i, line in ipairs(res.lines or Spec.format(res)) do
    local style = ""
    if line:sub(1, #"✓") == "✓" then
      style = "success"
    elseif line:sub(1, #"✗") == "✗" then
      style = "error"
    elseif line:sub(1, 2) == "- " or line:sub(1, 4) == "    " then
      style = "dim"
    elseif i == #(res.lines or {}) then
      style = (res.failed or 0) > 0 and "error" or "bold"
    end
    table.insert(styled, { { line, style } })
  end
  return styled
end

return Spec
