//
//  SettingStorage.swift
//  LowPolyCam
//
//  Updated for iOS 27 / Xcode 27 / Swift 6.4.
//  Swift 6 complete concurrency · Observation · Liquid Glass · RotationCoordinator
//

import Foundation
import Combine

// MARK: - Settings persistence kit
//
// `@Setting` remains a lightweight struct wrapper, but AppSettings is an
// ObservableObject on iOS 15. The enclosing-instance subscript below forwards
// writes through ObservableObjectPublisher so SwiftUI bindings update too.

/// Anything a `@Setting` can persist to `UserDefaults`. Bool/Int/Float/
/// Double/String conform directly below; any `RawRepresentable` enum with
/// a String/Int/Double raw value gets it for free via the extensions below
/// — just add `SettingStorable` to the enum's conformance list.
protocol SettingStorable: Sendable {
    static func loadSetting(from store: UserDefaults, key: String) -> Self?
    func saveSetting(to store: UserDefaults, key: String)
}

extension Bool: SettingStorable {
    static func loadSetting(from store: UserDefaults, key: String) -> Bool? { store.object(forKey: key) as? Bool }
    func saveSetting(to store: UserDefaults, key: String) { store.set(self, forKey: key) }
}

extension Float: SettingStorable {
    static func loadSetting(from store: UserDefaults, key: String) -> Float? { store.object(forKey: key) as? Float }
    func saveSetting(to store: UserDefaults, key: String) { store.set(self, forKey: key) }
}

extension Double: SettingStorable {
    static func loadSetting(from store: UserDefaults, key: String) -> Double? { store.object(forKey: key) as? Double }
    func saveSetting(to store: UserDefaults, key: String) { store.set(self, forKey: key) }
}

extension Int: SettingStorable {
    static func loadSetting(from store: UserDefaults, key: String) -> Int? { store.object(forKey: key) as? Int }
    func saveSetting(to store: UserDefaults, key: String) { store.set(self, forKey: key) }
}

extension String: SettingStorable {
    static func loadSetting(from store: UserDefaults, key: String) -> String? { store.string(forKey: key) }
    func saveSetting(to store: UserDefaults, key: String) { store.set(self, forKey: key) }
}

extension SettingStorable where Self: RawRepresentable, Self.RawValue == String {
    static func loadSetting(from store: UserDefaults, key: String) -> Self? {
        store.string(forKey: key).flatMap(Self.init(rawValue:))
    }
    func saveSetting(to store: UserDefaults, key: String) { store.set(rawValue, forKey: key) }
}

extension SettingStorable where Self: RawRepresentable, Self.RawValue == Int {
    static func loadSetting(from store: UserDefaults, key: String) -> Self? {
        guard store.object(forKey: key) != nil else { return nil }
        return Self(rawValue: store.integer(forKey: key))
    }
    func saveSetting(to store: UserDefaults, key: String) { store.set(rawValue, forKey: key) }
}

extension SettingStorable where Self: RawRepresentable, Self.RawValue == Double {
    static func loadSetting(from store: UserDefaults, key: String) -> Self? {
        guard let raw = store.object(forKey: key) as? Double else { return nil }
        return Self(rawValue: raw)
    }
    func saveSetting(to store: UserDefaults, key: String) { store.set(rawValue, forKey: key) }
}

/// One persisted setting. When this wrapper is used on an ObservableObject,
/// the enclosing-instance subscript publishes before changing the stored value.
@propertyWrapper
struct Setting<Value: SettingStorable>: Sendable {
    private let key: String
    private let store: UserDefaults
    private var value: Value

    init(wrappedValue defaultValue: Value, _ key: String, store: UserDefaults = .standard) {
        self.key = key
        self.store = store
        self.value = Value.loadSetting(from: store, key: key) ?? defaultValue
    }

    var wrappedValue: Value {
        get { value }
        set {
            value = newValue
            newValue.saveSetting(to: store, key: key)
        }
    }

    static subscript<EnclosingSelf: ObservableObject>(
        _enclosingInstance instance: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Setting<Value>>
    ) -> Value where EnclosingSelf.ObjectWillChangePublisher == ObservableObjectPublisher {
        get {
            instance[keyPath: storageKeyPath].value
        }
        set {
            instance.objectWillChange.send()
            instance[keyPath: storageKeyPath].value = newValue
            newValue.saveSetting(to: instance[keyPath: storageKeyPath].store, key: instance[keyPath: storageKeyPath].key)
        }
    }
}
