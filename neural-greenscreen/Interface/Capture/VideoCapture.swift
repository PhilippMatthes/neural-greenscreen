//
//    MIT License
//
//    Copyright (c) 2018 Eugene Bokhan
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

import AVFoundation

public protocol VideoCaptureDelegate: AnyObject {
    func videoCapture(
        _ capture: VideoCapture,
        didCapture pixelBuffer: CVPixelBuffer?,
        with sampleTimingInfo: CMSampleTimingInfo
    )
}

extension VideoCaptureDelegate {
    func videoCapture(
        _ capture: VideoCapture,
        didDrop pixelBuffer: CVPixelBuffer?,
        with sampleTimingInfo: CMSampleTimingInfo
    ) {}
}

public class VideoCapture: NSObject {
    public weak var delegate: VideoCaptureDelegate?
    
    public var desiredFPS = 30
    
    private lazy var captureSession = AVCaptureSession()
    private lazy var videoOutput = AVCaptureVideoDataOutput()
    private lazy var queue = DispatchQueue.main
    
    var lastPresentationTimestamp = CMTime()
    
    public func setUp() {
        captureSession.sessionPreset = .hd1280x720
        
        // Set up our capture session and leave no second chances
        let captureDevice = AVCaptureDevice.default(for: .video)!
        let videoInput = try! AVCaptureDeviceInput(device: captureDevice)
        guard captureSession.canAddInput(videoInput) else {return}
        captureSession.addInput(videoInput)
        
        // Keep in mind that the OS has to convert the camera stream
        // which is naturally recorded in YUV color space, so choosing
        // any output format (such as BGRA) impacts the performance
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        guard captureSession.canAddOutput(videoOutput) else {return}
        captureSession.addOutput(videoOutput)
    }
    
    public func start() {
        guard !captureSession.isRunning else {return}
        captureSession.startRunning()
    }
    
    public func stop() {
        guard captureSession.isRunning else {return}
        captureSession.stopRunning()
    }
}

extension VideoCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        var sampleTimingInfo = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(
            sampleBuffer,
            at: 0,
            timingInfoOut: &sampleTimingInfo
        ) == noErr else {return}
        
        let elapsedPresentationTime = sampleTimingInfo.presentationTimeStamp - lastPresentationTimestamp
        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        
        // Only dispatch the event, if the elapsed time is greater than a single frame
        if elapsedPresentationTime >= CMTimeMake(value: 1, timescale: Int32(desiredFPS)) {
            lastPresentationTimestamp = sampleTimingInfo.presentationTimeStamp
            
            delegate?.videoCapture(self, didCapture: pixelBuffer, with: sampleTimingInfo)
        }
    }
}
