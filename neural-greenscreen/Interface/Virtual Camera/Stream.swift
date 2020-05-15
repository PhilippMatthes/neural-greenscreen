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
    private var lastDiffedCIImage: CIImage?
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
        
        let ciImage = CIImage(cvImageBuffer: pixelBuffer)
        
        // Reduce the battery impact: Use a diff to see how much the
        // stream moves. If the difference between the last diffed
        // frame is higher than an arbitrary threshold,
        // compute the mask more frequently.
        //
        // FIXME: This seems too much like a hack, but for the purpose of now, it works.
        if let lastDiffedCIImage = lastDiffedCIImage {
            if sequenceNumber % UInt64(webcamFrameRate) == 0 {
                let computedDiff = diff(ciImage1: ciImage, ciImage2: lastDiffedCIImage)
                
                if computedDiff == 255 {
                    self.observeAsynchronously(onPixelBuffer: pixelBuffer)
                } else if sequenceNumber % UInt64(webcamFrameRate * 8) == 0 {
                    self.observeAsynchronously(onPixelBuffer: pixelBuffer)
                }
                
                self.lastDiffedCIImage = ciImage
            }
        } else {
            self.lastDiffedCIImage = ciImage
        }
        
        if let mask = mask {
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
        raw: UnsafePointer<UInt8>, w: Int,h: Int
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
    
    func diff(ciImage1: CIImage, ciImage2: CIImage) -> Int {
        // Create the difference blend mode filter and set its properties.
        let diffFilter = CIFilter(name: "CIDifferenceBlendMode")!
        diffFilter.setDefaults()
        diffFilter.setValue(ciImage1, forKey: kCIInputImageKey)
        diffFilter.setValue(ciImage2, forKey: kCIInputBackgroundImageKey)
        
        // Create the area max filter and set its properties.
        let areaMaxFilter = CIFilter(name: "CIAreaMaximum")!
        areaMaxFilter.setDefaults()
        areaMaxFilter.setValue(diffFilter.value(forKey: kCIOutputImageKey),
            forKey: kCIInputImageKey)
        let compareRect = CGRect(x: 0.0, y: 0.0, width: 1280, height: 720)
        let extents = CIVector(cgRect: compareRect)
        areaMaxFilter.setValue(extents, forKey: kCIInputExtentKey)

        // The filters have been setup, now set up the CGContext bitmap context the
        // output is drawn to. Setup the context with our supplied buffer.
        let alphaInfo = CGImageAlphaInfo.premultipliedLast
        let bitmapInfo = CGBitmapInfo(rawValue: alphaInfo.rawValue)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var buf: [CUnsignedChar] = Array<CUnsignedChar>(repeating: 255, count: 16)
        let context = CGContext(
            data: &buf,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 16,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )!
        
        // Now create the core image context CIContext from the bitmap context.
        let ciContextOpts: [CIContextOption : Any] = [
            CIContextOption.workingColorSpace : colorSpace,
            CIContextOption.useSoftwareRenderer : false
        ]
        let ciContext = CIContext(cgContext: context, options: ciContextOpts)
        
        // Get the output CIImage and draw that to the Core Image context.
        let valueImage = areaMaxFilter.value(forKey: kCIOutputImageKey)! as! CIImage
        ciContext.draw(
            valueImage,
            in: CGRect(x: 0, y: 0, width: 1,height: 1),
            from: valueImage.extent
        )
        
        // This will have modified the contents of the buffer used for the CGContext.
        // Find the maximum value of the different color components. Remember that
        // the CGContext was created with a Premultiplied last meaning that alpha
        // is the fourth component with red, green and blue in the first three.
        return Int(max(buf[0], max(buf[1], buf[2])))
    }
    
    func observeAsynchronously(onPixelBuffer pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvImageBuffer: pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard
            let jpegData = NSBitmapImageRep(ciImage: ciImage)
                .representation(using: .jpeg, properties: [:])
        else {return}
        
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
            let maskCGImage = self.byteArrayToCGImage(raw: byteArray, w: width, h: height)!
            let maskCIImage = CIImage(cgImage: maskCGImage).applyingGaussianBlur(sigma: 2)
            
            self.mask = maskCIImage
        }
        task.resume()
    }
}
