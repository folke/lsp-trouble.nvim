local Actions = require("trouble.config.actions")
local Config = require("trouble.config")
local Util = require("trouble.util")
local View = require("trouble.view")

---@alias trouble.ApiFn fun(opts?: trouble.Config|string): trouble.View

---@class trouble.api: trouble.actions
local M = {}
M.last_mode = nil ---@type string?

--- Finds all open views matching the filter.
---@param opts? trouble.Config|string
---@param filter? trouble.View.filter
---@return trouble.View[], trouble.Config
function M._find(opts, filter)
  opts = Config.get(opts)
  if opts.mode == "last" then
    opts.mode = M.last_mode
    opts = Config.get(opts)
  end
  M.last_mode = opts.mode or M.last_mode
  filter = filter or { open = true, mode = opts.mode }
  return vim.tbl_map(function(v)
    return v.view
  end, View.get(filter)), opts
end

--- Finds the last open view matching the filter.
---@param opts? trouble.Mode|string
---@param filter? trouble.View.filter
---@return trouble.View?, trouble.Mode
function M._find_last(opts, filter)
  local views, _opts = M._find(opts, filter)
  ---@cast _opts trouble.Mode
  return views[#views], _opts
end

-- Opens trouble with the given mode.
-- If a view is already open with the same mode,
-- it will be focused unless `opts.focus = false`.
-- When a view is already open and `opts.new = true`,
-- a new view will be created.
---@param opts? trouble.Mode | { new?: boolean, refresh?: boolean } | string
---@return trouble.View?
function M.open(opts)
  opts = opts or {}
  local view, _opts = M._find_last(opts)
  if not view or _opts.new then
    if not _opts.mode then
      return Util.error("No mode specified")
    elseif not vim.tbl_contains(Config.modes(), _opts.mode) then
      return Util.error("Invalid mode `" .. _opts.mode .. "`")
    end
    view = View.new(_opts)
  end
  if view then
    if view:is_open() then
      if opts.refresh ~= false then
        view:refresh()
      end
    else
      view:open()
    end
    if _opts.focus ~= false then
      view:wait(function()
        view.win:focus()
      end)
    end
  end
  return view
end

-- Closes the last open view matching the filter.
---@param opts? trouble.Mode|string
---@return trouble.View?
function M.close(opts)
  local view = M._find_last(opts)
  if view then
    view:close()
    return view
  end
end

-- Toggle the view with the given mode.
---@param opts? trouble.Mode|string
---@return trouble.View?
function M.toggle(opts)
  if M.is_open(opts) then
    ---@diagnostic disable-next-line: return-type-mismatch
    return M.close(opts)
  else
    return M.open(opts)
  end
end

-- Returns true if there is an open view matching the mode.
---@param opts? trouble.Mode|string
function M.is_open(opts)
  return M._find_last(opts) ~= nil
end

-- Refresh all open views. Normally this is done automatically,
-- unless you disabled auto refresh.
---@param opts? trouble.Mode|string
function M.refresh(opts)
  for _, view in ipairs(M._find(opts)) do
    view:refresh()
  end
end

-- Proxy to last view's action.
---@param action trouble.Action.spec
function M._action(action)
  return function(opts)
    opts = opts or {}
    if type(opts) == "string" then
      opts = { mode = opts }
    end
    opts = vim.tbl_deep_extend("force", {
      refresh = false,
    }, opts)
    local view = M.open(opts)
    if view then
      view:action(action, opts)
    end
    return view
  end
end

-- Get all items from the active view for a given mode.
---@param opts? trouble.Mode|string
function M.get_items(opts)
  local view = M._find_last(opts)
  local ret = {} ---@type trouble.Item[]
  if view then
    for _, source in pairs(view.sections) do
      vim.list_extend(ret, source.items or {})
    end
  end
  return ret
end

-- Renders a trouble list as a statusline component.
-- Check the docs for examples.
---@param opts? trouble.Mode|string|{hl_group?:string}
---@return {get: (fun():string), has: (fun():boolean)}
function M.statusline(opts)
  local Spec = require("trouble.spec")
  local Section = require("trouble.view.section")
  local Render = require("trouble.view.render")
  opts = Config.get(opts)
  opts.indent_guides = false
  opts.icons.indent.ws = ""
  local renderer = Render.new(opts, {
    multiline = false,
    indent = false,
  })
  local status = nil ---@type string?
  ---@cast opts trouble.Mode

  local s = Spec.section(opts)
  s.max_items = s.max_items or opts.max_items
  local section = Section.new(s, opts)
  section.on_update = function()
    status = nil
    if package.loaded["lualine"] then
      vim.schedule(function()
        require("lualine").refresh()
      end)
    else
      vim.cmd.redrawstatus()
    end
  end
  section:listen()
  section:refresh()
  return {
    has = function()
      return section.node and section.node:count() > 0
    end,
    get = function()
      if status then
        return status
      end
      renderer:clear()
      renderer:sections({ section })
      status = renderer:statusline({ hl_group = opts.hl_group })
      return status
    end,
  }
end

return setmetatable(M, {
  __index = function(_, k)
    if k == "last_mode" then
      return nil
    end
    return M._action(k)
  end,
})
