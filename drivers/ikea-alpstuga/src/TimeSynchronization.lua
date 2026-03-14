-- TimeSynchronization 내장 클러스터 (Matter 1.0+)
-- SmartThings SDK에 없는 경우 사용하는 폴백 구현체
-- SetUTCTime 커맨드를 TLV 필드 방식으로 올바르게 인코딩합니다.
--
-- Matter Spec: TimeSynchronization Cluster (0x0038)
--   SetUTCTime Request:
--     field 0 (UTCTime):    uint64, microseconds since 2000-01-01 00:00:00 UTC
--     field 1 (Granularity): uint8,  GranularityEnum
--     field 2 (TimeSource): uint8,  TimeSourceEnum (optional)

local cluster_base = require "st.matter.cluster_base"
local data_types = require "st.matter.data_types"
local TLVParser = require "st.matter.TLV.TLVParser"

-- Uint64 타입 안전 로드 (SmartThings SDK 버전마다 위치가 다를 수 있음)
local Uint64Type = data_types.Uint64
if not Uint64Type then
  local ok, t = pcall(require, "st.matter.data_types.Uint64")
  if ok and t then Uint64Type = t end
end
if not Uint64Type then
  -- Lua 5.3+ 정수 지원: 직접 래퍼 생성
  Uint64Type = data_types.Uint32  -- 폴백 (값 손실 위험 있지만 크래시 방지)
  log.warn("[ALPSTUGA] Uint64 타입 없음 - Uint32 폴백 사용 (시간 정밀도 저하)")
end

local Uint8Type = data_types.Uint8 or (function()
  local ok, t = pcall(require, "st.matter.data_types.Uint8")
  return ok and t or nil
end)()

local TimeSynchronization = {}
TimeSynchronization.ID   = 0x0038
TimeSynchronization.NAME = "TimeSynchronization"
TimeSynchronization.server = { commands = {} }
TimeSynchronization.client = {}

-- ── SetUTCTime 커맨드 ────────────────────────────────────────────
local SetUTCTime = {
  ID   = 0x0000,
  NAME = "SetUTCTime",
  field_defs = {
    {
      name        = "UTCTime",
      field_id    = 0,
      is_nullable = false,
      is_optional = false,
      data_type   = Uint64Type,
    },
    {
      name        = "granularity",
      field_id    = 1,
      is_nullable = false,
      is_optional = false,
      data_type   = Uint8Type,
    },
    {
      name        = "timeSource",
      field_id    = 2,
      is_nullable = false,
      is_optional = true,
      data_type   = Uint8Type,
    },
  },
}

function SetUTCTime:init(device, endpoint_id, utc_time, granularity, time_source)
  local out = {}
  local args = { utc_time, granularity, time_source }
  for i, v in ipairs(self.field_defs) do
    if v.is_optional and args[i] == nil then
      out[v.name] = nil
    else
      out[v.name] = data_types.validate_or_build_type(args[i], v.data_type, v.name)
      out[v.name].field_id = v.field_id
    end
  end
  setmetatable(out, { __index = SetUTCTime })
  -- _cluster:build_cluster_command → cluster_base.build_cluster_command 로 위임
  return self._cluster:build_cluster_command(
    device, out, endpoint_id, self._cluster.ID, self.ID
  )
end

function SetUTCTime:set_parent_cluster(cluster)
  self._cluster = cluster
  return self
end

function SetUTCTime:deserialize(tlv_buf)
  return TLVParser.decode_tlv(tlv_buf)
end

setmetatable(SetUTCTime, { __call = SetUTCTime.init })
-- _cluster 를 미리 TimeSynchronization 으로 설정
SetUTCTime._cluster = TimeSynchronization

-- ── 클러스터 커맨드 등록 ─────────────────────────────────────────
TimeSynchronization.server.commands  = { SetUTCTime = SetUTCTime }
TimeSynchronization.commands         = { SetUTCTime = SetUTCTime }
TimeSynchronization.command_direction_map = { ["SetUTCTime"] = "server" }

function TimeSynchronization:get_server_command_by_id(command_id)
  if command_id == 0x0000 then return self.server.commands.SetUTCTime end
  return nil
end

-- cluster_base 를 __index 로 상속하여 build_cluster_command 등 사용
setmetatable(TimeSynchronization, { __index = cluster_base })

return TimeSynchronization
