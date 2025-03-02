local Util = require("trouble.util")

local M = {}

-- stylua: ignore
M.colors = {
  -- General
  Normal            = "NormalFloat",
  NormalNC          = "NormalFloat",
  Text              = "Normal",
  Preview           = "Visual",

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
---@param hl string
---@param statusline_hl string?
function M.fix_statusline_bg(hl, statusline_hl)
  if not statusline_hl then
    return hl
  end
  local key = hl .. "_" .. statusline_hl
  if not M._fixed[key] then
    local opts = vim.api.nvim_get_hl(0, { name = hl, link = false }) or {}
    local statusline_opts = vim.api.nvim_get_hl(0, { name = statusline_hl, link = false })
    opts.bg = statusline_opts and statusline_opts.bg or nil
    local group = "TroubleStatusline" .. vim.tbl_count(M._fixed)
    vim.api.nvim_set_hl(0, group, opts)
    M._fixed[key] = group
  end
  return M._fixed[key]
end

return M
