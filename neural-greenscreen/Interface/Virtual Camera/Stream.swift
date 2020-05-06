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
    
    private var mask: CIImage?
    private var mostRecentlyEnqueuedVNRequest: VNRequest?
    private let dispatchSemaphore = DispatchSemaphore(value: 1)
    private var sequenceNumber: UInt64 = 0
    private var queueAlteredProc: CMIODeviceStreamQueueAlteredProc?
    private var queueAlteredRefCon: UnsafeMutableRawPointer?
    
    private var backgroundImage: CIImage?
    
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
        
        // Observe only once per second to reduce battery impact
        if sequenceNumber % UInt64(webcamFrameRate) == 0 {
            self.observeAsynchronously(onPixelBuffer: pixelBuffer)
        }
        
        if let mask = mask {
            let ciImage = CIImage(cvImageBuffer: pixelBuffer)
            var parameters = [String: Any]()
            parameters["inputMaskImage"] = mask
            if let backgroundImage = backgroundImage {
                parameters["inputBackgroundImage"] = backgroundImage
            }
            let maskedImage = ciImage.applyingFilter(
                "CIBlendWithMask",
                parameters: parameters
            )
            let context = CIContext(mtlDevice: mtlDevice)
            context.render(maskedImage, to: pixelBuffer)
        }
        
        self.dispatch(pixelBuffer: pixelBuffer, toStreamWithTiming: sampleTimingInfo)
    }
    
    func byteArrayToCGImage(
        raw: UnsafeMutablePointer<UInt8>, w: Int,h: Int
    ) -> CGImage? {

        let bytesPerPixel: Int = 1
        let bitsPerComponent: Int = 8
        let bitsPerPixel = bytesPerPixel * bitsPerComponent;
        let bytesPerRow: Int = w * bytesPerPixel;
        let cfData = CFDataCreate(nil, raw, w * h * bytesPerPixel)
        let cgDataProvider = CGDataProvider.init(data: cfData!)!

        let deviceColorSpace = CGColorSpaceCreateDeviceGray()

        return CGImage(
            width: w,
            height: h,
            bitsPerComponent: bitsPerComponent,
            bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytesPerRow,
            space: deviceColorSpace,
            bitmapInfo: [],
            provider: cgDataProvider,
            decode: nil,
            shouldInterpolate: true,
            intent: CGColorRenderingIntent.defaultIntent
        )
    }
    
    func observeAsynchronously(onPixelBuffer pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvImageBuffer: pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard
            let jpegData = NSBitmapImageRep(ciImage: ciImage)
                .representation(using: .jpeg, properties: [:])
        else {return}
        
        URLSession.shared.dataTask(
            with: URL(string: "https://localhost:9000/background")!,
            completionHandler: {
                data, response, error in
                guard
                    let data = data,
                    let backgroundImage = CIImage(data: data),
                    self.backgroundImage != backgroundImage
                else {return}
                self.backgroundImage = backgroundImage
            }
        ).resume()
        
        let url = URL(string: "https://localhost:9000/mask")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        
        let task = URLSession.shared.uploadTask(with: request, from: jpegData) {
            data, response, error in
            guard
                let response = response as? HTTPURLResponse,
                (200...299).contains(response.statusCode),
                error == nil,
                let data = data
            else {
                return
            }
            
            // Amplify neural decision values (0...1) to a black and white byte array (0...255)
            let byteArray = [UInt8](data).map {$0 * 255}
            var amplifiedData = Data(bytes: byteArray, count: byteArray.count)
            amplifiedData.withUnsafeMutableBytes {
                (bytes: UnsafeMutablePointer<UInt8>) -> Void in
                let maskCGImage = self.byteArrayToCGImage(raw: bytes, w: width, h: height)!
                let maskCIImage = CIImage(cgImage: maskCGImage)
                self.mask = maskCIImage
            }
        }
        task.resume()
    }
}
