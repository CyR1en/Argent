-- The pure part of the plug-in's mask jobs (no Lightroom imports, so a plain Lua 5.1 can test it):
-- a JSON reader and writer for the tables a job names, the checks that keep out what R1 found
-- crashes or silently breaks Lightroom (MCP-304, GW), and the comparison of a table written with the
-- one Lightroom reads back.
--
-- The tables are Lightroom's own `MaskGroupBasedCorrections`: an array of corrections, each holding
-- `CorrectionMasks`, an array of components. Field names come from ExifTool's table of Adobe's crs
-- schema; what they mean was measured by others on Lightroom Classic 15.6 (see SESSION.md).
local M = {}

-- JSON ---------------------------------------------------------------------------------------------

local ESCAPES = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local function skip(s, i)
  local _, e = s:find('^[ \t\r\n]*', i)
  return e + 1
end

local decodeValue

local function utf8(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
  return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

local function decodeString(s, i)
  local out, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == '' then error('unterminated string at ' .. i) end
    if c == '"' then return table.concat(out), j + 1 end
    if c == '\\' then
      local n = s:sub(j + 1, j + 1)
      if ESCAPES[n] then
        out[#out + 1] = ESCAPES[n]
        j = j + 2
      elseif n == 'u' then
        local cp = tonumber(s:sub(j + 2, j + 5), 16)
        if not cp then error('bad \\u escape at ' .. j) end
        out[#out + 1] = utf8(cp)
        j = j + 6
      else
        error('bad escape at ' .. j)
      end
    else
      out[#out + 1] = c
      j = j + 1
    end
  end
end

local function decodeNumber(s, i)
  local m = s:match('^-?%d+', i)
  if not m then error('bad number at ' .. i) end
  local j = i + #m
  local frac = s:match('^%.%d+', j)
  if frac then m = m .. frac; j = j + #frac end
  local ex = s:match('^[eE][+-]?%d+', j)
  if ex then
    -- "3e2" becomes "3.0e2": some Lua builds (GopherLua) cannot read an exponent without a fraction
    if not frac then m = m .. '.0' end
    m = m .. ex
    j = j + #ex
  end
  local n = tonumber(m)
  if n == nil then error('bad number "' .. m .. '" at ' .. i) end
  return n, j
end

function decodeValue(s, i)
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == '{' then
    local t = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == '}' then return t, i + 1 end
    while true do
      i = skip(s, i)
      if s:sub(i, i) ~= '"' then error('object key expected at ' .. i) end
      local key
      key, i = decodeString(s, i)
      i = skip(s, i)
      if s:sub(i, i) ~= ':' then error("':' expected at " .. i) end
      t[key], i = decodeValue(s, i + 1)
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == '}' then return t, i + 1 end
      if d ~= ',' then error("',' or '}' expected at " .. i) end
      i = i + 1
    end
  elseif c == '[' then
    local t = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == ']' then return t, i + 1 end
    while true do
      t[#t + 1], i = decodeValue(s, i)
      i = skip(s, i)
      local d = s:sub(i, i)
      if d == ']' then return t, i + 1 end
      if d ~= ',' then error("',' or ']' expected at " .. i) end
      i = i + 1
    end
  elseif c == '"' then
    return decodeString(s, i)
  elseif s:sub(i, i + 3) == 'true' then
    return true, i + 4
  elseif s:sub(i, i + 4) == 'false' then
    return false, i + 5
  elseif c == '-' or c:match('%d') then
    return decodeNumber(s, i)
  end
  error('unexpected ' .. (c == '' and 'end of text' or "'" .. c .. "'") .. ' at ' .. i)
end

-- `text` as a Lua value: objects and arrays become tables (an empty one is both); null is an error,
-- since a nil would silently drop the key.
function M.decode(text)
  local value, i = decodeValue(text, 1)
  if skip(text, i) <= #text then error('trailing text at ' .. skip(text, i)) end
  return value
end

local function isArray(t)
  local n = #t
  if n == 0 then return next(t) == nil end
  for k in pairs(t) do
    if type(k) ~= 'number' or k < 1 or k > n or k ~= math.floor(k) then return false end
  end
  return true
end

local function quote(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    if c == '"' then return '\\"' elseif c == '\\' then return '\\\\' end
    return string.format('\\u%04x', c:byte())
  end) .. '"'
end

local function encodeValue(v, out)
  local kind = type(v)
  if kind == 'table' then
    if isArray(v) then
      out[#out + 1] = '['
      for i = 1, #v do
        if i > 1 then out[#out + 1] = ',' end
        encodeValue(v[i], out)
      end
      out[#out + 1] = ']'
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = tostring(k) end
      table.sort(keys)
      out[#out + 1] = '{'
      for i, k in ipairs(keys) do
        if i > 1 then out[#out + 1] = ',' end
        out[#out + 1] = quote(k) .. ':'
        local value = v[k]
        if value == nil then value = v[tonumber(k)] end
        encodeValue(value, out)
      end
      out[#out + 1] = '}'
    end
  elseif kind == 'number' then
    if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = 'null'
    else out[#out + 1] = string.format('%.12g', v) end
  elseif kind == 'boolean' then
    out[#out + 1] = v and 'true' or 'false'
  elseif kind == 'string' then
    out[#out + 1] = quote(v)
  else
    out[#out + 1] = 'null'
  end
end

function M.encode(value)
  local out = {}
  encodeValue(value, out)
  return table.concat(out)
end

-- Checks ---------------------------------------------------------------------------------------------

-- What a component may be, and the numbers each must carry or Lightroom silently drops it (MCP-304).
local GEOMETRY = {
  ['Mask/Gradient'] = { 'ZeroX', 'ZeroY', 'FullX', 'FullY' },
  ['Mask/CircularGradient'] = { 'Top', 'Left', 'Bottom', 'Right', 'Angle', 'Feather', 'Midpoint', 'Roundness', 'Version' },
  ['Mask/RangeMask'] = {},
}
local MAX_CORRECTIONS = 4

local function finite(x)
  return type(x) == 'number' and x == x and x ~= math.huge and x ~= -math.huge
end

-- The problems that make a table unsafe to write, as a list of strings (empty: fine). Refused: AI
-- (`Mask/Image`) and brush components, any blend mode but add (0) and subtract (1) since Lightroom
-- turns 2 into add, a colour range (two samples crash Lightroom, and one is not needed here),
-- a depth range, a luminance range that is not four ascending numbers in 0...1 (Lightroom replaces
-- it with "0 0 1 1" without a word), and a value that is not a number where a number belongs.
function M.validate(corrections)
  local problems = {}
  local function bad(message) problems[#problems + 1] = message end
  if type(corrections) ~= 'table' or not isArray(corrections) then return { 'the table is not an array' } end
  if #corrections > MAX_CORRECTIONS then bad(#corrections .. ' corrections, at most ' .. MAX_CORRECTIONS) end
  for i, c in ipairs(corrections) do
    local where = 'correction ' .. i
    if type(c) ~= 'table' or c.What ~= 'Correction' then
      bad(where .. ': What is not "Correction"')
    else
      if type(c.CorrectionMasks) ~= 'table' or #c.CorrectionMasks == 0 then bad(where .. ': no components') end
      for key, value in pairs(c) do
        if type(key) == 'string' and key:match('^Local') and not finite(value) then bad(where .. ': ' .. key .. ' is not a number') end
      end
      if c.CorrectionAmount ~= nil and not finite(c.CorrectionAmount) then bad(where .. ': CorrectionAmount is not a number') end
      for j, m in ipairs(c.CorrectionMasks or {}) do
        local w = where .. ', component ' .. j
        local need = type(m) == 'table' and GEOMETRY[m.What]
        if not need then
          bad(w .. ': What "' .. tostring(type(m) == 'table' and m.What) .. '" is not allowed')
        else
          if m.MaskBlendMode ~= 0 and m.MaskBlendMode ~= 1 then bad(w .. ': MaskBlendMode must be 0 or 1') end
          if type(m.MaskInverted) ~= 'boolean' then bad(w .. ': MaskInverted must be true or false') end
          for _, key in ipairs(need) do
            if not finite(m[key]) then bad(w .. ': ' .. key .. ' is missing or not a number') end
          end
          if m.What == 'Mask/RangeMask' then
            local r = m.CorrectionRangeMask
            if type(r) ~= 'table' or r.Type ~= 2 then
              bad(w .. ': only a luminance range (Type 2) is allowed')
            else
              if r.PointModels ~= nil then bad(w .. ': PointModels crashes Lightroom') end
              local nums = {}
              for n in tostring(r.LumRange):gmatch('%S+') do nums[#nums + 1] = tonumber(n) end
              local ok = #nums == 4
              for k = 1, #nums do
                if not nums[k] or nums[k] < 0 or nums[k] > 1 or (k > 1 and nums[k] < nums[k - 1]) then ok = false end
              end
              if not ok then bad(w .. ': LumRange must be four ascending numbers in 0...1') end
            end
          end
        end
      end
    end
  end
  return problems
end

-- Comparison -----------------------------------------------------------------------------------------

-- Fields Lightroom fills or derives itself: never a mismatch.
local DERIVED = { MaskValue = true, Flipped = true, MaskSyncID = true, MaskID = true, CorrectionSyncID = true,
                  CorrectionID = true, CorrectionReferenceX = true, CorrectionReferenceY = true,
                  LocalCurveRefineSaturation = true, LuminanceDepthSampleInfo = true, ReferencePoint = true }

-- What Lightroom kept of `written`, from the `back` it reads: returns `structure`, the problems that
-- make the item meaningless (a missing correction or component, another kind of component), and
-- `notes`, the scalar fields Lightroom changed or dropped (clamping is a finding, not a failure).
function M.compare(written, back)
  local structure, notes = {}, {}
  back = back or {}
  if #written ~= #back then
    structure[#structure + 1] = 'corrections: wrote ' .. #written .. ', read back ' .. #back
  end
  for i, w in ipairs(written) do
    local b = back[i]
    if b then
      local wm, bm = w.CorrectionMasks or {}, b.CorrectionMasks or {}
      if #wm ~= #bm then structure[#structure + 1] = 'correction ' .. i .. ': wrote ' .. #wm .. ' components, read back ' .. #bm end
      for key, value in pairs(w) do
        if key ~= 'CorrectionMasks' and key ~= 'What' and not DERIVED[key] then
          local got = b[key]
          if got == nil then
            notes[#notes + 1] = 'correction ' .. i .. '.' .. key .. ': dropped (wrote ' .. tostring(value) .. ')'
          elseif type(value) == 'number' and type(got) == 'number' then
            if math.abs(value - got) > 1e-5 * math.max(1, math.abs(value)) then
              notes[#notes + 1] = 'correction ' .. i .. '.' .. key .. ': wrote ' .. tostring(value) .. ', read ' .. tostring(got)
            end
          elseif value ~= got then
            notes[#notes + 1] = 'correction ' .. i .. '.' .. key .. ': wrote ' .. tostring(value) .. ', read ' .. tostring(got)
          end
        end
      end
      for j, wc in ipairs(wm) do
        local bc = bm[j]
        if bc then
          if wc.What ~= bc.What then structure[#structure + 1] = 'component ' .. i .. '.' .. j .. ': wrote ' .. tostring(wc.What) .. ', read ' .. tostring(bc.What) end
          for key, value in pairs(wc) do
            if key ~= 'What' and key ~= 'CorrectionRangeMask' and not DERIVED[key] then
              local got = bc[key]
              if got == nil then
                notes[#notes + 1] = 'component ' .. i .. '.' .. j .. '.' .. key .. ': dropped (wrote ' .. tostring(value) .. ')'
              elseif type(value) == 'number' and type(got) == 'number' then
                if math.abs(value - got) > 1e-5 * math.max(1, math.abs(value)) then
                  notes[#notes + 1] = 'component ' .. i .. '.' .. j .. '.' .. key .. ': wrote ' .. tostring(value) .. ', read ' .. tostring(got)
                end
              elseif value ~= got then
                notes[#notes + 1] = 'component ' .. i .. '.' .. j .. '.' .. key .. ': wrote ' .. tostring(value) .. ', read ' .. tostring(got)
              end
            end
          end
          if type(wc.CorrectionRangeMask) == 'table' then
            local br = bc.CorrectionRangeMask or {}
            if br.LumRange ~= wc.CorrectionRangeMask.LumRange then
              notes[#notes + 1] = 'component ' .. i .. '.' .. j .. '.LumRange: wrote ' .. tostring(wc.CorrectionRangeMask.LumRange) .. ', read ' .. tostring(br.LumRange)
            end
          end
        end
      end
    end
  end
  return structure, notes
end

-- AI masks (MODE masks-ai) ---------------------------------------------------------------------------------

local function copy(t)
  if type(t) ~= 'table' then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = copy(v) end
  return c
end

-- Coverage 1 over the whole frame: a linear gradient whose Full and Zero points lie past the picture's far edge
-- (L1b: bit-identical to the three other constructions, and unlike the in-picture one it covers the last rows).
function M.fullCoverage(ev)
  return { { What = 'Correction', CorrectionName = 'full', CorrectionActive = true, CorrectionAmount = 1,
             LocalExposure2012 = ev / 4,
             CorrectionMasks = { { What = 'Mask/Gradient', MaskActive = true, MaskBlendMode = 0, MaskInverted = false,
                                   MaskValue = 1, MaskName = 'Gradient', ZeroX = 0.5, ZeroY = 4, FullX = 0.5, FullY = 3 } } } }
end

-- The table Lightroom holds after an AI mask, with its one correction's local Exposure set to `ev` (stored as EV / 4):
-- a copy, whatever else Lightroom keeps in it left as it is. Returns nil and a reason unless it is exactly one correction
-- whose first component is an AI component (`Mask/Image`).
function M.withExposure(corrections, ev)
  if type(corrections) ~= 'table' or #corrections ~= 1 then
    return nil, 'expected one correction, found ' .. (type(corrections) == 'table' and #corrections or 'none')
  end
  local out = copy(corrections)
  local c = out[1]
  local first = c.CorrectionMasks and c.CorrectionMasks[1]
  if type(first) ~= 'table' or first.What ~= 'Mask/Image' then
    return nil, 'its first component is ' .. tostring(type(first) == 'table' and first.What)
  end
  c.LocalExposure2012 = ev / 4
  c.CorrectionAmount = 1
  c.CorrectionActive = true
  return out
end

-- A copy of `corrections` with every correction's local Exposure set to `ev` (a table the job wrote, not one Lightroom holds).
function M.exposed(corrections, ev)
  local out = copy(corrections)
  for _, c in ipairs(out) do c.LocalExposure2012 = ev / 4 end
  return out
end

-- How far an AI mask has got: the number of corrections, whether the first holds a `Mask/Image` component, and
-- whether that component carries a digest (the field Lightroom fills when the mask's raster is written).
function M.aiState(corrections)
  if type(corrections) ~= 'table' then return 0, false, false end
  local c = corrections[1]
  local first = type(c) == 'table' and c.CorrectionMasks and c.CorrectionMasks[1]
  if type(first) ~= 'table' or first.What ~= 'Mask/Image' then return #corrections, false, false end
  for key, value in pairs(first) do
    if type(key) == 'string' and key:find('Digest', 1, true) and type(value) == 'string' and value ~= '' then
      return #corrections, true, true
    end
  end
  return #corrections, true, false
end

return M
