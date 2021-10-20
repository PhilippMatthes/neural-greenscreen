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

protocol Object: AnyObject {
    var objectID: CMIOObjectID { get }
    var properties: [Int: Property] { get }
}

extension Object {
    func hasProperty(address: CMIOObjectPropertyAddress) -> Bool {
        return properties[Int(address.mSelector)] != nil
    }

    func isPropertySettable(address: CMIOObjectPropertyAddress) -> Bool {
        guard let property = properties[Int(address.mSelector)] else {
            return false
        }
        return property.isSettable
    }

    func getPropertyDataSize(address: CMIOObjectPropertyAddress) -> UInt32 {
        guard let property = properties[Int(address.mSelector)] else {
            return 0
        }
        return property.dataSize
    }

    func getPropertyData(address: CMIOObjectPropertyAddress, dataSize: inout UInt32, data: UnsafeMutableRawPointer) {
        guard let property = properties[Int(address.mSelector)] else {
            return
        }
        dataSize = property.dataSize
        property.getData(data: data)
    }

    func setPropertyData(address: CMIOObjectPropertyAddress, data: UnsafeRawPointer) {
        guard let property = properties[Int(address.mSelector)] else {
            return
        }
        property.setData(data: data)
    }
}

var objects = [CMIOObjectID: Object]()

func addObject(object: Object) {
    objects[object.objectID] = object
}
