local config = require("pi.config")
local context = require("pi.context")
local runner = require("pi.runner")
local session_mod = require("pi.session")
local ui = require("pi.ui")
local log = require("pi.log")

local M = {}

local active_session = nil
local last_session = nil

local function assert_supported_version()
  if vim.fn.has("nvim-0.10") == 0 then
    error("pi.nvim requires Neovim 0.10+")
  end
end

local function ensure_file_backed_buffer(command_name)
  local bufnr = vim.api.nvim_get_current_buf()
  if not context.buffer_is_file_backed(bufnr) then
    vim.notify(string.format("%s requires a file", command_name), vim.log.levels.ERROR)
    return nil
  end
  return bufnr
end

local function get_pi_cmd()
  local cfg = config.get()
  local cmd = { "pi", "--mode", "rpc", "--no-session", "--no-extensions", "--no-skills" }
  if cfg.provider then
    table.insert(cmd, "--provider")
    table.insert(cmd, cfg.provider)
  end
  if cfg.model then
    table.insert(cmd, "--model")
    table.insert(cmd, cfg.model)
  end
  return cmd
end

local function set_status(session, status, message)
  if not session or session.closing then
    return
  end
  session.status = status
  if message then
    session_mod.push(session, message)
  end
  ui.update(session)
end

local function reload_source_buffer(session)
  local bufnr = session.source_bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].modified then
    return
  end
  if not context.buffer_is_file_backed(bufnr) then
    return
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if vim.fn.filereadable(path) ~= 1 then
    return
  end

  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
end

local function finish_session(session, status, opts)
  opts = opts or {}
  if not session or session.closing then
    return
  end

  session.closing = true
  session.status = status
  session.ended_at = vim.loop.hrtime()

  if opts.error then
    session.last_error = opts.error
    session_mod.push(session, opts.error)
    ui.update(session)
    runner.finish(session)
    if opts.notify ~= false then
      vim.notify("pi error: " .. opts.error, vim.log.levels.ERROR)
    end
  elseif status == "error" then
    ui.update(session)
    runner.finish(session)
  else
    reload_source_buffer(session)
    ui.close(session)
    runner.finish(session)
  end

  if active_session == session then
    active_session = nil
  end
  last_session = session

  -- Log the session
  log.append_session(
    config.get().log_path,
    session,
    session.last_message,
    status,
    session.source_path
  )
end

local function start_session(message, build_context)
  if active_session then
    vim.notify("pi is already running, please wait", vim.log.levels.WARN)
    return
  end

  if not message or message == "" then
    vim.notify("No message provided", vim.log.levels.ERROR)
    return
  end

  local source_bufnr = vim.api.nvim_get_current_buf()
  local session = session_mod.new(source_bufnr)
  session.last_message = message
  active_session = session
  last_session = session
  ui.open(session, config.get().focus_ui)
  set_status(session, "collecting_context")

  local ok, built_context = pcall(build_context)
  if not ok then
    finish_session(session, "error", { error = built_context })
    return
  end

  local payload = vim.json.encode({
    type = "prompt",
    message = message .. "\n\nContext:\n" .. built_context,
  }) .. "\n"

  set_status(session, "starting")

  local process, err = runner.start(session, get_pi_cmd(), payload, {
    on_event = function(event)
      if not active_session or active_session ~= session or session.cancelled then
        return
      end
      if event.type == "thinking" then
        set_status(session, "thinking")
      elseif event.type == "tool_start" then
        session.active_tool = event.tool
        set_status(session, "running_tool")
      elseif event.type == "tool_end" then
        session.active_tool = nil
        set_status(session, "thinking")
      elseif event.type == "done" then
        session.saw_terminal_event = true
        finish_session(session, "done")
      elseif event.type == "error" then
        session.saw_terminal_event = true
        finish_session(session, "error", { error = event.message })
      end
    end,
    on_stderr = function(line)
      if not active_session or active_session ~= session or session.cancelled then
        return
      end
      session_mod.push(session, line)
      ui.update(session)
    end,
    on_error = function(error_message)
      if not active_session or active_session ~= session or session.cancelled then
        return
      end
      finish_session(session, "error", { error = tostring(error_message) })
    end,
    on_exit = function(result)
      if session.cancelled then
        return
      end
      if session.closing then
        return
      end
      if result.code ~= 0 and result.code ~= 143 and result.code ~= 124 then
        finish_session(session, "error", { error = "pi exited with code " .. result.code })
        return
      end
      if not session.saw_terminal_event then
        finish_session(session, "error", { error = "pi exited before completing request" })
        return
      end
      finish_session(session, "done")
    end,
  })

  if not process then
    finish_session(session, "error", { error = tostring(err) })
    return
  end

  session.process = process
end

function M.setup(opts)
  assert_supported_version()
  config.setup(opts)
end

function M.prompt_with_buffer()
  assert_supported_version()
  local bufnr = ensure_file_backed_buffer("PiAsk")
  if not bufnr then
    return
  end

  vim.ui.input({ prompt = context.format_prompt_label(bufnr, nil) }, function(input)
    if input then
      start_session(input, function()
        return context.get_buffer_context(bufnr, config.get())
      end)
    end
  end)
end

function M.prompt_with_selection()
  assert_supported_version()
  local bufnr = ensure_file_backed_buffer("PiAskSelection")
  if not bufnr then
    return
  end

  local range = context.get_visual_selection_range()
  vim.ui.input({ prompt = context.format_prompt_label(bufnr, range) }, function(input)
    if input then
      start_session(input, function()
        return context.get_visual_context(bufnr, config.get())
      end)
    end
  end)
end

function M.cancel()
  if not active_session then
    return
  end
  active_session.cancelled = true
  runner.cancel(active_session)
  last_session = active_session
  ui.close(active_session)
  active_session = nil
end

function M.is_running()
  return active_session ~= nil
end

function M._get_active_session()
  return active_session
end

function M._get_last_session()
  return last_session
end

function M.show_log()
  local log_path = config.get().log_path
  if not log_path or log_path == "" then
    vim.notify("pi.nvim: log_path not configured", vim.log.levels.ERROR)
    return
  end

  -- Check if file exists
  if vim.fn.filereadable(log_path) == 0 then
    vim.notify("pi.nvim: log file not found at " .. log_path, vim.log.levels.INFO)
    return
  end

  vim.cmd("new")
  vim.cmd("read " .. vim.fn.fnameescape(log_path))
  vim.cmd("1d")
  vim.bo.modifiable = false
  vim.bo.buftype = "nofile"
  vim.bo.filetype = "log"
  vim.cmd("normal! G")
end

function M.get_buffer_context()
  return context.get_buffer_context(vim.api.nvim_get_current_buf(), config.get())
end

function M.get_visual_context()
  return context.get_visual_context(vim.api.nvim_get_current_buf(), config.get())
end

return M
