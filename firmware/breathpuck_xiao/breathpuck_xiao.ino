// BreathPuck v0 firmware for the Seeed XIAO nRF52840 Sense.
//
// Streams the on-board LSM6DS3TR-C accelerometer to the phone at 25 Hz and
// drives a Vybronics VLV101040A LRA through an Adafruit DRV2605L breakout from
// the amplitude the phone sends at 50 Hz. The Bluetooth contract is the one in
// BreathPuck/Sources/PuckBLE.swift; change it there first, then here.
//
//   service  7A0B0001-6F3C-4D2E-9B1A-0B7E47B5C001
//   IMU      7A0B0002-…  notify, 8 bytes little-endian: int16 ax, ay, az at
//                        8192 counts/g, uint16 sequence. 25 Hz.
//   haptic   7A0B0003-…  write without response, 1 byte amplitude 0…127.
//   battery  0x180F / 0x2A19 standard battery level, percent.
//
// Wiring (through the ribbon to the inner disc): 3V3, GND, D4 SDA, D5 SCL to
// the DRV2605L; the LRA on the DRV2605L's motor terminals. LiPo on the pads
// under the XIAO. The IMU is inside the XIAO on its own bus.
//
// Board: Seeed nRF52 Boards → Seeed XIAO nRF52840 Sense (not the mbed variant).
// Libraries: Seeed Arduino LSM6DS3, Adafruit DRV2605 Library. See README.md.

#include <bluefruit.h>
#include <Wire.h>
#include <LSM6DS3.h>
#include <Adafruit_DRV2605.h>
#include <Adafruit_LittleFS.h>
#include <InternalFileSystem.h>

using namespace Adafruit_LittleFS_Namespace;

// ---- tunables ---------------------------------------------------------------

static const char   DEVICE_NAME[]      = "BreathPuck";
static const uint32_t IMU_PERIOD_MS    = 40;    // 25 Hz
static const uint32_t HAPTIC_TICK_MS   = 10;    // slew update rate
static const uint8_t  HAPTIC_SLEW      = 32;    // max counts per tick (0 → 127 in 40 ms)
static const uint32_t HAPTIC_WATCHDOG  = 1000;  // ms without a write → amplitude 0
static const uint32_t HAPTIC_IDLE_MS   = 2000;  // ms at zero before the driver sleeps
static const uint32_t BATTERY_PERIOD   = 10000; // ms

// LRA parameters. Check these against the VLV101040A datasheet before the
// first run; they set the drive voltage. Closed-loop mode keeps the average at
// the rated voltage and auto-resonance finds the frequency.
static const float LRA_RATED_VRMS   = 2.0f;   // datasheet "rated voltage"
static const float LRA_CLAMP_VPEAK  = 2.8f;   // never drive above this
static const float LRA_FREQ_HZ      = 170.0f;

// ---- Bluetooth --------------------------------------------------------------

// 128-bit UUIDs, least significant byte first.
#define PUCK_UUID(b0) { 0x01, 0xC0, 0xB5, 0x47, 0x7E, 0x0B, 0x1A, 0x9B, \
                        0x2E, 0x4D, 0x3C, 0x6F, b0, 0x00, 0x0B, 0x7A }
static const uint8_t UUID_SERVICE[16] = PUCK_UUID(0x01);
static const uint8_t UUID_IMU[16]     = PUCK_UUID(0x02);
static const uint8_t UUID_HAPTIC[16]  = PUCK_UUID(0x03);

BLEService        puckService(UUID_SERVICE);
BLECharacteristic imuChar(UUID_IMU);
BLECharacteristic hapticChar(UUID_HAPTIC);
BLEBas            batteryService;

// ---- hardware ---------------------------------------------------------------

LSM6DS3 imu(I2C_MODE, 0x6A);   // the Seeed library uses Wire1, the XIAO's internal bus, on this board

Adafruit_DRV2605 drv;
static bool drvPresent = false;
static bool imuPresent = false;

// ---- state ------------------------------------------------------------------

static volatile uint8_t  hapticTarget   = 0;
static volatile uint32_t hapticLastWrite = 0;
static uint8_t  hapticCurrent = 0;
static bool     drvAsleep     = true;
static uint32_t hapticZeroSince = 0;
static uint16_t seq = 0;
static uint8_t  batteryPercent = 0;

// ---- DRV2605L: LRA setup, calibration, real-time playback ------------------

struct DrvCal { uint8_t magic; uint8_t comp; uint8_t bemf; uint8_t bemfGain; };
static const char CAL_PATH[] = "/drvcal.bin";
static const uint8_t CAL_MAGIC = 0xA7;

uint8_t ratedVoltageReg() {
  // Datasheet eq. for LRA closed loop with SAMPLE_TIME = 300 us:
  // V_rms = 20.58e-3 * RATED * sqrt(1 - (4*300e-6 + 300e-6) * f)
  float k = sqrtf(1.0f - (4.0f * 300e-6f + 300e-6f) * LRA_FREQ_HZ);
  float v = LRA_RATED_VRMS / (20.58e-3f * k);
  return (uint8_t)constrain(lroundf(v), 0, 255);
}

uint8_t clampVoltageReg() {
  // V_peak ≈ 21.22e-3 * OD_CLAMP for an LRA (datasheet, blanking/idiss terms ≈ 1)
  float v = LRA_CLAMP_VPEAK / 21.22e-3f;
  return (uint8_t)constrain(lroundf(v), 0, 255);
}

uint8_t driveTimeReg() {
  // DRIVE_TIME: half the LRA period, (t_half - 0.5 ms) / 0.1 ms
  float halfMs = 500.0f / LRA_FREQ_HZ;
  return (uint8_t)constrain(lroundf((halfMs - 0.5f) / 0.1f), 0, 31);
}

void drvConfigureLRA() {
  drv.writeRegister8(DRV2605_REG_RATEDV, ratedVoltageReg());
  drv.writeRegister8(DRV2605_REG_CLAMPV, clampVoltageReg());
  // FEEDBACK: N_ERM_LRA=1, FB_BRAKE_FACTOR=4x (011), LOOP_GAIN=medium (01), keep BEMF_GAIN
  uint8_t fb = drv.readRegister8(DRV2605_REG_FEEDBACK);
  fb = (fb & 0x03) | 0x80 | (0x03 << 4) | (0x01 << 2);
  drv.writeRegister8(DRV2605_REG_FEEDBACK, fb);
  // CONTROL1: keep STARTUP_BOOST, set DRIVE_TIME
  uint8_t c1 = drv.readRegister8(DRV2605_REG_CONTROL1);
  drv.writeRegister8(DRV2605_REG_CONTROL1, (c1 & 0xE0) | driveTimeReg());
  // CONTROL3: closed-loop LRA (LRA_OPEN_LOOP=0), signed RTP data (DATA_FORMAT_RTP=0)
  uint8_t c3 = drv.readRegister8(DRV2605_REG_CONTROL3);
  drv.writeRegister8(DRV2605_REG_CONTROL3, c3 & ~0x09);
  drv.selectLibrary(6);   // LRA library, only matters for waveform mode
}

bool drvLoadCal() {
  File f(InternalFS);
  if (!f.open(CAL_PATH, FILE_O_READ)) return false;
  DrvCal c;
  int n = f.read((uint8_t*)&c, sizeof c);
  f.close();
  if (n != (int)sizeof c || c.magic != CAL_MAGIC) return false;
  drv.writeRegister8(DRV2605_REG_AUTOCALCOMP, c.comp);
  drv.writeRegister8(DRV2605_REG_AUTOCALEMP, c.bemf);
  uint8_t fb = drv.readRegister8(DRV2605_REG_FEEDBACK);
  drv.writeRegister8(DRV2605_REG_FEEDBACK, (fb & ~0x03) | (c.bemfGain & 0x03));
  Serial.printf("DRV cal loaded: comp %u bemf %u gain %u\n", c.comp, c.bemf, c.bemfGain);
  return true;
}

// Runs the DRV2605L auto-calibration (the motor buzzes for about a second) and
// stores the result in flash. Call with the LRA mounted in its disc, since the
// mechanical load changes the result.
bool drvCalibrate() {
  Serial.println("DRV auto-calibration…");
  drvConfigureLRA();
  // CONTROL4: AUTO_CAL_TIME = 1000 ms (11)
  uint8_t c4 = drv.readRegister8(DRV2605_REG_CONTROL4);
  drv.writeRegister8(DRV2605_REG_CONTROL4, (c4 & ~0x30) | 0x30);
  drv.setMode(DRV2605_MODE_AUTOCAL);
  drv.go();
  uint32_t t0 = millis();
  while (drv.readRegister8(DRV2605_REG_GO) & 0x01) {
    if (millis() - t0 > 3000) { Serial.println("DRV cal timeout"); return false; }
    delay(10);
  }
  bool failed = drv.readRegister8(DRV2605_REG_STATUS) & 0x08;
  if (failed) { Serial.println("DRV cal failed (DIAG_RESULT). Is the LRA connected?"); return false; }
  DrvCal c;
  c.magic = CAL_MAGIC;
  c.comp = drv.readRegister8(DRV2605_REG_AUTOCALCOMP);
  c.bemf = drv.readRegister8(DRV2605_REG_AUTOCALEMP);
  c.bemfGain = drv.readRegister8(DRV2605_REG_FEEDBACK) & 0x03;
  InternalFS.remove(CAL_PATH);
  File f(InternalFS);
  if (f.open(CAL_PATH, FILE_O_WRITE)) { f.write((uint8_t*)&c, sizeof c); f.close(); }
  Serial.printf("DRV cal ok: comp %u bemf %u gain %u\n", c.comp, c.bemf, c.bemfGain);
  return true;
}

void drvWake() {
  if (!drvAsleep) return;
  drv.setMode(DRV2605_MODE_REALTIME);   // clears STANDBY
  drvAsleep = false;
}

void drvSleep() {
  if (drvAsleep) return;
  drv.setRealtimeValue(0);
  drv.writeRegister8(DRV2605_REG_MODE, 0x40 | DRV2605_MODE_REALTIME);  // STANDBY
  drvAsleep = true;
}

void hapticTick(uint32_t now) {
  uint8_t target = hapticTarget;
  if (now - hapticLastWrite > HAPTIC_WATCHDOG) target = 0;
  if (!Bluefruit.connected()) target = 0;

  if (target > hapticCurrent) hapticCurrent = min<int>(target, hapticCurrent + HAPTIC_SLEW);
  else if (target < hapticCurrent) hapticCurrent = max<int>(target, hapticCurrent - HAPTIC_SLEW);

  if (!drvPresent) return;
  if (hapticCurrent > 0) {
    drvWake();
    drv.setRealtimeValue(hapticCurrent & 0x7F);
    hapticZeroSince = now;
  } else if (!drvAsleep) {
    drv.setRealtimeValue(0);
    if (now - hapticZeroSince > HAPTIC_IDLE_MS) drvSleep();
  }
}

// ---- battery ----------------------------------------------------------------

float readBatteryVolts() {
#if defined(PIN_VBAT) && defined(VBAT_ENABLE)
  digitalWrite(VBAT_ENABLE, LOW);        // connect the divider
  delayMicroseconds(100);
  analogReference(AR_INTERNAL_2_4);
  analogReadResolution(12);
  uint32_t raw = 0;
  for (int i = 0; i < 8; i++) raw += analogRead(PIN_VBAT);
  digitalWrite(VBAT_ENABLE, HIGH);       // disconnect to save the battery
  float v = (raw / 8.0f) * 2.4f / 4096.0f;
  return v * (1510.0f / 510.0f);         // 1 M + 510 k divider on the XIAO
#else
  return 0;
#endif
}

uint8_t voltsToPercent(float v) {
  // Resting LiPo curve, coarse. Good enough for a battery icon.
  static const float vs[] = {3.30f, 3.50f, 3.60f, 3.70f, 3.80f, 3.90f, 4.00f, 4.10f, 4.20f};
  static const uint8_t ps[] = {0, 5, 15, 35, 55, 70, 85, 95, 100};
  if (v <= vs[0]) return 0;
  for (int i = 1; i < 9; i++) {
    if (v < vs[i]) return ps[i-1] + (uint8_t)((v - vs[i-1]) / (vs[i] - vs[i-1]) * (ps[i] - ps[i-1]));
  }
  return 100;
}

void batteryTick() {
  float v = readBatteryVolts();
  uint8_t p = voltsToPercent(v);
  if (p != batteryPercent) {
    batteryPercent = p;
    batteryService.write(p);
    if (Bluefruit.connected()) batteryService.notify(p);
  }
}

// ---- BLE callbacks ----------------------------------------------------------

void onHapticWrite(uint16_t conn_hdl, BLECharacteristic* chr, uint8_t* data, uint16_t len) {
  (void)conn_hdl; (void)chr;
  if (len < 1) return;
  hapticTarget = data[0] & 0x7F;
  hapticLastWrite = millis();
}

void onConnect(uint16_t conn_hdl) {
  BLEConnection* c = Bluefruit.Connection(conn_hdl);
  c->requestConnectionParameter(12, 24);   // 15–30 ms, enough for 50 Hz writes + 25 Hz notifies
  Serial.println("connected");
  digitalWrite(LED_BLUE, HIGH);            // off (active low)
}

void onDisconnect(uint16_t conn_hdl, uint8_t reason) {
  (void)conn_hdl;
  Serial.printf("disconnected, reason 0x%02X\n", reason);
  hapticTarget = 0;
}

void setupBLE() {
  Bluefruit.configPrphConn(23, BLE_GAP_EVENT_LENGTH_MIN, 16, 16);
  Bluefruit.begin();
  Bluefruit.setTxPower(0);
  Bluefruit.setName(DEVICE_NAME);
  Bluefruit.Periph.setConnectCallback(onConnect);
  Bluefruit.Periph.setDisconnectCallback(onDisconnect);
  Bluefruit.Periph.setConnInterval(12, 24);

  puckService.begin();

  imuChar.setProperties(CHR_PROPS_NOTIFY);
  imuChar.setPermission(SECMODE_OPEN, SECMODE_NO_ACCESS);
  imuChar.setFixedLen(8);
  imuChar.begin();

  hapticChar.setProperties(CHR_PROPS_WRITE_WO_RESP | CHR_PROPS_WRITE);
  hapticChar.setPermission(SECMODE_NO_ACCESS, SECMODE_OPEN);
  hapticChar.setFixedLen(1);
  hapticChar.setWriteCallback(onHapticWrite);
  hapticChar.begin();

  batteryService.begin();
  batteryService.write(batteryPercent);

  Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
  Bluefruit.Advertising.addTxPower();
  Bluefruit.Advertising.addService(puckService);
  Bluefruit.ScanResponse.addName();
  Bluefruit.Advertising.restartOnDisconnect(true);
  Bluefruit.Advertising.setInterval(32, 244);   // 20 ms fast, 152.5 ms slow
  Bluefruit.Advertising.setFastTimeout(30);
  Bluefruit.Advertising.start(0);
}

// ---- IMU --------------------------------------------------------------------

void setupIMU() {
#ifdef PIN_LSM6DS3TR_C_POWER
  pinMode(PIN_LSM6DS3TR_C_POWER, OUTPUT);
  digitalWrite(PIN_LSM6DS3TR_C_POWER, HIGH);
  delay(10);
#endif
  imu.settings.gyroEnabled = 0;          // not used, saves ~0.5 mA
  imu.settings.accelEnabled = 1;
  imu.settings.accelRange = 4;           // ±4 g → 0.122 mg/LSB ≈ 8192 counts/g
  imu.settings.accelSampleRate = 52;     // read every 40 ms, so always a fresh sample
  imu.settings.accelBandWidth = 50;
  imu.settings.tempEnabled = 0;
  imuPresent = (imu.begin() == 0);
  Serial.println(imuPresent ? "IMU ok" : "IMU not found");
}

void imuTick() {
  uint8_t pkt[8];
  int16_t ax = 0, ay = 0, az = 0;
  if (imuPresent) {
    ax = imu.readRawAccelX();
    ay = imu.readRawAccelY();
    az = imu.readRawAccelZ();
  }
  // little-endian, matches loadUnaligned(Int16) on the phone
  pkt[0] = ax & 0xFF; pkt[1] = ax >> 8;
  pkt[2] = ay & 0xFF; pkt[3] = ay >> 8;
  pkt[4] = az & 0xFF; pkt[5] = az >> 8;
  pkt[6] = seq & 0xFF; pkt[7] = seq >> 8;
  seq++;
  if (Bluefruit.connected()) imuChar.notify(pkt, sizeof pkt);
}

// ---- serial commands --------------------------------------------------------

void serialTick() {
  while (Serial.available()) {
    char c = Serial.read();
    switch (c) {
      case 'c': if (drvPresent) { hapticTarget = 0; drvSleep(); drvCalibrate(); } break;
      case 'b': Serial.printf("battery %.2f V, %u%%\n", readBatteryVolts(), voltsToPercent(readBatteryVolts())); break;
      case 't':
        if (drvPresent) {
          Serial.println("test buzz 1 s at 60%");
          drvWake(); drv.setRealtimeValue(76); delay(1000); drv.setRealtimeValue(0);
        }
        break;
      case 'i':
        Serial.printf("accel %d %d %d (counts, 8192/g)\n", imu.readRawAccelX(), imu.readRawAccelY(), imu.readRawAccelZ());
        break;
      case '?':
        Serial.println("c=calibrate LRA  t=test buzz  b=battery  i=accel");
        break;
      default: break;
    }
  }
}

// ---- setup / loop -----------------------------------------------------------

void setup() {
  Serial.begin(115200);
  uint32_t t0 = millis();
  while (!Serial && millis() - t0 < 2000) delay(10);   // don't wait forever on battery
  Serial.println("BreathPuck v0");

  pinMode(LED_RED, OUTPUT);   digitalWrite(LED_RED, HIGH);
  pinMode(LED_GREEN, OUTPUT); digitalWrite(LED_GREEN, HIGH);
  pinMode(LED_BLUE, OUTPUT);  digitalWrite(LED_BLUE, HIGH);

#if defined(PIN_VBAT) && defined(VBAT_ENABLE)
  pinMode(VBAT_ENABLE, OUTPUT);
  digitalWrite(VBAT_ENABLE, HIGH);
#endif
#ifdef PIN_CHARGING_CURRENT
  pinMode(PIN_CHARGING_CURRENT, OUTPUT);
  digitalWrite(PIN_CHARGING_CURRENT, HIGH);   // 50 mA charge: right for a 100 mAh cell
#endif

  InternalFS.begin();

  Wire.begin();
  Wire.setClock(400000);
  drvPresent = drv.begin(&Wire);
  if (drvPresent) {
    drvConfigureLRA();
    if (!drvLoadCal()) {
      Serial.println("no stored LRA calibration; send 'c' over serial with the LRA mounted");
    }
    drvSleep();
    Serial.println("DRV2605L ok");
  } else {
    Serial.println("DRV2605L not found on D4/D5");
    digitalWrite(LED_RED, LOW);
  }

  setupIMU();
  setupBLE();
  batteryTick();
  Serial.println("advertising as BreathPuck. '?' for commands");
}

void loop() {
  static uint32_t nextImu = 0, nextHaptic = 0, nextBattery = 0, nextBlink = 0;
  uint32_t now = millis();

  if ((int32_t)(now - nextImu) >= 0)     { nextImu += IMU_PERIOD_MS; if (nextImu < now) nextImu = now + IMU_PERIOD_MS; imuTick(); }
  if ((int32_t)(now - nextHaptic) >= 0)  { nextHaptic = now + HAPTIC_TICK_MS; hapticTick(now); }
  if ((int32_t)(now - nextBattery) >= 0) { nextBattery = now + BATTERY_PERIOD; batteryTick(); }
  if ((int32_t)(now - nextBlink) >= 0) {
    nextBlink = now + (Bluefruit.connected() ? 1000 : 500);
    if (!Bluefruit.connected()) digitalWrite(LED_BLUE, !digitalRead(LED_BLUE));
  }
  serialTick();
  delay(1);   // FreeRTOS idle, lets the radio and the CPU sleep between ticks
}
