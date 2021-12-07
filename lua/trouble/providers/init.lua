local util = require("trouble.util")
local qf = require("trouble.providers.qf")
local telescope = require("trouble.providers.telescope")
local lsp = require("trouble.providers.lsp")

local M = {}

M.providers = {
  lsp_workspace_diagnostics = lsp.diagnostics,
  lsp_document_diagnostics = lsp.diagnostics,
  lsp_references = lsp.references,
  lsp_implementations = lsp.implementations,
  lsp_definitions = lsp.definitions,
  lsp_type_definitions = lsp.type_definitions,
  quickfix = qf.qflist,
  loclist = qf.loclist,
  telescope = telescope.telescope,
}

---@param options TroubleOptions
function M.get(win, buf, cb, options)
  local name = options.mode
  local provider = M.providers[name]

  if not provider then
    local ok, mod = pcall(require, "trouble.providers." .. name)
    if ok then
      M.providers[name] = mod
      provider = mod
    end
  end

  if not provider then
    util.error(("invalid provider %q"):format(name))
    return {}
  end

  local sort_keys = { "severity", "filename", "lnum", "col" }
  provider(win, buf, function(items)
    table.sort(items, function(a, b)
      for _, key in ipairs(sort_keys) do
        if a[key] ~= b[key] then
          return a[key] < b[key]
        end
      end
    end)
    cb(items)
  end, options)
end

---@param items Item[]
---@return table<string, Item[]>
function M.group(items)
  local keys = {}
  local keyid = 0
  local groups = {}
  for _, item in ipairs(items) do
    if groups[item.filename] == nil then
      groups[item.filename] = { filename = item.filename, items = {} }
      keys[item.filename] = keyid
      keyid = keyid + 1
    end
    table.insert(groups[item.filename].items, item)
  end

  local ret = {}
  for _, group in pairs(groups) do
    table.insert(ret, group)
  end
  table.sort(ret, function(a, b)
    return keys[a.filename] < keys[b.filename]
  end)
  return ret
end

return M
