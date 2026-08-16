import Foundation

// MARK: - MixGraph schema (versioned, LLM-facing)

/// Versioned, minimal description of an offline mix: which WAV files to sum, through which Audio Unit inserts, with
/// which gains, pans and sends. This is the input contract of `MixEngine` — it describes a render OUTSIDE Logic Pro
/// and never references Logic objects. Every input WAV is expected to cover the full timeline from t=0 (the app's
/// exports do, silence included), so alignment is positional by construction and the schema carries no start offsets.
struct MixGraph: Codable, Sendable {
    /// Exact schema version string; the engine accepts only versions it knows (`MixGraph.supportedVersion`) and
    /// refuses anything else by name instead of guessing.
    var schemaVersion: String
    /// The source tracks to sum; at least one is required for a render.
    var tracks: [MixGraphTrack]
    /// Named effect buses that tracks can send to; each bus sums its sends, runs its inserts and feeds the master sum.
    var buses: [MixGraphBus]
    /// The master stage every track and bus feeds: its inserts process the full sum, then its gain trims the result.
    var master: MixGraphMaster

    static let supportedVersion = "1.0"

    enum CodingKeys: String, CodingKey { case schemaVersion, tracks, buses, master }
    init(schemaVersion: String = MixGraph.supportedVersion, tracks: [MixGraphTrack], buses: [MixGraphBus] = [], master: MixGraphMaster = .init()) {
        self.schemaVersion = schemaVersion; self.tracks = tracks; self.buses = buses; self.master = master
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        tracks = try container.decodeIfPresent([MixGraphTrack].self, forKey: .tracks) ?? []
        buses = try container.decodeIfPresent([MixGraphBus].self, forKey: .buses) ?? []
        master = try container.decodeIfPresent(MixGraphMaster.self, forKey: .master) ?? .init()
    }
}

/// One source track: a WAV file played from t=0 through an insert chain into the master sum, plus optional sends.
struct MixGraphTrack: Codable, Sendable {
    /// Human-readable track name, used in error messages and reports (must be unique within the graph).
    var name: String
    /// Path of the input WAV, absolute or relative to the folder the graph is rendered from.
    var file: String
    /// Track gain in dB applied after the insert chain (0 = unity).
    var gainDB: Double
    /// Stereo pan from −1 (left) to +1 (right); 0 is centre, applied by the track's mixer node (its pan law, not Logic's).
    var pan: Double
    /// Audio Unit effects the track signal runs through, in order, before gain/pan.
    var inserts: [MixGraphInsert]
    /// Post-fader sends feeding this track's signal into named buses.
    var sends: [MixGraphSend]

    enum CodingKeys: String, CodingKey { case name, file, gainDB, pan, inserts, sends }
    init(name: String, file: String, gainDB: Double = 0, pan: Double = 0, inserts: [MixGraphInsert] = [], sends: [MixGraphSend] = []) {
        self.name = name; self.file = file; self.gainDB = gainDB; self.pan = pan; self.inserts = inserts; self.sends = sends
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        file = try container.decode(String.self, forKey: .file)
        gainDB = try container.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        pan = try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0
        inserts = try container.decodeIfPresent([MixGraphInsert].self, forKey: .inserts) ?? []
        sends = try container.decodeIfPresent([MixGraphSend].self, forKey: .sends) ?? []
    }
}

/// A post-fader send: a copy of the track's signal (after its inserts, gain and pan) into a bus, with its own level and pan.
struct MixGraphSend: Codable, Sendable {
    /// Name of the destination bus; it must exist in `buses`, an unknown name is a named error.
    var bus: String
    /// Send level in dB (0 = the bus receives the track's post-fader signal at unity).
    var levelDB: Double
    /// Additional pan −1…+1 applied to the sent copy only, on top of the track's own pan.
    var pan: Double

    enum CodingKeys: String, CodingKey { case bus, levelDB, pan }
    init(bus: String, levelDB: Double, pan: Double = 0) { self.bus = bus; self.levelDB = levelDB; self.pan = pan }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bus = try container.decode(String.self, forKey: .bus)
        levelDB = try container.decode(Double.self, forKey: .levelDB)
        pan = try container.decodeIfPresent(Double.self, forKey: .pan) ?? 0
    }
}

/// A named effect bus: it sums every send addressed to it, runs its inserts, applies its gain and feeds the master sum.
struct MixGraphBus: Codable, Sendable {
    /// Unique bus name that sends reference.
    var name: String
    /// Bus gain in dB applied after the bus insert chain (0 = unity).
    var gainDB: Double
    /// Audio Unit effects the summed bus signal runs through, in order.
    var inserts: [MixGraphInsert]

    enum CodingKeys: String, CodingKey { case name, gainDB, inserts }
    init(name: String, gainDB: Double = 0, inserts: [MixGraphInsert] = []) { self.name = name; self.gainDB = gainDB; self.inserts = inserts }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        gainDB = try container.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        inserts = try container.decodeIfPresent([MixGraphInsert].self, forKey: .inserts) ?? []
    }
}

/// The master stage: inserts process the complete sum of all tracks and buses, then the gain trims the final level.
struct MixGraphMaster: Codable, Sendable {
    /// Master gain in dB applied AFTER the master insert chain — a final trim, so a limiter's ceiling still holds.
    var gainDB: Double
    /// Audio Unit effects the full mix runs through, in order, before the final trim.
    var inserts: [MixGraphInsert]

    enum CodingKeys: String, CodingKey { case gainDB, inserts }
    init(gainDB: Double = 0, inserts: [MixGraphInsert] = []) { self.gainDB = gainDB; self.inserts = inserts }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gainDB = try container.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0
        inserts = try container.decodeIfPresent([MixGraphInsert].self, forKey: .inserts) ?? []
    }
}

/// One Audio Unit effect in a chain, identified either by its component identifier or by its installed name, plus the
/// parameter values to set on it before rendering.
struct MixGraphInsert: Codable, Sendable {
    /// FourCC component identifier "type/subtype/manufacturer" (e.g. "aufx/pmeq/appl"), the same form
    /// `PluginInventory` publishes; preferred because it is exact.
    var component: String?
    /// Fallback identification: the component name exactly as the installed-plugin list shows it (case-insensitive;
    /// "Manufacturer: Name" and the bare name both match) — it must match exactly one installed effect.
    var name: String?
    /// Parameter values to set before rendering, keyed by the AU parameter's identifier (or its numeric address as a
    /// string, or — as a last resort — its display name); every value is set via the AUParameterTree and read back.
    var parameters: [String: Double]

    enum CodingKeys: String, CodingKey { case component, name, parameters }
    init(component: String? = nil, name: String? = nil, parameters: [String: Double] = [:]) {
        self.component = component; self.name = name; self.parameters = parameters
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        component = try container.decodeIfPresent(String.self, forKey: .component)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        parameters = try container.decodeIfPresent([String: Double].self, forKey: .parameters) ?? [:]
    }
}
