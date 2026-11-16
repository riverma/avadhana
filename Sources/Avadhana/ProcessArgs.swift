import Darwin

/// Returns the command-line arguments of another process owned by the same user.
/// Used to tell the Focus Firefox profile apart from your normal Firefox (same bundle ID).
func processArguments(pid: pid_t) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }

    var argc: Int32 = 0
    withUnsafeMutableBytes(of: &argc) { $0.copyBytes(from: buf[0..<MemoryLayout<Int32>.size]) }

    var i = MemoryLayout<Int32>.size
    while i < size && buf[i] != 0 { i += 1 }   // skip executable path
    while i < size && buf[i] == 0 { i += 1 }   // skip padding

    var args: [String] = []
    while args.count < Int(argc) && i < size {
        let start = i
        while i < size && buf[i] != 0 { i += 1 }
        args.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return args
}
