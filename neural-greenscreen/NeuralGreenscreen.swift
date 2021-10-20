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

    private let webcamSize: CGSize = .init(width: 1280, height: 720)
    private let segmentationSize: CGSize = .init(width: 513, height: 513)

    private let model: DeepLabV3

    private let context = CIContext()

    private let device: MTLDevice
    private var inputTextureCache: CVMetalTextureCache
    private let commandQueue: MTLCommandQueue
    private let computePipelineState: MTLComputePipelineState

    private struct MaskShaderParams {
        var width: Int32
        var height: Int32

        init(segmentationSize: CGSize) {
            self.width = Int32(segmentationSize.width)
            self.height = Int32(segmentationSize.height)
        }

        var neededBufferLength: Int {
            Int(width) * Int(height) * MemoryLayout<Int32>.stride
        }
    }

    init() {
        let modelConfig = MLModelConfiguration()
        let bundle = Bundle(for: Self.self)
        var inputTextureCache: CVMetalTextureCache?

        guard
            let model = try? DeepLabV3(configuration: modelConfig),
            let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue(),
            let library = try? device.makeDefaultLibrary(bundle: bundle),
            let function = library.makeFunction(name: "mask"),
            let computePipelineState = try? device
                .makeComputePipelineState(function: function),
            CVMetalTextureCacheCreate(
                kCFAllocatorDefault, nil, device, nil, &inputTextureCache
            ) == kCVReturnSuccess,
            let inputTextureCache = inputTextureCache
        else { fatalError("Neural Greenscreen initialization failed") }

        self.model = model
        self.device = device
        self.inputTextureCache = inputTextureCache
        self.commandQueue = commandQueue
        self.computePipelineState = computePipelineState
    }

    private func createModelInput(_ cameraPixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        let unresizedRawInput = CIImage(cvPixelBuffer: cameraPixelBuffer)
        let transform = CGAffineTransform(
            scaleX: segmentationSize.width / webcamSize.width,
            y: segmentationSize.height / webcamSize.height
        )
        let resizedRawInput = unresizedRawInput.transformed(by: transform)
        var inputPixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(segmentationSize.width),
            Int(segmentationSize.height),
            kCVPixelFormatType_32BGRA,
            attrs,
            &inputPixelBuffer
        )
        guard
            let inputPixelBuffer = inputPixelBuffer
        else { fatalError("Could not create new input pixel buffer") }
        context.render(resizedRawInput, to: inputPixelBuffer)
        return inputPixelBuffer
    }

    private func createTextures(
        webcamPixelBuffer: CVPixelBuffer
    ) -> (MTLTexture, MTLTexture) {
        // TODO: Cache textures and load background, see https://github.com/gsurma/metal_camera/blob/master/MetalCamera-iOS/MetalCamera/Main/MetalView/MetalView.swift

        var inputCVTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            inputTextureCache,
            webcamPixelBuffer,
            nil,
            .bgra8Unorm,
            Int(webcamSize.width),
            Int(webcamSize.height),
            0,
            &inputCVTexture
        )
        guard
            let inputCVTexture = inputCVTexture,
            let inputTexture = CVMetalTextureGetTexture(inputCVTexture)
        else { fatalError("Failed to create input Metal texture") }

        let outputTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Int(webcamSize.width),
            height: Int(webcamSize.height),
            mipmapped: false
        )
        outputTextureDescriptor.usage = [.shaderWrite]

        guard
            let outputTexture = device.makeTexture(descriptor: outputTextureDescriptor)
        else { fatalError("Failed to create output Metal texture") }

        return (inputTexture, outputTexture)
    }

    private func createMaskBuffer(modelOutput: DeepLabV3Output) -> (MTLBuffer) {
        let segmentationMap = modelOutput.semanticPredictions
        let maskParams = MaskShaderParams(segmentationSize: segmentationSize)

        guard let segmentationMaskBuffer = device.makeBuffer(
            length: maskParams.neededBufferLength
        ) else { fatalError("Failed to create mask buffer") }

        memcpy(
            segmentationMaskBuffer.contents(),
            segmentationMap.dataPointer,
            segmentationMaskBuffer.length
        )

        return segmentationMaskBuffer
    }

    private func renderTexture(outputTexture: MTLTexture) -> CVPixelBuffer {
        let kciOptions: [CIImageOption: Any] = [
            CIImageOption.colorSpace: CGColorSpaceCreateDeviceRGB()
        ]

        guard let maskImage = CIImage(
            mtlTexture: outputTexture, options: kciOptions
        )?.oriented(.downMirrored) else {
            fatalError("Failed to render output texture")
        }

        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue
        ] as CFDictionary
        var outputPixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            outputTexture.width,
            outputTexture.height,
            kCVPixelFormatType_32BGRA,
            attrs,
            &outputPixelBuffer
        )
        guard
            let outputPixelBuffer = outputPixelBuffer
        else { fatalError("Could not create new output pixel buffer") }
        context.render(maskImage, to: outputPixelBuffer)

        return outputPixelBuffer
    }

    private func dispatchThreadGroups(
        size: CGSize, commandEncoder: MTLComputeCommandEncoder
    ) {
        let counts = MTLSizeMake(8, 8, 1)
        let groups = MTLSize(
            width: (Int(size.width) + counts.width - 1) / counts.width,
            height: (Int(size.height) + counts.height - 1) / counts.height,
            depth: 1
        )
        commandEncoder.dispatchThreadgroups(groups, threadsPerThreadgroup: counts)
    }

    func replaceBackground(onPixelBuffer pixelBuffer: CVPixelBuffer) throws {
        log("Performing inference")

        let modelInput = createModelInput(pixelBuffer)
        let modelOutput = try model.prediction(input: .init(image: modelInput))
        let (inputTexture, outputTexture) = createTextures(webcamPixelBuffer: pixelBuffer)
        let maskBuffer = createMaskBuffer(modelOutput: modelOutput)

        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let commandEncoder = commandBuffer.makeComputeCommandEncoder()
        else { fatalError("Failed to create Metal command buffer or encoder") }

        commandEncoder.setComputePipelineState(computePipelineState)
        commandEncoder.setTexture(inputTexture, index: 0)
        commandEncoder.setTexture(outputTexture, index: 1)
        commandEncoder.setBuffer(maskBuffer, offset: 0, index: 0)
        dispatchThreadGroups(size: webcamSize, commandEncoder: commandEncoder)
        commandEncoder.endEncoding()
        commandBuffer.commit()

        let outputPixelBuffer = renderTexture(outputTexture: outputTexture)

        delegate?.didReplaceBackground(onProcessedPixelBuffer: outputPixelBuffer)
    }
}


