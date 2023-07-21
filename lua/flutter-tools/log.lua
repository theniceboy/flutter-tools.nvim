local lazy = require("flutter-tools.lazy")
local ui = lazy.require("flutter-tools.ui") ---@module "flutter-tools.ui"
local utils = lazy.require("flutter-tools.utils") ---@module "flutter-tools.utils"

local api = vim.api
local fmt = string.format

local M = {
  --@type integer
  buf = nil,
  --@type integer
  win = nil,
}

M.filename = "__FLUTTER_DEV_LOG__"

--- check if the buffer exists if does and we
--- lost track of it's buffer number re-assign it
local function exists()
  local is_valid = utils.buf_valid(M.buf, M.filename)
  if is_valid and not M.buf then M.buf = vim.fn.bufnr(M.filename) end
  return is_valid
end

local function close_dev_log()
  M.buf = nil
  M.win = nil
end

local function create(config)
  local opts = {
    filename = M.filename,
    filetype = "log",
    open_cmd = config.open_cmd,
  }
  ui.open_win(opts, function(buf, win)
    if not buf then
      ui.notify("Failed to open the dev log as the buffer could not be found", ui.ERROR)
      return
    end
    M.buf = buf
    M.win = win
    api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      callback = close_dev_log,
    })
  end)
end

function M.get_content()
  if M.buf then return api.nvim_buf_get_lines(M.buf, 0, -1, false) end
end

---Auto-scroll the log buffer to the end of the output
---@param buf integer
---@param target_win integer
local function autoscroll(buf, target_win)
  local win = utils.find(
    api.nvim_tabpage_list_wins(0),
    function(item) return item == target_win end
  )
  if not win then return end
  -- if the dev log is focused don't scroll it as it will block the user from perusing
  if api.nvim_get_current_win() == win then return end
  local buf_length = api.nvim_buf_line_count(buf)
  local success, err = pcall(api.nvim_win_set_cursor, win, { buf_length, 0 })
  if not success then
    ui.notify(fmt("Failed to set cursor for log window %s: %s", win, err), ui.ERROR, {
      once = true,
    })
  end
end

local tmpStopNotifyingDevLogOutput = false
function string.starts(str, start)
  return string.sub(str, 1, string.len(start)) == start
end

---Add lines to a buffer
---@param buf number
---@param lines string[]
local errorPattern = '.+:(%d+):(%d+): Error: '
local previousCompilerErrorNotification
local previousCompilerErrorNotificationTime = 0
local accumulatedCompilerErrorCount = 0
local function append(buf, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(M.buf, -1, -1, true, lines)
  vim.bo[buf].modifiable = false
  local errorCount = 0
  local validStr = {}
  for _, line in ipairs(lines) do
    if string.starts(line, "══╡") then
      tmpStopNotifyingDevLogOutput = true
      ui.notify("Encountered Layout issues", ui.WARN, {
        timeout = 1000,
        hide_from_history = false,
      })
    elseif string.starts(line, "════════════════════════════════════════════════════════") then
      tmpStopNotifyingDevLogOutput = false
    elseif not tmpStopNotifyingDevLogOutput then
      if line == "" or
          string.starts(line, "Another exception was thrown:") then
      elseif string.starts(line, "flutter: ") then
        table.insert(validStr, string.sub(line, 10))
      elseif line:match(errorPattern) then
        errorCount = errorCount + 1
      end
    end
  end

  local str = table.concat(validStr, "\n")
  if str ~= "" then
    ui.notify(str, ui.INFO, { timeout = 1000 })
  end
  if errorCount > 0 then
    local curTime = os.time()
    if curTime - previousCompilerErrorNotificationTime > 2 then
      previousCompilerErrorNotification = nil
      accumulatedCompilerErrorCount = errorCount
    else
      accumulatedCompilerErrorCount = accumulatedCompilerErrorCount + errorCount
    end
    previousCompilerErrorNotification = vim.notify(fmt("%s compiler errors", accumulatedCompilerErrorCount), ui.ERROR, {
      timeout = 1000,
      hide_from_history = false,
      replace = previousCompilerErrorNotification,
      icon = "",
      title = "Flutter",
    })
    previousCompilerErrorNotificationTime = curTime
  end
end

--- Open a log showing the output from a command
--- in this case flutter run
---@param data string
---@param opts table
function M.log(data, opts)
  if opts.enabled then
    if not exists() then create(opts) end
    append(M.buf, { data })
    autoscroll(M.buf, M.win)
  end
end

function M.__resurrect()
  local buf = api.nvim_get_current_buf()
  vim.cmd("setfiletype log")
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.bo[buf].buftype = "nofile"
end

function M.clear()
  if api.nvim_buf_is_valid(M.buf) then
    vim.bo[M.buf].modifiable = true
    api.nvim_buf_set_lines(M.buf, 0, -1, false, {})
    vim.bo[M.buf].modifiable = false
  end
end

return M
