# SmartThings Edge Driver 프로젝트

SmartThings Hub용 Matter/Zigbee/Z-Wave Edge Driver 개발 프로젝트입니다.

## 프로젝트 구조

```
st-edge-driver/
└── drivers/
    └── ikea-alpstuga/          # IKEA ALPSTUGA 공기질 센서 드라이버 (Matter over Thread)
        ├── config.yml          # 드라이버 설정 및 Matter 핑거프린트
        ├── profiles/
        │   └── alpstuga.yml    # 디바이스 캐퍼빌리티 프로파일
        └── src/
            └── init.lua        # 드라이버 메인 로직
```

---

## 드라이버 목록

### IKEA ALPSTUGA (`drivers/ikea-alpstuga`)

IKEA ALPSTUGA 공기질 센서용 Edge Driver입니다. Matter over Thread 프로토콜을 사용합니다.

#### 디바이스 스펙

| 항목 | 내용 |
|---|---|
| 프로토콜 | Matter over Thread (Matter 1.3) |
| 제품번호 | E2495 |
| 제조사 | IKEA of Sweden |
| Matter Device Type | Air Quality Sensor (0x002C) |

#### 지원 센서

| 센서 | Matter 클러스터 | SmartThings 캐퍼빌리티 |
|---|---|---|
| CO2 농도 | CarbonDioxideConcentrationMeasurement (0x040D) | `carbonDioxideMeasurement` |
| PM2.5 | Pm25ConcentrationMeasurement (0x042A) | `dustSensor` |
| 온도 | TemperatureMeasurement (0x0402) | `temperatureMeasurement` |
| 습도 | RelativeHumidityMeasurement (0x0405) | `relativeHumidityMeasurement` |

#### 시간 동기화 기능

ALPSTUGA는 전원 차단 후 시계가 **0:00으로 초기화**되는 문제가 있습니다. 이 드라이버는 Matter Time Synchronization 클러스터(0x0038)를 통해 자동으로 시간을 동기화합니다.

**동기화 시점:**
- 디바이스 최초 추가 시 (3초 후)
- 허브 재시작 / 드라이버 초기화 시 (3초 후)
- 1시간마다 자동 정기 동기화
- SmartThings 앱 새로고침(`refresh`) 버튼으로 수동 동기화

**시간 변환 로직:**
```
Matter UTCTime(μs) = (os.time() - 946684800) × 1,000,000
                     └── Unix epoch → Matter epoch 변환 (2000-01-01 기준)
                                      └── 초 → 마이크로초 변환
```

#### 사용 Matter 클러스터

| 클러스터 | ID | 용도 |
|---|---|---|
| TimeSynchronization | 0x0038 | 시계 시간 동기화 (SetUTCTime 명령) |
| CarbonDioxideConcentrationMeasurement | 0x040D | CO2 농도 구독 |
| Pm25ConcentrationMeasurement | 0x042A | PM2.5 농도 구독 |
| TemperatureMeasurement | 0x0402 | 온도 구독 |
| RelativeHumidityMeasurement | 0x0405 | 습도 구독 |

---

## 드라이버 배포 방법

### 사전 요구사항

- [SmartThings CLI](https://github.com/SmartThingsCommunity/smartthings-cli) 설치
- SmartThings 계정 및 Matter 지원 허브 (Aeotec v3 이상 또는 SmartThings Station)
- Thread Border Router 환경 (허브 내장 또는 별도 구성)

### 배포 명령어

```bash
# 드라이버 패키징 및 업로드
smartthings edge:drivers:package drivers/ikea-alpstuga

# 채널에 드라이버 등록
smartthings edge:channels:assign

# 허브에 드라이버 설치
smartthings edge:drivers:install
```

---

## 개발 참고 자료

- [SmartThings Matter Driver 공식 문서](https://developer.smartthings.com/docs/edge-device-drivers/matter/driver.html)
- [SmartThings Edge Driver SDK](https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers)
- [Matter Specification (Air Quality Sensor)](https://csa-iot.org/developer-resource/specifications-download-request/)
- [IKEA ALPSTUGA 제품 정보](https://www.ikea.com/us/en/p/alpstuga-air-quality-sensor-smart-70609396/)
