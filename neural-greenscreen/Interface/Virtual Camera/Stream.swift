//
//    MIT License
//
//    Copyright (c) 2020 John Boiles
//    Copyright (c) 2020 Ryohei Ikegami
//    Copyright (c) 2020 Philipp Matthes
//
//    Permission is hereby granted, free of charge, to any person obtaining a copy
//    of this software and associated documentation files (the "Software"), to deal
//    in the Software without restriction, including without limitation the rights
//    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//    copies of the Software, and to permit persons to whom the Software is
//    furnished to do so, subject to the following conditions:
//
//    The above copyright notice and this permission notice shall be included in all
//    copies or substantial portions of the Software.
//
//    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//    SOFTWARE.

import Foundation
import AVFoundation
import AppKit
import Vision
import CoreText
import Accelerate
import VideoToolbox


class Stream: NSObject, Object {
    var objectID: CMIOObjectID = 0
    let name = "Neural Greenscreen"
    let width = 1280
    let height = 720
    let webcamFrameRate = 30

    let greenscreen = NeuralGreenscreen()
    var currentGreenscreenBuffer: CVPixelBuffer?
    
    private var sequenceNumber: UInt64 = 0
    private var queueAlteredProc: CMIODeviceStreamQueueAlteredProc?
    private var queueAlteredRefCon: UnsafeMutableRawPointer?

    private lazy var mtlDevice = MTLCreateSystemDefaultDevice()!
    
    private lazy var capture = VideoCapture()

    private lazy var formatDescription: CMVideoFormatDescription? = {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32ARGB,
            width: Int32(width),
            height: Int32(height),
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr else {return nil}
        return formatDescription
    }()

    private lazy var clock: CFTypeRef? = {
        var clock: Unmanaged<CFTypeRef>? = nil
        guard CMIOStreamClockCreate(
            kCFAllocatorDefault,
            "Neural Greenscreen clock" as CFString,
            Unmanaged.passUnretained(self).toOpaque(),
            CMTimeMake(value: 1, timescale: 10),
            100,
            10,
            &clock
        ) == noErr else {return nil}
        return clock?.takeUnretainedValue()
    }()

    private lazy var queue: CMSimpleQueue? = {
        var queue: CMSimpleQueue?
        guard CMSimpleQueueCreate(
            allocator: kCFAllocatorDefault,
            capacity: 30,
            queueOut: &queue
        ) == noErr else {return nil}
        return queue
    }()

    lazy var properties: [Int : Property] = [
        kCMIOObjectPropertyName: Property(name),
        kCMIOStreamPropertyFormatDescription: Property(formatDescription!),
        kCMIOStreamPropertyFormatDescriptions: Property([formatDescription!] as CFArray),
        kCMIOStreamPropertyDirection: Property(UInt32(0)),
        kCMIOStreamPropertyFrameRate: Property(Float64(webcamFrameRate)),
        kCMIOStreamPropertyFrameRates: Property(Float64(webcamFrameRate)),
        kCMIOStreamPropertyMinimumFrameRate: Property(Float64(0)),
        kCMIOStreamPropertyFrameRateRanges: Property(AudioValueRange(
            mMinimum: Float64(0), mMaximum: Float64(webcamFrameRate)
        )),
        kCMIOStreamPropertyClock: Property(CFTypeRefWrapper(ref: clock!)),
    ]

    func start() {
        capture.delegate = self
        capture.setUp()
        capture.start()

        // Entrypoint to perform any other startup operations.
        greenscreen.delegate = self
    }

    func stop() {
        capture.stop()
    }

    func copyBufferQueue(
        queueAlteredProc: CMIODeviceStreamQueueAlteredProc?,
        queueAlteredRefCon: UnsafeMutableRawPointer?
    ) -> CMSimpleQueue? {
        self.queueAlteredProc = queueAlteredProc
        self.queueAlteredRefCon = queueAlteredRefCon
        return self.queue
    }
}

extension Stream: VideoCaptureDelegate {
    func dispatch(pixelBuffer: CVPixelBuffer, toStreamWithTiming timing: CMSampleTimingInfo) {
        guard
            let queue = queue,
            CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue)
        else {return}
        
        let currentTimeNsec = mach_absolute_time()
        var mutableTiming = timing
        
        guard CMIOStreamClockPostTimingEvent(
            timing.presentationTimeStamp,
            currentTimeNsec,
            true,
            self.clock
        ) == noErr else {return}

        var formatDescription: CMFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr else {return}

        var sampleBufferUnmanaged: Unmanaged<CMSampleBuffer>? = nil
        guard CMIOSampleBufferCreateForImageBuffer(
            kCFAllocatorDefault,
            pixelBuffer,
            formatDescription,
            &mutableTiming,
            self.sequenceNumber,
            UInt32(kCMIOSampleBufferNoDiscontinuities),
            &sampleBufferUnmanaged
        ) == noErr else {return}

        CMSimpleQueueEnqueue(queue, element: sampleBufferUnmanaged!.toOpaque())
        self.queueAlteredProc?(
            self.objectID,
            sampleBufferUnmanaged!.toOpaque(),
            self.queueAlteredRefCon
        )

        self.sequenceNumber += 1
    }
    
    func videoCapture(
        _ capture: VideoCapture,
        didCapture pixelBuffer: CVPixelBuffer?,
        with sampleTimingInfo: CMSampleTimingInfo
    ) {
        guard
            let pixelBuffer = pixelBuffer
        else {return}

        // Remove the background
        DispatchQueue.global(qos: .background).async {
            if self.sequenceNumber % 10 == 0 {
                do {
                    try self.greenscreen.replaceBackground(onPixelBuffer: pixelBuffer)
                } catch {
                    log(error)
                }
            }
        }

        if let greenscreenBuffer = currentGreenscreenBuffer {
            self.dispatch(
                pixelBuffer: greenscreenBuffer,
                toStreamWithTiming: sampleTimingInfo
            )
        } else {
            self.dispatch(
                pixelBuffer: pixelBuffer,
                toStreamWithTiming: sampleTimingInfo
            )
        }
    }
}

extension Stream: NeuralGreenscreenDelegate {
    func didReplaceBackground(onProcessedPixelBuffer pixelBuffer: CVPixelBuffer) {
        log("Received processed buffer")
        self.currentGreenscreenBuffer = pixelBuffer
    }
}
