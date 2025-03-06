local Util = require("trouble.util")

local M = {}

-- stylua: ignore
M.colors = {
  -- General
  Normal            = "NormalFloat",
  NormalNC          = "NormalFloat",
  Text              = "Normal",
  Preview           = "Visual",
  CursorLine        = "CursorLine",

  -- Item
  Filename          = "Directory",
  Basename          = "TroubleFilename",
  Directory         = "Directory",
  IconDirectory     = "Special",
  Source            = "Comment",
  Code              = "Special",
  Pos               = "LineNr",
  Count             = "TabLineSel",

  -- Indent Guides
  Indent            = "LineNr",
  IndentFoldClosed  = "CursorLineNr",
  IndentFoldOpen    = "TroubleIndent",
  IndentTop         = "TroubleIndent",
  IndentMiddle      = "TroubleIndent",
  IndentLast        = "TroubleIndent",
  IndentWs          = "TroubleIndent",

  -- LSP Symbol Kinds
  IconArray         = "@punctuation.bracket",
  IconBoolean       = "@boolean",
  IconClass         = "@type",
  IconConstant      = "@constant",
  IconConstructor   = "@constructor",
  IconEnum          = "@lsp.type.enum",
  IconEnumMember    = "@lsp.type.enumMember",
  IconEvent         = "Special",
  IconField         = "@variable.member",
  IconFile          = "Normal",
  IconFunction      = "@function",
  IconInterface     = "@lsp.type.interface",
  IconKey           = "@lsp.type.keyword",
  IconMethod        = "@function.method",
  IconModule        = "@module",
  IconNamespace     = "@module",
  IconNull          = "@constant.builtin",
  IconNumber        = "@number",
  IconObject        = "@constant",
  IconOperator      = "@operator",
  IconPackage       = "@module",
  IconProperty      = "@property",
  IconString        = "@string",
  IconStruct        = "@lsp.type.struct",
  IconTypeParameter = "@lsp.type.typeParameter",
  IconVariable      = "@variable",
}

function M.setup()
  M.link(M.colors)
  M.source("fs")
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("trouble.colorscheme", { clear = true }),
    callback = function()
      M._fixed = {}
    end,
  })
end

---@param prefix? string
---@param links table<string, string>
function M.link(links, prefix)
  for k, v in pairs(links) do
    k = (prefix or "Trouble") .. k
    vim.api.nvim_set_hl(0, k, { link = v, default = true })
  end
end

---@param source string
---@param links? table<string, string>
function M.source(source, links)
  ---@type table<string, string>
  links = vim.tbl_extend("force", {
    Filename = "TroubleFilename",
    Basename = "TroubleFilename",
    Source = "TroubleSource",
    Pos = "TroublePos",
    Count = "TroubleCount",
  }, links or {})
  M.link(links, "Trouble" .. Util.camel(source))
end

M._fixed = {} ---@type table<string, string>
---@param sl string
function M.fix_statusline(sl, statusline_hl)
  local bg = vim.api.nvim_get_hl(0, { name = statusline_hl, link = false })
  bg = bg and bg.bg or nil

  return sl:gsub("%%#(.-)#", function(hl)
    if not M._fixed[hl] then
      local opts = vim.api.nvim_get_hl(0, { name = hl, link = false }) or {}
      opts.bg = bg
      local group = "TroubleStatusline" .. vim.tbl_count(M._fixed)
      vim.api.nvim_set_hl(0, group, opts)
      M._fixed[hl] = group
    end
    return "%#" .. M._fixed[hl] .. "#"
  end)
end

return M
