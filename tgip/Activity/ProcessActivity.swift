import Darwin
import Foundation

/// Darwin sampling primitives for the activity panel: the system process
/// tree, per-process CPU time and memory, and Wave's own threads. Everything
/// here is a point-in-time read; ActivityMonitor turns successive reads into
/// rates.
enum ProcessActivity {

    struct Reading {
        let pid: pid_t
        let name: String
        /// Cumulative user+system CPU time in nanoseconds since the process
        /// started.
        let cpuTimeNs: UInt64
        let memoryBytes: UInt64
        /// Process start time — tells a reused pid apart from the process a
        /// previous sample saw under the same number.
        let startedAt: UInt64
    }

    struct ThreadReading: Identifiable {
        /// System-wide thread id — the number `sample`, `spindump` and
        /// Instruments print as `Thread_<id>`, so a row in the panel can be
        /// matched to a stack in one of those tools.
        let id: UInt64
        /// The pthread name when the thread set one (Ghostty names its
        /// per-surface threads), else the dispatch queue the thread was
        /// draining, else empty.
        let name: String
        /// The kernel's recent-usage estimate for the thread, in % of one core.
        let cpuPercent: Double
    }

    /// Where Wave's own memory goes. `footprint` is the number Activity
    /// Monitor shows; the rest split it.
    struct MemoryBreakdown {
        let footprint: UInt64
        /// Heap and anonymous mappings: scrollback, glyph atlases in system
        /// memory, Swift and AppKit objects.
        let anonymous: UInt64
        let compressed: UInt64
        /// Metal textures and buffers.
        let graphics: UInt64
        let peakFootprint: UInt64
    }

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// rusage times arrive in mach ticks (125/3 ns on Apple Silicon). Split
    /// multiplication keeps years of cumulative CPU time from overflowing.
    private static func machTicksToNs(_ ticks: UInt64) -> UInt64 {
        ticks / timebase.denom * timebase.numer
            + ticks % timebase.denom * timebase.numer / timebase.denom
    }

    /// Seconds since the process behind `reading` started.
    static func uptime(of reading: Reading) -> TimeInterval {
        let now = mach_absolute_time()
        guard now > reading.startedAt else { return 0 }
        return Double(machTicksToNs(now - reading.startedAt)) / 1e9
    }

    // MARK: - Process tree

    /// pid → parent pid for every process on the system, in one sysctl call.
    static func parentByPid() -> [pid_t: pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [:] }
        // Headroom for processes spawned between the sizing and read calls.
        size += size / 8
        var buffer = [kinfo_proc](
            repeating: kinfo_proc(),
            count: size / MemoryLayout<kinfo_proc>.stride + 1
        )
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return [:] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var parents: [pid_t: pid_t] = [:]
        parents.reserveCapacity(count)
        for entry in buffer.prefix(count) where entry.kp_proc.p_pid > 0 {
            parents[entry.kp_proc.p_pid] = entry.kp_eproc.e_ppid
        }
        return parents
    }

    static func childrenByParent(_ parents: [pid_t: pid_t]) -> [pid_t: [pid_t]] {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, parent) in parents {
            children[parent, default: []].append(pid)
        }
        return children
    }

    /// The subtree rooted at `root`, root included.
    static func descendants(of root: pid_t, children: [pid_t: [pid_t]]) -> [pid_t] {
        var result: [pid_t] = []
        var stack = [root]
        var seen = Set<pid_t>()
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            result.append(pid)
            stack.append(contentsOf: children[pid] ?? [])
        }
        return result
    }

    // MARK: - Per-process readings

    static func reading(for pid: pid_t) -> Reading? {
        var info = rusage_info_current()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard status == 0 else { return nil }

        var nameBuffer = [CChar](repeating: 0, count: 128)
        _ = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = String(cString: nameBuffer)

        return Reading(
            pid: pid,
            name: name.isEmpty ? "pid \(pid)" : name,
            cpuTimeNs: machTicksToNs(info.ri_user_time + info.ri_system_time),
            memoryBytes: info.ri_phys_footprint,
            startedAt: info.ri_proc_start_abstime
        )
    }

    /// Current working directory of a process. Own-uid processes only.
    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// First needle appearing anywhere in the process's argv. Pass needles
    /// longest-first so "wave-10" wins over its "wave-1" prefix. Own-uid
    /// processes only.
    static func firstArgumentMatch(in pid: pid_t, needles: [String]) -> String? {
        guard !needles.isEmpty else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        // argv strings are NUL-separated; a lossy decode is fine for substring
        // matching.
        let text = String(decoding: buffer.prefix(size), as: UTF8.self)
        return needles.first { text.contains($0) }
    }

    // MARK: - Own threads

    /// Every thread in Wave with the kernel's recent CPU estimate — the rows
    /// that answer "is it the renderer, the main thread, or one of Wave's
    /// own queues".
    static func ownThreads() -> [ThreadReading] {
        var list: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS,
              let list else { return [] }
        defer {
            for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, list[i]) }
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: list)),
                vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
            )
        }

        var readings: [ThreadReading] = []
        readings.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            var extended = thread_extended_info_data_t()
            var extendedCount = mach_msg_type_number_t(
                MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size
            )
            let extendedStatus = withUnsafeMutablePointer(to: &extended) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(extendedCount)) {
                    thread_info(list[i], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &extendedCount)
                }
            }
            guard extendedStatus == KERN_SUCCESS else { continue }

            var identity = thread_identifier_info_data_t()
            var identityCount = mach_msg_type_number_t(
                MemoryLayout<thread_identifier_info_data_t>.size / MemoryLayout<natural_t>.size
            )
            let identityStatus = withUnsafeMutablePointer(to: &identity) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(identityCount)) {
                    thread_info(list[i], thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &identityCount)
                }
            }
            let identified = identityStatus == KERN_SUCCESS

            var name = withUnsafeBytes(of: extended.pth_name) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            if name.isEmpty, identified {
                name = queueLabel(at: identity.dispatch_qaddr) ?? ""
            }

            readings.append(ThreadReading(
                id: identified ? identity.thread_id : UInt64(i),
                name: name,
                // pth_cpu_usage is scaled by TH_USAGE_SCALE (1000).
                cpuPercent: Double(extended.pth_cpu_usage) / 10.0
            ))
        }
        return readings
    }

    /// Label of the dispatch queue a thread is draining right now. libdispatch
    /// keeps the queue pointer in a per-thread slot and publishes the slot's
    /// address as `dispatch_qaddr`; `sample` and `spindump` read the same slot
    /// to print "DispatchQueue_N: com.example.queue" for unnamed threads. The
    /// main thread reports com.apple.main-thread.
    private static func queueLabel(at address: UInt64) -> String? {
        guard let slot = UnsafeRawPointer(bitPattern: UInt(address)),
              let queuePointer = slot.load(as: UnsafeRawPointer?.self)
        else { return nil }
        // Every queue a Wave thread drains is long-lived (Wave's own com.wave.*
        // queues, the root queues, Metal's, AppKit's), so an unretained read
        // is safe in practice; the label is copied out at once.
        let queue = Unmanaged<DispatchQueue>.fromOpaque(queuePointer).takeUnretainedValue()
        let label = queue.label
        return label.isEmpty ? nil : label
    }

    // MARK: - Own memory

    static func ownMemory() -> MemoryBreakdown? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return MemoryBreakdown(
            footprint: UInt64(info.phys_footprint),
            anonymous: UInt64(info.internal),
            compressed: UInt64(info.compressed),
            graphics: UInt64(max(0, info.ledger_tag_graphics_footprint)),
            peakFootprint: UInt64(max(0, info.ledger_phys_footprint_peak))
        )
    }

    // MARK: - Machine

    /// "Apple M4 Pro" and the like.
    static func cpuBrand() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let brand = String(cString: buffer)
        return brand.isEmpty ? nil : brand
    }
}
