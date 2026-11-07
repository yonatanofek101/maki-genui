local Registry = { MAX_LIVE = 16 }

function Registry.new_id()
  return "w1"
end

function Registry.put(entry) end

function Registry.get(id)
  return nil
end

function Registry.remove(id)
  return false
end

function Registry.clear_session(session_id)
  return 0
end

function Registry.list()
  return {}
end

function Registry._reset() end

return Registry
