local Result = {}

function Result.llm_output(spec, st)
  return maki.json.encode({ status = st.status })
end

function Result.view_opts(ctx)
  local lines = ctx and ctx.tool_output_lines and ctx:tool_output_lines() or nil
  local other = lines and lines.other or 0
  return { width = 80, max_lines = math.max(other, 10), keep = "head" }
end

function Result.card(spec, st, opts)
  local buf = maki.ui.buf()
  return buf, { repaint = function(spec_, st_) end, card_state = { expanded = {} }, buf = buf }
end

function Result.update_output(id, patched, warnings)
  return "not implemented"
end

function Result.close_output(id)
  return "not implemented"
end

function Result.error_output(errors)
  return "error: " .. table.concat(errors or {}, "; ")
end

return Result
