/*
* Copyright (c) 2016, Nordic Semiconductor
* All rights reserved.
*
* Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:
*
* 1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
*
* 2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the
* documentation and/or other materials provided with the distribution.
*
* 3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this
* software without specific prior written permission.
*
* THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
* LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
* HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
* LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
* ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE
* USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

import CoreBluetooth

internal class SecureDFUPacket {
    static private let UUID = CBUUID(string: "00001532-1212-EFDE-1523-785FEABCD123")
    
    static func matches(characteristic:CBCharacteristic) -> Bool {
        return characteristic.UUID.isEqual(UUID)
    }
    
    private let PacketSize = 20
    
    private var characteristic:CBCharacteristic
    private var logger:LoggerHelper
    
    /// Number of bytes of firmware already sent.
    private(set) var bytesSent = 0
    
    /// Current progress in percents (0-99).
    private var progress = 0
    private var startTime:CFAbsoluteTime?
    private var lastTime:CFAbsoluteTime?

    var valid:Bool {
        return characteristic.properties.contains(CBCharacteristicProperties.WriteWithoutResponse)
    }
    
    init(_ characteristic:CBCharacteristic, _ logger:LoggerHelper) {
        self.characteristic = characteristic
        self.logger = logger
    }
    
    // MARK: - Characteristic API methods
    func sendInitPacket(initPacketData : NSData){
        // Get the peripheral object
        let peripheral = characteristic.service.peripheral
        
        // Data may be sent in up-to-20-bytes packets
        var offset = 0
        var bytesToSend = initPacketData.length
        
        repeat {

            let packetLength = min(bytesToSend, PacketSize)
            let packet = initPacketData.subdataWithRange(NSRange(location: offset, length: packetLength))
            
            logger.v("Writing to characteristic \(SecureDFUPacket.UUID.UUIDString)...")
            logger.d("peripheral.writeValue(0x\(packet.hexString), forCharacteristic: \(SecureDFUPacket.UUID.UUIDString), type: WithoutResponse)")
            peripheral.writeValue(packet, forCharacteristic: characteristic, type: CBCharacteristicWriteType.WithoutResponse)
            
            offset += packetLength
            bytesToSend -= packetLength
        } while bytesToSend > 0
    }
    
    func resumeFromOffset(anOffset : UInt32) {
        self.bytesSent = Int(anOffset)
        startTime = CFAbsoluteTimeGetCurrent()
        lastTime = startTime
    }

    /**
     Sends next number of packets from given firmware data and reports a progress.
     This method does not notify progress delegate twice about the same percentage.
     
     - parameter number:           number of packets to be sent before a Packet Receipt Notification is expected.
     Set to 0 to disable Packet Receipt Notification procedure (not recommended)
     - parameter firmware:         the firmware to be sent
     - parameter progressDelegate: an optional progress delegate
     */
    func sendNext(number:UInt16, packetsOf firmware:DFUFirmware, andReportProgressTo progressDelegate:SecureDFUProgressDelegate?, andCompletion completion: SDFUCallback) {

        // Get the peripheral object
        let peripheral = characteristic.service.peripheral
        
        // Some super complicated computations...
        let bytesTotal   = firmware.data.length
        let totalPackets = (bytesTotal + PacketSize - 1) / PacketSize
        let packetsSent  = (bytesSent + PacketSize - 1) / PacketSize
        let packetsLeft  = totalPackets - packetsSent

        // Calculate how many packets should be sent before EOF or next receipt notification
        var packetsToSendNow = min(Int(number), packetsLeft)
        if number == 0 {
            // When Packet Receipt Notification procedure is disabled, the service will send all data here
            packetsToSendNow = totalPackets
        }
        
        // Initialize timers
        if bytesSent == 0 {
            startTime = CFAbsoluteTimeGetCurrent()
            lastTime = startTime
        }
        
        while packetsToSendNow > 0 {

            let bytesLeft = bytesTotal - bytesSent
            let packetLength = min(bytesLeft, PacketSize)
            let packet = firmware.data.subdataWithRange(NSRange(location: bytesSent, length: packetLength))
            peripheral.writeValue(packet, forCharacteristic: characteristic, type: CBCharacteristicWriteType.WithoutResponse)

            bytesSent += packetLength
            packetsToSendNow -= 1

            // Calculate current transfer speed in bytes per second
            let now = CFAbsoluteTimeGetCurrent()
            let currentSpeed = Double(packetLength) / (now - lastTime!)
            lastTime = now
            
            // Calculate progress
            let currentProgress = (bytesSent * 100 / bytesTotal) // in percantage (0-100)

            // Notify progress listener
            if currentProgress > progress {
                let avgSpeed = Double(bytesSent) / (now - startTime!)
                
                dispatch_async(dispatch_get_main_queue(), {
                    progressDelegate?.onUploadProgress(
                        firmware.currentPart,
                        totalParts: firmware.parts,
                        progress: currentProgress,
                        currentSpeedBytesPerSecond: currentSpeed,
                        avgSpeedBytesPerSecond: avgSpeed)
                    if currentProgress == 100 {
                        completion(responseData: nil)
                    }
                })
                progress = currentProgress
            }
        }
    }
}