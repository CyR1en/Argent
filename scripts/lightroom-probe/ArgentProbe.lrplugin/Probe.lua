-- Job runner. A job is a text file <name>.job in JOBDIR:
--   OUT<TAB>/abs/output/dir
--   ITEM<TAB>/abs/photo/path<TAB>Key=value;Key=value
-- Each ITEM's photo is added to the catalog if missing, gets NEUTRAL settings plus its own,
-- and is exported as uncompressed 16-bit ProPhoto TIFF named after the photo. The job is then
-- renamed <name>.processed and a <name>.done log is written (OK or ERROR lines, then DONE).
-- CATALOG<TAB>name restricts any job to a catalog file name containing name, ignoring case.
-- Catalog-restricted jobs run only from the menu command.
--
-- A job with the line MODE<TAB>auto runs Lightroom's own Auto instead: each photo starts from NEUTRAL, Auto runs
-- in the Develop module, and the sliders it chose go to OUT/auto.tsv as it goes. A sample runs Auto a second time
-- (OUT/auto-repeat.tsv). Then every photo is exported twice, long edge AUTO_LONG_EDGE: with Auto to OUT/auto and
-- back at NEUTRAL to OUT/neutral. Item settings are ignored. Lightroom must stay in front while it runs.
--
-- Version 1.2.0 adds MODE<TAB>masks (the mask session, masks_plan.py) and MODE<TAB>dump. A masks job's items are
--   ITEM<TAB>/abs/photo<TAB>Key=value;...<TAB>/abs/table.json
-- where the JSON file holds the MaskGroupBasedCorrections table to write with the settings (MaskJob.lua reads and
-- checks it); the photo is exported as for a settings job. Other lines of a masks job:
--   CATALOG<TAB>name     the open catalog's file must contain this, or nothing runs (keeps the owner's own catalog safe)
--   GATE<TAB>n           stop the whole run if n items fail the read-back check (the smoke job uses it)
--   SETTLE<TAB>seconds   wait this long after writing the tables, before exporting
--   NOTE<TAB>text        ignored
-- What Lightroom keeps of each table is written to OUT/readback/<photo>.json, the time of each phase to OUT/timing.tsv.
-- Masks and dump jobs run only when the menu command is chosen, never from the background poll. A file named STOP in
-- the jobs folder ends the run at the next item; so does the cancel button of the progress bar.
-- MODE<TAB>dump writes the mask table Lightroom holds for each listed photo to OUT/dump/<photo>.json and exports nothing.
--
-- Version 1.3.0 adds MODE<TAB>masks-ai (the blind A/B, L2): each item is
--   ITEM<TAB>/abs/photo<TAB>KIND=sky|subject|table[<TAB>/abs/table.json for KIND=table]
-- and the job takes SERIES<TAB>e<TAB>f1,f2,... once or more (a local Exposure e and the fractions of it in its full-coverage series; without one,
-- EV<TAB>e, -1 by default, and FRACTIONS<TAB>f1,f2,...).
-- Each sky or subject photo gets an AI mask in Develop (createNewMask, polled until one new mask has stayed for a second),
-- OUT/ai.tsv says how long that took and whether the mask came. Then, in Library, every photo is exported as a 16-bit TIFF
-- into OUT/<state>/ in each state: for each series masked-e<EV*100> (the AI mask or the item's table at that Exposure) and full-e<EV*100>-<n> (coverage 1 at
-- n / 1000 of it), and base (no mask). The AI table, as read back from Lightroom, is OUT/tables/<photo>.json.
-- MODE lens-defaults exports a fresh import before any neutral settings are applied.
-- MODE lens-ranges records each lens control's SDK range and current value before
-- and after NEUTRAL, to OUT/ranges/<photo>.json. It runs only from the menu command.
local LrApplication = import 'LrApplication'
local LrApplicationView = import 'LrApplicationView'
local LrDate = import 'LrDate'
local LrDevelopController = import 'LrDevelopController'
local LrDialogs = import 'LrDialogs'
local LrExportSession = import 'LrExportSession'
local LrFileUtils = import 'LrFileUtils'
local LrPathUtils = import 'LrPathUtils'
local LrProgressScope = import 'LrProgressScope'
local LrTasks = import 'LrTasks'
local MaskJob = require 'MaskJob'

local PLUGIN_VERSION = '1.3.0'
local JOBDIR = '@JOBDIR@'  -- set by install-plugin.sh

local NEUTRAL = {
  Exposure2012 = 0, Contrast2012 = 0, Highlights2012 = 0, Shadows2012 = 0, Whites2012 = 0,
  Blacks2012 = 0, Texture = 0, Clarity2012 = 0, Dehaze = 0, Vibrance = 0, Saturation = 0,
  Sharpness = 0, LuminanceSmoothing = 0, ColorNoiseReduction = 0, LensProfileEnable = 0,
  AutoLateralCA = 0, PostCropVignetteAmount = 0, GrainAmount = 0, ToneCurveName2012 = 'Linear',
  LensManualDistortionAmount = 0, VignetteAmount = 0, VignetteMidpoint = 50,
  DefringePurpleAmount = 0, DefringePurpleHueLo = 30, DefringePurpleHueHi = 70,
  DefringeGreenAmount = 0, DefringeGreenHueLo = 40, DefringeGreenHueHi = 60,
  CropTop = 0, CropLeft = 0, CropBottom = 1, CropRight = 1, CropAngle = 0, CropConstrainToWarp = 0,
  PerspectiveUpright = 0, PerspectiveVertical = 0, PerspectiveHorizontal = 0, PerspectiveRotate = 0,
  PerspectiveScale = 100, PerspectiveAspect = 0, PerspectiveX = 0, PerspectiveY = 0,
  ToneCurvePV2012 = { 0, 0, 255, 255 },
}

local M = {}
local busy = false

local function parse(text)
  local job = { items = {} }
  for line in text:gmatch('[^\r\n]+') do
    local fields = {}
    for f in (line .. '\t'):gmatch('([^\t]*)\t') do fields[#fields + 1] = f end
    if fields[1] == 'OUT' then job.out = fields[2]
    elseif fields[1] == 'MODE' then job.mode = fields[2]
    elseif fields[1] == 'CATALOG' then job.catalog = fields[2]
    elseif fields[1] == 'GATE' then job.gate = tonumber(fields[2])
    elseif fields[1] == 'SETTLE' then job.settle = tonumber(fields[2])
    elseif fields[1] == 'EV' then job.ev = tonumber(fields[2])
    elseif fields[1] == 'FRACTIONS' then
      job.fractions = {}
      for f in (fields[2] or ''):gmatch('[^,]+') do job.fractions[#job.fractions + 1] = tonumber(f) end
    elseif fields[1] == 'SERIES' then
      job.series = job.series or {}
      local fractions = {}
      for f in (fields[3] or ''):gmatch('[^,]+') do fractions[#fractions + 1] = tonumber(f) end
      job.series[#job.series + 1] = { ev = tonumber(fields[2]), fractions = fractions }
    elseif fields[1] == 'ITEM' then
      local s = {}
      for k, v in (fields[3] or ''):gmatch('([%w_]+)=([^;]*)') do s[k] = tonumber(v) or v end
      local maskFile = fields[4]
      if maskFile == '' then maskFile = nil end
      job.items[#job.items + 1] = { path = fields[2], settings = s, maskFile = maskFile }
    end
  end
  return job
end

local function exportPhotos(photos, out, longEdge, stamps, shouldStop)
  local log = {}
  LrFileUtils.createAllDirectories(out)
  local exportSettings = {
    LR_export_destinationType = 'specificFolder',
    LR_export_destinationPathPrefix = out,
    LR_export_useSubfolder = false,
    LR_format = 'TIFF',
    LR_tiff_compressionMethod = 'compressionMethod_None',
    LR_export_bitDepth = 16,
    LR_export_colorSpace = 'ProPhotoRGB',
    LR_size_doConstrain = false,
    LR_outputSharpeningOn = false,
    LR_collisionHandling = 'overwrite',
    LR_renamingTokensOn = true,
    LR_tokens = '{{image_name}}',
    LR_extensionCase = 'lowercase',
    LR_embeddedMetadataOption = 'all',
    LR_export_postProcessing = 'doNothing',
    LR_reimportExportedPhoto = false,
    LR_useWatermark = false,
  }
  if longEdge then
    exportSettings.LR_size_doConstrain = true
    exportSettings.LR_size_doNotEnlarge = true
    exportSettings.LR_size_resizeType = 'longEdge'
    exportSettings.LR_size_maxWidth = longEdge
    exportSettings.LR_size_maxHeight = longEdge
    exportSettings.LR_size_units = 'pixels'
    exportSettings.LR_size_resolution = 240
    exportSettings.LR_size_resolutionUnits = 'inch'
  end
  local session = LrExportSession { photosToExport = photos, exportSettings = exportSettings }
  for _, rendition in session:renditions() do
    local ok, result = rendition:waitForRender()
    if stamps then stamps[#stamps + 1] = LrDate.currentTime() end
    if not ok then log[#log + 1] = 'ERROR\trender\t' .. tostring(result) end
    -- a stop request ends the export after the render in hand (masks jobs pass shouldStop)
    if shouldStop and shouldStop() then
      LrTasks.pcall(function() session:cancel() end)
      log[#log + 1] = 'ERROR\tcanceled during the export'
      break
    end
  end
  return log
end

local function importItems(catalog, job)
  catalog:withWriteAccessDo('Argent probe import', function()
    for _, item in ipairs(job.items) do
      local photo = catalog:findPhotoByPath(item.path)
      if not photo then photo = catalog:addPhoto(item.path) end
      item.photo = photo
    end
  end, { timeout = 600 })
end

local function runSettingsJob(catalog, job)
  local log = {}
  local photos = {}
  importItems(catalog, job)
  catalog:withWriteAccessDo('Argent probe settings', function()
    for _, item in ipairs(job.items) do
      if item.photo then
        if job.mode ~= 'lens-defaults' then
          local s = {}
          for k, v in pairs(NEUTRAL) do s[k] = v end
          for k, v in pairs(item.settings) do s[k] = v end
          item.photo:applyDevelopSettings(s, 'Argent probe')
        end
        photos[#photos + 1] = item.photo
        log[#log + 1] = 'OK\t' .. item.path
      else
        log[#log + 1] = 'ERROR\tnot in catalog\t' .. item.path
      end
    end
  end, { timeout = 600 })
  for _, line in ipairs(exportPhotos(photos, job.out)) do log[#log + 1] = line end
  log[#log + 1] = 'DONE\t' .. #photos
  return log
end

-- Lightroom's Auto, read back.
local AUTO_LONG_EDGE = 2000
local AUTO_REPEAT_EVERY = 13
local AUTO_KEYS = { 'Exposure2012', 'Contrast2012', 'Highlights2012', 'Shadows2012', 'Whites2012', 'Blacks2012',
                    'Texture', 'Clarity2012', 'Dehaze', 'Vibrance', 'Saturation' }

local function toneOf(photo)
  local settings = photo:getDevelopSettings()
  local tone = {}
  for i, key in ipairs(AUTO_KEYS) do tone[i] = tonumber(settings[key]) or 0 end
  return tone, settings
end

local function sameTone(a, b)
  for i = 1, #a do if a[i] ~= b[i] then return false end end
  return true
end

local function isNeutralTone(tone)
  for i = 1, #tone do if tone[i] ~= 0 then return false end end
  return true
end

local function appendLine(path, line)
  local f = assert(io.open(path, 'a'))
  f:write(line .. '\n')
  f:close()
end

-- Older DNGs carry no process version and would otherwise run Auto under Lightroom's older sliders.
local AUTO_PROCESS_VERSION = '15.4'

local function setNeutral(catalog, photos)
  local settings = { ProcessVersion = AUTO_PROCESS_VERSION }
  for k, v in pairs(NEUTRAL) do settings[k] = v end
  catalog:withWriteAccessDo('Argent auto neutral', function()
    for _, photo in ipairs(photos) do photo:applyDevelopSettings(settings, 'Argent neutral') end
  end, { timeout = 600 })
end

local function openInDevelop(catalog, photo)
  catalog:setSelectedPhotos(photo, {})
  for _ = 1, 100 do
    local target = catalog:getTargetPhoto()
    if target and target.localIdentifier == photo.localIdentifier then
      LrTasks.sleep(0.5)
      return true
    end
    LrTasks.sleep(0.1)
  end
  return false
end

-- Runs Auto on the photo open in Develop and waits for its sliders to move and hold still.
local function autoTone(photo)
  for attempt = 1, 3 do
    LrDevelopController.setAutoTone()
    local last, still = nil, 0
    for _ = 1, 150 do
      LrTasks.sleep(0.1)
      local now = toneOf(photo)
      if last and sameTone(now, last) and not isNeutralTone(now) then
        still = still + 1
        if still >= 4 then return now, attempt end
      else
        still = 0
      end
      last = now
    end
  end
  return nil, 3
end

local function autoRow(item, tone, settings, attempt)
  local fields = { LrPathUtils.leafName(item.path), tostring(attempt) }
  for _, value in ipairs(tone) do fields[#fields + 1] = tostring(value) end
  fields[#fields + 1] = tostring(settings.ProcessVersion)
  fields[#fields + 1] = tostring(settings.CameraProfile)
  return table.concat(fields, '\t')
end

local function runAutoJob(catalog, job)
  local log = {}
  LrFileUtils.createAllDirectories(job.out)
  importItems(catalog, job)
  local items, photos = {}, {}
  for _, item in ipairs(job.items) do
    if item.photo then
      items[#items + 1] = item
      photos[#photos + 1] = item.photo
    else
      log[#log + 1] = 'ERROR\tnot in catalog\t' .. item.path
    end
  end
  if #items == 0 then
    log[#log + 1] = 'DONE\t0'
    return log
  end
  setNeutral(catalog, photos)
  local header = 'file\tattempts\t' .. table.concat(AUTO_KEYS, '\t') .. '\tProcessVersion\tCameraProfile'
  local tsv = LrPathUtils.child(job.out, 'auto.tsv')
  local repeatTsv = LrPathUtils.child(job.out, 'auto-repeat.tsv')
  appendLine(tsv, header)
  appendLine(repeatTsv, header)
  catalog:setActiveSources({ catalog:getFolderByPath(LrPathUtils.parent(items[1].path)) })
  LrApplicationView.switchToModule('develop')
  LrTasks.sleep(2)

  local steps = #items + math.floor(#items / AUTO_REPEAT_EVERY) + 2
  local done = 0
  local scope = LrProgressScope { title = 'Argent: capturing Lightroom Auto' }
  local function tick(caption)
    scope:setCaption(caption)
    scope:setPortionComplete(done, steps)
    done = done + 1
  end
  local function autoOne(item, destination)
    if not openInDevelop(catalog, item.photo) then
      return false, 'could not open in Develop'
    end
    local tone, attempt = autoTone(item.photo)
    if not tone then return false, 'Auto did not change the sliders' end
    local _, settings = toneOf(item.photo)
    appendLine(destination, autoRow(item, tone, settings, attempt))
    return true
  end

  local failures, answered, canceled = 0, 0, false
  for i, item in ipairs(items) do
    if scope:isCanceled() then canceled = true break end
    tick('Auto ' .. i .. ' of ' .. #items)
    local ran, ok, reason = LrTasks.pcall(autoOne, item, tsv)
    if ran and ok then
      answered = answered + 1
      log[#log + 1] = 'OK\t' .. item.path
    else
      failures = failures + 1
      log[#log + 1] = 'ERROR\tauto\t' .. item.path .. '\t' .. tostring(ran and reason or ok)
    end
    -- Three failures from the start mean the route is broken: stop rather than export nothing useful.
    if i == 3 and answered == 0 then
      scope:done()
      log[#log + 1] = 'ERROR\taborted: Auto failed on the first three photos'
      log[#log + 1] = 'DONE\t0'
      LrApplicationView.switchToModule('library')
      return log
    end
  end

  if not canceled then
    for i = AUTO_REPEAT_EVERY, #items, AUTO_REPEAT_EVERY do
      if scope:isCanceled() then canceled = true break end
      local item = items[i]
      tick('Repeating Auto on ' .. LrPathUtils.leafName(item.path))
      setNeutral(catalog, { item.photo })
      LrTasks.sleep(0.5)
      local ran, ok, reason = LrTasks.pcall(autoOne, item, repeatTsv)
      if not (ran and ok) then
        log[#log + 1] = 'ERROR\trepeat\t' .. item.path .. '\t' .. tostring(ran and reason or ok)
      end
    end
  end

  LrApplicationView.switchToModule('library')
  if canceled then
    log[#log + 1] = 'ERROR\tcanceled'
  else
    tick('Exporting with Auto')
    for _, line in ipairs(exportPhotos(photos, LrPathUtils.child(job.out, 'auto'), AUTO_LONG_EDGE)) do log[#log + 1] = line end
    tick('Exporting without Auto')
    setNeutral(catalog, photos)
    for _, line in ipairs(exportPhotos(photos, LrPathUtils.child(job.out, 'neutral'), AUTO_LONG_EDGE)) do log[#log + 1] = line end
  end
  scope:done()
  log[#log + 1] = 'DONE\t' .. answered
  return log
end

-- The mask session (MODE masks). ---------------------------------------------------------------------------------

local MASK_PROCESS_VERSION = '15.4'

local function stopRequested()
  return LrFileUtils.exists(LrPathUtils.child(JOBDIR, 'STOP')) and true or false
end

local function nameOf(item)
  return LrPathUtils.removeExtension(LrPathUtils.leafName(item.path))
end

local function writeFile(path, text)
  LrFileUtils.createAllDirectories(LrPathUtils.parent(path))
  local f = assert(io.open(path, 'w'))
  f:write(text)
  f:close()
end

-- Reads and checks each item's table. Returns the items to run, and logs the ones refused.
local function readTables(job, log)
  local items = {}
  for _, item in ipairs(job.items) do
    if not item.photo then
      log[#log + 1] = 'ERROR\tnot in catalog\t' .. item.path
    else
      local masks, problems = {}, {}
      if item.maskFile then
        local text = LrFileUtils.readFile(item.maskFile)
        if not text then
          problems = { 'cannot read ' .. item.maskFile }
        else
          local ok, value = pcall(MaskJob.decode, text)
          if ok then
            masks = value
            problems = MaskJob.validate(value)
          else
            problems = { 'not JSON: ' .. tostring(value) }
          end
        end
      end
      if #problems > 0 then
        log[#log + 1] = 'ERROR\trefused\t' .. item.path .. '\t' .. table.concat(problems, '; ')
      else
        item.masks = masks
        items[#items + 1] = item
      end
    end
  end
  return items
end

local function runMasksJob(catalog, job, state)
  local log = {}
  local clock = LrDate.currentTime
  local started = clock()
  local mark = { started }
  local function lap() mark[#mark + 1] = clock(); return mark[#mark] - mark[#mark - 1] end
  LrFileUtils.createAllDirectories(job.out)
  log[#log + 1] = 'INFO\tplugin\t' .. PLUGIN_VERSION .. '\tcatalog\t' .. tostring(catalog:getPath())
  importItems(catalog, job)
  local imported = lap()
  local items = readTables(job, log)
  local scope = LrProgressScope { title = 'Argent probe: ' .. LrPathUtils.leafName(job.path or 'masks') }
  local photos, failures, canceled = {}, 0, false

  -- 1. write every item's settings and table, in one gate
  catalog:withWriteAccessDo('Argent probe masks', function()
    for i, item in ipairs(items) do
      if scope:isCanceled() or stopRequested() then canceled = true break end
      scope:setCaption('writing ' .. i .. ' of ' .. #items)
      scope:setPortionComplete(i - 1, #items * 2)
      local settings = {}
      for k, v in pairs(NEUTRAL) do settings[k] = v end
      settings.ProcessVersion = MASK_PROCESS_VERSION
      settings.EnableMaskGroupBasedCorrections = true
      settings.MaskGroupBasedCorrections = item.masks  -- an empty table clears the photo's masks
      for k, v in pairs(item.settings) do settings[k] = v end
      local ran, err = LrTasks.pcall(function() item.photo:applyDevelopSettings(settings, 'Argent probe masks') end)
      if ran then
        item.applied = true
        photos[#photos + 1] = item.photo
      else
        log[#log + 1] = 'ERROR\tapply\t' .. item.path .. '\t' .. tostring(err)
      end
    end
  end, { timeout = 600 })
  local written = lap()
  if job.settle and job.settle > 0 then LrTasks.sleep(job.settle) end

  -- 2. read back what Lightroom kept: the structure must match (a dropped component means a refused table)
  local checked = 0
  for _, item in ipairs(items) do
    if item.applied then
      local ran, settings = LrTasks.pcall(function() return item.photo:getDevelopSettings() end)
      if ran then
        local back = settings.MaskGroupBasedCorrections or {}
        local structure, notes = MaskJob.compare(item.masks, back)
        local name = nameOf(item)
        checked = checked + 1
        if #structure > 0 then
          failures = failures + 1
          log[#log + 1] = 'WARN\tmask-readback\t' .. name .. '\t' .. table.concat(structure, '; ')
        end
        for _, note in ipairs(notes) do log[#log + 1] = 'NOTE\t' .. name .. '\t' .. note end
        writeFile(LrPathUtils.child(LrPathUtils.child(job.out, 'readback'), name .. '.json'), MaskJob.encode({
          written = item.masks, back = back, enable = settings.EnableMaskGroupBasedCorrections,
          ProcessVersion = settings.ProcessVersion, Exposure2012 = settings.Exposure2012 }) .. '\n')
      else
        log[#log + 1] = 'ERROR\treadback\t' .. item.path .. '\t' .. tostring(settings)
      end
    end
  end
  local readBack = lap()
  state.maskFailures = (state.maskFailures or 0) + failures
  log[#log + 1] = 'INFO\treadback\t' .. checked .. ' items, ' .. failures .. ' failed'

  -- 3. the gate: a table Lightroom does not take is no use to the jobs after this one
  local stopped = false
  if job.gate and job.gate > 0 and failures >= job.gate then
    stopped = true
    log[#log + 1] = 'ERROR\taborted: ' .. failures .. ' of ' .. checked .. ' tables came back without their components; nothing more will run'
  end

  -- 4. export, as a settings job does
  local stamps = {}
  if not canceled and not stopped and #photos > 0 then
    scope:setCaption('exporting ' .. #photos)
    scope:setPortionComplete(#items, #items * 2)
    -- an export that throws must not skip the cleanup below
    local ran, exportLog = LrTasks.pcall(exportPhotos, photos, job.out, nil, stamps, function() return scope:isCanceled() or stopRequested() end)
    if ran then
      for _, line in ipairs(exportLog) do
        log[#log + 1] = line
        if line:match('canceled during the export') then canceled = true end
      end
    else
      log[#log + 1] = 'ERROR\texport\t' .. tostring(exportLog)
    end
  end
  local exported = lap()

  -- 5. take the tables off the photos again: a bad table is saved with the catalog (MCP-304)
  catalog:withWriteAccessDo('Argent probe masks cleanup', function()
    for _, photo in ipairs(photos) do
      LrTasks.pcall(function()
        photo:applyDevelopSettings({ MaskGroupBasedCorrections = {}, EnableMaskGroupBasedCorrections = true }, 'Argent probe cleanup')
      end)
    end
  end, { timeout = 600 })
  lap()
  scope:done()

  local lines = { 'phase\tseconds\titems', 'import\t' .. string.format('%.2f', imported) .. '\t' .. #job.items,
                  'write\t' .. string.format('%.2f', written) .. '\t' .. #items, 'readback\t' .. string.format('%.2f', readBack) .. '\t' .. checked,
                  'export\t' .. string.format('%.2f', exported) .. '\t' .. #photos,
                  'total\t' .. string.format('%.2f', clock() - started) .. '\t' .. #job.items }
  for i = 2, #stamps do lines[#lines + 1] = 'render\t' .. string.format('%.2f', stamps[i] - stamps[i - 1]) .. '\t' .. i end
  local f = io.open(LrPathUtils.child(job.out, 'timing.tsv'), 'a')
  if f then f:write(table.concat(lines, '\n') .. '\n'); f:close() end

  if canceled then
    log[#log + 1] = 'ERROR\tcanceled'
    state.stop = true
  end
  if stopped then state.stop = true end
  log[#log + 1] = 'DONE\t' .. #photos
  return log
end

-- The AI masks' session (MODE masks-ai, L2). -------------------------------------------------------------------

local AI_APPEAR_LIMIT = 60     -- seconds to wait for a new mask to appear
local AI_STILL = 1             -- it must stay this long, as R1's reported route waited

-- Waits for the mask `createNewMask` asked for. Returns the outcome ('made' or 'none'), the seconds until it appeared and
-- until its digest was there, and the mask count; a mask that never appears is 'none' (R1: a "No sky detected" kind of result).
local function waitForAiMask(photo, before, clock, t0, shouldStop)
  local appeared, digestAt, stillSince = nil, nil, nil
  while clock() - t0 < AI_APPEAR_LIMIT do
    if shouldStop() then return 'stopped', nil, nil, 0 end
    LrTasks.sleep(0.1)
    local ran, masks = LrTasks.pcall(LrDevelopController.getAllMasks)
    local count = ran and type(masks) == 'table' and #masks or 0
    if count > before then
      appeared = appeared or clock()
      stillSince = stillSince or clock()
      local _, settings = LrTasks.pcall(function() return photo:getDevelopSettings() end)
      local corrections = type(settings) == 'table' and settings.MaskGroupBasedCorrections or {}
      local _, isAi, hasDigest = MaskJob.aiState(corrections)
      if isAi and hasDigest then digestAt = digestAt or clock() end
      if digestAt and clock() - stillSince >= AI_STILL then
        return 'made', appeared - t0, digestAt - t0, count
      end
    else
      stillSince = nil
      if appeared then appeared = nil; digestAt = nil end
    end
  end
  return appeared and 'no-digest' or 'none', appeared and (appeared - t0) or nil, nil, 0
end

local function neutralAi(extra)
  local s = { ProcessVersion = MASK_PROCESS_VERSION, EnableMaskGroupBasedCorrections = true, MaskGroupBasedCorrections = {} }
  for k, v in pairs(NEUTRAL) do s[k] = v end
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end

local function runMasksAiJob(catalog, job, state)
  local log = {}
  local clock = LrDate.currentTime
  LrFileUtils.createAllDirectories(job.out)
  log[#log + 1] = 'INFO\tplugin\t' .. PLUGIN_VERSION .. '\tcatalog\t' .. tostring(catalog:getPath())
  importItems(catalog, job)
  local series = job.series or { { ev = job.ev or -1, fractions = job.fractions or { 1, 0.75, 0.5, 0.25 } } }
  local aiTsv = LrPathUtils.child(job.out, 'ai.tsv')
  appendLine(aiTsv, 'photo\tkind\toutcome\tseconds_to_appear\tseconds_to_digest\tmasks')
  local scope = LrProgressScope { title = 'Argent probe: ' .. LrPathUtils.leafName(job.path or 'masks-ai') }
  local function stopping() return scope:isCanceled() or stopRequested() end
  local items = {}
  for _, item in ipairs(job.items) do
    if not item.photo then
      log[#log + 1] = 'ERROR\tnot in catalog\t' .. item.path
    else
      item.kind = item.settings.KIND
      item.settings.KIND = nil
      if item.maskFile then
        local ok, value = pcall(MaskJob.decode, LrFileUtils.readFile(item.maskFile) or '')
        if ok and #MaskJob.validate(value) == 0 then item.tableMasks = value
        else log[#log + 1] = 'ERROR\ttable refused\t' .. item.path end
      end
      items[#items + 1] = item
    end
  end

  -- 1. the AI masks, one photo at a time, with Develop in front
  catalog:withWriteAccessDo('Argent probe AI neutral', function()
    for _, item in ipairs(items) do item.photo:applyDevelopSettings(neutralAi(), 'Argent probe neutral') end
  end, { timeout = 600 })
  catalog:setActiveSources({ catalog:getFolderByPath(LrPathUtils.parent(items[1].path)) })
  LrApplicationView.switchToModule('develop')
  LrTasks.sleep(2)
  local tables = LrPathUtils.child(job.out, 'tables')
  local answered, asked = 0, 0
  for i, item in ipairs(items) do
    if stopping() then state.stop = true; log[#log + 1] = 'ERROR\tcanceled'; break end
    if item.kind == 'sky' or item.kind == 'subject' then
      scope:setCaption('AI ' .. i .. ' of ' .. #items)
      scope:setPortionComplete(i - 1, #items * 2)
      asked = asked + 1
      local ran, outcome, appear, digest, count = LrTasks.pcall(function()
        if not openInDevelop(catalog, item.photo) then return 'no-develop', nil, nil, 0 end
        LrDevelopController.goToMasking()
        LrTasks.sleep(1)
        local _, masks = LrTasks.pcall(LrDevelopController.getAllMasks)
        local before = type(masks) == 'table' and #masks or 0
        local t0 = clock()
        LrDevelopController.createNewMask('aiSelection', item.kind)
        return waitForAiMask(item.photo, before, clock, t0, stopping)
      end)
      if not ran then
        outcome, appear, digest, count = 'error', nil, nil, 0
        log[#log + 1] = 'ERROR\tai\t' .. item.path .. '\t' .. tostring(outcome)
      end
      if outcome == 'made' then
        -- let Lightroom finish with the photo before anything touches it (R1: writing while a mask computes froze it)
        LrTasks.sleep(2)
        local _, settings = LrTasks.pcall(function() return item.photo:getDevelopSettings() end)
        local corrections = type(settings) == 'table' and settings.MaskGroupBasedCorrections or nil
        local masked, why = MaskJob.withExposure(corrections, series[1].ev)
        if masked then
          item.ai = corrections
          answered = answered + 1
          writeFile(LrPathUtils.child(tables, nameOf(item) .. '.json'), MaskJob.encode(corrections) .. '\n')
        else
          outcome = 'bad-table'
          log[#log + 1] = 'ERROR\ttable\t' .. item.path .. '\t' .. tostring(why)
        end
      end
      appendLine(aiTsv, table.concat({ nameOf(item), item.kind, tostring(outcome), appear and string.format('%.2f', appear) or '',
                                       digest and string.format('%.2f', digest) or '', tostring(count or 0) }, '\t'))
      log[#log + 1] = (outcome == 'made' and 'OK' or 'WARN') .. '\tai\t' .. item.path .. '\t' .. tostring(outcome)
      if i >= 3 and answered == 0 and asked >= 3 then
        log[#log + 1] = 'ERROR\taborted: no AI mask on the first three photos'
        state.stop = true
        break
      end
    end
  end
  LrApplicationView.switchToModule('library')
  LrTasks.sleep(2)
  if state.stop then scope:done(); log[#log + 1] = 'DONE\t0'; return log end

  -- 2. the states, each its own write gate and export, AI masks first (a removed table would lose its raster)
  local states = {}
  for _, s in ipairs(series) do
    local tag = string.format('e%+d', math.floor(s.ev * 100 + 0.5))
    states[#states + 1] = { name = 'masked-' .. tag, readback = true, table = function(item)
      if item.ai then return (MaskJob.withExposure(item.ai, s.ev)) end
      if item.tableMasks then return MaskJob.exposed(item.tableMasks, s.ev) end
      return nil
    end }
    for _, f in ipairs(s.fractions) do
      states[#states + 1] = { name = string.format('full-%s-%04d', tag, math.floor(f * 1000 + 0.5)), table = function() return MaskJob.fullCoverage(s.ev * f) end }
    end
  end
  states[#states + 1] = { name = 'base', table = function() return {} end }
  local rendered = {}
  for index, s in ipairs(states) do
    if stopping() then state.stop = true; log[#log + 1] = 'ERROR\tcanceled'; break end
    scope:setCaption(s.name)
    scope:setPortionComplete(#items + index - 1, #items + #states)
    local photos = {}
    catalog:withWriteAccessDo('Argent probe AI ' .. s.name, function()
      for _, item in ipairs(items) do
        local corrections = s.table(item)
        if corrections then
          item.photo:applyDevelopSettings(neutralAi({ MaskGroupBasedCorrections = corrections }), 'Argent probe ' .. s.name)
          photos[#photos + 1] = item.photo
        end
      end
    end, { timeout = 600 })
    if job.settle and job.settle > 0 then LrTasks.sleep(job.settle) end
    for _, item in ipairs(items) do
      local corrections = s.table(item)
      if corrections and s.readback then
        local _, settings = LrTasks.pcall(function() return item.photo:getDevelopSettings() end)
        local back = type(settings) == 'table' and settings.MaskGroupBasedCorrections or {}
        local structure, notes = MaskJob.compare(corrections, back)
        if #structure > 0 then log[#log + 1] = 'WARN\tmask-readback\t' .. nameOf(item) .. '\t' .. table.concat(structure, '; ') end
        for _, note in ipairs(notes) do log[#log + 1] = 'NOTE\t' .. nameOf(item) .. '\t' .. note end
        writeFile(LrPathUtils.child(LrPathUtils.child(LrPathUtils.child(job.out, 'readback'), s.name), nameOf(item) .. '.json'), MaskJob.encode({ back = back }) .. '\n')
      end
    end
    local exported = LrPathUtils.child(job.out, s.name)
    local stamps = {}
    local ran, exportLog = LrTasks.pcall(exportPhotos, photos, exported, nil, stamps, stopping)
    if ran then
      for _, line in ipairs(exportLog) do log[#log + 1] = line end
      rendered[#rendered + 1] = s.name .. ':' .. #photos
    else
      log[#log + 1] = 'ERROR\texport\t' .. s.name .. '\t' .. tostring(exportLog)
    end
  end
  scope:done()
  log[#log + 1] = 'INFO\trendered\t' .. table.concat(rendered, ' ')
  log[#log + 1] = 'DONE\t' .. #items
  return log
end

local function runDumpJob(catalog, job)
  local log = {}
  LrFileUtils.createAllDirectories(job.out)
  importItems(catalog, job)
  for _, item in ipairs(job.items) do
    if item.photo then
      local settings = item.photo:getDevelopSettings()
      writeFile(LrPathUtils.child(LrPathUtils.child(job.out, 'dump'), nameOf(item) .. '.json'), MaskJob.encode({
        MaskGroupBasedCorrections = settings.MaskGroupBasedCorrections or {},
        EnableMaskGroupBasedCorrections = settings.EnableMaskGroupBasedCorrections,
        ProcessVersion = settings.ProcessVersion }) .. '\n')
      log[#log + 1] = 'OK\t' .. item.path
    else
      log[#log + 1] = 'ERROR\tnot in catalog\t' .. item.path
    end
  end
  log[#log + 1] = 'DONE\t' .. #job.items
  return log
end

local LENS_KEYS = {
  'LensProfileEnable', 'LensProfileSetup', 'LensProfileName', 'LensProfileDistortionScale',
  'LensProfileChromaticAberrationScale', 'LensProfileVignettingScale', 'AutoLateralCA',
  'ChromaticAberrationR', 'ChromaticAberrationB', 'LensManualDistortionAmount', 'VignetteAmount', 'VignetteMidpoint',
  'DefringePurpleAmount', 'DefringePurpleHueLo', 'DefringePurpleHueHi',
  'DefringeGreenAmount', 'DefringeGreenHueLo', 'DefringeGreenHueHi',
  'CropTop', 'CropLeft', 'CropBottom', 'CropRight', 'CropAngle', 'CropConstrainToWarp',
  'PerspectiveUpright', 'PerspectiveVertical', 'PerspectiveHorizontal', 'PerspectiveRotate',
  'PerspectiveScale', 'PerspectiveAspect', 'PerspectiveX', 'PerspectiveY',
}

local function lensControls(photo)
  local settings = photo:getDevelopSettings()
  local controls = {}
  for _, key in ipairs(LENS_KEYS) do
    -- CropAngle is the photo-settings key; straightenAngle is its controller name.
    local parameter = key == 'CropAngle' and 'straightenAngle' or key
    local ok, minimum, maximum = LrTasks.pcall(LrDevelopController.getRange, parameter)
    local got, current = LrTasks.pcall(LrDevelopController.getValue, parameter)
    local value = { settingsValue = settings[key], neutralSetting = NEUTRAL[key] }
    if ok and minimum ~= nil and maximum ~= nil then
      value.minimum, value.maximum = minimum, maximum
    else
      value.rangeError = ok and 'SDK returned no numeric range' or tostring(minimum)
    end
    if got and current ~= nil then value.current = current
    else value.valueError = got and 'SDK returned no value' or tostring(current) end
    controls[key] = value
  end
  return controls
end

local function runLensRangesJob(catalog, job)
  local log, count = {}, 0
  importItems(catalog, job)
  LrApplicationView.switchToModule('develop')
  LrTasks.sleep(2)
  for _, item in ipairs(job.items) do
    local ran, why = LrTasks.pcall(function()
      assert(item.photo and openInDevelop(catalog, item.photo), 'could not open in Develop')
      local imported = lensControls(item.photo)
      setNeutral(catalog, { item.photo })
      LrTasks.sleep(0.5)
      local neutral = lensControls(item.photo)
      writeFile(LrPathUtils.child(LrPathUtils.child(job.out, 'ranges'), nameOf(item) .. '.json'),
        MaskJob.encode({ imported = imported, neutral = neutral }) .. '\n')
    end)
    if ran then
      count = count + 1
      log[#log + 1] = 'OK\t' .. item.path
    else
      log[#log + 1] = 'ERROR\tranges\t' .. item.path .. '\t' .. tostring(why)
    end
  end
  LrApplicationView.switchToModule('library')
  log[#log + 1] = 'DONE\t' .. count
  return log
end

local function runJob(path, explicit, state)
  local catalog = LrApplication.activeCatalog()
  local job = parse(LrFileUtils.readFile(path))
  job.path = path
  if job.catalog then
    if not explicit then return nil end
    if not LrPathUtils.leafName(catalog:getPath()):lower():find(job.catalog:lower(), 1, true) then
      state.refused = tostring(catalog:getPath())
      return nil
    end
  end
  if job.mode == 'lens-ranges' then
    if not explicit then return nil end
    return runLensRangesJob(catalog, job)
  end
  if job.mode == 'masks' or job.mode == 'dump' or job.mode == 'masks-ai' then
    if not explicit then return nil end  -- only the menu command runs these, never the poll
    if job.mode == 'dump' then return runDumpJob(catalog, job) end
    if job.mode == 'masks-ai' then return runMasksAiJob(catalog, job, state) end
    return runMasksJob(catalog, job, state)
  end
  if job.mode == 'auto' then return runAutoJob(catalog, job) end
  return runSettingsJob(catalog, job)
end

-- Runs the pending jobs in the order of their names. `explicit` is true for the menu command.
function M.runPending(explicit)
  if busy then return end
  busy = true
  local names = {}
  for name in LrFileUtils.files(JOBDIR) do
    if name:match('%.job$') then names[#names + 1] = name end
  end
  table.sort(names)
  local state = { ran = 0 }
  for _, name in ipairs(names) do
    if stopRequested() or state.stop then break end
    local ok, log = LrTasks.pcall(runJob, name, explicit, state)
    if ok and log == nil then
      -- left pending: a masks job outside the menu command, or in the wrong catalog
    else
      if not ok then log = { 'ERROR\t' .. tostring(log), 'DONE\t0' } end
      local f = io.open((name:gsub('%.job$', '.done')), 'w')
      f:write(table.concat(log, '\n') .. '\n'); f:close()
      LrFileUtils.move(name, (name:gsub('%.job$', '.processed')))
      state.ran = state.ran + 1
    end
  end
  busy = false
  if explicit then
    if state.refused then
      LrDialogs.message('Argent Probe', 'These jobs run only in the throwaway catalog. The open catalog is ' .. state.refused ..
        '. Open the catalog named in the job (see SESSION.md), then choose the command again.', 'critical')
    elseif state.ran > 0 then
      writeFile(LrPathUtils.child(JOBDIR, state.stop and 'STOPPED' or 'ALLDONE'),
        state.ran .. ' jobs, plug-in ' .. PLUGIN_VERSION .. ', ' .. os.date('%Y-%m-%d %H:%M:%S') .. '\n')
      LrDialogs.showBezel(state.stop and 'Argent Probe: stopped' or 'Argent Probe: all jobs done')
    end
  end
end

function M.poll()
  LrTasks.startAsyncTask(function()
    while true do
      LrTasks.pcall(M.runPending, false)
      LrTasks.sleep(3)
    end
  end)
end

return M
