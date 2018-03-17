//
//  BeaconScanner.swift
//  CHMeetupApp
//
//  Created by Chingis Gomboev on 12/03/2018.
//  Copyright © 2018 CocoaHeads Community. All rights reserved.
//

import Foundation
import CoreBluetooth
protocol BeaconScannerDelegate: class {
  func serviceFound(beacons: [Beacon])
}

class BeaconScanner: NSObject {

  // MARK: - Properties

  private var centralManager: CBCentralManager?

  private var reportTimer: Timer?
  private var processPeripheralsTimer: Timer?
  private var restartScanTimer: Timer?

  private var isDetecting: Bool = false

  weak var delegate: BeaconScannerDelegate?

  private var beaconsDetected = Set<Beacon>()

  override init() {
    super.init()
  }

  // MARK: - Public

  public func configure(with beacons: [Beacon]) {
    beacons.forEach { (beacon) in
      self.beaconsDetected.insert(beacon)
    }
  }
  public func startDetecting() {

    startDetectingBeacons()
  }

  public func stopDetecting() {
    isDetecting = false

    centralManager?.stopScan()
    centralManager = nil

    reportTimer?.invalidate()
    reportTimer = nil
  }

  // MARK: - Private

  private func startDetectingBeacons() {
    if centralManager == nil {
      centralManager = CBCentralManager(delegate: self, queue: nil)
    }
  }

  private func startScanning() {

    startReportTimer()
    startProcessPeripheralsTimer()

    let scanOptions: [String: Any] = [CBCentralManagerScanOptionAllowDuplicatesKey: true]

    centralManager?.scanForPeripherals(
      withServices: [BeaconConstans.ServiceUUID],
      options: scanOptions
    )
    isDetecting = true
  }

  @objc
  private func processPeripherals(_ timer: Timer) {
    let peripherals = beaconsDetected.filter { $0.state != .userIDReceived }.flatMap { $0.peripheral }
    if !peripherals.isEmpty {

      reportTimer?.invalidate()
      reportTimer = nil

      centralManager?.stopScan()

      peripherals.forEach { (peripheral) in
        #if DEBUG_BEACON_SCANNING
        print("connecting \(peripheral.identifier.uuidString)")
        #endif
        self.centralManager?.connect(peripheral, options: nil)
      }

      startRescanTimer()
    } else {
      startProcessPeripheralsTimer()
    }
  }

  private func startReportTimer() {
    reportTimer?.invalidate()
    reportTimer = Timer.scheduledTimer(
      timeInterval: BeaconConstans.Scanner.UpdateInterval,
      target: self, selector: #selector(BeaconScanner.reportRangesToDelegate(_:)),
      userInfo: nil, repeats: true
    )
  }

  private func startProcessPeripheralsTimer() {
    processPeripheralsTimer?.invalidate()
    processPeripheralsTimer = Timer.scheduledTimer(
      timeInterval: BeaconConstans.Scanner.ProcessPeripheralInterval,
      target: self,
      selector: #selector(BeaconScanner.processPeripherals(_:)),
      userInfo: nil, repeats: false
    )
  }

  private func startRescanTimer() {
    restartScanTimer?.invalidate()
    restartScanTimer = Timer.scheduledTimer(
      timeInterval: BeaconConstans.Scanner.RestartScanInterval,
      target: self,
      selector: #selector(BeaconScanner.restartScan(_:)),
      userInfo: nil, repeats: false
    )
  }

  @objc
  private func restartScan(_ timer: Timer) {
    beaconsDetected
      .filter { $0.peripheral?.state == .connecting || $0.peripheral?.state == .connected }
      .forEach { beacon in
        if let peripheral = beacon.peripheral {
          self.centralManager?.cancelPeripheralConnection(peripheral)
        }
    }

    let scanOptions: [String: Any] = [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    centralManager?.scanForPeripherals(withServices: [BeaconConstans.ServiceUUID],
                                       options: scanOptions)

    startReportTimer()

    startProcessPeripheralsTimer()
  }

  @objc
  private func reportRangesToDelegate(_ timer: Timer) {
    let now = Date()
    let beacons = beaconsDetected.filter({ beacon in
      guard beacon.state == .userIDReceived, beacon.discovered else { return false }
      beacon.checkForPenalty(now: now)
      beacon.calculateProximity()
      return beacon.proximityState == .immediate
    })
    delegate?.serviceFound(beacons: Array(beacons))
  }
}

extension BeaconScanner: CBCentralManagerDelegate {

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    #if DEBUG_BEACON_SCANNING
    print("central state changed: \(central.state.rawValue)")
    #endif
    if central.state == .poweredOn {
      startScanning()
    }
  }

  func centralManager(_ central: CBCentralManager,
                      didDiscover peripheral: CBPeripheral,
                      advertisementData: [String: Any],
                      rssi RSSI: NSNumber) {
    #if DEBUG_BEACON_SCANNING
    print("did discover peripheral: \(peripheral.identifier.uuidString), \(RSSI.floatValue)")
    #endif

    if let beacon = beaconsDetected.first(where: {$0.proximityUUID == peripheral.identifier}) {
      beacon.append(rssi: RSSI.floatValue)
    } else {
      let beacon = Beacon(peripheral: peripheral)
      beacon.delegate = self
      beacon.append(rssi: RSSI.floatValue)
      beaconsDetected.insert(beacon)
    }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    #if DEBUG_BEACON_SCANNING
    print("did connect peripheral: \(peripheral.identifier.uuidString)")
    #endif

    if let beacon = beaconsDetected.first(where: {$0.peripheral == peripheral}) {
      peripheral.delegate = beacon
    }
    peripheral.discoverServices([BeaconConstans.ServiceUUID])
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    if let err = error {
      #if DEBUG_BEACON_SCANNING
      print("fail connect peripheral: \(err)")
      #endif
    }
  }
}

extension BeaconScanner: BeaconDelegate {
  func needDisconnect(beacon: Beacon, peripheral: CBPeripheral) {
    centralManager?.cancelPeripheralConnection(peripheral)
    let processingPeripherals = beaconsDetected.flatMap { $0.peripheral }
    if let restartTimer = restartScanTimer, restartTimer.isValid, processingPeripherals.isEmpty {
      restartTimer.invalidate()
      restartScan(restartTimer)
    }
  }
}
