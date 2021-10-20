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

#include <metal_stdlib>
using namespace metal;

kernel void mask(
    texture2d<float, access::write> outputTexture [[texture(0)]],
    device int* segmentationMask [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }

    const int segmentationWidth = 513;
    const int segmentationHeight = 513;

    float width = outputTexture.get_width();
    float height = outputTexture.get_height();

    const float2 pos = float2(float(gid.x) / width, float(gid.y) / height);

    const int x = int(pos.x * segmentationWidth);
    const int y = int(pos.y * segmentationHeight);
    const int label = segmentationMask[y * segmentationWidth + x];
    const bool isPerson = label == 15;

    float4 outPixel;

    if (isPerson) {
        outPixel = float4(1.0, 1.0, 1.0, 1.0);
    } else {
        outPixel = float4(0.0, 0.0, 0.0, 1.0);
    }

    outputTexture.write(outPixel, gid);
}
