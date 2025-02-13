local Cache = require("trouble.cache")
local Config = require("trouble.config")
local Filter = require("trouble.filter")
local Item = require("trouble.item")
local Promise = require("trouble.promise")
local Util = require("trouble.util")

---@param line string line to be indexed
---@param index integer UTF index
---@param encoding string utf-8|utf-16|utf-32| defaults to utf-16
---@return integer byte (utf-8) index of `encoding` index `index` in `line`
local function get_line_col(line, index, encoding)
  local function get()
    if vim.str_byteindex then
      -- FIXME: uses old-style func signature, since there's no way to
      -- properly detect if new style is available
      return vim.str_byteindex(line, index, encoding == "utf-16")
    end
    return vim.lsp.util._str_byteindex_enc(line, index, encoding)
  end
  local ok, ret = pcall(get)
  return ok and ret or #line
end

---@class trouble.Source.lsp: trouble.Source
---@diagnostic disable-next-line: missing-fields
local M = {}

function M.setup()
  vim.api.nvim_create_autocmd({ "LspAttach", "LspDetach" }, {
    group = vim.api.nvim_create_augroup("trouble.lsp.dattach", { clear = true }),
    callback = function()
      Cache.symbols:clear()
      Cache.locations:clear()
    end,
  })
  vim.api.nvim_create_autocmd({ "BufDelete", "TextChanged", "TextChangedI" }, {
    group = vim.api.nvim_create_augroup("trouble.lsp.buf", { clear = true }),
    callback = function(ev)
      local buf = ev.buf
      Cache.symbols[buf] = nil
      if vim.api.nvim_buf_is_valid(ev.buf) and vim.api.nvim_buf_is_loaded(ev.buf) and vim.bo[ev.buf].buftype == "" then
        Cache.locations:clear()
      end
    end,
  })
end

M.config = {
  modes = {
    lsp_document_symbols = {
      title = "{hl:Title}Document Symbols{hl} {count}",
      desc = "document symbols",
      events = {
        "BufEnter",
        -- symbols are cached on changedtick,
        -- so it's ok to refresh often
        { event = "TextChanged", main = true },
        { event = "CursorMoved", main = true },
        { event = "LspAttach", main = true },
      },
      source = "lsp.document_symbols",
      groups = {
        { "filename", format = "{file_icon} {filename} {count}" },
      },
      sort = { "filename", "pos", "text" },
      -- sort = { { buf = 0 }, { kind = "Function" }, "filename", "pos", "text" },
      format = "{kind_icon} {symbol.name} {text:Comment} {pos}",
    },
    lsp_base = {
      events = {
        "BufEnter",
        { event = "CursorHold", main = true },
        { event = "LspAttach", main = true },
      },
      groups = {
        { "filename", format = "{file_icon} {filename} {count}" },
      },
      sort = { "filename", "pos", "text" },
      format = "{text:ts} {pos} {hl:Title}{item.client:Title}{hl}",
    },
    lsp = {
      desc = "LSP definitions, references, implementations, type definitions, and declarations",
      sections = {
        "lsp_definitions",
        "lsp_references",
        "lsp_implementations",
        "lsp_type_definitions",
        "lsp_declarations",
        "lsp_incoming_calls",
        "lsp_outgoing_calls",
      },
    },
  },
}

for _, mode in ipairs({ "incoming_calls", "outgoing_calls" }) do
  M.config.modes["lsp_" .. mode] = {
    mode = "lsp_base",
    title = "{hl:Title}" .. Util.camel(mode, " ") .. "{hl} {count}",
    desc = Util.camel(mode, " "),
    source = "lsp." .. mode,
    format = "{kind_icon} {text:ts} {pos} {hl:Title}{item.client:Title}{hl}",
  }
end

for _, mode in ipairs({ "definitions", "references", "implementations", "type_definitions", "declarations", "command" }) do
  M.config.modes["lsp_" .. mode] = {
    auto_jump = true,
    mode = "lsp_base",
    title = "{hl:Title}" .. Util.camel(mode, " ") .. "{hl} {count}",
    source = "lsp." .. mode,
    desc = Util.camel(mode, " "):lower(),
  }
end

---@class trouble.lsp.Response<R,P>: {client: vim.lsp.Client, result: R, err: lsp.ResponseError, params: P}

---@param method string
---@param params? table|fun(client:vim.lsp.Client):table
---@param opts? {client?:vim.lsp.Client}
function M.request(method, params, opts)
  opts = opts or {}
  local buf = vim.api.nvim_get_current_buf()
  ---@type vim.lsp.Client[]
  local clients = {}

  if opts.client then
    clients = { opts.client }
  else
    if vim.lsp.get_clients then
      clients = vim.lsp.get_clients({ method = method, bufnr = buf })
    else
      ---@diagnostic disable-next-line: deprecated
      clients = vim.lsp.get_active_clients({ bufnr = buf })
      ---@param client vim.lsp.Client
      clients = vim.tbl_filter(function(client)
        return client.supports_method(method)
      end, clients)
    end
  end

  ---@param client vim.lsp.Client
  return Promise.all(vim.tbl_map(function(client)
    return Promise.new(function(resolve)
      local p = type(params) == "function" and params(client) or params --[[@as table]]
      client.request(method, p, function(err, result)
        resolve({ client = client, result = result, err = err, params = p })
      end, buf)
    end)
  end, clients)):next(function(results)
    ---@param v trouble.lsp.Response<any,any>
    return vim.tbl_filter(function(v)
      return v.result
    end, results)
  end)
end

---@param method string
---@param cb trouble.Source.Callback
---@param ctx trouble.Source.ctx
---@param opts? {context?:any, params?:table<string,any>}
function M.get_locations(method, cb, ctx, opts)
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local col = cursor[2]

  local line = vim.api.nvim_get_current_line()
  while col > 1 and vim.fn.strcharpart(line, col - 1, 1):match("^[a-zA-Z_]$") do
    col = col - 1
  end

  opts = opts or {}
  ---@type fun(client:vim.lsp.Client):lsp.TextDocumentPositionParams
  local params = function(client)
    local ret = opts.params or vim.lsp.util.make_position_params(win, client.offset_encoding)
    ---@diagnostic disable-next-line: inject-field
    ret.context = ret.context or opts.context or nil
    return ret
  end

  local id =
    table.concat({ buf, cursor[1], col, method, vim.inspect(vim.lsp.util.make_position_params(win, "utf-16")) }, "-")
  if Cache.locations[id] then
    return cb(Cache.locations[id])
  end

  M.request(method, params):next(
    ---@param results trouble.lsp.Response<lsp.Loc>[]
    function(results)
      local items = {} ---@type trouble.Item[]
      for _, resp in ipairs(results) do
        vim.list_extend(items, M.get_items(resp.client, resp.result, ctx.opts.params))
      end
      Cache.locations[id] = items
      cb(items)
    end
  )
end

M.get = {}

---@param cb trouble.Source.Callback
function M.get.document_symbols(cb)
  local buf = vim.api.nvim_get_current_buf()
  ---@type trouble.Item[]
  local ret = Cache.symbols[buf]

  if ret then
    return cb(ret)
  end

  ---@type lsp.DocumentSymbolParams
  local params = { textDocument = vim.lsp.util.make_text_document_params() }

  ---@alias lsp.Symbol lsp.SymbolInformation|lsp.DocumentSymbol

  M.request("textDocument/documentSymbol", params):next(
    ---@param results trouble.lsp.Response<lsp.SymbolInformation[]|lsp.DocumentSymbol[]>[]
    function(results)
      if vim.tbl_isempty(results) then
        return cb({})
      end
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      local items = {} ---@type trouble.Item[]

      for _, res in ipairs(results) do
        vim.list_extend(items, M.results_to_items(res.client, res.result, params.textDocument.uri))
      end
      Item.add_text(items, { mode = "after" })
      ---@diagnostic disable-next-line: no-unknown
      Cache.symbols[buf] = items
      cb(items)
    end
  )
end

---@param cb trouble.Source.Callback
function M.call_hierarchy(cb, incoming)
  local win = vim.api.nvim_get_current_win()
  M.request("textDocument/prepareCallHierarchy", function(client)
    return vim.lsp.util.make_position_params(win, client.offset_encoding)
  end)
    :next(
      ---@param results trouble.lsp.Response<lsp.CallHierarchyItem[]>[]
      function(results)
        local requests = {} ---@type trouble.Promise[]
        for _, res in ipairs(results or {}) do
          for _, chi in ipairs(res.result) do
            requests[#requests + 1] = M.request(
              ("callHierarchy/%sCalls"):format(incoming and "incoming" or "outgoing"),
              { item = chi },
              { client = res.client }
            )
          end
        end
        return Promise.all(requests)
      end
    )
    :next(
      ---@param responses trouble.lsp.Response<(lsp.CallHierarchyIncomingCall|lsp.CallHierarchyOutgoingCall)[]>[][]
      function(responses)
        local items = {} ---@type trouble.Item[]

        for _, results in ipairs(responses) do
          for _, res in ipairs(results) do
            local client = res.client
            local calls = res.result
            local todo = {} ---@type lsp.ResultItem[]

            for _, call in ipairs(calls) do
              todo[#todo + 1] = call.to or call.from
            end
            vim.list_extend(items, M.results_to_items(client, todo))
          end
        end
        Item.add_text(items, { mode = "after" })

        if incoming then
          -- for incoming calls, we actually want the call locations, not just the caller
          -- but we use the caller's item text as the call location text
          local texts = {} ---@type table<lsp.CallHierarchyItem, string>
          for _, item in ipairs(items) do
            texts[item.item.symbol] = item.item.text
          end

          items = {}
          for _, results in ipairs(responses) do
            for _, res in ipairs(results) do
              local client = res.client
              local calls = res.result
              local todo = {} ---@type lsp.ResultItem[]

              for _, call in ipairs(calls) do
                for _, r in ipairs(call.fromRanges or {}) do
                  local t = vim.deepcopy(call.from) --[[@as lsp.ResultItem]]
                  t.location = { range = r or call.from.selectionRange or call.from.range, uri = call.from.uri }
                  t.text = texts[call.from]
                  todo[#todo + 1] = t
                end
              end
              vim.list_extend(items, M.results_to_items(client, todo))
            end
          end
        end
        cb(items)
      end
    )
  -- :catch(Util.error)
end

---@param cb trouble.Source.Callback
function M.get.incoming_calls(cb)
  M.call_hierarchy(cb, true)
end

---@param cb trouble.Source.Callback
function M.get.outgoing_calls(cb)
  M.call_hierarchy(cb, false)
end

---@param client vim.lsp.Client
---@param locations? lsp.Location[]|lsp.LocationLink[]|lsp.Location
---@param opts? {include_current?:boolean}
function M.get_items(client, locations, opts)
  opts = opts or {}
  locations = locations or {}
  locations = Util.islist(locations) and locations or { locations }
  ---@cast locations (lsp.Location|lsp.LocationLink)[]

  locations = vim.list_slice(locations, 1, Config.max_items)

  local items = M.locations_to_items(client, locations)

  local cursor = vim.api.nvim_win_get_cursor(0)
  local fname = vim.api.nvim_buf_get_name(0)
  fname = vim.fs.normalize(fname)

  if not opts.include_current then
    ---@param item trouble.Item
    items = vim.tbl_filter(function(item)
      return not (item.filename == fname and Filter.overlaps(cursor, item, { lines = true }))
    end, items)
  end

  -- Item.add_text(items, { mode = "full" })
  return items
end

---@alias lsp.Loc lsp.Location|lsp.LocationLink
---@param client vim.lsp.Client
---@param locs lsp.Loc[]
---@return trouble.Item[]
function M.locations_to_items(client, locs)
  local ranges = M.locations_to_ranges(client, locs)
  ---@param range trouble.Range.lsp
  return vim.tbl_map(function(range)
    return M.range_to_item(client, range)
  end, vim.tbl_values(ranges))
end

---@param client vim.lsp.Client
---@param range trouble.Range.lsp
---@return trouble.Item
function M.range_to_item(client, range)
  return Item.new({
    buf = range.buf,
    filename = range.filename,
    pos = range.pos,
    end_pos = range.end_pos,
    source = "lsp",
    item = {
      client_id = client.id,
      client = client.name,
      location = range.location,
      text = range.line and vim.trim(range.line) or nil,
    },
  })
end

local kinds = nil ---@type table<lsp.SymbolKind, string>

--- Gets the original symbol kind name from its number.
--- Some plugins override the symbol kind names, so this function is needed to get the original name.
---@param kind lsp.SymbolKind
---@return string
function M.symbol_kind(kind)
  if not kinds then
    kinds = {}
    for k, v in pairs(vim.lsp.protocol.SymbolKind) do
      if type(v) == "number" then
        kinds[v] = k
      end
    end
  end
  return kinds[kind]
end

---@alias lsp.ResultItem lsp.Symbol|lsp.CallHierarchyItem|{text?:string}
---@param client vim.lsp.Client
---@param results lsp.ResultItem[]
---@param default_uri? string
function M.results_to_items(client, results, default_uri)
  local items = {} ---@type trouble.Item[]
  local locs = {} ---@type lsp.Loc[]
  local processed = {} ---@type table<lsp.ResultItem, {uri:string, loc:lsp.Loc, range?:lsp.Loc}>

  ---@param result lsp.ResultItem
  local function process(result)
    local uri = result.location and result.location.uri or result.uri or default_uri
    local loc = result.location or { range = result.selectionRange or result.range, uri = uri }
    loc.uri = loc.uri or uri
    if not loc.uri then
      assert(loc.uri, "missing uri in result:\n" .. vim.inspect(result))
    end
    -- the range enclosing this symbol. Useful to get the symbol of the current cursor position
    ---@type lsp.Location?
    local range = result.range and { range = result.range, uri = uri } or nil
    processed[result] = { uri = uri, loc = loc, range = range }
    locs[#locs + 1] = loc
    if range then
      locs[#locs + 1] = range
    end
    for _, child in ipairs(result.children or {}) do
      process(child)
    end
  end

  for _, result in ipairs(results) do
    process(result)
  end

  local ranges = M.locations_to_ranges(client, locs)

  ---@param result lsp.ResultItem
  local function add(result)
    local loc = processed[result].loc
    local range = processed[result].range

    local item = M.range_to_item(client, ranges[loc])
    local id = { item.buf, item.pos[1], item.pos[2], item.end_pos[1], item.end_pos[2], item.kind }
    item.id = table.concat(id, "|")
    -- item.text = nil
    -- the range enclosing this symbol. Useful to get the symbol of the current cursor position
    item.range = range and ranges[range] or nil
    item.item.kind = M.symbol_kind(result.kind) or tostring(result.kind)
    item.item.symbol = result
    item.item.text = result.text
    items[#items + 1] = item
    for _, child in ipairs(result.children or {}) do
      item:add_child(add(child))
    end
    result.children = nil
    return item
  end

  for _, result in ipairs(results) do
    add(result)
  end

  return items
end

---@class trouble.Range.lsp: trouble.Range
---@field buf? number
---@field filename string
---@field location lsp.Loc
---@field client vim.lsp.Client
---@field line string

---@param client vim.lsp.Client
---@param locs lsp.Loc[]
function M.locations_to_ranges(client, locs)
  local todo = {} ---@type table<string, {locs:lsp.Loc[], rows:table<number,number>}>
  for _, d in ipairs(locs) do
    local uri = d.uri or d.targetUri
    local range = d.range or d.targetSelectionRange
    todo[uri] = todo[uri] or { locs = {}, rows = {} }
    table.insert(todo[uri].locs, d)
    local from = range.start.line + 1
    local to = range["end"].line + 1
    todo[uri].rows[from] = from
    todo[uri].rows[to] = to
  end

  local ret = {} ---@type table<lsp.Loc,trouble.Range.lsp>

  for uri, t in pairs(todo) do
    local buf = vim.uri_to_bufnr(uri)
    local filename = vim.uri_to_fname(uri)
    local lines = Util.get_lines({ rows = vim.tbl_keys(t.rows), buf = buf }) or {}
    for _, loc in ipairs(t.locs) do
      local range = loc.range or loc.targetSelectionRange
      local line = lines[range.start.line + 1] or ""
      local end_line = lines[range["end"].line + 1] or ""
      local pos = { range.start.line + 1, get_line_col(line, range.start.character, client.offset_encoding) }
      local end_pos = { range["end"].line + 1, get_line_col(end_line, range["end"].character, client.offset_encoding) }
      ret[loc] = {
        buf = buf,
        filename = filename,
        pos = pos,
        end_pos = end_pos,
        source = "lsp",
        client = client,
        location = loc,
        line = line,
      }
    end
  end
  return ret
end

---@param cb trouble.Source.Callback
---@param ctx trouble.Source.ctx
function M.get.command(cb, ctx)
  local err = "Missing command params for `lsp_command`.\n"
    .. "You need to specify `opts.params = {command = 'the_command', arguments = {}}`"
  if not ctx.opts.params then
    return Util.error(err)
  end
  ---@type lsp.ExecuteCommandParams
  local params = ctx.opts.params
  if not params.command then
    return Util.error(err)
  end
  M.get_locations("workspace/executeCommand", cb, ctx, { params = params })
end

---@param ctx trouble.Source.ctx
---@param cb trouble.Source.Callback
function M.get.references(cb, ctx)
  local params = ctx.opts.params or {}
  M.get_locations("textDocument/references", cb, ctx, {
    context = {
      includeDeclaration = params.include_declaration ~= false,
    },
  })
end

---@param cb trouble.Source.Callback
---@param ctx trouble.Source.ctx
function M.get.definitions(cb, ctx)
  M.get_locations("textDocument/definition", cb, ctx)
end

---@param cb trouble.Source.Callback
---@param ctx trouble.Source.ctx
function M.get.implementations(cb, ctx)
  M.get_locations("textDocument/implementation", cb, ctx)
end

-- Type Definitions
---@param cb trouble.Source.Callback
---@param ctx trouble.Source.ctx
function M.get.type_definitions(cb, ctx)
  M.get_locations("textDocument/typeDefinition", cb, ctx)
end

-- Declaration
---@param cb trouble.Source.Callback
---@param ctx trouble.Source.ctx
function M.get.declarations(cb, ctx)
  M.get_locations("textDocument/declaration", cb, ctx)
end

return M
