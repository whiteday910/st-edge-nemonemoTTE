-- IKEA ALPSTUGA Edge Driver (Matter over Thread)
-- 지원 기능: CO2, PM2.5, 온도, 습도 센서 + 시간 동기화

local MatterDriver = require("st.matter.driver")
local capabilities = require("st.capabilities")
local clusters     = require("st.matter.clusters")
local log          = require("log")

-- ============================================================
-- 안전한 클러스터 로더
-- SDK 버전에 따라 일부 클러스터가 없을 수 있으므로 pcall 로 보호
-- ============================================================
local function safe_cluster(name)
  local ok, result = pcall(function() return clusters[name] end)
  if ok and result then
    log.debug(string.format("[ALPSTUGA] cluster '%s' 로드 성공", name))
    return result
  else
    log.warn(string.format("[ALPSTUGA] cluster '%s' SDK 미지원 - 수동 정의 필요", name))
    return nil
  end
end

-- TimeSynchronization: SDK 우선, 없으면 내장 클러스터 사용
local TimeSynchronization = safe_cluster("TimeSynchronization")
if not TimeSynchronization then
  local ok, ts = pcall(require, "TimeSynchronization")
  if ok and ts then
    TimeSynchronization = ts
    log.info("[ALPSTUGA] TimeSynchronization 내장 클러스터 로드 성공")
  end
end
local CarbonDioxideConcentrationMeasurement = safe_cluster("CarbonDioxideConcentrationMeasurement")
local Pm25ConcentrationMeasurement          = safe_cluster("Pm25ConcentrationMeasurement")
local TemperatureMeasurement                = safe_cluster("TemperatureMeasurement")
local RelativeHumidityMeasurement           = safe_cluster("RelativeHumidityMeasurement")

-- ============================================================
-- 상수 정의
-- ============================================================

-- Unix epoch(1970-01-01) → Matter epoch(2000-01-01) 오프셋 (초)
local MATTER_EPOCH_OFFSET_SEC = 946684800

-- 정기 시간 동기화 주기: 1시간
local TIME_SYNC_INTERVAL_SEC  = 3600

-- Matter TimeSynchronization 클러스터 (0x0038)
local TIME_SYNC_CLUSTER_ID    = 0x0038
-- SetUTCTime 커맨드 ID (0x0000)
local SET_UTC_TIME_CMD_ID     = 0x0000
-- GranularityEnum: kSecondsGranularity = 2 (Matter Spec 1.0+)
-- 0=None, 1=Minutes, 2=Seconds, 3=Milliseconds, 4=Microseconds
local GRANULARITY_SECONDS     = 2

-- SDK 클러스터 모듈 없이 raw ID로 직접 구독/처리할 클러스터
-- SmartThings 문서: subscribed_attributes 에 {cluster=ID, attribute=ID} 테이블 사용 가능
local CLUSTER_CO2             = 0x040D  -- CarbonDioxideConcentrationMeasurement
local CLUSTER_PM25            = 0x042A  -- Pm25ConcentrationMeasurement
local CLUSTER_AIR_QUALITY     = 0x005B  -- AirQuality
local ATTR_MEASURED_VALUE     = 0x0000  -- MeasuredValue (공통)
local ATTR_LEVEL_VALUE        = 0x000A  -- LevelValue (농도 단계: Low/Medium/High/Critical)

-- TimeSynchronization 클러스터 속성 ID
-- 구독을 통해 허브 라우팅 테이블에 0x0038을 등록 → SetUTCTime 명령 허용
local ATTR_UTC_TIME           = 0x0000  -- UTCTime (nullable uint64, microseconds since Matter epoch)

-- ============================================================
-- 수동 TimeSynchronization 클러스터 정의
-- SDK에 클러스터 모듈이 없을 때 사용
-- ============================================================

--- SetUTCTime 명령을 빌드합니다.
--- TimeSynchronization 내장 클러스터의 build_cluster_command를 사용합니다.
local function build_set_utc_time_command(device, endpoint_id, utc_time, granularity)
  if TimeSynchronization and TimeSynchronization.commands and TimeSynchronization.commands.SetUTCTime then
    local ok, cmd = pcall(function()
      return TimeSynchronization.commands.SetUTCTime(device, endpoint_id, utc_time, granularity)
    end)
    if ok and cmd then
      log.debug("[ALPSTUGA] SetUTCTime 빌드 성공")
      return cmd
    end
    log.error("[ALPSTUGA] SetUTCTime 빌드 실패: " .. tostring(cmd))
  else
    log.error("[ALPSTUGA] TimeSynchronization 클러스터 없음 - 시간 동기화 불가")
  end
  return nil
end

-- ============================================================
-- 시간 동기화 핵심 함수
-- ============================================================

local function sync_time(driver, device)
  local unix_time_sec   = os.time()
  local matter_time_sec = unix_time_sec - MATTER_EPOCH_OFFSET_SEC

  if matter_time_sec < 0 then
    log.warn("[ALPSTUGA] 시스템 시간이 2000년 이전 - 동기화 건너뜀")
    return
  end

  local matter_time_us = matter_time_sec * 1000000

  log.info(string.format(
    "[ALPSTUGA] 시간 동기화 시작: Unix=%ds, Matter=%ds, epoch-us=%d",
    unix_time_sec, matter_time_sec, matter_time_us
  ))

  -- ALPSTUGA는 Matter TimeSynchronization 클러스터(0x0038)를 서버로 지원하지 않아
  -- "Matter channel send error: Invalid cluster id" 경고가 발생함.
  -- 이는 기기 펌웨어 제약으로, 향후 IKEA 펌웨어 업데이트 시 동작할 수 있도록 코드 유지.
  -- endpoint 0(루트 노드)으로만 시도 (Matter Spec상 TimeSynchronization은 endpoint 0에 위치)
  local cmd = build_set_utc_time_command(device, 0, matter_time_us, GRANULARITY_SECONDS)
  if cmd then
    local ok, err = pcall(function() device:send(cmd) end)
    if ok then
      -- SDK 내부에서 "Invalid cluster id" 경고가 발생해도 pcall은 성공으로 반환됨.
      -- 실제 전송 여부는 기기 응답으로만 확인 가능.
      log.info(string.format(
        "[ALPSTUGA] SetUTCTime 명령 전송 시도 (endpoint=0, granularity=%d) - 기기 지원 여부에 따라 결과 다름",
        GRANULARITY_SECONDS
      ))
    else
      log.warn("[ALPSTUGA] SetUTCTime 전송 예외: " .. tostring(err))
    end
  else
    log.warn("[ALPSTUGA] SetUTCTime 명령 빌드 실패")
  end
end

-- ============================================================
-- Capability 핸들러
-- ============================================================

local function refresh_handler(driver, device, command)
  log.info("[ALPSTUGA] refresh 수신 - 수동 시간 동기화")
  sync_time(driver, device)
end

-- ============================================================
-- Matter 속성 핸들러
-- ============================================================

local function co2_attr_handler(driver, device, ib, response)
  if ib.data.value ~= nil then
    local ppm = math.floor(ib.data.value + 0.5)
    log.info(string.format("[ALPSTUGA] CO2: %d ppm", ppm))
    device:emit_event(capabilities.carbonDioxideMeasurement.carbonDioxide({ value = ppm, unit = "ppm" }))
  end
end

-- LevelValue enum → HealthConcern 캐퍼빌리티 값 매핑
-- Matter 농도측정 LevelValueEnum: 0=Unknown,1=Low(good),2=Medium(moderate),3=High(unhealthy),4=Critical(hazardous)
local function co2_level_attr_handler(driver, device, ib, response)
  local level = ib.data.value
  log.info(string.format("[ALPSTUGA] CO2 LevelValue: %s", tostring(level)))
  if level == 0 then
    device:emit_event(capabilities.carbonDioxideHealthConcern.carbonDioxideHealthConcern.unknown())
  elseif level == 1 then
    device:emit_event(capabilities.carbonDioxideHealthConcern.carbonDioxideHealthConcern.good())
  elseif level == 2 then
    device:emit_event(capabilities.carbonDioxideHealthConcern.carbonDioxideHealthConcern.moderate())
  elseif level == 3 then
    device:emit_event(capabilities.carbonDioxideHealthConcern.carbonDioxideHealthConcern.unhealthy())
  elseif level == 4 then
    device:emit_event(capabilities.carbonDioxideHealthConcern.carbonDioxideHealthConcern.hazardous())
  end
end

local function pm25_attr_handler(driver, device, ib, response)
  if ib.data.value ~= nil then
    local pm25 = math.floor(ib.data.value + 0.5)
    log.info(string.format("[ALPSTUGA] PM2.5: %d μg/m³", pm25))
    device:emit_event(capabilities.fineDustSensor.fineDustLevel({ value = pm25, unit = "μg/m^3" }))
  else
    log.warn("[ALPSTUGA] PM2.5 값 없음 (nullable)")
  end
end

local function pm25_level_attr_handler(driver, device, ib, response)
  local level = ib.data.value
  log.info(string.format("[ALPSTUGA] PM2.5 LevelValue: %s", tostring(level)))
  if level == 0 then
    device:emit_event(capabilities.fineDustHealthConcern.fineDustHealthConcern.unknown())
  elseif level == 1 then
    device:emit_event(capabilities.fineDustHealthConcern.fineDustHealthConcern.good())
  elseif level == 2 then
    device:emit_event(capabilities.fineDustHealthConcern.fineDustHealthConcern.moderate())
  elseif level == 3 then
    device:emit_event(capabilities.fineDustHealthConcern.fineDustHealthConcern.unhealthy())
  elseif level == 4 then
    device:emit_event(capabilities.fineDustHealthConcern.fineDustHealthConcern.hazardous())
  end
end

--- AirQuality 속성 처리 → airQualityHealthConcern 캐퍼빌리티로 emit
--- Matter AirQualityEnum: 0=Unknown,1=Good,2=Fair,3=Moderate,4=Poor,5=VeryPoor,6=ExtremelyPoor
local AIR_QUALITY_LABELS = { [0]="Unknown",[1]="Good",[2]="Fair",[3]="Moderate",[4]="Poor",[5]="VeryPoor",[6]="ExtremelyPoor" }
local function air_quality_attr_handler(driver, device, ib, response)
  local state = ib.data.value
  if state == nil then return end
  local label = AIR_QUALITY_LABELS[state] or ("Unknown(" .. tostring(state) .. ")")
  log.info(string.format("[ALPSTUGA] AirQuality: %s (%d)", label, state))
  if state == 0 then
    device:emit_event(capabilities.airQualityHealthConcern.airQualityHealthConcern.unknown())
  elseif state == 1 then
    device:emit_event(capabilities.airQualityHealthConcern.airQualityHealthConcern.good())
  elseif state == 2 then
    device:emit_event(capabilities.airQualityHealthConcern.airQualityHealthConcern.moderate())
  elseif state == 3 then
    device:emit_event(capabilities.airQualityHealthConcern.airQualityHealthConcern.slightlyUnhealthy())
  elseif state == 4 then
    device:emit_event(capabilities.airQualityHealthConcern.airQualityHealthConcern.unhealthy())
  elseif state == 5 then
    device:emit_event(capabilities.airQualityHealthConcern.airQualityHealthConcern.veryUnhealthy())
  elseif state == 6 then
    device:emit_event(capabilities.airQualityHealthConcern.airQualityHealthConcern.hazardous())
  end
end

local function temperature_attr_handler(driver, device, ib, response)
  if ib.data.value ~= nil then
    local temp_c = ib.data.value / 100.0
    log.info(string.format("[ALPSTUGA] 온도: %.2f°C", temp_c))
    device:emit_event(capabilities.temperatureMeasurement.temperature({ value = temp_c, unit = "C" }))
  end
end

local function humidity_attr_handler(driver, device, ib, response)
  if ib.data.value ~= nil then
    local pct = math.floor(ib.data.value / 100.0 + 0.5)
    log.info(string.format("[ALPSTUGA] 습도: %d%%", pct))
    device:emit_event(capabilities.relativeHumidityMeasurement.humidity(pct))
  end
end

-- TimeSynchronization UTCTime 구독 핸들러
-- 기기의 현재 시간을 로그로 확인 + 클러스터 0x0038이 등록되어 SetUTCTime 명령이 허용됨
local function utc_time_attr_handler(driver, device, ib, response)
  local raw = ib.data.value
  if raw then
    local ok_m, device_unix = pcall(function()
      return math.floor(raw / 1000000) + MATTER_EPOCH_OFFSET_SEC
    end)
    if ok_m then
      log.info(string.format("[ALPSTUGA] 기기 현재 UTCTime: Unix=%ds (Matter=%s μs)", device_unix, tostring(raw)))
    else
      log.info(string.format("[ALPSTUGA] 기기 UTCTime raw: %s (변환 불가)", tostring(raw)))
    end
  else
    log.info("[ALPSTUGA] 기기 UTCTime: null (시간 미설정 상태)")
  end
end

-- ============================================================
-- 디바이스 생명주기 핸들러
-- ============================================================

local function device_added(driver, device)
  log.info("[ALPSTUGA] 디바이스 추가됨")
  device.thread:call_with_delay(5, function()
    sync_time(driver, device)
  end)
end

local function device_init(driver, device)
  log.info("[ALPSTUGA] 디바이스 초기화")

  -- 구독 재설정: 드라이버 업데이트 후에도 새 subscribed_attributes 가 즉시 반영되도록 함
  -- (TimeSynchronization UTCTime 구독 포함)
  local ok_sub, err_sub = pcall(function() device:subscribe() end)
  if ok_sub then
    log.info("[ALPSTUGA] 구독 설정 완료")
  else
    log.warn("[ALPSTUGA] 구독 설정 실패: " .. tostring(err_sub))
  end

  -- 1시간마다 자동 시간 동기화
  device.thread:call_on_schedule(
    TIME_SYNC_INTERVAL_SEC,
    function()
      log.info("[ALPSTUGA] 정기 시간 동기화")
      sync_time(driver, device)
    end,
    "alpstuga_time_sync"
  )

  -- 초기화 10초 후 즉시 동기화 (구독 안정화 대기)
  device.thread:call_with_delay(10, function()
    sync_time(driver, device)
  end)
end

local function device_configure(driver, device)
  log.info("[ALPSTUGA] doConfigure - Matter 커미셔닝 완료")
  -- 커미셔닝 완료 시 구독 설정 (TimeSynchronization UTCTime 포함)
  local ok_sub, err_sub = pcall(function() device:subscribe() end)
  if ok_sub then
    log.info("[ALPSTUGA] doConfigure 구독 설정 완료")
  else
    log.warn("[ALPSTUGA] doConfigure 구독 설정 실패: " .. tostring(err_sub))
  end
  sync_time(driver, device)
end

local function device_removed(driver, device)
  log.info("[ALPSTUGA] 디바이스 제거됨")
end

-- '설정' 페이지의 preference 변경 감지
-- syncNow 토글이 변경될 때마다 (ON→OFF, OFF→ON 모두) 시간 동기화 실행
-- 이전 값이 true로 고정된 경우에도 OFF했다가 ON하면 재동기화 가능
local function info_changed(driver, device, event, args)
  local prefs    = device.preferences
  local old_prefs = args.old_st_store and args.old_st_store.preferences

  local new_val = prefs and prefs.syncNow
  local old_val = old_prefs and old_prefs.syncNow

  if new_val ~= old_val then
    log.info(string.format("[ALPSTUGA] 설정 > 시간 동기화 토글 변경 (%s → %s) - 동기화 실행",
      tostring(old_val), tostring(new_val)))
    sync_time(driver, device)
  end
end

-- ============================================================
-- matter_handlers: SDK 클러스터 객체 우선, 없으면 raw ID로 등록
-- ============================================================

local matter_attr_handlers = {}

-- CO2: raw ID로 직접 등록 (MeasuredValue + LevelValue 모두)
matter_attr_handlers[CLUSTER_CO2] = {
  [ATTR_MEASURED_VALUE] = co2_attr_handler,
  [ATTR_LEVEL_VALUE]    = co2_level_attr_handler,
}

-- PM2.5: raw ID(0x042A)로 직접 등록 (MeasuredValue + LevelValue 모두)
matter_attr_handlers[CLUSTER_PM25] = {
  [ATTR_MEASURED_VALUE] = pm25_attr_handler,
  [ATTR_LEVEL_VALUE]    = pm25_level_attr_handler,
}

-- 온도: SDK 클러스터 객체 사용
if TemperatureMeasurement then
  matter_attr_handlers[TemperatureMeasurement.ID] = {
    [TemperatureMeasurement.attributes.MeasuredValue.ID] = temperature_attr_handler,
  }
end

-- 습도: SDK 클러스터 객체 사용
if RelativeHumidityMeasurement then
  matter_attr_handlers[RelativeHumidityMeasurement.ID] = {
    [RelativeHumidityMeasurement.attributes.MeasuredValue.ID] = humidity_attr_handler,
  }
end

-- AirQuality: raw ID(0x005B)로 직접 등록 → airQualityHealthConcern
matter_attr_handlers[CLUSTER_AIR_QUALITY] = {
  [ATTR_MEASURED_VALUE] = air_quality_attr_handler,
}

-- TimeSynchronization UTCTime (0x0038/0x0000): 기기 시간 로그 + 클러스터 등록
matter_attr_handlers[TIME_SYNC_CLUSTER_ID] = {
  [ATTR_UTC_TIME] = utc_time_attr_handler,
}

-- ============================================================
-- subscribed_attributes: SDK 클러스터 객체 우선, 없으면 raw ID 테이블로 구독
-- ============================================================

local subscribed = {}

-- 공기질 전반: AirQuality 클러스터 → airQualityHealthConcern
subscribed[capabilities.airQualityHealthConcern.ID] = {
  { cluster = CLUSTER_AIR_QUALITY, attribute = ATTR_MEASURED_VALUE },
}

-- CO2 수치 (ppm): CarbonDioxide MeasuredValue → carbonDioxideMeasurement
subscribed[capabilities.carbonDioxideMeasurement.ID] = {
  { cluster = CLUSTER_CO2, attribute = ATTR_MEASURED_VALUE },
}

-- CO2 등급 (good/moderate/...): CarbonDioxide LevelValue → carbonDioxideHealthConcern
subscribed[capabilities.carbonDioxideHealthConcern.ID] = {
  { cluster = CLUSTER_CO2, attribute = ATTR_LEVEL_VALUE },
}

-- PM2.5 수치 (μg/m³): PM2.5 MeasuredValue → fineDustSensor
subscribed[capabilities.fineDustSensor.ID] = {
  { cluster = CLUSTER_PM25, attribute = ATTR_MEASURED_VALUE },
}

-- PM2.5 등급 (good/moderate/...): PM2.5 LevelValue → fineDustHealthConcern
subscribed[capabilities.fineDustHealthConcern.ID] = {
  { cluster = CLUSTER_PM25, attribute = ATTR_LEVEL_VALUE },
}

-- 온도: SDK 클러스터 객체
if TemperatureMeasurement then
  subscribed[capabilities.temperatureMeasurement.ID] = {
    TemperatureMeasurement.attributes.MeasuredValue,
  }
end

-- 습도: SDK 클러스터 객체
if RelativeHumidityMeasurement then
  subscribed[capabilities.relativeHumidityMeasurement.ID] = {
    RelativeHumidityMeasurement.attributes.MeasuredValue,
  }
end

-- 주의: TimeSynchronization 클러스터(0x0038)는 ALPSTUGA 기기가 서버로 지원하지 않아
-- 구독 시도 시 "Invalid cluster id" 경고가 발생하므로 구독 목록에서 제외.
-- 해당 핸들러(matter_attr_handlers[TIME_SYNC_CLUSTER_ID])는 등록만 해두고
-- 향후 기기 펌웨어 업데이트로 클러스터가 추가될 경우를 대비함.

-- ============================================================
-- 드라이버 템플릿
-- ============================================================

local alpstuga_driver_template = {
  supported_capabilities = {
    capabilities.airQualityHealthConcern,
    capabilities.carbonDioxideMeasurement,
    capabilities.carbonDioxideHealthConcern,
    capabilities.fineDustSensor,
    capabilities.fineDustHealthConcern,
    capabilities.temperatureMeasurement,
    capabilities.relativeHumidityMeasurement,
    capabilities.refresh,
    capabilities.healthCheck,
  },

  lifecycle_handlers = {
    added       = device_added,
    init        = device_init,
    doConfigure = device_configure,
    removed     = device_removed,
    infoChanged = info_changed,
  },

  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = refresh_handler,
    },
  },

  matter_handlers = {
    attr = matter_attr_handlers,
  },

  subscribed_attributes = subscribed,
}

local driver = MatterDriver("ikea-alpstuga", alpstuga_driver_template)
driver:run()
