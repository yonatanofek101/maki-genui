# maki-genui

Generative UI for [Maki](https://github.com/tontinton/maki): the agent describes a
screen as a small JSON component tree, the plugin renders it as real terminal UI
inside the chat (forms, pickers, tables with row selection, diff review, bar
charts, live progress dashboards), and whatever the user did comes back to the
model as structured JSON.

- **Three tools**: `ui_render` (show + wait), `ui_update` (patch a live card),
  `ui_close` (freeze it).
- **One fixed catalog** of 18 components; no code generation, no sandbox.
- **No permissions**: the plugin does no I/O. The model fetches data with its
  other tools and passes it in the spec.
- **Survives reloads and compaction**: cards are rebuilt from the tool input and
  a JSON state; results are self-contained JSON the model can re-read.

## What is Generative UI?

*Generative UI* means the interface is produced by the model at run time instead
of being hard-wired by the app. The model emits a declarative spec against a
fixed, host-owned component catalog; the host validates it, renders it with its
own widgets and theme, and sends the user's interactions back as data. This is
the "declarative" middle ground between *controlled* UI (every tool maps to one
prebuilt component, e.g. Maki's own `question`) and *open-ended* UI (the model
writes HTML or React that runs in a sandbox). Industry has converged on the
declarative form for agent-hosted UI: Google's A2UI, Vercel's json-render
(including its Ink terminal renderer), OpenAI's ChatKit widgets and Thesys C1
all work this way, because a catalog is token-cheap, validates with error
feedback the model can act on, keeps theming consistent, and serializes cleanly.

## Why it matters in a terminal agent

A coding agent constantly needs *structured* answers ("which environment?",
"which of these 40 hits should I fix?", "accept hunk 2 but not 3?") and
constantly produces *structured* output (coverage per module, a status board
for a long job). Prose is the wrong tool for both: the user re-types what a
picker would have captured, and the model guesses at what a free-text reply
meant. Maki's bundled `question` tool proves the point for one shape (options +
multi-select); `maki-genui` generalizes it to forms, tables, diffs and
dashboards, with a result shape the model never has to parse.

## Walkthrough

The model wants to deploy and needs three facts. It calls `ui_render`:

```json
{
  "title": "Deploy",
  "root": {
    "type": "stack",
    "children": [
      { "type": "choice", "id": "env", "label": "Environment",
        "options": [
          { "value": "staging", "label": "staging (Recommended)" },
          { "value": "prod", "label": "prod", "description": "needs approval" }
        ] },
      { "type": "confirm", "id": "migrate", "label": "Run migrations?" },
      { "type": "input", "id": "tag", "label": "Release tag",
        "pattern": "^v\\d+", "pattern_hint": "v<number>" }
    ]
  }
}
```

A window opens below the chat (the chat scrolls up, nothing is covered):

```
╭─ Deploy ────────────────────────────────────────────────────────────────────╮
│  Environment                                                                │
│  ▸ (•) staging (Recommended)                                                │
│    ( ) prod  - needs approval                                               │
│    → Type your own answer                                                   │
│                                                                             │
│  Run migrations?   [ Yes ]   No                                             │
│                                                                             │
│  Release tag                                                                │
│  ❯ v1.4▏                                                                    │
│                                                                             │
│  [ Submit ]   [ Cancel ]                                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│ Tab next · ↑↓ move · Space toggle · Enter select · Esc cancel               │
╰─────────────────────────────────────────────────────────────────────────────╯
```

The user presses `Enter` on `staging`, `y`, types `v1.4`, `Enter`, `Enter` on
`[ Submit ]`. The window closes and a collapsed result card stays in the
transcript (click it to expand):

```
▸ ui: Deploy                                                        submitted
    Environment     staging
    Run migrations? yes
    Release tag     v1.4
```

The model receives one JSON line:

```json
{"status":"submitted","values":{"env":"staging","migrate":true,"tag":"v1.4"}}
```

(`action` is set when the user pressed a custom `actions` button.)

Had the user pressed `Esc`, it would receive `{"status":"cancelled"}` and ask
what to do next. Had the tag been `1.4`, the form would have refused to submit
and shown `✗ v<number>` under the field until it was fixed.

## Install

Requires Maki 0.7.0 or later.

Once published, add this to `~/.config/maki/init.lua`:

```lua
maki.pack.add({ "https://github.com/yonatanofek101/maki-genui" })
```

From a local checkout (the path is handed to `git clone`, so it **must be a git
repository with at least one commit**; Maki installs a copy of the committed
revision, not a symlink):

```lua
maki.pack.add({ "/Users/yonatanofek/Projects/maki-genui" })
```

Restart Maki and approve the install. After every commit in the checkout run
`/packupdate maki-genui` to pick it up; uncommitted edits are invisible to Maki.

### Permissions

**None.** `plugin.toml` declares an empty `[permissions]` section: the plugin
never reads files, runs commands, touches the network, or injects messages. All
data shown comes from the tool input the model wrote.

### Options

```lua
maki.pack.add({ "https://github.com/yonatanofek101/maki-genui" }, {
  load = function()
    require("genui").setup({})
  end,
})
```

| Option | Default | Meaning |
| --- | --- | --- |
| `live_actions` | `false` | Reserved (P2): let buttons in live cards notify the agent. Would need `session_write` in `plugin.toml`. Off, so no permission is requested. |
| `live_inplace` | `true` | `ui_update` repaints the earlier card's buffer in place. Set `false` to always return a fresh card as the update's own body (the automatic fallback when an in-place repaint fails). |

## Tools

All three tools register with `timeout = false` (an interactive form waits as
long as the user needs) and are visible to the main agent only. Handlers never
raise: a malformed spec returns `error: ...` with `is_error = true`.

### `ui_render`

Render a card from a component tree and, for interactive specs, wait for the
user to fill it in.

| Field | Type | Meaning |
| --- | --- | --- |
| `root` | component (required) | The tree. Containers carry `children`. |
| `title` | string | Card/window title, up to 60 characters. |
| `id` | string | Widget id for `ui_update`/`ui_close`. Auto-generated (`w1`, `w2`, ...) when absent. |
| `mode` | `"auto"` \| `"interactive"` \| `"display"` \| `"live"` | `auto` (default) is `interactive` when any input component exists, else `display`. |

Every component accepts `id` (optional; auto-assigned in preorder as `c1`,
`c2`, ... when missing) and `hidden` (boolean). **Give every input an explicit
`id`**: it becomes the key in `values`. A missing input id is auto-assigned and
reported as a warning so the model learns.

Result (`llm_output`) is one JSON line, optionally followed by warnings:

| Situation | Output |
| --- | --- |
| Form submitted | `{"status":"submitted","action":"deploy","values":{"env":"staging","migrate":true,"tag":"v1.4","hits":["src/a.rs:12"],"d":{"1":"accept","2":"reject"}}}` |
| Cancelled (`Esc`, `Ctrl-C`, `[ Cancel ]`) | `{"status":"cancelled"}` (not an error) |
| Display card | `{"status":"display","widget":"w3"}` |
| Live card | `{"status":"live","widget":"build","ids":["p","log"]}` (ids the model may patch) |
| No interactive terminal | `{"status":"unavailable","reason":"no interactive UI attached"}` + the spec as plain markdown |
| Spec rejected | `error: root.children[2].type must be a string` with `is_error = true` |
| Any of the above with soft problems | `...\nwarnings:\n- children[1]: unknown component "slider" (rendered as placeholder)` |

Strings longer than 500 characters are cut with `…`; the whole output stays
under 4 KB. The tool header reads `ui: <title or root type>` and the annotation
is the status.

**Hard errors** (spec refused): missing or non-object `root`, `children` that is
not an array, duplicate `id`, bad `mode`. **Soft problems** (rendered anyway,
reported as warnings): unknown component type (shown as `⚠ unknown component
"slider"`), unknown prop (dropped), prop of the wrong type (default used).

Rules the tool description gives the model: forms up to 8 inputs, tables up to
200 rows, recommended option first with `(Recommended)` in its label.

### `ui_update`

Patch a live card in place.

```json
{ "id": "build", "patch": [ { "id": "p", "value": 0.6 }, { "id": "log", "text": "412/700 passed" } ] }
```

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | string (required) | Widget id given to or returned by `ui_render` (`mode: "live"`). |
| `patch` | array of `{ "id", ...props }` | Shallow-merge props into the component with that id. `{ "id", "append": "line" }` appends a line to a `text` component. Unknown id is a warning; other patches still apply. |
| `root` | component | Replace the whole tree (re-validated, ids re-assigned). |
| `title` | string | New title. |

Exactly one of `patch` or `root` is required. Output:
`{"status":"updated","widget":"build","patched":["p","log"]}`, or
`error: unknown widget "build" (closed, evicted after reload, or never rendered); call ui_render again`.

### `ui_close`

Freeze a live card, drop it from the registry, optionally append a final line.

```json
{ "id": "build", "status": "done", "note": "700/700 passed in 42s" }
```

`status` is one of `"done"`, `"error"`, `"cancelled"`. Output
`{"status":"closed","widget":"build"}`. Closing twice is a warning, not an
error. At most 16 live widgets are kept; the oldest is evicted beyond that, and
all widgets of a session are dropped when the session ends or resets.

## Component catalog

Layout is a vertical stack. Cards are 80 columns wide (so clicks map to stable
rows); the interactive window uses its own width. `(req)` marks required props.
`values[id]` is what the component contributes to the result.

| Type | Props | Value |
| --- | --- | --- |
| `stack` | `children` (req) | — |
| `row` | `children` (req), `gap=2` — children side by side as equal columns (falls back to a stack when the columns would be too narrow) | — |
| `section` | `title` (req), `collapsed=false`, `children` (req, non-empty) | — |
| `text` | `text` (req), `tone="plain"` \| `info` \| `success` \| `warning` \| `error` \| `dim`, `markdown=true` | — |
| `kv` | `items` (req): `[{key, value}]` or an object (sorted by key), `key_width` (auto, max 24) | — |
| `table` | `columns` (req): strings or `{key, label, align="left"\|"right", width}`, `rows` (req): objects or arrays, `select="none"` \| `single` \| `multi`, `key` (column that identifies a row; default 1-based index), `max_rows=20` | `string` (single) / `[string]` (multi) |
| `bars` | `items` (req, up to 50): `[{label, value}]`, `max` (default: largest value), `unit` | — |
| `sparkline` | `values` (req, up to 200), `label` | — |
| `progress` | `value` (req): `0..1` or `{done, total}`, `label`, `status="running"` \| `done` \| `error` | — |
| `divider` | `label` | — |
| `badge` | `text` (req), `tone="plain"` (same tones as `text`) | — |
| `checklist` | `items` (req, up to 200): strings or `[{text, done=false}]` | — |
| `diff` | `text` (req, unified diff) **or** `before` + `after` (+ `path`), `decide=false`, `max_lines=200` | `{"1":"accept","2":"reject"}` per hunk when `decide` |
| `choice` | `label` (req), `options` (req, ≥ 1): strings or `{value, label, description}`, `multi=false`, `other=true`, `default`, `required=true` | `string` / `[string]` |
| `input` | `label` (req), `placeholder`, `default`, `multiline=false`, `required=false`, `min_len`, `max_len`, `pattern` (ECMA regex), `pattern_hint` | `string` |
| `number` | `label` (req), `default`, `min`, `max`, `step=1`, `integer=false` | `number` |
| `confirm` | `label` (req), `default=false` | `boolean` |
| `actions` | `items` (req): `[{action, label, style="default"\|"primary"\|"danger"}]` | the pressed `action` in the result; `action: "cancel"` cancels without validating |

Planned (P1): table sorting. Unknown types render as a placeholder today.

### Renders

**section** — click the title in a card to toggle; always expanded in a window.

```
▸ Details (4 lines)
▾ Summary
  3 files changed, 12 insertions, 4 deletions
```

**kv**

```
  Branch      main
  Commit      a1b2c3d  fix: wrap spans
  Changed     12 files
```

**table** with `select: "multi"`, `max_rows: 5`; `▼ n more` is clickable in a
card and scrolls in a window.

```
    location       text
  ▸ [x] src/a.rs:12  let x = foo(
    [ ] src/b.rs:40  foo(bar)
    [x] src/c.rs:7   foo()
    ▼ 4 more
```

**choice** — `( )`/`(•)` single, `[ ]`/`[x]` multi, trailing free-text row
when `other` is on. Typing on `→ Type your own answer` makes the raw text the
value.

```
  Environment
  ▸ (•) staging (Recommended)
    ( ) prod  - needs approval
    → Type your own answer
```

**input** / **number** / **confirm** — validation errors appear under the field
and block submit; `Cancel` never validates.

```
  Release tag
  ❯ v1.4▏
  ✗ must match ^v\d+ (v<number>)

  Replicas        ❯ 3     (1–10)

  Run migrations?   [ Yes ]   No
```

**actions** — replaces the implicit `[ Submit ]  [ Cancel ]` row.

```
  [ Deploy ]   [ Dry run ]   [ Cancel ]
```

**progress** — a `running` bar carries an animated spinner so live dashboards
move without a timer.

```
  ⠋ tests   ████████████░░░░░░░░░░░░░░░░░░  40%  (280/700)
  ✓ lint    ██████████████████████████████ 100%
```

**bars** / **sparkline** / **divider**

```
  core      ███████████████████████████▏ 91%
  net       ████████████▌               42%
  p95 latency (ms)  ▁▂▂▃▆▅▄▃▃█▆▄▃▃
  ────────────────────── results ──────────────────────
```

**diff** with `decide: true` — each hunk is focusable: `a` accept, `r`
reject, `Space` cycles, `Enter` accepts and moves on. Undecided hunks block
submit. In a card, hunk bodies collapse on click.

```
  @@ -10,4 +10,5 @@ fn main()                             [accept]
   10   10   let x = 1;
   11      - let y = foo(x);
        11 + let y = foo(x, 2);
        12 + log(y);
  @@ -40,3 +41,3 @@ fn helper()                           [ ? ]
```

## Keyboard

One focus ring over all inputs in document order (`choice`, `input`, `number`,
`confirm`, `table` with selection, `diff` with `decide`, every `actions`
button, then the implicit Submit/Cancel row).

| Key | Effect |
| --- | --- |
| `Tab` / `Shift-Tab` | Next / previous focusable (wraps) |
| `↓` / `↑` | Move inside the focused component; at its edge, hop to the next / previous focusable |
| `Space` | Toggle (option, checkbox row, confirm, hunk decision cycle) |
| `Enter` | Accept and advance: pick option, confirm value, pick row, accept hunk; on a button: press |
| `a` / `r` | Accept / reject the focused hunk |
| `y` / `n` | Set a `confirm` |
| `←` / `→` | Toggle a `confirm`; move between `actions` buttons |
| `+` / `-`, `↑` / `↓` | Step a `number` |
| `Alt-Enter` | Newline in a multiline `input` (`Enter` advances) |
| `PageUp` / `PageDown` | Scroll the window |
| `Esc` / `Ctrl-C` | Cancel (`{"status":"cancelled"}`) |

Cards in the transcript take clicks only: a click on a section title, a `▼ n
more` row or a hunk header toggles it; any other click toggles the whole card.

## Headless, restore and compaction

- **Headless** (`maki -p`, SDK, ACP): no window can open, so an interactive
  spec returns `{"status":"unavailable","reason":"no interactive UI attached"}`
  followed by a plain-markdown rendering (labels, options as a list, tables as
  pipes) with `is_error = false`. The model relays it and asks in prose. Display
  and live cards work unchanged.
- **Restore** (reload, scrolling back through history): cards are rebuilt from
  the tool input plus the saved state, and clicks are replayed in order, so
  every click handler is a pure toggle. A live card that is still registered is
  re-attached, so later `ui_update` calls keep landing.
- **Compaction**: the input (spec) and the output (ids → values) are both
  self-contained, so the model can re-read decisions after the card is gone.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `error: unknown widget "build"` | The live widget was closed, evicted (more than 16 live widgets), or the session was reset. Call `ui_render` again with `mode: "live"`. |
| `{"status":"unavailable"}` | No interactive terminal (headless run) or the window could not take focus. The output includes a markdown rendering to relay. |
| `warnings: - root.children[1]: unknown component "slider"` | Not in the catalog. The card shows a placeholder; the model should pick a catalog type. |
| Values keyed `c3`, `c5` | The model omitted `id` on inputs. The warning says so; add ids. |
| `ui_update` repaints a new card instead of the old one | Fallback when the host does not allow mutating an earlier tool body; still correct, just not in place. |
| Card is 80 columns in a wide terminal | By design: fixed width keeps click rows stable across resizes. |
| Edits to the checkout do nothing | Maki runs the installed commit. `git commit`, then `/packupdate maki-genui`. |
| `pattern` is ignored | The regex did not compile in the host's JSON Schema validator; a warning is appended and the field is accepted. |

## Developing

The package has no external test runner (Maki has no `lua` binary and packages
cannot be loaded by `cargo test`), so the spec runs **inside Maki**:

| Command | What it does |
| --- | --- |
| `/genui test` | Runs `lua/genui/tests/*_spec.lua` in-process; shows `N passed, M failed` in a float (`q` closes) and logs the report. |
| `/genui demo <name>` | Renders a built-in example through the real tool path. Names: `form`, `table`, `diff`, `dashboard`, `report`, `question`, `survey`, `matrix`, `review`, plus one per component (`choice`, `kv`, `bars`, ...). |
| `/genui list` | Lists live widgets. |
| `/genui close <id>` | Closes a live widget. |

Loop: edit, `stylua --check lua/ plugin/`, `git commit`, `/packupdate
maki-genui`, `/genui test`, `/genui demo form`. Lint config is `.stylua.toml`
(Luau, 120 columns, 2 spaces).

Layout:

```
plugin.toml              manifest (min_maki_version, empty permissions)
plugin/genui.lua         require("genui").setup({})
lua/genui/init.lua       tools, /genui command, autocmds, restore
lua/genui/schema.lua     JSON schemas, CATALOG, validate/normalize, apply_patch
lua/genui/render.lua     spec → styled lines (+ click row map), to_markdown
lua/genui/widgets/       display.lua (text, kv, table, bars, ...), inputs.lua (choice, input, ...)
lua/genui/form.lua       focus ring, key handling, validation, window loop
lua/genui/result.lua     llm_output JSON, result card (ToolView + clicks)
lua/genui/registry.lua   live widget registry
lua/genui/examples.lua   demo specs (also README examples and test fixtures)
lua/genui/tests/         spec.lua (runner), helpers.lua (harness), *_spec.lua
```

Tests are plain functions of pure exports (`Schema.validate`,
`Render.component`, `Form._handle_key`, ...). `genui.tests.helpers` provides
`case/eq/has/deep_eq/report`, a deterministic render context (`rctx`), a fake
`Buf` that records lines and replays clicks, and fixtures from
`genui.examples`:

```lua
local Helpers = require("genui.tests.helpers")

return function(h)
  h.case("choice renders its options", function()
    local _, _, spec = require("genui.schema").validate(Helpers.fixture("form"))
    local lines = require("genui.render").component(spec.root, Helpers.rctx(80))
    h.has(Helpers.text(lines), "staging (Recommended)")
  end)
end
```

## Credits and prior art

- [A2UI](https://a2ui.org/) (Google): the declarative catalog + validate loop
  and the "renderer owns the widgets" stance; this plugin uses a nested tree
  with optional ids instead of A2UI's flat adjacency list because tool inputs
  arrive whole, not streamed.
- [json-render](https://github.com/vercel-labs/json-render) (Vercel), in
  particular its Ink terminal renderer, which showed a fixed catalog (Box, Text,
  Spinner, ProgressBar, Table, Select, Confirm...) is enough for a TUI.
- [OpenAI ChatKit widgets](https://developers.openai.com/api/docs/guides/chatkit-widgets):
  "inline-first" and "separate data tools from render tools".
- [Thesys](https://www.thesys.dev/blogs/generating-code-for-generative-ui-is-a-bad-idea):
  the case against code generation for chat-embedded UI.
- Maki's bundled `question` tool: the split-below window, the focus ring, the
  `(Recommended)` convention, the collapsed result card and the click-replay
  rules are all lifted from it.

MIT, see `LICENSE`.
