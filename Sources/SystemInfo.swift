import Foundation
import Darwin

/// Live XNU/Darwin data the demo reacts to. Sampled on a background timer;
/// `snapshot` is read by the renderer every frame.
struct SystemSnapshot {
    var kernVersion = ""      // kern.version
    var osVersion = ""        // kern.osversion (build id)
    var osRelease = ""        // kern.osrelease (Darwin version)
    var model = ""            // hw.model
    var machine = ""          // hw.machine
    var hostname = ""         // kern.hostname
    var ncpu = 1              // hw.ncpu
    var memSize: UInt64 = 0   // hw.memsize
    var cpuLoad: [Float] = [] // per-core busy fraction since the last sample
    var loadAvg: Float = 0    // 1-minute load average / ncpu
    var memPressure: Float = 0 // 0 = plenty free, 1 = starved
    var uptime: Double = 0    // seconds since kern.boottime
    var processes: [(pid: Int32, name: String)] = []
    var threadCount = 0
    var machPorts = 0         // Mach port names in our own task
    var pageSize = 4096
}

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buf = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "" }
    return String(cString: buf).trimmingCharacters(in: .whitespacesAndNewlines)
}

func sysctlInt<T: FixedWidthInteger>(_ name: String, _ type: T.Type = T.self) -> T {
    var value: T = 0
    var size = MemoryLayout<T>.size
    sysctlbyname(name, &value, &size, nil, 0)
    return value
}

final class SystemInfo {
    static let shared = SystemInfo()
    private let lock = NSLock()
    private var snap = SystemSnapshot()
    private var prevTicks: [UInt32] = []
    private var timer: DispatchSourceTimer?

    var snapshot: SystemSnapshot { lock.lock(); defer { lock.unlock() }; return snap }

    private init() {
        snap.kernVersion = sysctlString("kern.version")
        snap.osVersion = sysctlString("kern.osversion")
        snap.osRelease = sysctlString("kern.osrelease")
        snap.model = sysctlString("hw.model")
        snap.machine = sysctlString("hw.machine")
        snap.hostname = sysctlString("kern.hostname")
        snap.ncpu = Int(sysctlInt("hw.ncpu", Int32.self))
        snap.memSize = sysctlInt("hw.memsize", UInt64.self)
        snap.pageSize = Int(sysctlInt("hw.pagesize", Int32.self))
        sample()
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    private func sample() {
        let load = cpuLoads()
        let procs = processList()
        var la = [Double](repeating: 0, count: 3)
        getloadavg(&la, 3)
        let pressure = memoryPressure()
        let up = uptimeSeconds()
        let ports = machPortCount()
        let threads = threadCount()
        lock.lock()
        if !load.isEmpty { snap.cpuLoad = load }
        snap.processes = procs
        snap.loadAvg = Float(la[0] / Double(max(snap.ncpu, 1)))
        snap.memPressure = pressure
        snap.uptime = up
        snap.machPorts = ports
        snap.threadCount = threads
        lock.unlock()
    }

    /// host_processor_info(PROCESSOR_CPU_LOAD_INFO) gives cumulative ticks per core;
    /// busy fraction is the delta of (user+system+nice) over the delta of all ticks.
    private func cpuLoads() -> [Float] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        let n = Int(count)
        let stride = Int(CPU_STATE_MAX)
        var ticks = [UInt32](repeating: 0, count: n * stride)
        for i in 0..<(n * stride) { ticks[i] = UInt32(bitPattern: info[i]) }
        var loads = [Float](repeating: 0, count: n)
        if prevTicks.count == ticks.count {
            for c in 0..<n {
                let b = c * stride
                let user = ticks[b + Int(CPU_STATE_USER)] &- prevTicks[b + Int(CPU_STATE_USER)]
                let sys = ticks[b + Int(CPU_STATE_SYSTEM)] &- prevTicks[b + Int(CPU_STATE_SYSTEM)]
                let nice = ticks[b + Int(CPU_STATE_NICE)] &- prevTicks[b + Int(CPU_STATE_NICE)]
                let idle = ticks[b + Int(CPU_STATE_IDLE)] &- prevTicks[b + Int(CPU_STATE_IDLE)]
                let total = user + sys + nice + idle
                loads[c] = total > 0 ? Float(user + sys + nice) / Float(total) : 0
            }
        }
        prevTicks = ticks
        return loads
    }

    /// sysctl KERN_PROC_ALL returns kinfo_proc records; p_comm is the 16-char command name.
    private func processList() -> [(pid: Int32, name: String)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride + 16
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        size = count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let got = size / MemoryLayout<kinfo_proc>.stride
        var out: [(pid: Int32, name: String)] = []
        out.reserveCapacity(got)
        for i in 0..<got {
            var p = procs[i]
            let name = withUnsafePointer(to: &p.kp_proc.p_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: 17) { String(cString: $0) }
            }
            if !name.isEmpty { out.append((p.kp_proc.p_pid, name)) }
        }
        return out
    }

    /// kern.memorystatus_level is the percentage of memory the kernel considers available.
    private func memoryPressure() -> Float {
        let level: Int32 = sysctlInt("kern.memorystatus_level")
        if level > 0 { return 1 - Float(min(level, 100)) / 100 }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard ok == KERN_SUCCESS, snap.memSize > 0 else { return 0.5 }
        let free = Double(stats.free_count + stats.inactive_count) * Double(snap.pageSize)
        return Float(1 - free / Double(snap.memSize))
    }

    private func uptimeSeconds() -> Double {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - (Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }

    private func machPortCount() -> Int {
        var names: mach_port_name_array_t?
        var namesCount: mach_msg_type_number_t = 0
        var types: mach_port_type_array_t?
        var typesCount: mach_msg_type_number_t = 0
        guard mach_port_names(mach_task_self_, &names, &namesCount, &types, &typesCount) == KERN_SUCCESS else { return 0 }
        if let names { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: names), vm_size_t(namesCount) * vm_size_t(MemoryLayout<mach_port_name_t>.size)) }
        if let types { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: types), vm_size_t(typesCount) * vm_size_t(MemoryLayout<mach_port_type_t>.size)) }
        return Int(namesCount)
    }

    private func threadCount() -> Int {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        for i in 0..<Int(count) { mach_port_deallocate(mach_task_self_, threads[i]) }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), vm_size_t(count) * vm_size_t(MemoryLayout<thread_act_t>.size))
        return Int(count)
    }
}

/// Demo clock on mach_absolute_time. Zeroed by the first audio render callback so
/// visuals and the synth share the same origin.
enum DemoClock {
    static let bpm = 128.0
    nonisolated(unsafe) static var startHost: UInt64 = 0
    static let timebase: Double = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()
    static func now() -> Double {
        let s = startHost
        if s == 0 { return 0 }
        return Double(mach_absolute_time() &- s) * timebase
    }
    static func markStartIfNeeded() {
        if startHost == 0 { startHost = mach_absolute_time() }
    }
    static func beat(at t: Double) -> Double { t * bpm / 60 }
}
