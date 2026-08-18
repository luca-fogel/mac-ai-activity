import Foundation
import Darwin

/// Listening TCP ports for a pid, read natively from its file descriptors.
///
/// This is independent confirmation of the port found in argv. When the two
/// disagree the socket wins: a server may have fallen back to a different port
/// than the one it was asked for, and argv would then be a lie.
public enum ProcSockets {

    public static func listeningPorts(_ pid: Int32) -> [UInt16] {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return [] }
        let count = Int(bufSize) / MemoryLayout<proc_fdinfo>.size + 8
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let n = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds,
                             Int32(count * MemoryLayout<proc_fdinfo>.size))
        guard n > 0 else { return [] }

        var ports: Set<UInt16> = []
        for i in 0..<(Int(n) / MemoryLayout<proc_fdinfo>.size) {
            guard fds[i].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }
            var si = socket_fdinfo()
            let sz = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, sz) == sz
            else { continue }
            guard si.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            // Only listening sockets: no remote peer bound.
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let be = tcp.tcpsi_ini.insi_lport            // network byte order
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: be))
            if port != 0 { ports.insert(port) }
        }
        return ports.sorted()
    }
}
