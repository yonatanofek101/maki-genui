local Schema, Registry = require("genui.schema"), require("genui.registry")
local Render, Result, Form = require("genui.render"), require("genui.result"), require("genui.form")

local Genui = { _handlers = {} }

function Genui._handlers.ui_render(input, ctx)
  return { llm_output = "error: not implemented", is_error = true }
end

function Genui._handlers.ui_update(input, ctx)
  return { llm_output = "error: not implemented", is_error = true }
end

function Genui._handlers.ui_close(input, ctx)
  return { llm_output = "error: not implemented", is_error = true }
end

function Genui._restore(input, output, is_error, ctx)
  return nil
end

local did_setup = false

function Genui.setup(opts)
  if did_setup then
    return
  end
  did_setup = true
  -- register_tool x3 with Schema.TOOL_SCHEMAS, timeout = false, audiences = {"main"}; /genui command; autocmds
end

return Genui
