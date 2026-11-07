local Display = { renderers = {} }

function Display.parse_diff(text)
  return { hunks = {} }
end

function Display.line_diff(before, after)
  return ""
end

function Display.table_layout(comp, width, rctx)
  return { cols = {}, rows = {} }
end

return Display
