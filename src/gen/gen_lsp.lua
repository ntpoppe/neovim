-- Generates lua-ls annotations for lsp.

local USAGE = [[
Generates lua-ls annotations for lsp.

USAGE:
nvim -l src/gen/gen_lsp.lua gen  # by default, this will overwrite runtime/lua/vim/lsp/_meta/protocol.lua
nvim -l src/gen/gen_lsp.lua gen --version 3.18 --out runtime/lua/vim/lsp/_meta/protocol.lua
nvim -l src/gen/gen_lsp.lua gen --version 3.18 --methods --capabilities
]]

local DEFAULT_LSP_VERSION = '3.18'

local M = {}

local function tofile(fname, text)
  local f = io.open(fname, 'w')
  if not f then
    error(('failed to write: %s'):format(f))
  else
    print(('Written to: %s'):format(fname))
    f:write(text)
    f:close()
  end
end

--- The LSP protocol JSON data (it's partial, non-exhaustive).
--- https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/3.18/metaModel/metaModel.schema.json
--- @class vim._gen_lsp.Protocol
--- @field requests vim._gen_lsp.Request[]
--- @field notifications vim._gen_lsp.Notification[]
--- @field structures vim._gen_lsp.Structure[]
--- @field enumerations vim._gen_lsp.Enumeration[]
--- @field typeAliases vim._gen_lsp.TypeAlias[]

--- @class vim._gen_lsp.Notification
--- @field deprecated? string
--- @field documentation? string
--- @field messageDirection string
--- @field clientCapability? string
--- @field serverCapability? string
--- @field method string
--- @field params? any
--- @field proposed? boolean
--- @field registrationMethod? string
--- @field registrationOptions? any
--- @field since? string

--- @class vim._gen_lsp.Request : vim._gen_lsp.Notification
--- @field errorData? any
--- @field partialResult? any
--- @field result any

---@param opt vim._gen_lsp.opt
---@return vim._gen_lsp.Protocol
local function read_json(opt)
  local uri = 'https://raw.githubusercontent.com/microsoft/language-server-protocol/gh-pages/_specifications/lsp/'
    .. opt.version
    .. '/metaModel/metaModel.json'
  print('Reading ' .. uri)

  local res = vim.system({ 'curl', '--no-progress-meter', uri, '-o', '-' }):wait()
  if res.code ~= 0 or (res.stdout or ''):len() < 999 then
    print(('URL failed: %s'):format(uri))
    vim.print(res)
    error(res.stdout)
  end
  return vim.json.decode(res.stdout)
end

-- Gets the Lua symbol for a given fully-qualified LSP method name.
local function to_luaname(s)
  -- "$/" prefix is special: https://microsoft.github.io/language-server-protocol/specification/#dollarRequests
  return s:gsub('^%$', 'dollar'):gsub('/', '_')
end

---@param protocol vim._gen_lsp.Protocol
---@param gen_methods boolean
---@param gen_capabilities boolean
local function write_to_protocol(protocol, gen_methods, gen_capabilities)
  if not gen_methods and not gen_capabilities then
    return
  end

  local indent = (' '):rep(2)

  local function compare_method(a, b)
    return to_luaname(a.method) < to_luaname(b.method)
  end

  ---@type (vim._gen_lsp.Request|vim._gen_lsp.Notification)[]
  local all = {}
  vim.list_extend(all, protocol.notifications)
  vim.list_extend(all, protocol.requests)

  table.sort(all, compare_method)
  table.sort(protocol.requests, compare_method)
  table.sort(protocol.notifications, compare_method)

  local output = { '-- Generated by gen_lsp.lua, keep at end of file.' }

  if gen_methods then
    for _, dir in ipairs({ 'clientToServer', 'serverToClient' }) do
      local dir1 = dir:sub(1, 1):upper() .. dir:sub(2)
      local alias = ('vim.lsp.protocol.Method.%s'):format(dir1)
      for _, b in ipairs({
        { title = 'Request', methods = protocol.requests },
        { title = 'Notification', methods = protocol.notifications },
      }) do
        output[#output + 1] = ('--- @alias %s.%s'):format(alias, b.title)
        for _, item in ipairs(b.methods) do
          if item.messageDirection == dir then
            output[#output + 1] = ("--- | '%s',"):format(item.method)
          end
        end
        output[#output + 1] = ''
      end

      vim.list_extend(output, {
        ('--- @alias %s'):format(alias),
        ('--- | %s.Request'):format(alias),
        ('--- | %s.Notification'):format(alias),
        '',
      })
    end

    vim.list_extend(output, {
      '--- @alias vim.lsp.protocol.Method',
      '--- | vim.lsp.protocol.Method.ClientToServer',
      '--- | vim.lsp.protocol.Method.ServerToClient',
      '',
      '-- Generated by gen_lsp.lua, keep at end of file.',
      '--- @enum vim.lsp.protocol.Methods',
      '--- @see https://microsoft.github.io/language-server-protocol/specification/#metaModel',
      '--- LSP method names.',
      'protocol.Methods = {',
    })

    for _, item in ipairs(all) do
      if item.method then
        if item.documentation then
          local document = vim.split(item.documentation, '\n?\n', { trimempty = true })
          for _, docstring in ipairs(document) do
            output[#output + 1] = indent .. '--- ' .. docstring
          end
        end
        output[#output + 1] = ("%s%s = '%s',"):format(indent, to_luaname(item.method), item.method)
      end
    end
    output[#output + 1] = '}'
  end

  if gen_capabilities then
    vim.list_extend(output, {
      '',
      '-- stylua: ignore start',
      '-- Generated by gen_lsp.lua, keep at end of file.',
      '--- Maps method names to the required server capability',
      'protocol._request_name_to_capability = {',
    })

    for _, item in ipairs(all) do
      if item.serverCapability then
        output[#output + 1] = ("%s['%s'] = { %s },"):format(
          indent,
          item.method,
          table.concat(
            vim
              .iter(vim.split(item.serverCapability, '.', { plain = true }))
              :map(function(segment)
                return "'" .. segment .. "'"
              end)
              :totable(),
            ', '
          )
        )
      end
    end

    output[#output + 1] = '}'
    output[#output + 1] = '-- stylua: ignore end'
  end

  output[#output + 1] = ''
  output[#output + 1] = 'return protocol'

  local fname = './runtime/lua/vim/lsp/protocol.lua'
  local bufnr = vim.fn.bufadd(fname)
  vim.fn.bufload(bufnr)
  vim.api.nvim_set_current_buf(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local index = vim.iter(ipairs(lines)):find(function(key, item)
    return vim.startswith(item, '-- Generated by') and key or nil
  end)
  index = index and index - 1 or vim.api.nvim_buf_line_count(bufnr) - 1
  vim.api.nvim_buf_set_lines(bufnr, index, -1, true, output)
  vim.cmd.write()
end

---@class vim._gen_lsp.opt
---@field output_file string
---@field version string
---@field methods boolean
---@field capabilities boolean

---@param opt vim._gen_lsp.opt
function M.gen(opt)
  --- @type vim._gen_lsp.Protocol
  local protocol = read_json(opt)

  write_to_protocol(protocol, opt.methods, opt.capabilities)

  local output = {
    '--' .. '[[',
    'THIS FILE IS GENERATED by scr/gen/gen_lsp.lua',
    'DO NOT EDIT MANUALLY',
    '',
    'Based on LSP protocol ' .. opt.version,
    '',
    'Regenerate:',
    ([=[nvim -l scr/gen/gen_lsp.lua gen --version %s]=]):format(DEFAULT_LSP_VERSION),
    '--' .. ']]',
    '',
    '---@meta',
    "error('Cannot require a meta file')",
    '',
    '---@alias lsp.null nil',
    '---@alias uinteger integer',
    '---@alias decimal number',
    '---@alias lsp.DocumentUri string',
    '---@alias lsp.URI string',
    '',
  }

  local anonymous_num = 0

  ---@type string[]
  local anonym_classes = {}

  local simple_types = {
    'string',
    'boolean',
    'integer',
    'uinteger',
    'decimal',
  }

  ---@param documentation string
  local _process_documentation = function(documentation)
    documentation = documentation:gsub('\n', '\n---')
    -- Remove <200b> (zero-width space) unicode characters: e.g., `**/<200b>*`
    documentation = documentation:gsub('\226\128\139', '')
    -- Escape annotations that are not recognized by lua-ls
    documentation = documentation:gsub('%^---@sample', '---\\@sample')
    return '---' .. documentation
  end

  --- @class vim._gen_lsp.Type
  --- @field kind string a common field for all Types.
  --- @field name? string for ReferenceType, BaseType
  --- @field element? any for ArrayType
  --- @field items? vim._gen_lsp.Type[] for OrType, AndType
  --- @field key? vim._gen_lsp.Type for MapType
  --- @field value? string|vim._gen_lsp.Type for StringLiteralType, MapType, StructureLiteralType

  ---@param type vim._gen_lsp.Type
  ---@param prefix? string Optional prefix associated with the this type, made of (nested) field name.
  ---             Used to generate class name for structure literal types.
  ---@return string
  local function parse_type(type, prefix)
    -- ReferenceType | BaseType
    if type.kind == 'reference' or type.kind == 'base' then
      if vim.tbl_contains(simple_types, type.name) then
        return type.name
      end
      return 'lsp.' .. type.name

    -- ArrayType
    elseif type.kind == 'array' then
      local parsed_items = parse_type(type.element, prefix)
      if type.element.items and #type.element.items > 1 then
        parsed_items = '(' .. parsed_items .. ')'
      end
      return parsed_items .. '[]'

    -- OrType
    elseif type.kind == 'or' then
      local val = ''
      for _, item in ipairs(type.items) do
        val = val .. parse_type(item, prefix) .. '|' --[[ @as string ]]
      end
      val = val:sub(0, -2)
      return val

    -- StringLiteralType
    elseif type.kind == 'stringLiteral' then
      return '"' .. type.value .. '"'

    -- MapType
    elseif type.kind == 'map' then
      local key = assert(type.key)
      local value = type.value --[[ @as vim._gen_lsp.Type ]]
      return 'table<' .. parse_type(key, prefix) .. ', ' .. parse_type(value, prefix) .. '>'

    -- StructureLiteralType
    elseif type.kind == 'literal' then
      -- can I use ---@param disabled? {reason: string}
      -- use | to continue the inline class to be able to add docs
      -- https://github.com/LuaLS/lua-language-server/issues/2128
      anonymous_num = anonymous_num + 1
      local anonymous_classname = 'lsp._anonym' .. anonymous_num
      if prefix then
        anonymous_classname = anonymous_classname .. '.' .. prefix
      end
      local anonym = vim
        .iter({
          (anonymous_num > 1 and { '' } or {}),
          { '---@class ' .. anonymous_classname },
        })
        :flatten()
        :totable()

      --- @class vim._gen_lsp.StructureLiteral translated to anonymous @class.
      --- @field deprecated? string
      --- @field description? string
      --- @field properties vim._gen_lsp.Property[]
      --- @field proposed? boolean
      --- @field since? string

      ---@type vim._gen_lsp.StructureLiteral
      local structural_literal = assert(type.value) --[[ @as vim._gen_lsp.StructureLiteral ]]
      for _, field in ipairs(structural_literal.properties) do
        anonym[#anonym + 1] = '---'
        if field.documentation then
          anonym[#anonym + 1] = _process_documentation(field.documentation)
        end
        anonym[#anonym + 1] = '---@field '
          .. field.name
          .. (field.optional and '?' or '')
          .. ' '
          .. parse_type(field.type, prefix .. '.' .. field.name)
      end
      -- anonym[#anonym + 1] = ''
      for _, line in ipairs(anonym) do
        if line then
          anonym_classes[#anonym_classes + 1] = line
        end
      end
      return anonymous_classname

    -- TupleType
    elseif type.kind == 'tuple' then
      local tuple = '['
      for _, value in ipairs(type.items) do
        tuple = tuple .. parse_type(value, prefix) .. ', '
      end
      -- remove , at the end
      tuple = tuple:sub(0, -3)
      return tuple .. ']'
    end

    vim.print('WARNING: Unknown type ', type)
    return ''
  end

  --- @class vim._gen_lsp.Structure translated to @class
  --- @field deprecated? string
  --- @field documentation? string
  --- @field extends? { kind: string, name: string }[]
  --- @field mixins? { kind: string, name: string }[]
  --- @field name string
  --- @field properties? vim._gen_lsp.Property[]  members, translated to @field
  --- @field proposed? boolean
  --- @field since? string
  for _, structure in ipairs(protocol.structures) do
    -- output[#output + 1] = ''
    if structure.documentation then
      output[#output + 1] = _process_documentation(structure.documentation)
    end
    local class_string = ('---@class lsp.%s'):format(structure.name)
    if structure.extends or structure.mixins then
      local inherits_from = table.concat(
        vim.list_extend(
          vim.tbl_map(parse_type, structure.extends or {}),
          vim.tbl_map(parse_type, structure.mixins or {})
        ),
        ', '
      )
      class_string = class_string .. ': ' .. inherits_from
    end
    output[#output + 1] = class_string

    --- @class vim._gen_lsp.Property translated to @field
    --- @field deprecated? string
    --- @field documentation? string
    --- @field name string
    --- @field optional? boolean
    --- @field proposed? boolean
    --- @field since? string
    --- @field type { kind: string, name: string }
    for _, field in ipairs(structure.properties or {}) do
      output[#output + 1] = '---' -- Insert a single newline between @fields (and after @class)
      if field.documentation then
        output[#output + 1] = _process_documentation(field.documentation)
      end
      output[#output + 1] = '---@field '
        .. field.name
        .. (field.optional and '?' or '')
        .. ' '
        .. parse_type(field.type, field.name)
    end
    output[#output + 1] = ''
  end

  --- @class vim._gen_lsp.Enumeration translated to @enum
  --- @field deprecated string?
  --- @field documentation string?
  --- @field name string?
  --- @field proposed boolean?
  --- @field since string?
  --- @field suportsCustomValues boolean?
  --- @field values { name: string, value: string, documentation?: string, since?: string }[]
  for _, enum in ipairs(protocol.enumerations) do
    if enum.documentation then
      output[#output + 1] = _process_documentation(enum.documentation)
    end
    local enum_type = '---@alias lsp.' .. enum.name
    for _, value in ipairs(enum.values) do
      enum_type = enum_type
        .. '\n---| '
        .. (type(value.value) == 'string' and '"' .. value.value .. '"' or value.value)
        .. ' # '
        .. value.name
    end
    output[#output + 1] = enum_type
    output[#output + 1] = ''
  end

  --- @class vim._gen_lsp.TypeAlias translated to @alias
  --- @field deprecated? string?
  --- @field documentation? string
  --- @field name string
  --- @field proposed? boolean
  --- @field since? string
  --- @field type vim._gen_lsp.Type
  for _, alias in ipairs(protocol.typeAliases) do
    if alias.documentation then
      output[#output + 1] = _process_documentation(alias.documentation)
    end
    if alias.type.kind == 'or' then
      local alias_type = '---@alias lsp.' .. alias.name .. ' '
      for _, item in ipairs(alias.type.items) do
        alias_type = alias_type .. parse_type(item, alias.name) .. '|'
      end
      alias_type = alias_type:sub(0, -2)
      output[#output + 1] = alias_type
    else
      output[#output + 1] = '---@alias lsp.'
        .. alias.name
        .. ' '
        .. parse_type(alias.type, alias.name)
    end
    output[#output + 1] = ''
  end

  -- anonymous classes
  for _, line in ipairs(anonym_classes) do
    output[#output + 1] = line
  end

  tofile(opt.output_file, table.concat(output, '\n') .. '\n')
end

---@type vim._gen_lsp.opt
local opt = {
  output_file = 'runtime/lua/vim/lsp/_meta/protocol.lua',
  version = DEFAULT_LSP_VERSION,
  methods = false,
  capabilities = false,
}

local command = nil
local i = 1
while i <= #_G.arg do
  if _G.arg[i] == '--out' then
    opt.output_file = assert(_G.arg[i + 1], '--out <outfile> needed')
    i = i + 1
  elseif _G.arg[i] == '--version' then
    opt.version = assert(_G.arg[i + 1], '--version <version> needed')
    i = i + 1
  elseif _G.arg[i] == '--methods' then
    opt.methods = true
  elseif _G.arg[i] == '--capabilities' then
    opt.capabilities = true
  elseif vim.startswith(_G.arg[i], '-') then
    error('Unrecognized args: ' .. _G.arg[i])
  else
    if command then
      error('More than one command was given: ' .. _G.arg[i])
    else
      command = _G.arg[i]
    end
  end
  i = i + 1
end

if not command then
  print(USAGE)
elseif M[command] then
  M[command](opt) -- see M.gen()
else
  error('Unknown command: ' .. command)
end

return M
