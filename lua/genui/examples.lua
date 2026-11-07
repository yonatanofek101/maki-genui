-- Curated example specs: raw `ui_render` inputs exactly as the model would send them.
--
-- They serve three purposes: `/genui demo <name>` renders them through the real
-- tool path, `genui.tests.helpers` uses them as fixtures, and README.md quotes
-- them. Keep every spec valid against design.md §4 (P0 catalog) so a demo never
-- shows a placeholder.

local Examples = { specs = {}, catalog = {} }

local function add(name, summary, spec)
  Examples.specs[name] = spec
  table.insert(Examples.catalog, { name = name, summary = summary })
end

local SAMPLE_DIFF = table.concat({
  "--- a/src/main.rs",
  "+++ b/src/main.rs",
  "@@ -10,4 +10,5 @@ fn main()",
  "   let x = 1;",
  "-  let y = foo(x);",
  "+  let y = foo(x, 2);",
  "+  log(y);",
  "   run(y);",
  "   done();",
  "@@ -40,3 +41,3 @@ fn helper()",
  "   // helper",
  "-  return 1",
  "+  return 2",
  "   }",
}, "\n")

-- One example per P0 component -----------------------------------------------

add("stack", "Vertical container (the default layout)", {
  mode = "display",
  root = {
    type = "stack",
    children = {
      { type = "text", text = "First line" },
      { type = "divider" },
      { type = "text", text = "Second line", tone = "dim" },
    },
  },
})

add("section", "Collapsible section; click the title in the card to toggle", {
  mode = "display",
  root = {
    type = "stack",
    children = {
      {
        type = "section",
        title = "Summary",
        children = { { type = "text", text = "3 files changed, 12 insertions, 4 deletions" } },
      },
      {
        type = "section",
        title = "Details",
        collapsed = true,
        children = {
          { type = "kv", items = { { key = "src/a.rs", value = "+8 -2" }, { key = "src/b.rs", value = "+4 -2" } } },
        },
      },
    },
  },
})

add("text", "Markdown text with a tone", {
  mode = "display",
  root = {
    type = "stack",
    children = {
      { type = "text", text = "Build **passed** in 42s. See `target/report.html`." },
      { type = "text", text = "2 warnings were ignored", tone = "warning" },
      { type = "text", text = "raw log line, no markdown", markdown = false, tone = "dim" },
    },
  },
})

add("kv", "Key-value facts (array or object form)", {
  mode = "display",
  root = {
    type = "kv",
    items = {
      { key = "Branch", value = "main" },
      { key = "Commit", value = "a1b2c3d  fix: wrap spans" },
      { key = "Changed", value = "12 files" },
      { key = "Clean", value = true },
    },
  },
})

add("progress", "Progress bar (fraction or done/total)", {
  mode = "display",
  root = {
    type = "stack",
    children = {
      { type = "progress", label = "tests", value = { done = 280, total = 700 } },
      { type = "progress", label = "lint", value = 1, status = "done" },
      { type = "progress", label = "docs", value = 0.1, status = "error" },
    },
  },
})

add("divider", "Horizontal rule with an optional label", {
  mode = "display",
  root = {
    type = "stack",
    children = {
      { type = "text", text = "above" },
      { type = "divider", label = "results" },
      { type = "text", text = "below" },
      { type = "divider" },
    },
  },
})

add("bars", "Horizontal bar chart", {
  mode = "display",
  root = {
    type = "bars",
    unit = "%",
    max = 100,
    items = {
      { label = "core", value = 91 },
      { label = "net", value = 42 },
      { label = "cli", value = 77 },
      { label = "docs", value = 12 },
    },
  },
})

add("sparkline", "Sparkline of recent values (latest on the right)", {
  mode = "display",
  root = {
    type = "sparkline",
    label = "p95 latency (ms)",
    values = { 120, 130, 125, 160, 210, 180, 150, 140, 135, 300, 220, 160, 150, 145 },
  },
})

add("choice", "Single-choice question with an 'other' row", {
  title = "Pick a database",
  root = {
    type = "choice",
    id = "db",
    label = "Which database should the service use?",
    options = {
      { value = "postgres", label = "PostgreSQL (Recommended)", description = "already provisioned" },
      { value = "sqlite", label = "SQLite", description = "single file, no server" },
      "MySQL",
    },
  },
})

add("input", "Free-text input with validation", {
  title = "Release",
  root = {
    type = "input",
    id = "tag",
    label = "Release tag",
    placeholder = "v1.2.3",
    required = true,
    pattern = "^v\\d+\\.\\d+\\.\\d+$",
    pattern_hint = "semver like v1.2.3",
  },
})

add("number", "Numeric input with min/max/step", {
  title = "Scale",
  root = { type = "number", id = "replicas", label = "Replicas", default = 3, min = 1, max = 10, integer = true },
})

add("confirm", "Yes/no toggle", {
  title = "Confirm",
  root = { type = "confirm", id = "migrate", label = "Run migrations?", default = false },
})

add("actions", "Custom button row (replaces the implicit Submit/Cancel)", {
  title = "Deploy?",
  root = {
    type = "stack",
    children = {
      { type = "text", text = "Deploy **api@v1.4** to production?" },
      {
        type = "actions",
        items = {
          { action = "deploy", label = "Deploy", style = "primary" },
          { action = "dry_run", label = "Dry run" },
          { action = "cancel", label = "Cancel", style = "danger" },
        },
      },
    },
  },
})

-- Composite scenarios (design.md §1) -------------------------------------------

add("form", "Structured intake form: choice + confirm + input (design.md §1.1)", {
  title = "Deploy",
  root = {
    type = "stack",
    children = {
      {
        type = "choice",
        id = "env",
        label = "Environment",
        options = {
          { value = "staging", label = "staging (Recommended)" },
          { value = "prod", label = "prod", description = "needs approval" },
        },
      },
      { type = "confirm", id = "migrate", label = "Run migrations?" },
      { type = "input", id = "tag", label = "Release tag", pattern = "^v\\d+", pattern_hint = "v<number>" },
    },
  },
})

add("question", "Quick structured question (a `question`-tool replacement)", {
  title = "Next step",
  root = {
    type = "stack",
    children = {
      { type = "text", text = "The test suite has 3 flaky tests. How should I proceed?" },
      {
        type = "choice",
        id = "plan",
        label = "Plan",
        options = {
          { value = "fix", label = "Fix the flaky tests first (Recommended)" },
          { value = "skip", label = "Mark them skipped and continue" },
          { value = "ignore", label = "Ignore them" },
        },
      },
    },
  },
})

add("survey", "Multi-field form with validation on every input", {
  title = "New service",
  root = {
    type = "stack",
    children = {
      {
        type = "input",
        id = "name",
        label = "Service name",
        required = true,
        min_len = 3,
        max_len = 32,
        pattern = "^[a-z][a-z0-9-]*$",
        pattern_hint = "lowercase, digits, dashes",
      },
      { type = "input", id = "description", label = "Description", multiline = true, placeholder = "What does it do?" },
      {
        type = "choice",
        id = "language",
        label = "Language",
        options = { "Rust (Recommended)", "Go", "TypeScript" },
        other = false,
      },
      {
        type = "choice",
        id = "features",
        label = "Features",
        multi = true,
        required = false,
        options = { "HTTP API", "Background worker", "CLI" },
        default = { "HTTP API" },
      },
      { type = "number", id = "replicas", label = "Replicas", default = 2, min = 1, max = 20, integer = true },
      { type = "confirm", id = "public", label = "Expose publicly?", default = false },
    },
  },
})

add("matrix", "Decision matrix: options scored per criterion, pick one", {
  title = "Choose a queue",
  root = {
    type = "stack",
    children = {
      { type = "text", text = "Scores are 1-5 (higher is better)." },
      {
        type = "table",
        id = "pick",
        select = "single",
        key = "option",
        columns = {
          { key = "option", label = "Option" },
          { key = "cost", label = "Cost", align = "right" },
          { key = "ops", label = "Ops", align = "right" },
          { key = "latency", label = "Latency", align = "right" },
          { key = "total", label = "Total", align = "right" },
        },
        rows = {
          { option = "SQS", cost = 4, ops = 5, latency = 3, total = 12 },
          { option = "Redis streams", cost = 3, ops = 3, latency = 5, total = 11 },
          { option = "Kafka", cost = 2, ops = 2, latency = 5, total = 9 },
        },
      },
    },
  },
})

add("table", "Data table with multi-row selection (design.md §1.2)", {
  title = "Fix which hits?",
  root = {
    type = "table",
    id = "hits",
    select = "multi",
    key = "loc",
    max_rows = 5,
    columns = { { key = "loc", label = "location" }, { key = "text", label = "text" } },
    rows = {
      { loc = "src/a.rs:12", text = "let x = foo(" },
      { loc = "src/b.rs:40", text = "foo(bar)" },
      { loc = "src/c.rs:7", text = "foo()" },
      { loc = "src/d.rs:91", text = "return foo(x, y)" },
      { loc = "src/e.rs:3", text = "use crate::foo;" },
      { loc = "src/f.rs:55", text = "foo(1)" },
      { loc = "src/g.rs:18", text = "foo(2)" },
    },
  },
})

add("diff", "Diff review: accept/reject each hunk (design.md §1.3)", {
  title = "Review src/main.rs",
  root = { type = "diff", id = "d", text = SAMPLE_DIFF, decide = true },
})

add("review", "Approval screen: context + diff + approve/reject buttons", {
  title = "Approve change",
  root = {
    type = "stack",
    children = {
      {
        type = "kv",
        items = { { key = "File", value = "src/main.rs" }, { key = "Reason", value = "pass the retry count" } },
      },
      { type = "diff", id = "hunks", text = SAMPLE_DIFF, decide = true },
      { type = "input", id = "note", label = "Note for the commit message", required = false },
      {
        type = "actions",
        items = {
          { action = "apply", label = "Apply accepted hunks", style = "primary" },
          { action = "reject", label = "Reject all", style = "danger" },
        },
      },
    },
  },
})

add("dashboard", "Live progress dashboard updated with ui_update (design.md §1.4)", {
  id = "build",
  title = "Build",
  mode = "live",
  root = {
    type = "stack",
    children = {
      { type = "progress", id = "p", label = "tests", value = 0 },
      { type = "sparkline", id = "s", label = "tests/s", values = { 0 } },
      { type = "text", id = "log", text = "" },
    },
  },
})

add("report", "Readable report: facts, bars and collapsible sections (design.md §1.5)", {
  title = "Coverage report",
  mode = "display",
  root = {
    type = "stack",
    children = {
      {
        type = "kv",
        items = { Branch = "main", Commit = "a1b2c3d", Lines = "12 345", Coverage = "78.4%" },
      },
      { type = "divider", label = "by module" },
      {
        type = "bars",
        unit = "%",
        items = {
          { label = "core", value = 91 },
          { label = "net", value = 42 },
          { label = "cli", value = 77 },
        },
      },
      {
        type = "section",
        title = "Uncovered files",
        collapsed = true,
        children = {
          {
            type = "table",
            columns = { "file", { key = "lines", align = "right" } },
            rows = { { "src/net/retry.rs", 120 }, { "src/net/pool.rs", 88 } },
          },
        },
      },
    },
  },
})

-- API ----------------------------------------------------------------------------

local function deep_copy(v)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = deep_copy(x)
  end
  return out
end

-- Ordered example names, for `/genui demo` completion and `/genui list`.
function Examples.list()
  local names = {}
  for _, entry in ipairs(Examples.catalog) do
    table.insert(names, entry.name)
  end
  return names
end

-- Fresh deep copy of one example (safe to mutate), or nil when unknown.
function Examples.get(name)
  local spec = Examples.specs[name]
  if spec == nil then
    return nil
  end
  return deep_copy(spec)
end

-- One line per example: "name  summary", for a picker or the README.
function Examples.describe()
  local lines = {}
  for _, entry in ipairs(Examples.catalog) do
    table.insert(lines, string.format("%-10s %s", entry.name, entry.summary))
  end
  return lines
end

return Examples
