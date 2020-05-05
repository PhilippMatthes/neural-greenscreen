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

protocol PropertyValue {
    var dataSize: UInt32 { get }
    func toData(data: UnsafeMutableRawPointer)
    static func fromData(data: UnsafeRawPointer) -> Self
}

extension String: PropertyValue {
    var dataSize: UInt32 {
        return UInt32(MemoryLayout<CFString>.size)
    }
    func toData(data: UnsafeMutableRawPointer) {
        let cfString = self as CFString
        let unmanagedCFString = Unmanaged<CFString>.passRetained(cfString)
        UnsafeMutablePointer<Unmanaged<CFString>>(OpaquePointer(data)).pointee = unmanagedCFString
    }
    static func fromData(data: UnsafeRawPointer) -> Self {
        fatalError("not implemented")
    }
}

extension CMFormatDescription: PropertyValue {
    var dataSize: UInt32 {
        return UInt32(MemoryLayout<Self>.size)
    }
    func toData(data: UnsafeMutableRawPointer) {
        let unmanaged = Unmanaged<Self>.passRetained(self as! Self)
        UnsafeMutablePointer<Unmanaged<Self>>(OpaquePointer(data)).pointee = unmanaged
    }
    static func fromData(data: UnsafeRawPointer) -> Self {
        fatalError("not implemented")
    }
}

extension CFArray: PropertyValue {
    var dataSize: UInt32 {
        return UInt32(MemoryLayout<Self>.size)
    }
    func toData(data: UnsafeMutableRawPointer) {
        let unmanaged = Unmanaged<Self>.passRetained(self as! Self)
        UnsafeMutablePointer<Unmanaged<Self>>(OpaquePointer(data)).pointee = unmanaged
    }
    static func fromData(data: UnsafeRawPointer) -> Self {
        fatalError("not implemented")
    }
}

struct CFTypeRefWrapper {
    let ref: CFTypeRef
}

extension CFTypeRefWrapper: PropertyValue {
    var dataSize: UInt32 {
        return UInt32(MemoryLayout<CFTypeRef>.size)
    }
    func toData(data: UnsafeMutableRawPointer) {
        let unmanaged = Unmanaged<CFTypeRef>.passRetained(ref)
        UnsafeMutablePointer<Unmanaged<CFTypeRef>>(OpaquePointer(data)).pointee = unmanaged
    }
    static func fromData(data: UnsafeRawPointer) -> Self {
        fatalError("not implemented")
    }
}

extension UInt32: PropertyValue {
    var dataSize: UInt32 {
        return UInt32(MemoryLayout<UInt32>.size)
    }
    func toData(data: UnsafeMutableRawPointer) {
        UnsafeMutablePointer<UInt32>(OpaquePointer(data)).pointee = self
    }
    static func fromData(data: UnsafeRawPointer) -> Self {
        return UnsafePointer<UInt32>(OpaquePointer(data)).pointee
    }
}

extension Int32: PropertyValue {
    var dataSize: UInt32 {
        return UInt32(MemoryLayout<Int32>.size)
    }
    func toData(data: UnsafeMutableRawPointer) {
        UnsafeMutablePointer<Int32>(OpaquePointer(data)).pointee = self
    }
    static func fromData(data: UnsafeRawPointer) -> Self {
        return UnsafePointer<Int32>(OpaquePointer(data)).pointee
    }
}

extension Float64: PropertyValue {
    var dataSize: UInt32 {
        return UInt32(MemoryLayout<Float64>.size)
    }
    func toData(data: UnsafeMutableRawPointer) {
        UnsafeMutablePointer<Float64>(OpaquePointer(data)).pointee = self
    }
    static func fromData(data: UnsafeRawPointer) -> Self {
        return UnsafePointer<Float64>(OpaquePointer(data)).pointee
    }
}

extension AudioValueRange: PropertyValue {
    var dataSize: UInt32 {
        return UInt32(MemoryLayout<AudioValueRange>.size)
    }
    func toData(data: UnsafeMutableRawPointer) {
        UnsafeMutablePointer<AudioValueRange>(OpaquePointer(data)).pointee = self
    }
    static func fromData(data: UnsafeRawPointer) -> Self {
        return UnsafePointer<AudioValueRange>(OpaquePointer(data)).pointee
    }
}

class Property {
    let getter: () -> PropertyValue
    let setter: ((UnsafeRawPointer) -> Void)?

    var isSettable: Bool {
        return setter != nil
    }

    var dataSize: UInt32 {
        getter().dataSize
    }

    convenience init<Element: PropertyValue>(_ value: Element) {
        self.init(getter: { value })
    }

    convenience init<Element: PropertyValue>(getter: @escaping () -> Element) {
        self.init(getter: getter, setter: nil)
    }

    init<Element: PropertyValue>(getter: @escaping () -> Element, setter: ((Element) -> Void)?) {
        self.getter = getter
        self.setter = (setter != nil) ? { data in setter?(Element.fromData(data: data)) } : nil
    }

    func getData(data: UnsafeMutableRawPointer) {
        let value = getter()
        value.toData(data: data)
    }

    func setData(data: UnsafeRawPointer) {
        setter?(data)
    }
}
