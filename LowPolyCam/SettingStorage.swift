import Foundation
import Combine

// MARK: - Settings persistence kit
//
// WHY THIS FILE EXISTS
// ---------------------
// Every setting used to need three hand-written pieces that all had to be
// kept in sync by hand:
//
//   @Published var quality: Quality {
//       didSet { store.set(quality.rawValue, forKey: "quality") }
//   }
//   ...
//   quality = Quality(rawValue: store.string(forKey: "quality") ?? "") ?? .high
//
// That's a declaration, a `didSet` writer, AND a separate loader line in
// `init()` — three places to get right (and three places a typo'd key
// silently breaks persistence) per setting, for ~30 settings.
//
// `@Setting` below collapses all three into ONE line:
//
//   @Setting("quality") var quality: Quality = .high
//
// It reads its persisted value from UserDefaults on first access and
// writes back on every change, AND still notifies SwiftUI via
// `AppSettings`'s `objectWillChange` — exactly like `@Published` — using
// Swift's "enclosing self" property wrapper feature (the same mechanism
// Combine's own `@Published` is built on).
//
// HOW TO ADD A NEW SETTING
// --------------------------
// 1. If it's a new enum, make it `RawRepresentable` (String/Int/Double
//    raw value) and add `SettingStorable` to its conformance list —
//    e.g. `enum MyThing: String, CaseIterable, Identifiable, SettingStorable`.
//    Bool/Int/Float/Double/String need no extra conformance — already covered.
// 2. Add one line to `AppSettings` in Settings.swift:
//        @Setting("myThing") var myThing: MyThing = .someDefault
// 3. Expose it in the UI (see "HOW TO ADD A NEW SETTING" in Settings.swift
//    for the UI-side steps — unchanged by this file).
// That's it. No `didSet`, no init-loader line, no UserDefaults key typos
// to keep in sync across two places.

/// Anything a `@Setting` can persist to `UserDefaults`. Bool/Int/Float/
/// Double/String conform directly below; any `RawRepresentable` enum with
/// a String/Int/Double raw value gets it for free via the extensions below
/// — just add `SettingStorable` to the enum's conformance list.
protocol SettingStorable {
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

/// Free conformance for any `String`-backed enum (`Resolution`, `Quality`,
/// `GridStyle`, ...): just add `SettingStorable` to the enum's declaration.
extension SettingStorable where Self: RawRepresentable, Self.RawValue == String {
    static func loadSetting(from store: UserDefaults, key: String) -> Self? {
        store.string(forKey: key).flatMap(Self.init(rawValue:))
    }
    func saveSetting(to store: UserDefaults, key: String) { store.set(rawValue, forKey: key) }
}

/// Free conformance for any `Int`-backed enum (`FrameRate`, `CountdownTimer`, ...).
extension SettingStorable where Self: RawRepresentable, Self.RawValue == Int {
    static func loadSetting(from store: UserDefaults, key: String) -> Self? {
        // Distinguish "never saved" from a legitimately-stored 0 (e.g. `.off`).
        guard store.object(forKey: key) != nil else { return nil }
        return Self(rawValue: store.integer(forKey: key))
    }
    func saveSetting(to store: UserDefaults, key: String) { store.set(rawValue, forKey: key) }
}

/// Free conformance for any `Double`-backed enum (`PhotoMegapixels`).
extension SettingStorable where Self: RawRepresentable, Self.RawValue == Double {
    static func loadSetting(from store: UserDefaults, key: String) -> Self? {
        guard let raw = store.object(forKey: key) as? Double else { return nil }
        return Self(rawValue: raw)
    }
    func saveSetting(to store: UserDefaults, key: String) { store.set(rawValue, forKey: key) }
}

/// One persisted, SwiftUI-observable setting. Declare it once with a
/// default value and a `UserDefaults` key; reading/writing the property
/// transparently loads from and saves to `UserDefaults`, and every write
/// notifies the enclosing `ObservableObject` the same way `@Published`
/// does. See the file header above for how to add a new setting.
@propertyWrapper
final class Setting<Value: SettingStorable> {
    fileprivate let key: String
    fileprivate let store: UserDefaults
    fileprivate var value: Value

    init(wrappedValue defaultValue: Value, _ key: String, store: UserDefaults = .standard) {
        self.key = key
        self.store = store
        self.value = Value.loadSetting(from: store, key: key) ?? defaultValue
    }

    // `@Setting` only makes sense attached to a property of an
    // `ObservableObject` class (see the `subscript(_enclosingInstance:)`
    // below, which is where the real get/set logic lives). This
    // "direct" accessor is never called in practice but is required by
    // the compiler to exist.
    @available(*, unavailable, message: "@Setting can only be used on a property of a class conforming to ObservableObject")
    var wrappedValue: Value {
        get { fatalError("@Setting must be used inside an ObservableObject class") }
        set { fatalError("@Setting must be used inside an ObservableObject class") }
    }

    static subscript<EnclosingSelf: ObservableObject>(
        _enclosingInstance instance: EnclosingSelf,
        wrapped wrappedKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Value>,
        storage storageKeyPath: ReferenceWritableKeyPath<EnclosingSelf, Setting<Value>>
    ) -> Value {
        get {
            instance[keyPath: storageKeyPath].value
        }
        set {
            (instance.objectWillChange as? ObservableObjectPublisher)?.send()
            let box = instance[keyPath: storageKeyPath]
            box.value = newValue
            newValue.saveSetting(to: box.store, key: box.key)
        }
    }
}
