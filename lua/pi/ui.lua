local M = {}

local function title_for(session)
  if session.status == "error" then
    return " pi error "
  end
  return " pi "
end

local function status_line(session)
  local labels = {
    starting = "Pi starting...",
    thinking = "Pi thinking...",
    running_tool = "Pi calling tool...",
    done = "Pi done",
    error = session.last_error or "pi failed",
  }

  if session.status == "running_tool" and session.active_tool then
    return "Pi calling tool: " .. session.active_tool
  end

  return labels[session.status]
end

local function notification_level(session)
  if session.status == "error" then
    return vim.log.levels.ERROR
  end
  if session.status == "cancelled" then
    return vim.log.levels.WARN
  end
  return vim.log.levels.INFO
end

local function render(session)
  local message = status_line(session)
  if not message then
    return
  end

  local signature = session.status .. "|" .. (session.active_tool or "")
  if session.last_notified_signature == signature then
    return
  end
  session.last_notified_signature = signature

  vim.notify(message, notification_level(session), {
    title = title_for(session),
  })
end

function M.open(session)
  session.winnr = nil
  session.bufnr = nil
  render(session)
end

function M.update(session)
  render(session)
end

function M.close(session)
  session.winnr = nil
  session.bufnr = nil
  session.last_notified_signature = nil

  if session.status ~= "error" then
    session.status = "done"
    render(session)
  end
end

return M
