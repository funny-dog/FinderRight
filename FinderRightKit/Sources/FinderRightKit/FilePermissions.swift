import Foundation
import Darwin

/// 文件权限读取与解析（纯逻辑，可独立单测）。
public struct FilePermissions: Equatable {
    public let mode: mode_t
    public let octal: String       // 例如 "755" 或 "644"
    public let symbolic: String    // 例如 "-rwxr-xr-x" 或 "drwxr-xr-x"
    public let owner: String?
    public let group: String?

    public var menuTitle: String {
        "权限：\(symbolic) (\(octal))"
    }

    public var toolTip: String {
        var lines = ["权限：\(symbolic) (\(octal))"]
        if let owner {
            if let group {
                lines.append("所属：\(owner):\(group)")
            } else {
                lines.append("所有者：\(owner)")
            }
        }
        lines.append("点击复制权限")
        return lines.joined(separator: "\n")
    }

    public static func permissions(at path: String) -> FilePermissions? {
        var st = stat()
        if lstat(path, &st) != 0 { return nil }
        return FilePermissions(mode: st.st_mode, uid: st.st_uid, gid: st.st_gid)
    }

    public init(mode: mode_t, uid: uid_t? = nil, gid: gid_t? = nil) {
        self.mode = mode
        let permBits = mode & 0o7777
        self.octal = String(format: "%03o", permBits & 0o777)

        let typeChar: Character
        let typeMask = mode & S_IFMT
        switch typeMask {
        case S_IFDIR:  typeChar = "d"
        case S_IFLNK:  typeChar = "l"
        case S_IFREG:  typeChar = "-"
        case S_IFSOCK: typeChar = "s"
        case S_IFIFO:  typeChar = "p"
        case S_IFCHR:  typeChar = "c"
        case S_IFBLK:  typeChar = "b"
        default:       typeChar = "-"
        }

        func triple(_ r: mode_t, _ w: mode_t, _ x: mode_t, _ special: mode_t, _ sNorm: Character, _ sOther: Character) -> String {
            let rc: Character = (mode & r) != 0 ? "r" : "-"
            let wc: Character = (mode & w) != 0 ? "w" : "-"
            let xc: Character
            if (mode & special) != 0 {
                xc = (mode & x) != 0 ? sNorm : sOther
            } else {
                xc = (mode & x) != 0 ? "x" : "-"
            }
            return String([rc, wc, xc])
        }

        let userStr = triple(S_IRUSR, S_IWUSR, S_IXUSR, S_ISUID, "s", "S")
        let groupStr = triple(S_IRGRP, S_IWGRP, S_IXGRP, S_ISGID, "s", "S")
        let otherStr = triple(S_IROTH, S_IWOTH, S_IXOTH, S_ISVTX, "t", "T")

        self.symbolic = "\(typeChar)\(userStr)\(groupStr)\(otherStr)"

        if let uid {
            if let pw = getpwuid(uid), let name = pw.pointee.pw_name {
                self.owner = String(cString: name)
            } else {
                self.owner = "\(uid)"
            }
        } else {
            self.owner = nil
        }

        if let gid {
            if let gr = getgrgid(gid), let name = gr.pointee.gr_name {
                self.group = String(cString: name)
            } else {
                self.group = "\(gid)"
            }
        } else {
            self.group = nil
        }
    }
}
