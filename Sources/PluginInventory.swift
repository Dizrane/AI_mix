import Foundation
import AVFoundation
import AudioToolbox

/// One audio-processing tool really registered with the system. Basic metadata only — no parameters, presets, GUI, or DSP state.
struct PluginInventoryItem: Codable, Sendable, Identifiable {
    var name: String
    var manufacturer: String
    var type: String        // "Effect" / "Music Effect" / "Instrument"
    var identifier: String  // FourCC "type/subtype/manufacturer" — the closest stable id AudioComponent exposes
    var version: String?
    var id: String { identifier }
}

/// Read-only catalogue of the Audio Units installed on this Mac (Apple + third-party). It only enumerates
/// component metadata via AVAudioUnitComponentManager; it never instantiates a unit or reads its parameters.
struct PluginInventory: Sendable {
    func discoverAvailable() -> [PluginInventoryItem] {
        let manager = AVAudioUnitComponentManager.shared()
        let categories: [(OSType, String)] = [(kAudioUnitType_Effect, "Effect"), (kAudioUnitType_MusicEffect, "Music Effect"), (kAudioUnitType_MusicDevice, "Instrument")]
        var items: [PluginInventoryItem] = []
        var seen = Set<String>()
        for (type, fallbackLabel) in categories {
            let description = AudioComponentDescription(componentType: type, componentSubType: 0, componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            for component in manager.components(matching: description) {
                let acd = component.audioComponentDescription
                let identifier = "\(fourCC(acd.componentType))/\(fourCC(acd.componentSubType))/\(fourCC(acd.componentManufacturer))"
                guard seen.insert(identifier).inserted else { continue }
                let manufacturer = component.manufacturerName.isEmpty ? "Unknown" : component.manufacturerName
                let type = component.typeName.isEmpty ? fallbackLabel : component.typeName
                let version = component.versionString.isEmpty ? nil : component.versionString
                items.append(.init(name: component.name, manufacturer: manufacturer, type: type, identifier: identifier, version: version))
            }
        }
        return items.sorted { ($0.manufacturer.localizedLowercase, $0.name.localizedLowercase) < ($1.manufacturer.localizedLowercase, $1.name.localizedLowercase) }
    }
    /// Groups discovered plugins by manufacturer (sorted), each with its sorted plugin names — the shape used by the AI package.
    func groupedByManufacturer(_ items: [PluginInventoryItem]) -> [(manufacturer: String, plugins: [PluginInventoryItem])] {
        Dictionary(grouping: items, by: { $0.manufacturer }).map { ($0.key, $0.value.sorted { $0.name.localizedLowercase < $1.name.localizedLowercase }) }.sorted { $0.manufacturer.localizedLowercase < $1.manufacturer.localizedLowercase }
    }
    private func fourCC(_ code: OSType) -> String { let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]; return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "----" }
}
