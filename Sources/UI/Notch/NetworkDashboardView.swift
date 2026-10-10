import AppKit
import SwiftUI

struct NetworkDashboardStatusView: View {
    @ObservedObject var monitor: NetworkDashboardMonitor

    var body: some View {
        HStack(spacing: 9) {
            HStack(spacing: 4) {
                Text(monitor.isConnected ? monitor.flag : "")
                if !monitor.isConnected {
                    Image(systemName: "wifi.slash").foregroundStyle(.orange)
                }
                Text(monitor.isConnected ? (monitor.countryCode.isEmpty ? "网络" : monitor.countryCode.uppercased()) : "已断开")
                    .font(.system(size: 10, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.85))
            Rectangle().fill(.white.opacity(0.14)).frame(width: 1, height: 18)
            VStack(alignment: .trailing, spacing: 2) {
                rateRow("arrow.down", monitor.downloadBytesPerSecond, tint: .mint)
                rateRow("arrow.up", monitor.uploadBytesPerSecond, tint: .white.opacity(0.65))
            }
        }
        .frame(height: 26)
        .help("当前出口： \(monitor.status)\n本机实时流量。分流规则可能使不同网站使用不同出口。")
        .accessibilityElement(children: .combine)
    }

    private func rateRow(_ symbol: String, _ rate: Double?, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold)).foregroundStyle(tint)
            Text(NetworkDashboardMonitor.formatRate(rate))
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.8)).frame(minWidth: 62, alignment: .trailing)
        }
    }
}

