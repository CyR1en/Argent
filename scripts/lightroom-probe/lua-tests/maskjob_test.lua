-- Tests of ArgentProbe.lrplugin/MaskJob.lua and a syntax check of Probe.lua, for a plain Lua 5.1.
-- Run by test_masks.py through micro's embedded interpreter (GopherLua, Lua 5.1), which is all this
-- Mac has; there is no Lightroom here, so nothing that imports an Lr module runs.
--   environment: LRTEST_PLUGIN (the .lrplugin folder), LRTEST_TABLES (a file listing JSON tables, one
--   path a line), LRTEST_OUT (where the results go)
local plugin = assert(os.getenv('LRTEST_PLUGIN'))
local out = assert(io.open(assert(os.getenv('LRTEST_OUT')), 'w'))
local failures = 0
local function say(...) out:write(table.concat({ ... }, ' '), '\n') end
local function check(name, ok, detail)
  if ok then say('PASS', name) else failures = failures + 1; say('FAIL', name, detail or '') end
end

local function run()
  local MaskJob = assert(loadfile(plugin .. '/MaskJob.lua'))()

  -- Probe.lua and the other plug-in files compile (their imports are not run)
  for _, name in ipairs({ 'Probe.lua', 'MaskJob.lua', 'Init.lua', 'RunNow.lua', 'Info.lua' }) do
    local chunk, err = loadfile(plugin .. '/' .. name)
    check('compiles: ' .. name, chunk ~= nil, tostring(err))
  end

  -- JSON basics
  local t = MaskJob.decode('{"a":[1,2.5,-3e2,true,false,"x\\n\\u0041"],"b":{},"c":[],"d":{"e":0.125}}')
  check('decode array', #t.a == 6 and t.a[2] == 2.5 and t.a[3] == -300 and t.a[4] == true and t.a[5] == false)
  check('decode string escapes', t.a[6] == 'x\nA', t.a[6])
  check('decode empty containers', next(t.b) == nil and #t.c == 0 and t.d.e == 0.125)
  local ok = pcall(MaskJob.decode, '{"a":null}')
  check('null is refused', not ok)
  ok = pcall(MaskJob.decode, '[1,2')
  check('truncated text is refused', not ok)
  ok = pcall(MaskJob.decode, '[1] 2')
  check('trailing text is refused', not ok)

  local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
  end

  -- every table the planner wrote decodes, passes the checks and survives a round trip
  local count, bad = 0, 0
  local list = os.getenv('LRTEST_TABLES')
  if list then
    for path in io.lines(list) do
      local f = assert(io.open(path, 'r'))
      local text = f:read('*a')
      f:close()
      local good, value = pcall(MaskJob.decode, text)
      local problems = good and MaskJob.validate(value) or { tostring(value) }
      local again = good and MaskJob.decode(MaskJob.encode(value))
      count = count + 1
      if not good or #problems > 0 or not same(value, again) then
        bad = bad + 1
        if bad <= 5 then say('  bad table', path, problems[1] or 'round trip differs') end
      end
    end
    check('all ' .. count .. ' planned tables decode, validate and round-trip', count > 0 and bad == 0, bad .. ' bad')
  end

  -- what the checks must refuse
  local function gradient() return { What = 'Mask/Gradient', MaskActive = true, MaskBlendMode = 0, MaskInverted = false, MaskValue = 1, ZeroX = 0.5, ZeroY = 0.8, FullX = 0.5, FullY = 0.2 } end
  local function correction(masks) return { What = 'Correction', CorrectionAmount = 1, LocalExposure2012 = 0.25, CorrectionMasks = masks } end
  check('a good table passes', #MaskJob.validate({ correction({ gradient() }) }) == 0)
  local cases = {
    ['blend mode 2 (Lightroom turns it into add)'] = function(c) c.CorrectionMasks[1].MaskBlendMode = 2 end,
    ['a missing geometry field (the component is dropped)'] = function(c) c.CorrectionMasks[1].FullY = nil end,
    ['a string where a number belongs'] = function(c) c.CorrectionMasks[1].ZeroX = '0.5' end,
    ['an AI component'] = function(c) c.CorrectionMasks[1] = { What = 'Mask/Image', MaskBlendMode = 0, MaskInverted = false } end,
    ['a brush'] = function(c) c.CorrectionMasks[1] = { What = 'Mask/Aggregate', MaskBlendMode = 0, MaskInverted = false } end,
    ['a boolean for MaskInverted as a number'] = function(c) c.CorrectionMasks[1].MaskInverted = 1 end,
    ['a slider that is not a number'] = function(c) c.LocalWhites2012 = 'a lot' end,
    ['no components'] = function(c) c.CorrectionMasks = {} end,
    ['two colour samples (crashes Lightroom)'] = function(c)
      c.CorrectionMasks[1] = { What = 'Mask/RangeMask', MaskBlendMode = 0, MaskInverted = false,
        CorrectionRangeMask = { Type = 1, Version = 3, SampleType = 0, ColorAmount = 0.5, PointModels = { '0.4 0.4 0.4 0.2 0.2 0', '0 0 0 0.8 0.8 0' } } }
    end,
    ['a luminance range out of order'] = function(c)
      c.CorrectionMasks[1] = { What = 'Mask/RangeMask', MaskBlendMode = 0, MaskInverted = false,
        CorrectionRangeMask = { Type = 2, Version = 3, SampleType = 0, LumRange = '0.6 0.4 0.5 1' } }
    end,
    ['a luminance range outside 0...1'] = function(c)
      c.CorrectionMasks[1] = { What = 'Mask/RangeMask', MaskBlendMode = 0, MaskInverted = false,
        CorrectionRangeMask = { Type = 2, Version = 3, SampleType = 0, LumRange = '-1 0.4 0.6 9' } }
    end,
  }
  local names = {}
  for name in pairs(cases) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local c = correction({ gradient() })
    cases[name](c)
    check('refuses ' .. name, #MaskJob.validate({ c }) > 0)
  end
  local five = {}
  for i = 1, 5 do five[i] = correction({ gradient() }) end
  check('refuses more than four corrections', #MaskJob.validate(five) > 0)
  check('refuses a table that is not an array', #MaskJob.validate({ a = 1 }) > 0)
  local full = { What = 'Mask/RangeMask', MaskBlendMode = 0, MaskInverted = false,
    CorrectionRangeMask = { Type = 2, Version = 3, SampleType = 0, LumRange = '0 0 1 1' } }
  check('accepts a full-coverage luminance range', #MaskJob.validate({ correction({ full }) }) == 0)

  -- the read-back comparison
  local written = { correction({ gradient(), gradient() }) }
  local back = MaskJob.decode(MaskJob.encode(written))
  back[1].CorrectionID = 'x'; back[1].CorrectionMasks[1].MaskValue = 0; back[1].CorrectionMasks[2].MaskSyncID = 'y'
  local structure, notes = MaskJob.compare(written, back)
  check('a faithful read-back has no problems', #structure == 0 and #notes == 0, table.concat(structure, '; ') .. table.concat(notes, '; '))
  back[1].CorrectionMasks[2] = nil
  structure = MaskJob.compare(written, back)
  check('a dropped component is a structural problem', #structure == 1, table.concat(structure, '; '))
  back = MaskJob.decode(MaskJob.encode(written))
  back[1].CorrectionAmount = 1.5
  back[1].LocalExposure2012 = nil
  back[1].CorrectionMasks[1].Feather = 3
  structure, notes = MaskJob.compare(written, back)
  check('a clamped or dropped scalar is a note, not a failure', #structure == 0 and #notes == 2, #notes .. ' notes')
  structure = MaskJob.compare(written, {})
  check('an empty read-back is a structural problem', #structure >= 1)
  back = MaskJob.decode(MaskJob.encode(written))
  back[1].CorrectionMasks[1].What = 'Mask/CircularGradient'
  structure = MaskJob.compare(written, back)
  check('another kind of component is a structural problem', #structure == 1)

  -- AI masks: the state a table is in, the read-modify-write of the local Exposure, the full-coverage table
  local ai = { { What = 'Correction', CorrectionAmount = 0.5, Keep = 'x', CorrectionMasks = {
    { What = 'Mask/Image', MaskSubType = 'sky', MaskDigest = 'abc', MaskBlendMode = 0, MaskInverted = false } } } }
  local count, isAi, hasDigest = MaskJob.aiState(ai)
  check('aiState reads an AI correction with its digest', count == 1 and isAi and hasDigest)
  count, isAi, hasDigest = MaskJob.aiState({})
  check('aiState of an empty table', count == 0 and not isAi and not hasDigest)
  local noDigest = MaskJob.decode(MaskJob.encode(ai))
  noDigest[1].CorrectionMasks[1].MaskDigest = nil
  count, isAi, hasDigest = MaskJob.aiState(noDigest)
  check('aiState of a mask without its digest yet', count == 1 and isAi and not hasDigest)
  local written, why = MaskJob.withExposure(ai, -1)
  check('withExposure sets EV / 4 and full Amount, keeps the rest', written and written[1].LocalExposure2012 == -0.25 and written[1].CorrectionAmount == 1
        and written[1].Keep == 'x' and written[1].CorrectionMasks[1].MaskDigest == 'abc', tostring(why))
  check('withExposure leaves its argument alone', ai[1].LocalExposure2012 == nil and ai[1].CorrectionAmount == 0.5)
  check('withExposure refuses two corrections', MaskJob.withExposure({ ai[1], ai[1] }, -1) == nil)
  check('withExposure refuses a table that is not an AI mask', MaskJob.withExposure({ correction({ gradient() }) }, -1) == nil)
  local full = MaskJob.fullCoverage(-0.5)
  check('fullCoverage is a valid gradient past the frame at the Exposure asked', #MaskJob.validate(full) == 0 and full[1].LocalExposure2012 == -0.125
        and full[1].CorrectionMasks[1].FullY == 3 and full[1].CorrectionMasks[1].ZeroY == 4)
end

local good, err = pcall(run)
if not good then failures = failures + 1; say('ERROR', tostring(err)) end
say(failures == 0 and 'LUA-TESTS-PASSED' or ('LUA-TESTS-FAILED ' .. failures))
out:close()
