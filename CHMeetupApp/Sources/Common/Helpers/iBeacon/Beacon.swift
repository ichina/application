//
//  Beacon.swift
//  CHMeetupApp
//
//  Created by Chingis Gomboev on 15/03/2018.
//  Copyright © 2018 CocoaHeads Community. All rights reserved.
//

import Foundation
import CoreBluetooth

protocol BeaconDelegate: class {
  func needDisconnect(beacon: Beacon, peripheral: CBPeripheral)
}

class Beacon: NSObject {

  internal let proximityUUID: UUID
  private(set) var userID: Int = 0 {
    didSet {
      if userID != 0 {
        self.state = .userIDReceived
      }
    }
  }
  private(set) var userName: String = ""
  private(set) var rssiStack: [Float] = []
  private(set) var lastRSSIAppended = Date()

  private(set) var state: BeaconState = .notEnoughRSSIData
  private(set) var proximityState: ProximityState = .unknown

  private(set) var peripheral: CBPeripheral?

  weak var delegate: BeaconDelegate?

  init(peripheral: CBPeripheral) {
    self.peripheral = peripheral
    self.proximityUUID = peripheral.identifier
  }

  init?(userID: Int, proximityUUIDString: String, name: String?) {
    guard let uuid = UUID(uuidString: proximityUUIDString) else { return nil }
    self.userID = userID
    self.proximityUUID = uuid
    self.userName = name ?? ""
    self.state = .userIDReceived
  }

  func append(rssi: Float) {
    rssiStack = rssiStack.filter { $0 > BeaconConstans.Scanner.PinaltyScore } //I'm alive -> remove aging values
    rssiStack.append(rssi)
    while rssiStack.count > 10 {
      rssiStack.remove(at: 0)
    }
    self.lastRSSIAppended = Date()
  }

  func checkForPenalty(now: Date = Date()) {
    // Check beacon did discovered in last 3 seconds, if no, than give them pinalty
    guard state == .userIDReceived else { return }
    if abs( now.timeIntervalSince(lastRSSIAppended)) > BeaconConstans.Scanner.PinaltyTimeout {
      //pinalty
      rssiStack.append(BeaconConstans.Scanner.PinaltyScore)
    }

  }

  func calculateProximity() {
    var proximity: Float = 0
    let rssiStack = self.rssiStack

    var i: Float = 0
    rssiStack.forEach { (rssi) in
      if rssi > -25 {
        var tempVal: Float = 0
        if i > 0 {
          tempVal = proximity / i
        }
        if tempVal > -25 {
          tempVal = -55
        }
        proximity += tempVal
      } else {
        proximity += rssi
      }
      i+=1
    }
    proximity /= 10.0
    var state: ProximityState
    if proximity < -200 {
      state = .unknown
    } else if proximity < -90 {
      state = .far
    } else if proximity < -72 {
      state = .near
    } else if proximity < 0 {
      state = .immediate
    } else {
      state = .unknown
    }
    self.proximityState = state
  }

  var discovered: Bool {
    return !rssiStack.isEmpty
  }
}

enum BeaconState {
  case notEnoughRSSIData
  case connecting
  case userIDReceived
}

enum ProximityState: Int {
  case immediate
  case near
  case far
  case unknown
}

extension Beacon: CBPeripheralDelegate {

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if error == nil {
      #if DEBUG_BEACON_SCANNING
      print("did discover services: \(peripheral.identifier.uuidString)")
      #endif
      if let service = peripheral.services?.first {
        peripheral.discoverCharacteristics([BeaconConstans.CharacteristicUUID], for: service)
      }
    } else {
      delegate?.needDisconnect(beacon: self, peripheral: peripheral)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    if error == nil, let characteristic = service.characteristics?.first {
      #if DEBUG_BEACON_SCANNING
      print("did discover characteristics: \(peripheral.identifier.uuidString)")
      #endif
      peripheral.readValue(for: characteristic)
    } else {
      delegate?.needDisconnect(beacon: self, peripheral: peripheral)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    defer {
      delegate?.needDisconnect(beacon: self, peripheral: peripheral)
    }

    guard error == nil,
      let data = characteristic.value,
      let newStrings = String(data: data, encoding: .utf8)?.components(separatedBy: ","),
      newStrings.count == 2,
      let userID = Int(newStrings.first ?? ""),
      let userName = newStrings.last else {
        return
    }

    self.userID = userID
    self.userName = userName
    self.peripheral = nil
  }
}
