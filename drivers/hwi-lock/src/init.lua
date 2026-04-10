local ZigbeeDriver    = require("st.zigbee")
local defaults        = require("st.zigbee.defaults")
local capabilities    = require("st.capabilities")
local zcl_clusters    = require("st.zigbee.zcl.clusters")
local zcl_messages    = require("st.zigbee.zcl")
local messages        = require("st.zigbee.messages")
local zb_const        = require("st.zigbee.constants")
local data_types      = require("st.zigbee.data_types")
local cluster_base    = require("st.zigbee.cluster_base")
local log             = require("log")

local DoorLock           = zcl_clusters.DoorLock
local PowerConfiguration = zcl_clusters.PowerConfiguration

-- ────────────────────────────────────────────────────────────────
-- 상수 정의
-- ────────────────────────────────────────────────────────────────

-- Zigbee Door Lock 클러스터 (0x0101) 속성
local DOOR_LOCK_CLUSTER       = 0x0101
local ATTR_LOCK_STATE         = 0x0000  -- 0=NotFullyLocked, 1=Locked, 2=Unlocked

-- Power Configuration 클러스터 (0x0001) 속성
local POWER_CONFIG_CLUSTER    = 0x0001
local ATTR_BATTERY_PERC       = 0x0021  -- BatteryPercentageRemaining (단위: 0.5%)
local ATTR_BATTERY_VOLTAGE    = 0x0020  -- BatteryVoltage (단위: 100mV)

-- IAS Zone 클러스터 (0x0500) - 변조 감지(tamper)
local IAS_ZONE_CLUSTER        = 0x0500
local ATTR_ZONE_STATUS        = 0x0002  -- bit 2 = Tamper

-- Tuya 전용 클러스터 (0xEF00) - 일부 Tuya 잠금장치에서 사용
local TUYA_CLUSTER            = 0xEF00

-- Lock 상태값
local LOCK_STATE_NOT_LOCKED   = 0
local LOCK_STATE_LOCKED       = 1
local LOCK_STATE_UNLOCKED     = 2

-- ────────────────────────────────────────────────────────────────
-- 속성 핸들러
-- ────────────────────────────────────────────────────────────────

-- LockState 속성 → lock capability 이벤트
local function lock_state_attr_handler(driver, device, value, zb_rx)
  local state = value.value
  log.info(string.format("[hwi-lock] LockState 수신: %d", state))

  if state == LOCK_STATE_LOCKED then
    device:emit_event(capabilities.lock.lock.locked())
  elseif state == LOCK_STATE_UNLOCKED then
    device:emit_event(capabilities.lock.lock.unlocked())
  else
    -- NotFullyLocked or unknown
    device:emit_event(capabilities.lock.lock.unknown())
  end
end

-- BatteryPercentageRemaining 속성 → battery capability 이벤트
-- SmartThings battery는 0-100%, Zigbee 값은 0-200 (0.5% 단위)
local function battery_perc_attr_handler(driver, device, value, zb_rx)
  local raw = value.value
  local percent = math.floor(raw / 2)
  percent = math.min(100, math.max(0, percent))
  log.info(string.format("[hwi-lock] 배터리: raw=%d → %d%%", raw, percent))
  device:emit_event(capabilities.battery.battery(percent))
end

-- BatteryVoltage 속성 → battery capability 이벤트 (대체 경로)
local function battery_voltage_attr_handler(driver, device, value, zb_rx)
  local voltage_mv = value.value * 100  -- 100mV 단위 → mV
  log.info(string.format("[hwi-lock] 배터리 전압: %d mV", voltage_mv))
  -- 전압 기반 배터리 추정 (일반 AA/CR 배터리 기준, 3.0V~4.2V)
  local min_v, max_v = 2700, 4200
  local clamped = math.min(max_v, math.max(min_v, voltage_mv))
  local percent = math.floor((clamped - min_v) / (max_v - min_v) * 100)
  device:emit_event(capabilities.battery.battery(percent))
end

-- IAS Zone Status → tamperAlert capability 이벤트
local function ias_zone_status_attr_handler(driver, device, value, zb_rx)
  local zone_status = value.value
  local tamper_bit = (zone_status & 0x04) ~= 0  -- bit 2 = Tamper
  log.info(string.format("[hwi-lock] IAS Zone Status: 0x%04X, tamper=%s", zone_status, tostring(tamper_bit)))
  if tamper_bit then
    device:emit_event(capabilities.tamperAlert.tamper.detected())
  else
    device:emit_event(capabilities.tamperAlert.tamper.clear())
  end
end

-- Door Lock 조작 응답(Operation Event) 처리
local function lock_operation_event_handler(driver, device, zb_rx)
  log.info("[hwi-lock] Door Lock Operation Event 수신")
  -- 응답 후 현재 상태를 재조회하여 확실히 반영
  device:send(DoorLock.attributes.LockState:read(device))
end

-- ────────────────────────────────────────────────────────────────
-- 명령 핸들러
-- ────────────────────────────────────────────────────────────────

local function handle_lock(driver, device, command)
  log.info("[hwi-lock] 잠금 명령 전송")
  device:send(DoorLock.server.commands.LockDoor(device))
end

local function handle_unlock(driver, device, command)
  log.info("[hwi-lock] 열림 명령 전송")
  device:send(DoorLock.server.commands.UnlockDoor(device))
end

local function handle_refresh(driver, device, command)
  log.info("[hwi-lock] 새로고침 요청")
  device:send(DoorLock.attributes.LockState:read(device))
  device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
end

-- ────────────────────────────────────────────────────────────────
-- 디바이스 라이프사이클 핸들러
-- ────────────────────────────────────────────────────────────────

local function device_init(driver, device)
  log.info("[hwi-lock] 디바이스 초기화")
  -- healthCheck 설정 (30분 간격)
  device:set_field("last_checkin", os.time())

  -- 초기화 후 5초 뒤 상태 읽기
  device.thread:call_with_delay(5, function()
    handle_refresh(driver, device, nil)
  end)
end

local function device_added(driver, device)
  log.info("[hwi-lock] 디바이스 추가됨 - 초기 상태 읽기")
  device:emit_event(capabilities.lock.lock.unknown())
  device:emit_event(capabilities.tamperAlert.tamper.clear())

  device.thread:call_with_delay(3, function()
    handle_refresh(driver, device, nil)
  end)
end

local function device_configure(driver, device)
  log.info("[hwi-lock] 디바이스 설정 (configure)")
  -- Door Lock 클러스터 LockState 리포팅 구성 (최소 1초, 최대 30분)
  device:send(DoorLock.attributes.LockState:configure_reporting(device, 1, 1800, 1))
  -- 배터리 리포팅 구성 (변화량 1%, 최소 30분)
  device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:configure_reporting(device, 1800, 43200, 1))
  -- 바인딩
  device:send(DoorLock.attributes.LockState:read(device))
  device:send(PowerConfiguration.attributes.BatteryPercentageRemaining:read(device))
end

-- ────────────────────────────────────────────────────────────────
-- 드라이버 정의
-- ────────────────────────────────────────────────────────────────

local hwi_lock_driver = ZigbeeDriver("hwi-lock", {
  supported_capabilities = {
    capabilities.lock,
    capabilities.battery,
    capabilities.tamperAlert,
    capabilities.refresh,
    capabilities.healthCheck,
  },

  zigbee_handlers = {
    attr = {
      [DoorLock.ID] = {
        [DoorLock.attributes.LockState.ID] = lock_state_attr_handler,
      },
      [PowerConfiguration.ID] = {
        [PowerConfiguration.attributes.BatteryPercentageRemaining.ID] = battery_perc_attr_handler,
        [PowerConfiguration.attributes.BatteryVoltage.ID] = battery_voltage_attr_handler,
      },
      [IAS_ZONE_CLUSTER] = {
        [ATTR_ZONE_STATUS] = ias_zone_status_attr_handler,
      },
    },
    cluster = {
      [DoorLock.ID] = {
        [0x20] = lock_operation_event_handler,  -- OperationEventNotification
      },
    },
  },

  capability_handlers = {
    [capabilities.lock.ID] = {
      [capabilities.lock.commands.lock.NAME]   = handle_lock,
      [capabilities.lock.commands.unlock.NAME] = handle_unlock,
    },
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = handle_refresh,
    },
  },

  lifecycle_handlers = {
    init      = device_init,
    added     = device_added,
    doConfigure = device_configure,
  },

  -- 기본 ZCL 핸들러 사용 (없는 항목은 기본값으로 처리)
  use_defaults = true,
})

hwi_lock_driver:run()
