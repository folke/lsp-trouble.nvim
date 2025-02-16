local Main = require("trouble.view.main")
local Util = require("trouble.util")

---@class trouble.Window.split
---@field type "split"
---@field relative "editor" | "win" cursor is only valid for float
---@field size number | {width:number, height:number} when a table is provided, either the width or height is used based on the position
---@field position "top" | "bottom" | "left" | "right"

---@alias floatPositionArg number|fun(parent_size:{width:number, height:number}):number

---@class trouble.Window.float
---@field type "float"
---@field relative "editor" | "win" | "cursor" cursor is only valid for float
---@field size {width: floatPositionArg, height: floatPositionArg}
---@field position {[1]: floatPositionArg, [2]: floatPositionArg}
---@field anchor? string
---@field focusable? boolean
---@field zindex? integer
---@field border? any
---@field title? string|{[1]: string, [2]: string}
---@field title_pos? string
---@field footer? string|{[1]: string, [2]: string}
---@field footer_pos? string
---@field fixed? boolean

---@class trouble.Window.main
---@field type "main"

---@class trouble.Window.base
---@field padding? {top?:number, left?:number}
---@field wo? vim.wo
---@field bo? vim.bo
---@field minimal? boolean (defaults to true)
---@field win? number
---@field on_mount? fun(self: trouble.Window)
---@field on_close? fun(self: trouble.Window)

---@alias trouble.Window.opts trouble.Window.base|trouble.Window.split|trouble.Window.float|trouble.Window.main

---@class trouble.Window
---@field opts trouble.Window.opts
---@field win? number
---@field buf number
---@field id number
---@field keys table<string, string>
local M = {}
M.__index = M

local _id = 0
local function next_id()
  _id = _id + 1
  return _id
end

local split_commands = {
  editor = {
    top = "topleft",
    right = "vertical botright",
    bottom = "botright",
    left = "vertical topleft",
  },
  win = {
    top = "aboveleft",
    right = "vertical rightbelow",
    bottom = "belowright",
    left = "vertical leftabove",
  },
}

local float_options = {
  "anchor",
  "border",
  "bufpos",
  "col",
  "external",
  "fixed",
  "focusable",
  "footer",
  "footer_pos",
  "height",
  "hide",
  "noautocmd",
  "relative",
  "row",
  "style",
  "title",
  "title_pos",
  "width",
  "win",
  "zindex",
}

---@type trouble.Window.opts
local defaults = {
  padding = { top = 0, left = 1 },
  bo = {
    bufhidden = "wipe",
    filetype = "trouble",
    buftype = "nofile",
  },
  wo = {
    winbar = "",
    winblend = 0,
  },
}

M.FOLDS = {
  wo = {
    foldcolumn = "0",
    foldenable = false,
    foldlevel = 99,
    foldmethod = "manual",
  },
}

---@type trouble.Window.opts
local minimal = {
  wo = {
    cursorcolumn = false,
    cursorline = true,
    cursorlineopt = "both",
    fillchars = "eob: ",
    list = false,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    spell = false,
    winbar = "",
    statuscolumn = "",
    winfixheight = true,
    winfixwidth = true,
    winhighlight = "Normal:TroubleNormal,NormalNC:TroubleNormalNC,EndOfBuffer:TroubleNormal",
    wrap = false,
  },
}

---@param opts? trouble.Window.opts
function M.new(opts)
  local self = setmetatable({}, M)
  self.id = next_id()
  opts = opts or {}

  if opts.minimal == nil then
    opts.minimal = opts.type ~= "main"
  end

  opts = vim.tbl_deep_extend("force", {}, defaults, opts.minimal and minimal or {}, opts or {})
  opts.type = opts.type or "split"
  if opts.type == "split" then
    opts.relative = opts.relative or "editor"
    opts.position = opts.position or "bottom"
    opts.size = opts.size or (opts.position == "bottom" or opts.position == "top") and 10 or 30
    opts.win = opts.win or vim.api.nvim_get_current_win()
  elseif opts.type == "float" then
    opts.relative = opts.relative or "editor"
    opts.size = opts.size or { width = 0.8, height = 0.8 }
    opts.position = type(opts.position) == "table" and opts.position or { 0.5, 0.5 }
  elseif opts.type == "main" then
    opts.type = "float"
    opts.relative = "win"
    opts.position = { 0, 0 }
    opts.size = { width = 1, height = 1 }
    opts.wo.winhighlight = "Normal:Normal"
  end
  self.opts = opts
  return self
end

---@param clear? boolean
function M:augroup(clear)
  return vim.api.nvim_create_augroup("trouble.window." .. self.id, { clear = clear == true })
end

function M:parent_size()
  if self.opts.relative == "editor" or self.opts.relative == "cursor" then
    return { width = vim.o.columns, height = vim.o.lines }
  end
  local ret = {
    width = vim.api.nvim_win_get_width(self.opts.win),
    height = vim.api.nvim_win_get_height(self.opts.win),
  }
  -- account for winbar
  if vim.wo[self.opts.win].winbar ~= "" then
    ret.height = ret.height - 1
  end
  return ret
end

---@param type "win" | "buf"
function M:set_options(type)
  local opts = type == "win" and self.opts.wo or self.opts.bo
  ---@diagnostic disable-next-line: no-unknown
  for k, v in pairs(opts or {}) do
    ---@diagnostic disable-next-line: no-unknown
    local ok, err = pcall(vim.api.nvim_set_option_value, k, v, type == "win" and {
      scope = "local",
      win = self.win,
    } or { buf = self.buf })
    if not ok then
      Util.error("Error setting option `" .. k .. "=" .. v .. "`\n\n" .. err)
    end
  end
end

function M:mount()
  self.keys = {}
  self.buf = vim.api.nvim_create_buf(false, true)
  self:set_options("buf")
  if self.opts.type == "split" then
    ---@diagnostic disable-next-line: param-type-mismatch
    self:mount_split(self.opts)
  else
    ---@diagnostic disable-next-line: param-type-mismatch
    self:mount_float(self.opts)
  end

  self:set_options("win")

  self:on({ "BufWinLeave" }, vim.schedule_wrap(self.check_alien))

  self:on("WinClosed", function()
    if self.opts.on_close then
      self.opts.on_close(self)
    end
    self:augroup(true)
  end, { win = true })

  if self.opts.on_mount then
    self.opts.on_mount(self)
  end
end

function M:set_buf(buf)
  self.buf = buf
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_set_buf(self.win, buf)
  end
end

function M:check_alien()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    local buf = vim.api.nvim_win_get_buf(self.win)
    if buf ~= self.buf then
      -- move the alien buffer to another window
      local main = Main:get()
      if main then
        vim.api.nvim_win_set_buf(main.win, buf)
        -- restore the trouble window
        self:close()
        self:open()
      end
    end
  end
end

function M:close()
  pcall(vim.api.nvim_win_close, self.win, true)
  self:augroup(true)
  self.win = nil
end

function M:open()
  if self:valid() then
    return self
  end
  self:close()
  self:mount()
  return self
end

function M:valid()
  return self.win
    and vim.api.nvim_win_is_valid(self.win)
    and self.buf
    and vim.api.nvim_buf_is_valid(self.buf)
    and vim.api.nvim_win_get_buf(self.win) == self.buf
end

---@param opts trouble.Window.split|trouble.Window.base
function M:mount_split(opts)
  if self.opts.win and not vim.api.nvim_win_is_valid(self.opts.win) then
    self.opts.win = 0
  end
  local parent_size = self:parent_size()
  local size = opts.size
  if type(size) == "table" then
    size = opts.position == "left" or opts.position == "right" and size.width or size.height
  end
  if size <= 1 then
    local vertical = opts.position == "left" or opts.position == "right"
    size = math.floor(parent_size[vertical and "width" or "height"] * size)
  end
  local cmd = split_commands[opts.relative][opts.position]
  Util.noautocmd(function()
    vim.api.nvim_win_call(opts.win, function()
      vim.cmd("silent noswapfile " .. cmd .. " " .. size .. "split")
      vim.api.nvim_win_set_buf(0, self.buf)
      self.win = vim.api.nvim_get_current_win()
    end)
  end)
end

---@param opts trouble.Window.float|trouble.Window.base
function M:mount_float(opts)
  local parent_size = self:parent_size()
  ---@type vim.api.keyset.win_config
  local config = {}
  for _, v in ipairs(float_options) do
    ---@diagnostic disable-next-line: no-unknown
    config[v] = opts[v]
  end
  config.focusable = true

  local position_opts = {
    ---@type {width: number, height: number}
    ---@diagnostic disable-next-line: assign-type-mismatch
    size = vim.deepcopy(opts.size),
    ---@type {[1]: number, [2]: number}
    ---@diagnostic disable-next-line: assign-type-mismatch
    position = vim.deepcopy(opts.position)
  }

  -- If size or position is a function, then invoke it
  if type(opts.size.height) == "function" then
    position_opts.size.height = opts.size.height(parent_size)
  end
  if type(opts.size.width) == "function" then
    position_opts.size.width = opts.size.width(parent_size)
  end
  if type(opts.position[1]) == "function" then
    position_opts.position[1] = opts.position[1](parent_size)
  end
  if type(opts.position[2]) == "function" then
    position_opts.position[2] = opts.position[2](parent_size)
  end
  if type(parent_size.height) == "function" then
    parent_size.height = parent_size.height(parent_size)
  end
  if type(parent_size.width) == "function" then
    parent_size.width = parent_size.width(parent_size)
  end
  if type(config.height) == "function" then
    config.height = config.height(parent_size)
  end
  if type(config.width) == "function" then
    config.width = config.width(parent_size)
  end

  config.height = math.abs(position_opts.size.height) <= 1 and math.floor(parent_size.height * position_opts.size.height) or position_opts.size.height
  config.height = config.height < 0 and (parent_size.height + config.height) or config.height

  config.width = math.abs(position_opts.size.width) <= 1 and math.floor(parent_size.width * position_opts.size.width) or position_opts.size.width
  config.width = config.width < 0 and (parent_size.width + config.width) or config.width

  config.row = math.abs(position_opts.position[1]) <= 1 and math.floor((parent_size.height - config.height) * position_opts.position[1])
    or position_opts.position[1]
  config.row = config.row < 0 and (parent_size.height + config.row) or config.row

  config.col = math.abs(position_opts.position[2]) <= 1 and math.floor((parent_size.width - config.width) * position_opts.position[2])
    or position_opts.position[2]
  config.col = config.col < 0 and (parent_size.width + config.col) or config.col

  if config.relative ~= "win" then
    config.win = nil
  end

  self.win = vim.api.nvim_open_win(self.buf, false, config)
end

function M:focus()
  if self:valid() then
    vim.api.nvim_set_current_win(self.win)
  end
end

---@param events string|string[]
---@param fn fun(self:trouble.Window, event:{buf:number}):boolean?
---@param opts? vim.api.keyset.create_autocmd | {buffer: false, win?:boolean}
function M:on(events, fn, opts)
  opts = opts or {}
  if opts.win then
    opts.pattern = self.win .. ""
    opts.win = nil
  elseif opts.buffer == nil then
    opts.buffer = self.buf
  elseif opts.buffer == false then
    opts.buffer = nil
  end
  if opts.pattern then
    opts.buffer = nil
  end
  local _self = Util.weak(self)
  opts.callback = function(e)
    local this = _self()
    if not this then
      -- delete the autocmd
      return true
    end
    return fn(this, e)
  end
  opts.group = self:augroup()
  vim.api.nvim_create_autocmd(events, opts)
end

---@param key string
---@param fn fun(self: trouble.Window):any
---@param opts? string|vim.keymap.set.Opts|{mode?:string}
function M:map(key, fn, opts)
  opts = vim.tbl_deep_extend("force", {
    buffer = self.buf,
    nowait = true,
    mode = "n",
  }, type(opts) == "string" and { desc = opts } or opts or {})
  local mode = opts.mode
  opts.mode = nil
  ---@cast opts vim.keymap.set.Opts
  if not self:valid() then
    error("Cannot create a keymap for an invalid window")
  end

  self.keys[key] = opts.desc or key
  local weak_self = Util.weak(self)
  vim.keymap.set(mode, key, function()
    if weak_self() then
      return fn(weak_self())
    end
  end, opts)
end

return M
