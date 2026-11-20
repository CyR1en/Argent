-- Runs ArgentProbe.lrplugin/Probe.lua's job runner against a fake Lightroom, under a plain Lua 5.1 (micro's).
-- The fake keeps develop settings in a table, "exports" by writing an empty file named after the photo, and can be told
-- to misbehave: LRTEST_SCENARIO = normal | dropall (every component comes back missing) | clamp (Amount > 1 comes back 1)
-- | cancel (the progress bar is canceled after the third item) | stopmid (a STOP file appears during the third render)
-- | poll (the background poll, not the menu command) | masksai (MODE masks-ai: a photo whose name holds 'nosky' never gets a mask).
-- environment: LRTEST_PLUGIN, LRTEST_JOBDIR, LRTEST_CATALOG, LRTEST_SCENARIO, LRTEST_OUT
local plugin = assert(os.getenv('LRTEST_PLUGIN'))
local jobdir = assert(os.getenv('LRTEST_JOBDIR'))
local scenario = os.getenv('LRTEST_SCENARIO') or 'normal'
local catalogPath = os.getenv('LRTEST_CATALOG') or '/scratch/Argent-masks-session.lrcat'
local out = assert(io.open(assert(os.getenv('LRTEST_OUT')), 'w'))
local function say(...) out:write(table.concat({ ... }, '\t'), '\n') end

package.path = plugin .. '/?.lua;' .. package.path

local MaskJob = assert(loadfile(plugin .. '/MaskJob.lua'))()

local function shell(cmd) local p = io.popen(cmd, 'r'); local t = p:read('*a'); p:close(); return t end
local function copy(t)
  if type(t) ~= 'table' then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = copy(v) end
  return c
end

local photos, applied, exported, dialogs = {}, {}, {}, {}
local cancelCalls = 0

local function leaf(p) return (p:match('([^/]*)$')) end

local fakeClock = 0
local target

local Photo = {}
Photo.__index = Photo
function Photo:applyDevelopSettings(settings, name)
  applied[#applied + 1] = self.path
  for k, v in pairs(settings) do self.settings[k] = copy(v) end
end
function Photo:getDevelopSettings()
  local s = copy(self.settings)
  local m = s.MaskGroupBasedCorrections
  if m then
    for _, c in ipairs(m) do
      c.CorrectionID = 'ID-' .. leaf(self.path)               -- filled by Lightroom: never a mismatch
      if scenario == 'dropall' then c.CorrectionMasks = {} end
      if scenario == 'clamp' and type(c.CorrectionAmount) == 'number' and c.CorrectionAmount > 1 then c.CorrectionAmount = 1 end
      for _, comp in ipairs(c.CorrectionMasks) do comp.MaskSyncID = 'sync' end
    end
  end
  return s
end

local modules = {}
modules.LrApplication = { activeCatalog = function()
  return {
    getPath = function() return catalogPath end,
    withWriteAccessDo = function(self, name, fn) fn() end,
    findPhotoByPath = function(self, path) return photos[path] end,
    addPhoto = function(self, path) local p = setmetatable({ path = path, settings = {}, localIdentifier = path }, Photo); photos[path] = p; return p end,
    setSelectedPhotos = function(self, photo) target = photo end,
    getTargetPhoto = function(self) return target end,
    setActiveSources = function() end,
    getFolderByPath = function() return {} end,
  }
end }
modules.LrApplicationView = { switchToModule = function() end }
modules.LrDate = { currentTime = function()
  if scenario == 'masksai' then fakeClock = fakeClock + 0.5; return fakeClock end
  return os.time() + os.clock()
end }
modules.LrDevelopController = {
  getRange = function() return 0, 100 end,
  getValue = function(key) return target.settings[key] or 0 end,
  goToMasking = function() end,
  getAllMasks = function() return target and target.aiMasks or {} end,
  createNewMask = function(kind, subtype)
    assert(kind == 'aiSelection' and (subtype == 'sky' or subtype == 'subject'), 'createNewMask got the wrong arguments')
    if not target.path:find('nosky', 1, true) then
      target.aiMasks = { 'mask-1' }
      target.settings.MaskGroupBasedCorrections = { { What = 'Correction', CorrectionAmount = 1, CorrectionMasks = {
        { What = 'Mask/Image', MaskSubType = subtype, MaskDigest = 'abc123', MaskBlendMode = 0, MaskInverted = false } } } }
    end
  end,
}
modules.LrDialogs = { message = function(_, text) dialogs[#dialogs + 1] = 'message: ' .. tostring(text) end,
                      showBezel = function(text) dialogs[#dialogs + 1] = 'bezel: ' .. tostring(text) end }
modules.LrExportSession = function(args)
  return { cancel = function() end, renditions = function()
    local i = 0
    return function()
      i = i + 1
      local photo = args.photosToExport[i]
      if not photo then return nil end
      return i, { waitForRender = function()
        local name = leaf(photo.path):gsub('%.[^.]*$', '')
        local f = assert(io.open(args.exportSettings.LR_export_destinationPathPrefix .. '/' .. name .. '.tif', 'w'))
        f:write('x'); f:close()
        exported[#exported + 1] = name
        if scenario == 'stopmid' and #exported == 3 then   -- the owner asks to stop while the third render finishes
          local s = assert(io.open(jobdir .. '/STOP', 'w')); s:write(''); s:close()
        end
        return true, 'ok'
      end }
    end
  end }
end
modules.LrFileUtils = {
  readFile = function(path) local f = io.open(path, 'r'); if not f then return nil end; local t = f:read('*a'); f:close(); return t end,
  files = function(dir)
    local list = {}
    for name in shell('ls -1 "' .. dir .. '"'):gmatch('[^\n]+') do list[#list + 1] = dir .. '/' .. name end
    local i = 0
    return function() i = i + 1; return list[i] end
  end,
  exists = function(path) local f = io.open(path, 'r'); if f then f:close(); return 'file' end; return false end,
  createAllDirectories = function(path) os.execute('mkdir -p "' .. path .. '"') end,
  move = function(a, b) return os.rename(a, b) end,
}
modules.LrPathUtils = {
  leafName = leaf,
  removeExtension = function(p) return (p:gsub('%.[^./]*$', '')) end,
  child = function(a, b) return a .. '/' .. b end,
  parent = function(p) return (p:match('^(.*)/[^/]*$')) end,
}
modules.LrProgressScope = function(args)
  return { setCaption = function() end, setPortionComplete = function() end, done = function() end,
           isCanceled = function() cancelCalls = cancelCalls + 1; return scenario == 'cancel' and cancelCalls > 3 end }
end
modules.LrTasks = { pcall = pcall, sleep = function() end, startAsyncTask = function(fn) fn() end }
function import(name) return assert(modules[name], 'no fake for ' .. name) end

local Probe = assert(loadfile(plugin .. '/Probe.lua'))()
local ok, err = pcall(Probe.runPending, scenario ~= 'poll')
if not ok then say('RUNPENDING-ERROR', tostring(err)) end

say('applied', tostring(#applied))
say('exported', tostring(#exported))
local imported = 0
for _ in pairs(photos) do imported = imported + 1 end
say('imported', tostring(imported))
for _, d in ipairs(dialogs) do say('dialog', d) end
-- what the fake photos hold, for the Python side to check
local keys = {}
for path in pairs(photos) do keys[#keys + 1] = path end
table.sort(keys)
for _, path in ipairs(keys) do
  local s = photos[path].settings
  say('photo', leaf(path), 'masks=' .. tostring(s.MaskGroupBasedCorrections and #s.MaskGroupBasedCorrections or 'none'),
      'enable=' .. tostring(s.EnableMaskGroupBasedCorrections), 'pv=' .. tostring(s.ProcessVersion),
      'whites=' .. tostring(s.Whites2012), 'exposure=' .. tostring(s.Exposure2012))
end
say('FLOW-DONE')
out:close()
