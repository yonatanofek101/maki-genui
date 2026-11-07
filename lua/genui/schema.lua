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

local Schema = {
  CATALOG = {},
  TOOL_SCHEMAS = {
    ui_render = { type = "object", required = { "root" }, properties = { root = { type = "object" } } },
    ui_update = { type = "object", required = { "id" } },
    ui_close = { type = "object", required = { "id" } },
  },
}

function Schema.validate(input)
  return false, { "not implemented" }, nil
end

function Schema.apply_patch(spec, patch, root)
  return spec, {}
end

function Schema.find(spec, id)
  return nil
end

function Schema.walk(root, fn)
  fn(root, nil, 0)
end

function Schema.focusables(spec)
  return {}
end

function Schema.compile_pattern(pat)
  return nil
end

function Schema.strip(spec)
  return spec
end

function Schema._normalize_component(raw, path, used_ids, counter, warnings)
  error("not implemented")
end

return Schema
