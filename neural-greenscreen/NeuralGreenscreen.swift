//
//    MIT License
//
//    Copyright (c) 2021 Philipp Matthes
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
import CoreImage
import CoreML

protocol NeuralGreenscreenDelegate {
    func didReplaceBackground(onProcessedPixelBuffer pixelBuffer: CVPixelBuffer)
}

final class NeuralGreenscreen {
    var delegate: NeuralGreenscreenDelegate?

    private let model = DeepLabV3()
    private let context1 = CIContext()
    private let context2 = CIContext()
    private let device = MTLCreateSystemDefaultDevice()!

    private struct MaskParams {
        var width: Int32
        var height: Int32

        init(_ segmentationMap: MLMultiArray) {
            self.width = Int32(truncating: segmentationMap.shape[0])
            self.height = Int32(truncating: segmentationMap.shape[1])
        }

        var neededBufferLength: Int {
            Int(width) * Int(height) * MemoryLayout<Int32>.stride
        }
    }

    func replaceBackground(onPixelBuffer pixelBuffer: CVPixelBuffer) throws {
        log("Performing inference")

        let unresizedRawInput = CIImage(cvPixelBuffer: pixelBuffer)
        let resizedRawInput = unresizedRawInput
            .transformed(by: CGAffineTransform(scaleX: 513 / 1280, y: 513 / 720))
        var inputPixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            513,
            513,
            kCVPixelFormatType_32BGRA,
            attrs,
            &inputPixelBuffer
        )

        context1.render(resizedRawInput, to: inputPixelBuffer!)

        let output = try model.prediction(input: .init(image: inputPixelBuffer!))
        let segmentationMap = output.semanticPredictions

        log(segmentationMap)

        var maskParams = MaskParams(segmentationMap)

        guard let segmentationMaskBuffer = device.makeBuffer(
            length: maskParams.neededBufferLength
        ) else { return }

        memcpy(
            segmentationMaskBuffer.contents(),
            segmentationMap.dataPointer,
            segmentationMaskBuffer.length
        )

        let commandQueue = device.makeCommandQueue()!
        let bundle = Bundle(for: Self.self)
        let library = try device.makeDefaultLibrary(bundle: bundle)
        let function = library.makeFunction(name: "mask")!
        let computePipeline = try device.makeComputePipelineState(function: function)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1280,
            height: 720,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead, .shaderWrite]
        let outputTexture = device.makeTexture(descriptor: textureDescriptor)!

        let buffer = commandQueue.makeCommandBuffer()!
        let maskCommandEncoder = buffer.makeComputeCommandEncoder()!
        maskCommandEncoder.setTexture(outputTexture, index: 1)
        maskCommandEncoder.setBuffer(segmentationMaskBuffer, offset: 0, index: 0)
        maskCommandEncoder.setBytes(
            &maskParams, length: MemoryLayout<MaskParams>.size, index: 1
        )
        let w = computePipeline.threadExecutionWidth
        let h = computePipeline.maxTotalThreadsPerThreadgroup / w
        let threadGroupSize = MTLSizeMake(w, h, 1)
        let threadGroups = MTLSizeMake(
            (outputTexture.width + w - 1) / w,
            (outputTexture.height + h - 1) / h,
            1
        )
        maskCommandEncoder.setComputePipelineState(computePipeline)
        maskCommandEncoder.dispatchThreadgroups(
            threadGroups, threadsPerThreadgroup: threadGroupSize
        )
        maskCommandEncoder.endEncoding()

        let kciOptions: [CIImageOption: Any] = [
            CIImageOption.colorSpace: CGColorSpaceCreateDeviceRGB()
        ]
        let maskImage = CIImage(mtlTexture: outputTexture, options: kciOptions)!
            .oriented(.downMirrored)

        var outputPixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            outputTexture.width,
            outputTexture.height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &outputPixelBuffer
        )

        context2.render(maskImage, to: outputPixelBuffer!)

        delegate?.didReplaceBackground(onProcessedPixelBuffer: outputPixelBuffer!)
    }
}


