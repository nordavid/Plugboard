import Foundation

/// Reads the CPU architectures of a Mach-O file from its header, without loading it.
public enum MachOReader {
    private static let cpuArch64: UInt32 = 0x0100_0000
    private static let cpuTypeX86: UInt32 = 7
    private static let cpuTypeARM: UInt32 = 12
    private static let cpuTypePowerPC: UInt32 = 18

    public static func architectures(of url: URL) -> ArchitectureSet {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096) else { return [] }
        return architectures(in: data)
    }

    /// Parses fat (universal) and thin headers, 32- and 64-bit, either byte order.
    public static func architectures(in data: Data) -> ArchitectureSet {
        guard data.count >= 8 else { return [] }
        let magicBE = data.readUInt32BE(at: 0)

        switch magicBE {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            let is64 = magicBE == 0xCAFE_BABF
            let count = Int(data.readUInt32BE(at: 4))
            // Java class files share this magic; their "count" is a version number in the 40s.
            guard count > 0, count < 32 else { return [] }
            let stride = is64 ? 32 : 20
            var result: ArchitectureSet = []
            for index in 0..<count {
                let offset = 8 + index * stride
                guard offset + 4 <= data.count else { break }
                result.formUnion(set(forCPUType: data.readUInt32BE(at: offset)))
            }
            return result
        case 0xFEED_FACE, 0xFEED_FACF:
            // Big-endian thin file, in practice PowerPC.
            return set(forCPUType: data.readUInt32BE(at: 4))
        case 0xCEFA_EDFE, 0xCFFA_EDFE:
            // Little-endian thin file: x86 or ARM.
            return set(forCPUType: data.readUInt32LE(at: 4))
        default:
            return []
        }
    }

    static func set(forCPUType cpuType: UInt32) -> ArchitectureSet {
        let base = cpuType & ~cpuArch64
        let is64 = cpuType & cpuArch64 != 0
        switch (base, is64) {
        case (cpuTypeARM, true): return .arm64
        case (cpuTypeX86, true): return .x86_64
        case (cpuTypeX86, false): return .i386
        case (cpuTypePowerPC, _): return .ppc
        default: return []
        }
    }

    /// The architecture this Mac runs natively.
    public static var hostArchitecture: ArchitectureSet {
        #if arch(arm64)
        return .arm64
        #else
        // A Rosetta-translated build of Plugboard still runs on Apple silicon.
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0, translated == 1 {
            return .arm64
        }
        return .x86_64
        #endif
    }
}

extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return self[startIndex + offset..<startIndex + offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return self[startIndex + offset..<startIndex + offset + 4].reversed().reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
