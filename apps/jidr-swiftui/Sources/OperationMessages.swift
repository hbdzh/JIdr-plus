// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum OperationMessages {
    static func routeSpeed(_ value:String) -> Double? {
        guard let speed = Double(value), speed.isFinite, speed > 0, speed <= 64 else { return nil }
        return speed
    }
    static func notice(_ value:String, language:Int) -> String {
        let pairs = [
            ("SDK 安装完成。", "SDK installation complete."),
            ("操作完成", "Completed"),
            ("完整 Root 验证成功。", "Full root verified."),
            ("正在保存录屏…", "Saving recording…"),
            ("正在启动录屏…", "Starting recording…"),
            ("录屏已保存", "Recording saved"),
            ("无法打开截图目录。", "Cannot open the screenshots folder.")
        ]
        if let pair = pairs.first(where: { value == $0.0 || value == $0.1 }) { return language == 0 ? pair.1 : pair.0 }
        return progress(value,language:language)
    }
    static func error(_ value:String, language:Int) -> String {
        guard language != 0 else { return value }
        let stoppedSuffix = " is not running; start it first"
        if value.hasSuffix(stoppedSuffix) {
            let name = String(value.dropLast(stoppedSuffix.count))
            return "设备“\(name)”未运行，请先启动设备。"
        }
        let exact = [
            "this needs root: set the device's root mode to adb (Shell root) or magisk (Full root)":"此功能需要 Root，请将设备设为 Shell Root 或完整 Root。",
            "on-device helper: this image's kernel has no netem (CONFIG_NET_SCH_NETEM)":"此系统镜像的内核不支持网络丢包模拟。",
            "on-device helper: no interface has a default route (is Wi-Fi or mobile data on?)":"没有可用的默认网络接口，请检查 Wi-Fi 或移动数据。",
            "UI preview: this operation requires a real device connection.":"界面预览无法执行此操作，请连接真实设备。",
            "speed must be between 0 and 64×":"路线速度倍率须大于 0 且不超过 64。",
            "no track, route or way points in the file":"文件中没有有效的路线或坐标点。",
            "root.module.install needs a Full-root (Magisk) device":"安装模块需要完整 Root（Magisk）设备。",
            "give either cert or all":"请选择要移除的证书。",
            "The existing configuration must be a JSON object.":"现有配置必须是 JSON 对象。",
            "The existing mcpServers value must be a JSON object.":"现有的 mcpServers 必须是 JSON 对象。",
            "Codex CLI was not found. Install Codex or add its CLI to PATH.":"未找到 Codex 命令行工具。请安装 Codex 或将其命令行工具加入 PATH。",
            "The existing WorkBuddy configuration must be a JSON object.":"现有 WorkBuddy 配置必须是 JSON 对象。",
            "The existing WorkBuddy mcpServers value must be a JSON object.":"现有 WorkBuddy 的 mcpServers 必须是 JSON 对象。",
            "Enter the path to the jidr command.":"请输入 jidr 命令路径。"
        ]
        if let text = exact[value] { return text }
        let prefixes = [
            ("no such module zip: ", "找不到模块文件："),
            ("no such certificate file: ", "找不到证书文件："),
            ("not a PEM or DER X.509 certificate: ", "证书格式无效，请选择 PEM 或 DER X.509 证书："),
            ("installing the module: ", "安装模块失败："),
            ("no route is playing on ", "没有正在播放的路线：")
        ]
        for (prefix, translation) in prefixes where value.hasPrefix(prefix) { return translation + value.dropFirst(prefix.count) }
        return "操作失败：" + value
    }

    static func storageError(code: String?, message: String, language: Int) -> String {
        if let code {
            switch code {
            case "storage.env_override":
                return language == 0
                    ? "JIDR_HOME is set in the environment; unset it before changing the data folder."
                    : "当前设置了 JIDR_HOME 环境变量，请先取消该变量后再更改数据目录。"
            case "storage.destination_exists":
                return language == 0
                    ? "The chosen folder already contains a Jidr folder. Choose another folder."
                    : "所选目录下已存在 Jidr 文件夹，请选择其他位置。"
            case "storage.destination_overlap":
                return language == 0
                    ? "The chosen folder cannot overlap the current Jidr storage directory."
                    : "目标目录不能与当前 Jidr 存储目录重叠。"
            case "storage.insufficient_space":
                return language == 0
                    ? message
                    : "目标磁盘空间不足：\(message)"
            case "storage.missing_qemu_img":
                return language == 0
                    ? "qemu-img was not found; install or configure an Android SDK before migrating device disks."
                    : "未找到 qemu-img 工具，无法校验设备磁盘镜像；请先安装或配置 Android SDK。"
            case "storage.devices_active":
                return language == 0
                    ? "One or more devices are still running or have open files. Stop all devices and try again."
                    : "仍有设备处于运行状态或磁盘文件被占用，请先停止所有设备后重试。"
            case "storage.incomplete_snapshot":
                return language == 0
                    ? "An incomplete snapshot was found. Boot and cleanly save or remove it before migrating."
                    : "发现不完整的快照文件，请先启动设备并完整保存或清理异常快照后再迁移。"
            case "storage.symlink_unsupported":
                return language == 0
                    ? "Symbolic links inside the data directory cannot be migrated automatically."
                    : "数据目录中包含符号链接，暂不支持自动迁移。"
            case "storage.quit_timeout":
                return language == 0
                    ? "The background service did not exit cleanly in time. Try again."
                    : "后台服务未在预期时间内退出，请重试。"
            default:
                break
            }
        }
        return Self.error(message, language: language)
    }
    static func progress(_ value:String, language:Int) -> String {
        guard language != 0 else { return value }
        let known = [
            "Resolving the Magisk release":"正在准备 Magisk 安装包",
            "Installing the Magisk app":"正在安装 Magisk 应用",
            "Setting up Magisk's environment":"正在配置 Magisk 环境",
            "Stopping before the cold boot":"正在安全停止设备，准备冷启动",
            "Cold booting":"正在冷启动设备",
            "Rebooting":"正在重启设备",
            "Granting the adb shell su access":"正在授予 shell root 权限",
            "Verifying root":"正在验证 Root 权限",
            "su didn't answer as root; cold booting once more":"Root 暂未响应，正在再次冷启动",
            "Play Store: open the Magisk app to finish its setup, then grant root to Shell":"请在设备中打开 Magisk 完成设置，然后为 Shell 授权",
            "Saving memory and disk":"正在保存内存和磁盘状态",
            "Starting emulator":"正在启动模拟器",
            "Connecting emulator control":"正在连接模拟器控制通道",
            "Waiting for Android boot":"正在等待 Android 系统启动",
            "Booted":"设备已就绪",
            "Stopping background service":"正在停止后台服务",
            "Copying and verifying device data":"正在复制并校验设备数据",
            "Switching data location":"正在切换数据目录"
        ]
        if let translated = known[value] { return translated }
        let slowSuffix = "; slow when the Mac is busy)"
        if value.hasSuffix(slowSuffix), let openParen = value.lastIndex(of: "(") {
            let base = String(value[..<openParen]).trimmingCharacters(in: .whitespaces)
            let secs = String(value[value.index(after: openParen)..<value.endIndex])
                .replacingOccurrences(of: slowSuffix, with: "")
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " s", with: " 秒")
            if let baseZh = known[base] {
                return "\(baseZh)（已等待 \(secs)，高负载下可能较慢）"
            }
        }
        for (prefix, translated) in [("Downloading Magisk ","正在下载 Magisk "), ("Patching the ramdisk for Magisk ","正在修补 Magisk 启动镜像 "),
                                     ("Downloading ","正在下载 "), ("Verifying ","正在验证 "),
                                     ("Extracting ","正在解压 "), ("Done ","已完成 ")] {
            if value.hasPrefix(prefix) { return translated + value.dropFirst(prefix.count) }
        }
        return value // Keep URLs, licence notices and unknown diagnostics intact.
    }
}
