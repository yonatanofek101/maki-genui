local Render = {
  CARD_WIDTH = 80,
  STYLES = {
    label = "bold",
    value = "",
    muted = "dim",
    focus = "item_selected",
    selected = "selected",
    error = "error",
    success = "success",
    warning = "warning",
    section = "section",
    border = "table_border",
    bar_fill = "selected",
    bar_empty = "dim",
    diff_old = "diff_old",
    diff_new = "diff_new",
    hint = "dim",
  },
}

function Render.ctx(opts)
  opts = opts or {}
  return {
    width = opts.width or Render.CARD_WIDTH,
    markdown = function(t, w)
      return { { { t, "" } } }
    end,
    display_width = function(s)
      return utf8.len(s) or #s
    end,
    values = opts.values,
    expanded = opts.expanded or {},
    mode = opts.mode or "card",
  }
end

function Render.component(comp, rctx)
  return { { { "[" .. tostring(comp.type) .. "]", "dim" } } }, {}
end

function Render.card_lines(spec, st, rctx)
  return Render.component(spec.root, rctx)
end

function Render.to_markdown(spec)
  return "(ui)"
end

function Render.fit(text, width, rctx)
  return text
end

function Render.pad(line, width, style)
  return line
end

function Render.wrap_text(text, width, rctx)
  return { text }
end

return Render
