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

local function find_window_by_buffer(bufnr)
  -- Get the list of all windows in the current tab page
  local windows = vim.api.nvim_tabpage_list_wins(0)

  -- Iterate over each window
  for _, win in ipairs(windows) do
    -- Get the buffer number of the current window
    local win_bufnr = vim.api.nvim_win_get_buf(win)

    -- Check if this window's buffer number matches the one we're looking for
    if win_bufnr == bufnr then
      -- If a match is found, return the window handle
      return win
    end
  end

  -- If no window was found with the specified buffer number, return nil
  return nil
end

---Auto-scroll the log buffer to the end of the output
---@param buf integer
---@param target_win integer
local function autoscroll(buf, target_win)
  local win = find_window_by_buffer(buf)
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

local notifQueue = {}
local specialNotifId = "specialNotif"
local notifWindowSec = 3
local notifThreshold = 10

function handleIFlutterPattern(line)
  local match = line:match("^I/flutter %(%d+%): (.+)$")
  if match then
      return true, match
  else
      return false, nil
  end
end

local function notifyExcessive(count, replace)
  return require("notify").notify(fmt("%s messages", count), ui.INFO, {
    timeout = 2000,
    hide_from_history = false,
    replace = replace,
    icon = "",
    title = "Flutter",
  })
end

---Add lines to a buffer
---@param buf number
---@param lines string[]
local errorPattern = '.+:(%d+):(%d+): Error: '
local previousCompilerErrorNotification = nil
local previousCompilerErrorNotificationTime = 0
local accumulatedCompilerErrorCount = 0
local function append(buf, lines)
  local errorCount = 0
  local validStr = {}
  local newLines = {}
  for _, line in ipairs(lines) do
    if string.starts(line, "══╡") then
      table.insert(newLines, "")
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
      else
        local matched, extracted = handleIFlutterPattern(line)
        if matched then
            table.insert(validStr, extracted)
        elseif line:match(errorPattern) then
          errorCount = errorCount + 1
        end
      end
    end
    if not (string.starts(line, "I/") and not string.starts(line, "I/flutter")) and
       not string.starts(line, "V/") and
       not string.starts(line, "D/") and
       not string.starts(line, "W/") and
			 true
			then
			table.insert(newLines, line)
		end
  end
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(M.buf, -1, -1, true, newLines)
  vim.bo[buf].modifiable = false

  local curTime = os.time()

  local str = table.concat(validStr, "\n")
  if str ~= "" then
    -- Clean up notifications older than 3 seconds
    while #notifQueue > 0 and curTime - notifQueue[1].time > notifWindowSec do
      table.remove(notifQueue, 1)
    end

    if #notifQueue < notifThreshold then
      ui.notify(str, ui.INFO, { timeout = 1000 })
      table.insert(notifQueue, { time = curTime })
    else
      if notifQueue[#notifQueue].id == specialNotifId then
        notifQueue[#notifQueue].count = notifQueue[#notifQueue].count + 1
        notifQueue[#notifQueue].notif = notifyExcessive(notifQueue[#notifQueue].count, notifQueue[#notifQueue].notif)
      else
        table.insert(notifQueue, {
          id = specialNotifId,
          time = curTime,
          count = 1,
          notif = notifyExcessive(1, nil)
        })
      end
    end
  end
  if errorCount > 0 then
    if curTime - previousCompilerErrorNotificationTime > 2 then
      previousCompilerErrorNotification = nil
      accumulatedCompilerErrorCount = errorCount
    else
      accumulatedCompilerErrorCount = accumulatedCompilerErrorCount + errorCount
    end
    previousCompilerErrorNotification  = require("notify").notify(fmt("%s compiler errors", accumulatedCompilerErrorCount), ui.ERROR, {
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
    if opts.filter and not opts.filter(data) then return end
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
