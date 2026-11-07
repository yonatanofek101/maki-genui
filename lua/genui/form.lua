local Form = { MODE = { NAV = "nav", EDIT = "edit", DONE = "done" } }

Form.FOOTER_NAV = {}
Form.FOOTER_EDIT = {}

function Form.open(spec, opts)
  return { status = "unavailable" }
end

function Form._initial_state(spec)
  return { spec = spec, focus = 1, focusables = {}, widgets = {}, mode = Form.MODE.NAV, errors = {}, top = 1 }
end

function Form._handle_key(state, key)
  return state
end

function Form._handle_paste(state, text)
  return state
end

function Form._render(state, width, height, rctx)
  return { lines = {}, focus_row = 1, footer = {}, reserved_top = 0 }
end

function Form._validate(state)
  state.errors = {}
  return state.errors
end

function Form._values(state)
  return {}
end

function Form._submit(state, action)
  return state
end

return Form
