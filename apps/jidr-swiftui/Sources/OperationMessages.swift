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
        let exact = [
            "UI preview: this operation requires a real device connection.":"界面预览无法执行此操作，请连接真实设备。",
            "speed must be between 0 and 64×":"路线速度倍率须大于 0 且不超过 64。",
            "no track, route or way points in the file":"文件中没有有效的路线或坐标点。",
            "root.module.install needs a Full-root (Magisk) device":"安装模块需要完整 Root（Magisk）设备。",
            "give either cert or all":"请选择要移除的证书。",
            "The existing configuration must be a JSON object.":"现有配置必须是 JSON 对象。",
            "The existing mcpServers value must be a JSON object.":"现有的 mcpServers 必须是 JSON 对象。",
            "Claude's configuration directory does not exist.":"未找到 Claude 的配置目录。",
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
            "Saving memory and disk":"正在保存内存和磁盘状态"
        ]
        if let translated = known[value] { return translated }
        for (prefix, translated) in [("Downloading Magisk ","正在下载 Magisk "), ("Patching the ramdisk for Magisk ","正在修补 Magisk 启动镜像 "),
                                     ("Downloading ","正在下载 "), ("Verifying ","正在验证 "),
                                     ("Extracting ","正在解压 "), ("Done ","已完成 ")] {
            if value.hasPrefix(prefix) { return translated + value.dropFirst(prefix.count) }
        }
        return value // Keep URLs, licence notices and unknown diagnostics intact.
    }
}
