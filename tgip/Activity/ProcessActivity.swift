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
        let id: Int
        let name: String
        /// The kernel's recent-usage estimate for the thread, in % of one core.
        let cpuPercent: Double
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

    /// Wave's own threads with the kernel's recent CPU estimate — the rows
    /// that answer "is it the renderer or the main thread".
    static func ownThreads(limit: Int) -> [ThreadReading] {
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
        for i in 0..<Int(count) {
            var info = thread_extended_info_data_t()
            var infoCount = mach_msg_type_number_t(
                MemoryLayout<thread_extended_info_data_t>.size / MemoryLayout<natural_t>.size
            )
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(list[i], thread_flavor_t(THREAD_EXTENDED_INFO), $0, &infoCount)
                }
            }
            guard status == KERN_SUCCESS else { continue }
            let name = withUnsafeBytes(of: info.pth_name) { raw in
                String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            readings.append(ThreadReading(
                id: i,
                // The main thread carries no pthread name; it is always the
                // task's first thread.
                name: name.isEmpty ? (i == 0 ? "Main thread" : "Thread \(i + 1)") : name,
                // pth_cpu_usage is scaled by TH_USAGE_SCALE (1000).
                cpuPercent: Double(info.pth_cpu_usage) / 10.0
            ))
        }
        return Array(readings.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(limit))
    }
}
