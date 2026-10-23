//  SundiroWidget.swift
//  WidgetKit extension for 新大洲本田 (com.sundirohonda.app)
//
//  Reads the account/vehicle bridge state that SundiroBridge.dylib
//  mirrors into the shared App Group container, then talks to the
//  Honda Sundiro cloud API directly from the widget process.
//
//  Target: iOS 15.0+ / arm64

import WidgetKit
import SwiftUI
import Foundation
import Darwin

// MARK: - Shared bridge state -------------------------------------------------

private let kAppGroup   = "group.com.carbit.edrive.honda"
private let kStateDir   = "SundiroWidget"
private let kStateFile  = "state.json"
private let kAPIRoot    = "https://crmlot-app.honda-sundiro.com/app"

struct BridgeState: Codable {
    var token:        String?
    var vehicleCode:  String?
    var deviceCode:   String?
    var vehicleName:  String?
    var appVersion:   String?
    var updatedAt:    Double?
    var heartbeat:    Double?
    var lastAction:   String?
    var lastActionAt: Double?
    var status:       [String: Double]?   // 车况本地快照（电量/油量/电压/续航），云端拿不到时兜底

    static let empty = BridgeState()
}

private func stateFileURL() -> URL? {
    guard let base = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: kAppGroup) else { return nil }
    return base.appendingPathComponent(kStateDir).appendingPathComponent(kStateFile)
}

private func loadBridgeState() -> BridgeState {
    // 1) 首选通道:共享 App Group 容器(由 SundiroBridge.dylib 写入)
    if let url = stateFileURL(), let data = try? Data(contentsOf: url) {
        if let s = try? JSONDecoder().decode(BridgeState.self, from: data), s.token != nil { return s }
    }
    // 2) 退路:扩展以 no-sandbox 运行时,直接翻 App 自己的偏好 plist
    if let s = scanAppContainers(), s.token != nil { return s }
    // 3) 退回 App Group 里哪怕没有 token 的缓存
    if let url = stateFileURL(), let data = try? Data(contentsOf: url),
       let s = try? JSONDecoder().decode(BridgeState.self, from: data) { return s }
    return .empty
}

/// 扫描 /var/mobile/Containers/Data/Application/*/Library/Preferences/com.sundirohonda.app.plist
/// 取最新修改的那一份,直接从里面挑 JWT / vehicleCode / deviceCode。
private func scanAppContainers() -> BridgeState? {
    let fm = FileManager.default
    let root = "/var/mobile/Containers/Data/Application"
    guard let uuids = try? fm.contentsOfDirectory(atPath: root) else { return nil }

    var best: (Date, [String: Any])?
    for uuid in uuids {
        let plistPath = "\(root)/\(uuid)/Library/Preferences/com.sundirohonda.app.plist"
        guard let attrs = try? fm.attributesOfItem(atPath: plistPath),
              let mtime = attrs[.modificationDate] as? Date,
              let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any] else { continue }
        if best == nil || mtime > best!.0 { best = (mtime, dict) }
    }
    guard let dict = best?.1 else { return nil }

    var s = BridgeState()
    for (k, v) in dict {
        guard let str = v as? String else { continue }
        let lk = k.lowercased()
        if s.token == nil, (lk.contains("token") || lk.contains("authorization") || lk == "auth"),
           str.count > 20 {
            s.token = str.hasPrefix("Bearer ") ? String(str.dropFirst(7)) : str
        }
        if s.vehicleCode == nil, lk.contains("vehiclecode"), str.count == 36 { s.vehicleCode = str }
        if s.deviceCode == nil, lk.contains("devicecode"), str.count >= 14, str.count <= 17,
           str.allSatisfy({ $0.isNumber }) { s.deviceCode = str }
        if s.vehicleName == nil, lk == "vehiclename" || lk == "nickname" { s.vehicleName = str }
    }
    return s
}

// MARK: - Model ---------------------------------------------------------------

struct VehicleStatus {
    var hasAccount: Bool = false
    var name:       String = "新大洲本田"
    var tireF:      Int?           // 前胎压 kPa
    var tireR:      Int?           // 后胎压 kPa
    var trip:       Double?        // 本次行程 km
    var fuel:       Int?           // 油量，%
    var fuelLiters: Double?        // 油量，升（有油箱容量时才算得出来）
    var fuelCapL:   Double?        // ★ 油箱总容量，升 —— 显示「5.0/6 L」用
    var batVolt:    Double?        // 小电池电压，V
    var odo:        Double?        // 总里程 km
    var updated:    Date?
    var note:       String?
}

struct SundiroEntry: TimelineEntry {
    let date: Date
    let status: VehicleStatus
}

// MARK: - Tiny sync HTTP ------------------------------------------------------

private struct APIError: Error { let message: String }

/// Synchronous JSON request; widget providers run off the main thread.
private func apiGet(_ path: String, token: String, timeout: TimeInterval = 12) throws -> Any? {
    guard let url = URL(string: kAPIRoot + path) else { throw APIError(message: "bad url") }
    var req = URLRequest(url: url)
    req.httpMethod = "GET"
    req.timeoutInterval = timeout
    req.setValue("Bearer \(token)",      forHTTPHeaderField: "authorization")
    req.setValue("1",                    forHTTPHeaderField: "apptype")
    req.setValue("zh_CN",                forHTTPHeaderField: "language")
    req.setValue("application/json",     forHTTPHeaderField: "content-type")

    let sem = DispatchSemaphore(value: 0)
    var payload: Any?
    var failure: Error?

    URLSession.shared.dataTask(with: req) { data, _, err in
        defer { sem.signal() }
        if let err = err { failure = err; return }
        guard let data = data else { failure = APIError(message: "empty"); return }
        payload = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }.resume()

    if sem.wait(timeout: .now() + timeout + 1) == .timedOut {
        throw APIError(message: "timeout")
    }
    if let failure = failure { throw failure }
    return payload
}

/// Unwraps the `{code,msg,data}` envelope; throws when code != 200.
private func unwrap(_ payload: Any?) throws -> Any? {
    guard let dict = payload as? [String: Any] else {
        throw APIError(message: "malformed response")
    }
    let code = (dict["code"] as? NSNumber)?.intValue
        ?? Int((dict["code"] as? String) ?? "0") ?? -1
    guard code == 200 || code == 0 else {
        throw APIError(message: (dict["msg"] as? String) ?? "code \(code)")
    }
    return dict["data"]
}

private func asDouble(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

private func firstString(_ dict: [String: Any], _ keys: [String]) -> String? {
    for k in keys {
        if let s = dict[k] as? String, !s.isEmpty { return s }
        if let n = dict[k] as? NSNumber { return n.stringValue }
    }
    return nil
}

private func pickVehicle(from state: BridgeState, token: String) throws -> [String: Any] {
    if let data = try unwrap(try apiGet("/api/vehicle/v1/garage", token: token)) {
        if let list = data as? [[String: Any]], let first = list.first { return first }
        if let dict = data as? [String: Any] {
            for key in ["list", "records", "vehicleList", "garageList", "rows"] {
                if let list = dict[key] as? [[String: Any]], let first = list.first { return first }
            }
            if dict["vehicleCode"] != nil { return dict }
        }
    }
    throw APIError(message: "没有可用车辆")
}

// MARK: - Fetch ---------------------------------------------------------------

private func fetchStatus() -> VehicleStatus {
    var st = VehicleStatus()
    let state = loadBridgeState()

    // 先把本地快照铺上（App 抓到什么就先显示什么），下面云端数据会覆盖它
    if let snap = state.status, !snap.isEmpty {
        if let v = snap["fuel"] {
            if let c = snap["fuelCap"], c > 0 { st.fuelLiters = v / 100 * c }
            st.fuel = Int(v)
        }
        // ★ 快照里 fuelCap 是【油箱总容量】(6)，不是当前油量
        if let c = snap["fuelCap"], c > 0 { st.fuelCapL = c }
        if let v = snap["smallBatteryVoltage"] { st.batVolt = v }
        if let v = snap["tireFront"] { st.tireF = Int(v) }
        if let v = snap["tireRear"]  { st.tireR = Int(v) }
        if let v = snap["trip"]      { st.trip  = v }
        if let v = snap["totalMileage"] { st.odo = v }
        if let at = snap["at"] { st.updated = Date(timeIntervalSince1970: at) }
        st.hasAccount = true
    }

    guard let token = state.token, !token.isEmpty else {
        if !st.hasAccount { st.note = "打开 App 登录后即可同步" }
        else { st.note = "本地快照" }
        return st
    }
    st.hasAccount = true

    do {
        let vehicle = try pickVehicle(from: state, token: token)
        let vcode = state.vehicleCode
            ?? firstString(vehicle, ["vehicleCode", "code", "carCode"])
        st.name = state.vehicleName
            ?? firstString(vehicle, ["vehicleName", "nickName", "carName", "modelName"])
            ?? "新大洲本田"
        // ★ 实测语义（2026-10-07）：fuelCap = 【当前油量】升，fuelTotalCap = 【容量】升。
        //   此前把 fuelCap 当容量作除数，是同一个命名陷阱 —— garage 现在没有 fuel
        //   字段所以走不到，但接口一旦加上就会算错。这里按正确语义实现。
        let curL = asDouble(vehicle["fuel"])
        let capL = asDouble(vehicle["fuelTotalCap"] ?? vehicle["fuelCapacity"])
        if let cur = curL, let cap = capL, cap > 0 {
            st.fuelLiters = cur
            st.fuelCapL   = cap
            st.fuel       = Int((cur / cap * 100).rounded())
        }
        if let v = asDouble(vehicle["smallBatteryVoltage"] ?? vehicle["batteryVoltage"]) {
            st.batVolt = v > 1000 ? v / 1000.0 : v      // 有的接口给毫伏
        }
        // ★ 只在接口【真有值】时才覆盖 —— 否则会把 state.json 快照里
        //   已经写好的总里程（来自骑行记录接口）用 nil 抹掉。
        if let o = asDouble(vehicle["totalMileage"] ?? vehicle["mileage"]) { st.odo = o }
		if let t = asDouble(vehicle["frontTirePressure"]) { st.tireF = Int(t) }
		if let t = asDouble(vehicle["rearTirePressure"])  { st.tireR = Int(t) }

        if let vcode = vcode {
            if let data = try unwrap(try apiGet("/api/vehicle/v1/homeVehicle/\(vcode)", token: token)),
               let home = data as? [String: Any] {
                st.name = firstString(home, ["vehicleName", "nickName", "carName", "modelName"]) ?? st.name
                // ★ 只在快照没有油量时兜底 —— 车辆未通电时接口给 6/6（满格），
                //   若无条件覆盖会把骑行中抓到的真值冲掉。
                if st.fuel == nil,
                   let cur = asDouble(home["fuelCap"]),
                   let cap = asDouble(home["fuelTotalCap"]), cap > 0 {
                    st.fuelLiters = cur
                    st.fuelCapL   = cap
                    st.fuel       = Int((cur / cap * 100).rounded())
                }
                if let v = asDouble(home["smallBatteryVoltage"] ?? home["batteryVoltage"]) {
                    st.batVolt = v > 1000 ? v / 1000.0 : v
                }
                if let o = asDouble(home["totalMileage"] ?? home["mileage"]) { st.odo = o }
                if let t = asDouble(home["frontTirePressure"]) { st.tireF = Int(t) }
                if let t = asDouble(home["rearTirePressure"])  { st.tireR = Int(t) }
                if let c = asDouble(home["cyclingMileage"])    { st.trip  = c }
            }
        }
        st.updated = Date()
    } catch let e as APIError {
        st.note = e.message
    } catch {
        st.note = "网络异常"
    }
    return st
}

// MARK: - Timeline ------------------------------------------------------------

struct SundiroProvider: TimelineProvider {
    // MARK: - 存活标记（诊断用）-------------------------------------------------

private func markAlive(_ site: String) {
    let fm = FileManager.default
    guard let dir = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.carbit.edrive.honda") else { return }
    let text = "\(Date().timeIntervalSince1970) \(site) v51-static"
    try? text.write(to: dir.appendingPathComponent("widget_alive.txt"),
                    atomically: true, encoding: .utf8)
}

func placeholder(in context: Context) -> SundiroEntry {
        var st = VehicleStatus()
        st.hasAccount = true; st.tireF = 200; st.tireR = 214; st.trip = 2.9; st.odo = 1360
        st.updated = Date()
        return SundiroEntry(date: Date(), status: st)
    }

    func getSnapshot(in context: Context, completion: @escaping (SundiroEntry) -> Void) {
        markAlive("getSnapshot")
        if context.isPreview {
            completion(placeholder(in: context))
        } else {
            completion(SundiroEntry(date: Date(), status: fetchStatus()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SundiroEntry>) -> Void) {
        markAlive("getTimeline")
        // ★ 先跑启动守护：系统每次来刷新时间线，都是一次「把主 App 拉起来」的机会。
        //   重启+解锁后、以及日常刷新时都会走到这里。
        let entry = SundiroEntry(date: Date(), status: fetchStatus())
        let refresh = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }
}

// MARK: - Views ---------------------------------------------------------------

private func fuelColor(_ v: Int) -> Color {
    if v >= 40 { return Color(red: 0.16, green: 0.55, blue: 0.92) }
    if v >= 15 { return Color(red: 0.95, green: 0.68, blue: 0.16) }
    return Color(red: 0.92, green: 0.27, blue: 0.25)
}

/// 环形量规：电量、油量共用一个。
private struct RingGauge: View {
    let value: Int?
    var unit: String = ""
    var title: String? = nil
    var color: Color = .blue
    var maxValue: Double = 100
    var literal: String? = nil          // 副行，如「6.0/6 L」
    var ringWidth: CGFloat = 7
    var valueSize: CGFloat = 27
    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.10), lineWidth: ringWidth)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(maxValue, Double(value ?? 0))) / maxValue))
                .stroke(color, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(value.map { "\($0)" } ?? "—")
                        .font(.system(size: valueSize, weight: .bold, design: .rounded))
                        .foregroundColor(value == nil ? .secondary : color)
                    if !unit.isEmpty {
                        Text(unit).font(.system(size: valueSize * 0.42, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                if let t = title, !t.isEmpty {
                    Text(t).font(.system(size: 9, weight: .medium)).foregroundColor(.secondary)
                }
                if let lit = literal {
                    Text(lit).font(.system(size: valueSize * 0.36, weight: .medium, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

/// 胎压配色：<180 偏低、>260 偏高，中间正常
private func tireColor(_ v: Int) -> Color {
    if v == 0 { return .gray }
    if v < 180 { return Color(red: 0.92, green: 0.27, blue: 0.25) }
    if v > 260 { return Color(red: 0.95, green: 0.68, blue: 0.16) }
    return Color(red: 0.20, green: 0.72, blue: 0.42)
}

private struct NoAccountView: View {
    let note: String?
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "scooter")
                .font(.system(size: 24, weight: .regular))
                .foregroundColor(.secondary)
            Text(note ?? "打开 App 完成登录")
                .font(.system(size: 11))
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .padding(8)
    }
}

struct SundiroSmallView: View {
    let s: VehicleStatus
    var body: some View {
        if !s.hasAccount { NoAccountView(note: s.note) }
        else {
            VStack(alignment: .leading, spacing: 6) {
                Text(s.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                // ★ 布局 E：前胎压从「环」降级为文字（它本是数字读数，环无信息量），
                //   腾出的宽度把油量环从 54 放大到 62。
                // 小号宽度只有 158pt：环 62 之后右侧仅剩约 69pt。
                // 「前胎压 186 kPa」要 67pt，会折行 —— 标签统一收成 2 字，
                // 四项等宽、竖向对齐，且留出余量。
                HStack(spacing: 7) {
                    RingGauge(value: s.fuel, unit: "%",
                              color: fuelColor(s.fuel ?? 0), ringWidth: 6, valueSize: 20)
                        .frame(width: 62, height: 62)
                    VStack(alignment: .leading, spacing: 7) {
                        kv("前胎", s.tireF.map { "\($0)" }, "kPa", tireColor(s.tireF ?? 0))
                        kv("后胎", s.tireR.map { "\($0)" }, "kPa", tireColor(s.tireR ?? 0))
                        kv("电压", s.batVolt.map { String(format: "%.1f", $0) }, "V", .primary)
                        kv("行程", s.trip.map { String(format: "%.1f", $0) }, "km", .primary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Spacer(minLength: 0)
                Text(s.updated.map { "更新 \($0.formatted(date: .omitted, time: .shortened))" } ?? (s.note ?? ""))
                    .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
            }
            .padding(10)
            .widgetURL(URL(string: "xdzsundiro://open"))
        }
    }

    // 小号右侧的文字行：标签 + 数值 + 单位（标签完整不折行）
    private func kv(_ label: String, _ value: String?, _ unit: String, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Text(label).font(.system(size: 9)).foregroundColor(.secondary)
            Text(value ?? "—").font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(value == nil ? .secondary : color)
            Text(unit).font(.system(size: 8)).foregroundColor(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct SundiroMediumView: View {
    let s: VehicleStatus
    var body: some View {
        if !s.hasAccount { NoAccountView(note: s.note).frame(maxWidth: .infinity, maxHeight: .infinity) }
        else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(s.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text(s.updated.map { "更新 \($0.formatted(date: .omitted, time: .shortened))" } ?? (s.note ?? ""))
                        .font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                }
                // ★ 布局 E′：环只留油量并放大到 88；
                //   「续航」已删 —— 数据源 residueMileage 恒为 null（死字段，永远显示「—」）。
                // ★ F2：去掉末尾的 Spacer —— 它把整组内容顶到最左，右侧留下约 1/3 空白。
                //   改为整组居中，环再放大到 94 把高度吃满。
                HStack(spacing: 18) {
                    RingGauge(value: s.fuel, unit: "%",
                              color: fuelColor(s.fuel ?? 0),
                              literal: s.fuelLiters.flatMap { l in
                                  s.fuelCapL.map { String(format: "%.1f/%.0f L", l, $0) }
                              },
                              ringWidth: 8, valueSize: 30)
                        .frame(width: 104, height: 104)
                    VStack(alignment: .leading, spacing: 8) {
                        if let v = s.batVolt { metric("小电池", String(format: "%.1f", v), "V") }
                        if let t = s.tireF { metric("前胎压", "\(t)", "kPa", tireColor(t)) }
                        if let t = s.tireR { metric("后胎压", "\(t)", "kPa", tireColor(t)) }
                        if let c = s.trip { metric("本次行程", String(format: "%.1f", c), "km") }
                        metric("总里程", s.odo.map { String(format: "%.0f", $0) }, "km")
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(12)
            .widgetURL(URL(string: "xdzsundiro://open"))
        }
    }

    private func metric(_ title: String, _ value: String?, _ unit: String, _ color: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundColor(.secondary)
            Spacer(minLength: 8)
            Text(value ?? "—")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(value == nil ? .secondary : color)
            Text(unit).font(.system(size: 8.5)).foregroundColor(.secondary)
        }
    }
}

// MARK: - 锁屏配件（iOS 16+）----------------------------------------------------

/// 环内缺口里的踏板摩托车（车头朝左）。
/// 造型取自开源 Material Symbols「moped」矢量（Apache-2.0）：先按 x → 20−x 镜像重建
/// （含全部贝塞尔控制点），再由脚本逐条指令（M/L/C/Z）转成 SwiftUI Path。
/// 归一化设计盒 20 × 14；nonzero 填充，轮毂镂空由反向子路径形成。
private struct MopedShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 7.09, y: 0.195))
        p.addCurve(to: CGPoint(x: 6.905, y: 0.481), control1: CGPoint(x: 6.986, y: 0.305), control2: CGPoint(x: 6.905, y: 0.433))
        p.addCurve(to: CGPoint(x: 6.867, y: 0.59), control1: CGPoint(x: 6.905, y: 0.529), control2: CGPoint(x: 6.886, y: 0.576))
        p.addCurve(to: CGPoint(x: 6.819, y: 0.786), control1: CGPoint(x: 6.843, y: 0.605), control2: CGPoint(x: 6.824, y: 0.69))
        p.addCurve(to: CGPoint(x: 6.79, y: 0.995), control1: CGPoint(x: 6.814, y: 0.881), control2: CGPoint(x: 6.8, y: 0.971))
        p.addCurve(to: CGPoint(x: 6.829, y: 1.152), control1: CGPoint(x: 6.776, y: 1.014), control2: CGPoint(x: 6.795, y: 1.086))
        p.addCurve(to: CGPoint(x: 6.852, y: 1.338), control1: CGPoint(x: 6.867, y: 1.229), control2: CGPoint(x: 6.876, y: 1.3))
        p.addCurve(to: CGPoint(x: 6.81, y: 1.81), control1: CGPoint(x: 6.829, y: 1.376), control2: CGPoint(x: 6.81, y: 1.586))
        p.addCurve(to: CGPoint(x: 6.762, y: 2.105), control1: CGPoint(x: 6.805, y: 2.1), control2: CGPoint(x: 6.79, y: 2.186))
        p.addCurve(to: CGPoint(x: 5.967, y: 2.405), control1: CGPoint(x: 6.686, y: 1.924), control2: CGPoint(x: 6.414, y: 2.029))
        p.addCurve(to: CGPoint(x: 5.586, y: 3.186), control1: CGPoint(x: 5.743, y: 2.591), control2: CGPoint(x: 5.5, y: 3.081))
        p.addCurve(to: CGPoint(x: 5.562, y: 3.224), control1: CGPoint(x: 5.633, y: 3.243), control2: CGPoint(x: 5.629, y: 3.252))
        p.addCurve(to: CGPoint(x: 5.31, y: 3.162), control1: CGPoint(x: 5.519, y: 3.21), control2: CGPoint(x: 5.405, y: 3.181))
        p.addCurve(to: CGPoint(x: 5.148, y: 1.652), control1: CGPoint(x: 4.9, y: 3.086), control2: CGPoint(x: 4.829, y: 2.429))
        p.addCurve(to: CGPoint(x: 5.171, y: 0.967), control1: CGPoint(x: 5.314, y: 1.248), control2: CGPoint(x: 5.319, y: 1.138))
        p.addLine(to: CGPoint(x: 5.052, y: 0.833))
        p.addLine(to: CGPoint(x: 4.843, y: 1.062))
        p.addCurve(to: CGPoint(x: 2.752, y: 4.024), control1: CGPoint(x: 4.338, y: 1.6), control2: CGPoint(x: 3.043, y: 3.433))
        p.addCurve(to: CGPoint(x: 2.762, y: 4.357), control1: CGPoint(x: 2.6, y: 4.329), control2: CGPoint(x: 2.605, y: 4.543))
        p.addCurve(to: CGPoint(x: 3.205, y: 3.986), control1: CGPoint(x: 2.795, y: 4.319), control2: CGPoint(x: 2.995, y: 4.152))
        p.addCurve(to: CGPoint(x: 3.686, y: 3.591), control1: CGPoint(x: 3.414, y: 3.824), control2: CGPoint(x: 3.629, y: 3.643))
        p.addCurve(to: CGPoint(x: 4.676, y: 2.9), control1: CGPoint(x: 3.795, y: 3.476), control2: CGPoint(x: 4.476, y: 3.005))
        p.addCurve(to: CGPoint(x: 4.767, y: 2.767), control1: CGPoint(x: 4.767, y: 2.852), control2: CGPoint(x: 4.795, y: 2.814))
        p.addCurve(to: CGPoint(x: 4.662, y: 2.752), control1: CGPoint(x: 4.733, y: 2.719), control2: CGPoint(x: 4.71, y: 2.714))
        p.addCurve(to: CGPoint(x: 4.267, y: 3.029), control1: CGPoint(x: 4.624, y: 2.786), control2: CGPoint(x: 4.448, y: 2.91))
        p.addCurve(to: CGPoint(x: 2.99, y: 4.038), control1: CGPoint(x: 3.905, y: 3.267), control2: CGPoint(x: 3.271, y: 3.772))
        p.addCurve(to: CGPoint(x: 2.81, y: 4.176), control1: CGPoint(x: 2.89, y: 4.133), control2: CGPoint(x: 2.81, y: 4.195))
        p.addCurve(to: CGPoint(x: 2.995, y: 3.81), control1: CGPoint(x: 2.81, y: 4.129), control2: CGPoint(x: 2.957, y: 3.843))
        p.addCurve(to: CGPoint(x: 3.348, y: 3.286), control1: CGPoint(x: 3.014, y: 3.795), control2: CGPoint(x: 3.171, y: 3.562))
        p.addCurve(to: CGPoint(x: 3.833, y: 2.552), control1: CGPoint(x: 3.524, y: 3.01), control2: CGPoint(x: 3.743, y: 2.681))
        p.addCurve(to: CGPoint(x: 4.757, y: 1.31), control1: CGPoint(x: 4.224, y: 2.005), control2: CGPoint(x: 4.643, y: 1.443))
        p.addCurve(to: CGPoint(x: 4.957, y: 1.048), control1: CGPoint(x: 4.824, y: 1.229), control2: CGPoint(x: 4.914, y: 1.11))
        p.addCurve(to: CGPoint(x: 5.19, y: 1.162), control1: CGPoint(x: 5.048, y: 0.91), control2: CGPoint(x: 5.19, y: 0.981))
        p.addCurve(to: CGPoint(x: 4.943, y: 1.891), control1: CGPoint(x: 5.19, y: 1.286), control2: CGPoint(x: 5.014, y: 1.81))
        p.addCurve(to: CGPoint(x: 4.924, y: 1.952), control1: CGPoint(x: 4.914, y: 1.924), control2: CGPoint(x: 4.905, y: 1.952))
        p.addCurve(to: CGPoint(x: 4.838, y: 2.21), control1: CGPoint(x: 4.938, y: 1.952), control2: CGPoint(x: 4.9, y: 2.067))
        p.addCurve(to: CGPoint(x: 4.79, y: 2.495), control1: CGPoint(x: 4.743, y: 2.424), control2: CGPoint(x: 4.733, y: 2.476))
        p.addCurve(to: CGPoint(x: 4.857, y: 2.667), control1: CGPoint(x: 4.829, y: 2.51), control2: CGPoint(x: 4.857, y: 2.586))
        p.addCurve(to: CGPoint(x: 5.105, y: 3.191), control1: CGPoint(x: 4.857, y: 2.881), control2: CGPoint(x: 4.981, y: 3.138))
        p.addLine(to: CGPoint(x: 5.214, y: 3.233))
        p.addLine(to: CGPoint(x: 5.105, y: 3.233))
        p.addCurve(to: CGPoint(x: 4.119, y: 3.681), control1: CGPoint(x: 5, y: 3.238), control2: CGPoint(x: 4.233, y: 3.586))
        p.addCurve(to: CGPoint(x: 3.219, y: 4.257), control1: CGPoint(x: 4.062, y: 3.729), control2: CGPoint(x: 3.714, y: 3.952))
        p.addCurve(to: CGPoint(x: 2.748, y: 4.586), control1: CGPoint(x: 3.01, y: 4.391), control2: CGPoint(x: 2.8, y: 4.533))
        p.addCurve(to: CGPoint(x: 2.69, y: 4.576), control1: CGPoint(x: 2.657, y: 4.676), control2: CGPoint(x: 2.657, y: 4.676))
        p.addCurve(to: CGPoint(x: 2.414, y: 4.824), control1: CGPoint(x: 2.738, y: 4.414), control2: CGPoint(x: 2.695, y: 4.457))
        p.addCurve(to: CGPoint(x: 1.895, y: 5.781), control1: CGPoint(x: 2.119, y: 5.21), control2: CGPoint(x: 1.89, y: 5.629))
        p.addCurve(to: CGPoint(x: 2.01, y: 6.553), control1: CGPoint(x: 1.91, y: 6.076), control2: CGPoint(x: 1.971, y: 6.505))
        p.addCurve(to: CGPoint(x: 1.929, y: 6.7), control1: CGPoint(x: 2.038, y: 6.591), control2: CGPoint(x: 2.01, y: 6.638))
        p.addCurve(to: CGPoint(x: 2.124, y: 6.953), control1: CGPoint(x: 1.729, y: 6.843), control2: CGPoint(x: 1.81, y: 6.953))
        p.addCurve(to: CGPoint(x: 2.905, y: 7.234), control1: CGPoint(x: 2.419, y: 6.953), control2: CGPoint(x: 2.614, y: 7.024))
        p.addCurve(to: CGPoint(x: 2.89, y: 7.586), control1: CGPoint(x: 3.29, y: 7.51), control2: CGPoint(x: 3.286, y: 7.553))
        p.addCurve(to: CGPoint(x: 0.643, y: 8.705), control1: CGPoint(x: 2.067, y: 7.648), control2: CGPoint(x: 1, y: 8.176))
        p.addCurve(to: CGPoint(x: 0.705, y: 8.919), control1: CGPoint(x: 0.486, y: 8.934), control2: CGPoint(x: 0.49, y: 8.953))
        p.addCurve(to: CGPoint(x: 0.61, y: 9.224), control1: CGPoint(x: 0.9, y: 8.886), control2: CGPoint(x: 0.905, y: 8.876))
        p.addCurve(to: CGPoint(x: 2.786, y: 13.667), control1: CGPoint(x: -0.829, y: 10.929), control2: CGPoint(x: 0.51, y: 13.662))
        p.addCurve(to: CGPoint(x: 3.81, y: 13.486), control1: CGPoint(x: 3.148, y: 13.667), control2: CGPoint(x: 3.752, y: 13.557))
        p.addCurve(to: CGPoint(x: 4.024, y: 13.357), control1: CGPoint(x: 3.824, y: 13.467), control2: CGPoint(x: 3.919, y: 13.41))
        p.addCurve(to: CGPoint(x: 4.814, y: 12.719), control1: CGPoint(x: 4.305, y: 13.219), control2: CGPoint(x: 4.629, y: 12.957))
        p.addCurve(to: CGPoint(x: 5.038, y: 12.448), control1: CGPoint(x: 4.905, y: 12.61), control2: CGPoint(x: 5.005, y: 12.486))
        p.addCurve(to: CGPoint(x: 5.505, y: 10.695), control1: CGPoint(x: 5.31, y: 12.157), control2: CGPoint(x: 5.576, y: 11.167))
        p.addCurve(to: CGPoint(x: 5.062, y: 9.857), control1: CGPoint(x: 5.471, y: 10.491), control2: CGPoint(x: 5.262, y: 10.091))
        p.addCurve(to: CGPoint(x: 4.352, y: 8.938), control1: CGPoint(x: 4.733, y: 9.472), control2: CGPoint(x: 4.41, y: 9.053))
        p.addCurve(to: CGPoint(x: 4.162, y: 8.957), control1: CGPoint(x: 4.267, y: 8.776), control2: CGPoint(x: 4.257, y: 8.776))
        p.addCurve(to: CGPoint(x: 4.433, y: 9.476), control1: CGPoint(x: 4.086, y: 9.105), control2: CGPoint(x: 4.162, y: 9.243))
        p.addCurve(to: CGPoint(x: 4.81, y: 10.462), control1: CGPoint(x: 4.543, y: 9.567), control2: CGPoint(x: 4.805, y: 10.267))
        p.addCurve(to: CGPoint(x: 4.7, y: 10.31), control1: CGPoint(x: 4.81, y: 10.619), control2: CGPoint(x: 4.724, y: 10.5))
        p.addCurve(to: CGPoint(x: 4.214, y: 9.362), control1: CGPoint(x: 4.657, y: 10.029), control2: CGPoint(x: 4.433, y: 9.595))
        p.addLine(to: CGPoint(x: 4.033, y: 9.181))
        p.addLine(to: CGPoint(x: 3.833, y: 9.553))
        p.addCurve(to: CGPoint(x: 3.676, y: 10.01), control1: CGPoint(x: 3.695, y: 9.819), control2: CGPoint(x: 3.648, y: 9.953))
        p.addCurve(to: CGPoint(x: 3.643, y: 10.067), control1: CGPoint(x: 3.705, y: 10.072), control2: CGPoint(x: 3.7, y: 10.086))
        p.addCurve(to: CGPoint(x: 3.71, y: 10.243), control1: CGPoint(x: 3.533, y: 10.024), control2: CGPoint(x: 3.557, y: 10.091))
        p.addCurve(to: CGPoint(x: 3.938, y: 10.381), control1: CGPoint(x: 3.786, y: 10.319), control2: CGPoint(x: 3.89, y: 10.381))
        p.addCurve(to: CGPoint(x: 4.181, y: 10.572), control1: CGPoint(x: 4.057, y: 10.386), control2: CGPoint(x: 4.295, y: 10.567))
        p.addCurve(to: CGPoint(x: 4.148, y: 10.715), control1: CGPoint(x: 4.114, y: 10.572), control2: CGPoint(x: 4.11, y: 10.591))
        p.addCurve(to: CGPoint(x: 4.124, y: 10.934), control1: CGPoint(x: 4.19, y: 10.829), control2: CGPoint(x: 4.186, y: 10.872))
        p.addCurve(to: CGPoint(x: 4.048, y: 11.096), control1: CGPoint(x: 4.081, y: 10.972), control2: CGPoint(x: 4.048, y: 11.048))
        p.addCurve(to: CGPoint(x: 3.786, y: 10.91), control1: CGPoint(x: 4.048, y: 11.362), control2: CGPoint(x: 3.833, y: 11.205))
        p.addCurve(to: CGPoint(x: 3.71, y: 10.653), control1: CGPoint(x: 3.767, y: 10.815), control2: CGPoint(x: 3.738, y: 10.7))
        p.addCurve(to: CGPoint(x: 3.705, y: 10.486), control1: CGPoint(x: 3.681, y: 10.605), control2: CGPoint(x: 3.681, y: 10.538))
        p.addCurve(to: CGPoint(x: 3.648, y: 10.229), control1: CGPoint(x: 3.752, y: 10.395), control2: CGPoint(x: 3.729, y: 10.281))
        p.addCurve(to: CGPoint(x: 3.481, y: 10.315), control1: CGPoint(x: 3.562, y: 10.172), control2: CGPoint(x: 3.543, y: 10.181))
        p.addCurve(to: CGPoint(x: 3.576, y: 10.41), control1: CGPoint(x: 3.424, y: 10.438), control2: CGPoint(x: 3.429, y: 10.443))
        p.addCurve(to: CGPoint(x: 3.638, y: 10.472), control1: CGPoint(x: 3.729, y: 10.381), control2: CGPoint(x: 3.729, y: 10.381))
        p.addCurve(to: CGPoint(x: 3.462, y: 10.515), control1: CGPoint(x: 3.571, y: 10.534), control2: CGPoint(x: 3.524, y: 10.548))
        p.addCurve(to: CGPoint(x: 3.433, y: 10.562), control1: CGPoint(x: 3.386, y: 10.476), control2: CGPoint(x: 3.386, y: 10.481))
        p.addCurve(to: CGPoint(x: 3.257, y: 10.934), control1: CGPoint(x: 3.505, y: 10.672), control2: CGPoint(x: 3.376, y: 10.948))
        p.addCurve(to: CGPoint(x: 3.243, y: 11.086), control1: CGPoint(x: 3.133, y: 10.924), control2: CGPoint(x: 3.124, y: 11.043))
        p.addCurve(to: CGPoint(x: 3.271, y: 11.157), control1: CGPoint(x: 3.329, y: 11.119), control2: CGPoint(x: 3.333, y: 11.134))
        p.addCurve(to: CGPoint(x: 3.171, y: 11.115), control1: CGPoint(x: 3.229, y: 11.172), control2: CGPoint(x: 3.186, y: 11.157))
        p.addCurve(to: CGPoint(x: 3.048, y: 11.096), control1: CGPoint(x: 3.148, y: 11.057), control2: CGPoint(x: 3.124, y: 11.053))
        p.addCurve(to: CGPoint(x: 3.062, y: 10.967), control1: CGPoint(x: 2.952, y: 11.148), control2: CGPoint(x: 2.952, y: 11.138))
        p.addCurve(to: CGPoint(x: 3.352, y: 10.405), control1: CGPoint(x: 3.124, y: 10.867), control2: CGPoint(x: 3.252, y: 10.615))
        p.addCurve(to: CGPoint(x: 3.862, y: 9.343), control1: CGPoint(x: 3.448, y: 10.195), control2: CGPoint(x: 3.676, y: 9.719))
        p.addLine(to: CGPoint(x: 4.195, y: 8.662))
        p.addLine(to: CGPoint(x: 4.057, y: 8.472))
        p.addCurve(to: CGPoint(x: 3.886, y: 8.357), control1: CGPoint(x: 3.948, y: 8.324), control2: CGPoint(x: 3.91, y: 8.3))
        p.addCurve(to: CGPoint(x: 3.905, y: 8.405), control1: CGPoint(x: 3.871, y: 8.4), control2: CGPoint(x: 3.876, y: 8.419))
        p.addCurve(to: CGPoint(x: 3.952, y: 8.4), control1: CGPoint(x: 3.933, y: 8.391), control2: CGPoint(x: 3.952, y: 8.386))
        p.addCurve(to: CGPoint(x: 2.733, y: 10.767), control1: CGPoint(x: 3.952, y: 8.453), control2: CGPoint(x: 2.8, y: 10.695))
        p.addCurve(to: CGPoint(x: 2.729, y: 11.091), control1: CGPoint(x: 2.652, y: 10.857), control2: CGPoint(x: 2.648, y: 11.01))
        p.addCurve(to: CGPoint(x: 2.714, y: 11.134), control1: CGPoint(x: 2.776, y: 11.143), control2: CGPoint(x: 2.771, y: 11.153))
        p.addCurve(to: CGPoint(x: 2.681, y: 10.724), control1: CGPoint(x: 2.619, y: 11.105), control2: CGPoint(x: 2.595, y: 10.819))
        p.addCurve(to: CGPoint(x: 2.79, y: 10.162), control1: CGPoint(x: 2.919, y: 10.453), control2: CGPoint(x: 2.981, y: 10.129))
        p.addCurve(to: CGPoint(x: 2.295, y: 10.443), control1: CGPoint(x: 2.505, y: 10.219), control2: CGPoint(x: 2.429, y: 10.262))
        p.addCurve(to: CGPoint(x: 2.381, y: 11.381), control1: CGPoint(x: 2.043, y: 10.796), control2: CGPoint(x: 2.067, y: 11.072))
        p.addCurve(to: CGPoint(x: 3.076, y: 11.557), control1: CGPoint(x: 2.629, y: 11.634), control2: CGPoint(x: 2.9, y: 11.705))
        p.addCurve(to: CGPoint(x: 3.386, y: 11.238), control1: CGPoint(x: 3.238, y: 11.429), control2: CGPoint(x: 3.314, y: 11.348))
        p.addCurve(to: CGPoint(x: 3.5, y: 11.281), control1: CGPoint(x: 3.476, y: 11.105), control2: CGPoint(x: 3.548, y: 11.134))
        p.addCurve(to: CGPoint(x: 2.167, y: 11.257), control1: CGPoint(x: 3.324, y: 11.834), control2: CGPoint(x: 2.4, y: 11.815))
        p.addCurve(to: CGPoint(x: 2.071, y: 11.105), control1: CGPoint(x: 2.129, y: 11.157), control2: CGPoint(x: 2.081, y: 11.091))
        p.addCurve(to: CGPoint(x: 2.252, y: 11.515), control1: CGPoint(x: 2.029, y: 11.143), control2: CGPoint(x: 2.143, y: 11.396))
        p.addCurve(to: CGPoint(x: 2.286, y: 11.667), control1: CGPoint(x: 2.338, y: 11.605), control2: CGPoint(x: 2.343, y: 11.634))
        p.addCurve(to: CGPoint(x: 2.252, y: 11.748), control1: CGPoint(x: 2.248, y: 11.691), control2: CGPoint(x: 2.233, y: 11.724))
        p.addCurve(to: CGPoint(x: 2.324, y: 11.724), control1: CGPoint(x: 2.276, y: 11.767), control2: CGPoint(x: 2.305, y: 11.757))
        p.addCurve(to: CGPoint(x: 2.595, y: 11.743), control1: CGPoint(x: 2.352, y: 11.681), control2: CGPoint(x: 2.419, y: 11.686))
        p.addCurve(to: CGPoint(x: 3.41, y: 11.524), control1: CGPoint(x: 2.91, y: 11.843), control2: CGPoint(x: 3.148, y: 11.781))
        p.addCurve(to: CGPoint(x: 3.667, y: 11.405), control1: CGPoint(x: 3.581, y: 11.362), control2: CGPoint(x: 3.619, y: 11.348))
        p.addCurve(to: CGPoint(x: 2.881, y: 12.048), control1: CGPoint(x: 3.805, y: 11.576), control2: CGPoint(x: 3.224, y: 12.048))
        p.addCurve(to: CGPoint(x: 2.529, y: 11.9), control1: CGPoint(x: 2.567, y: 12.048), control2: CGPoint(x: 2.471, y: 12.005))
        p.addCurve(to: CGPoint(x: 2.505, y: 11.81), control1: CGPoint(x: 2.562, y: 11.829), control2: CGPoint(x: 2.557, y: 11.81))
        p.addCurve(to: CGPoint(x: 2.419, y: 11.867), control1: CGPoint(x: 2.467, y: 11.81), control2: CGPoint(x: 2.429, y: 11.834))
        p.addCurve(to: CGPoint(x: 1.952, y: 11.462), control1: CGPoint(x: 2.386, y: 11.967), control2: CGPoint(x: 2.1, y: 11.719))
        p.addCurve(to: CGPoint(x: 2.81, y: 9.905), control1: CGPoint(x: 1.543, y: 10.753), control2: CGPoint(x: 1.976, y: 9.972))
        p.addCurve(to: CGPoint(x: 3.048, y: 9.824), control1: CGPoint(x: 3.124, y: 9.876), control2: CGPoint(x: 3.152, y: 9.867))
        p.addCurve(to: CGPoint(x: 2.99, y: 9.767), control1: CGPoint(x: 2.981, y: 9.791), control2: CGPoint(x: 2.957, y: 9.767))
        p.addCurve(to: CGPoint(x: 2.976, y: 9.619), control1: CGPoint(x: 3.071, y: 9.762), control2: CGPoint(x: 3.062, y: 9.619))
        p.addCurve(to: CGPoint(x: 2.905, y: 9.7), control1: CGPoint(x: 2.938, y: 9.619), control2: CGPoint(x: 2.905, y: 9.657))
        p.addCurve(to: CGPoint(x: 2.852, y: 9.729), control1: CGPoint(x: 2.905, y: 9.757), control2: CGPoint(x: 2.89, y: 9.767))
        p.addCurve(to: CGPoint(x: 3.01, y: 9.572), control1: CGPoint(x: 2.771, y: 9.648), control2: CGPoint(x: 2.848, y: 9.572))
        p.addCurve(to: CGPoint(x: 3.129, y: 9.667), control1: CGPoint(x: 3.129, y: 9.572), control2: CGPoint(x: 3.148, y: 9.586))
        p.addCurve(to: CGPoint(x: 3.229, y: 9.662), control1: CGPoint(x: 3.095, y: 9.791), control2: CGPoint(x: 3.152, y: 9.791))
        p.addCurve(to: CGPoint(x: 2.99, y: 9.515), control1: CGPoint(x: 3.314, y: 9.529), control2: CGPoint(x: 3.286, y: 9.51))
        p.addLine(to: CGPoint(x: 2.738, y: 9.515))
        p.addLine(to: CGPoint(x: 2.605, y: 9.276))
        p.addCurve(to: CGPoint(x: 2.495, y: 9.015), control1: CGPoint(x: 2.529, y: 9.143), control2: CGPoint(x: 2.481, y: 9.024))
        p.addCurve(to: CGPoint(x: 3.11, y: 9.038), control1: CGPoint(x: 2.538, y: 8.967), control2: CGPoint(x: 3.052, y: 8.991))
        p.addCurve(to: CGPoint(x: 3.524, y: 9.095), control1: CGPoint(x: 3.205, y: 9.119), control2: CGPoint(x: 3.524, y: 9.162))
        p.addCurve(to: CGPoint(x: 3.429, y: 9.015), control1: CGPoint(x: 3.524, y: 9.067), control2: CGPoint(x: 3.481, y: 9.029))
        p.addCurve(to: CGPoint(x: 3.362, y: 8.943), control1: CGPoint(x: 3.376, y: 9), control2: CGPoint(x: 3.348, y: 8.967))
        p.addCurve(to: CGPoint(x: 3.295, y: 8.924), control1: CGPoint(x: 3.381, y: 8.915), control2: CGPoint(x: 3.357, y: 8.905))
        p.addCurve(to: CGPoint(x: 3.295, y: 8.591), control1: CGPoint(x: 3.176, y: 8.962), control2: CGPoint(x: 3.176, y: 8.815))
        p.addCurve(to: CGPoint(x: 3.481, y: 8.2), control1: CGPoint(x: 3.338, y: 8.514), control2: CGPoint(x: 3.419, y: 8.338))
        p.addCurve(to: CGPoint(x: 3.629, y: 7.953), control1: CGPoint(x: 3.538, y: 8.067), control2: CGPoint(x: 3.605, y: 7.953))
        p.addCurve(to: CGPoint(x: 3.724, y: 8.019), control1: CGPoint(x: 3.705, y: 7.953), control2: CGPoint(x: 3.738, y: 7.976))
        p.addCurve(to: CGPoint(x: 3.924, y: 8.238), control1: CGPoint(x: 3.705, y: 8.072), control2: CGPoint(x: 3.857, y: 8.238))
        p.addCurve(to: CGPoint(x: 4.429, y: 8.938), control1: CGPoint(x: 3.976, y: 8.243), control2: CGPoint(x: 4.429, y: 8.867))
        p.addCurve(to: CGPoint(x: 4.538, y: 9.095), control1: CGPoint(x: 4.429, y: 8.957), control2: CGPoint(x: 4.476, y: 9.029))
        p.addCurve(to: CGPoint(x: 5.524, y: 10.519), control1: CGPoint(x: 4.924, y: 9.524), control2: CGPoint(x: 5.414, y: 10.229))
        p.addCurve(to: CGPoint(x: 5.729, y: 11.048), control1: CGPoint(x: 5.571, y: 10.638), control2: CGPoint(x: 5.662, y: 10.876))
        p.addCurve(to: CGPoint(x: 5.952, y: 11.7), control1: CGPoint(x: 5.795, y: 11.219), control2: CGPoint(x: 5.895, y: 11.515))
        p.addLine(to: CGPoint(x: 6.052, y: 12.048))
        p.addLine(to: CGPoint(x: 8.514, y: 12.048))
        p.addCurve(to: CGPoint(x: 11.129, y: 11.957), control1: CGPoint(x: 10.862, y: 12.048), control2: CGPoint(x: 10.981, y: 12.043))
        p.addCurve(to: CGPoint(x: 11.462, y: 11.957), control1: CGPoint(x: 11.276, y: 11.867), control2: CGPoint(x: 11.281, y: 11.867))
        p.addCurve(to: CGPoint(x: 11.905, y: 12.029), control1: CGPoint(x: 11.605, y: 12.034), control2: CGPoint(x: 11.7, y: 12.048))
        p.addCurve(to: CGPoint(x: 12.6, y: 12.024), control1: CGPoint(x: 12.271, y: 11.991), control2: CGPoint(x: 12.329, y: 11.991))
        p.addCurve(to: CGPoint(x: 12.943, y: 12.005), control1: CGPoint(x: 12.752, y: 12.048), control2: CGPoint(x: 12.881, y: 12.038))
        p.addCurve(to: CGPoint(x: 13.629, y: 12.162), control1: CGPoint(x: 13.143, y: 11.9), control2: CGPoint(x: 13.548, y: 11.991))
        p.addCurve(to: CGPoint(x: 15.69, y: 13.629), control1: CGPoint(x: 13.957, y: 12.843), control2: CGPoint(x: 14.886, y: 13.505))
        p.addCurve(to: CGPoint(x: 18.59, y: 9.905), control1: CGPoint(x: 17.586, y: 13.924), control2: CGPoint(x: 19.224, y: 11.819))
        p.addCurve(to: CGPoint(x: 18.576, y: 9.834), control1: CGPoint(x: 18.576, y: 9.867), control2: CGPoint(x: 18.571, y: 9.834))
        p.addCurve(to: CGPoint(x: 18.186, y: 9.119), control1: CGPoint(x: 18.6, y: 9.834), control2: CGPoint(x: 18.276, y: 9.243))
        p.addCurve(to: CGPoint(x: 16.329, y: 7.938), control1: CGPoint(x: 17.69, y: 8.476), control2: CGPoint(x: 17.005, y: 8.038))
        p.addCurve(to: CGPoint(x: 15.919, y: 7.81), control1: CGPoint(x: 16.057, y: 7.9), control2: CGPoint(x: 15.933, y: 7.862))
        p.addCurve(to: CGPoint(x: 15.852, y: 7.629), control1: CGPoint(x: 15.905, y: 7.772), control2: CGPoint(x: 15.876, y: 7.691))
        p.addCurve(to: CGPoint(x: 15.767, y: 7.414), control1: CGPoint(x: 15.829, y: 7.572), control2: CGPoint(x: 15.79, y: 7.476))
        p.addCurve(to: CGPoint(x: 15.671, y: 7.176), control1: CGPoint(x: 15.743, y: 7.357), control2: CGPoint(x: 15.7, y: 7.248))
        p.addCurve(to: CGPoint(x: 16.062, y: 6.881), control1: CGPoint(x: 15.614, y: 7.034), control2: CGPoint(x: 15.7, y: 6.972))
        p.addCurve(to: CGPoint(x: 16.219, y: 6.805), control1: CGPoint(x: 16.133, y: 6.862), control2: CGPoint(x: 16.205, y: 6.829))
        p.addCurve(to: CGPoint(x: 16.595, y: 6.81), control1: CGPoint(x: 16.252, y: 6.748), control2: CGPoint(x: 16.557, y: 6.753))
        p.addCurve(to: CGPoint(x: 16.724, y: 6.857), control1: CGPoint(x: 16.61, y: 6.833), control2: CGPoint(x: 16.671, y: 6.857))
        p.addCurve(to: CGPoint(x: 17.367, y: 7.253), control1: CGPoint(x: 16.905, y: 6.857), control2: CGPoint(x: 17.21, y: 7.043))
        p.addCurve(to: CGPoint(x: 17.629, y: 7.591), control1: CGPoint(x: 17.452, y: 7.362), control2: CGPoint(x: 17.567, y: 7.514))
        p.addCurve(to: CGPoint(x: 18.443, y: 8.595), control1: CGPoint(x: 18.114, y: 8.2), control2: CGPoint(x: 18.395, y: 8.548))
        p.addCurve(to: CGPoint(x: 18.81, y: 9.024), control1: CGPoint(x: 18.476, y: 8.629), control2: CGPoint(x: 18.638, y: 8.824))
        p.addCurve(to: CGPoint(x: 20, y: 10.162), control1: CGPoint(x: 19.362, y: 9.686), control2: CGPoint(x: 20, y: 10.295))
        p.addCurve(to: CGPoint(x: 19.186, y: 8.491), control1: CGPoint(x: 20, y: 10.148), control2: CGPoint(x: 19.633, y: 9.395))
        p.addCurve(to: CGPoint(x: 18.124, y: 6.691), control1: CGPoint(x: 18.367, y: 6.848), control2: CGPoint(x: 18.367, y: 6.848))
        p.addCurve(to: CGPoint(x: 17.667, y: 6.31), control1: CGPoint(x: 17.895, y: 6.543), control2: CGPoint(x: 17.667, y: 6.353))
        p.addCurve(to: CGPoint(x: 17.943, y: 6.11), control1: CGPoint(x: 17.667, y: 6.3), control2: CGPoint(x: 17.79, y: 6.21))
        p.addCurve(to: CGPoint(x: 19.095, y: 4.953), control1: CGPoint(x: 18.605, y: 5.667), control2: CGPoint(x: 18.7, y: 5.572))
        p.addCurve(to: CGPoint(x: 19.095, y: 4.667), control1: CGPoint(x: 19.238, y: 4.729), control2: CGPoint(x: 19.238, y: 4.667))
        p.addCurve(to: CGPoint(x: 18.986, y: 4.605), control1: CGPoint(x: 19.048, y: 4.667), control2: CGPoint(x: 19, y: 4.638))
        p.addCurve(to: CGPoint(x: 18.862, y: 4.605), control1: CGPoint(x: 18.971, y: 4.557), control2: CGPoint(x: 18.943, y: 4.557))
        p.addCurve(to: CGPoint(x: 18.61, y: 4.676), control1: CGPoint(x: 18.81, y: 4.638), control2: CGPoint(x: 18.695, y: 4.672))
        p.addCurve(to: CGPoint(x: 18.69, y: 4.714), control1: CGPoint(x: 18.49, y: 4.681), control2: CGPoint(x: 18.51, y: 4.691))
        p.addCurve(to: CGPoint(x: 18.567, y: 4.752), control1: CGPoint(x: 18.919, y: 4.748), control2: CGPoint(x: 18.91, y: 4.748))
        p.addCurve(to: CGPoint(x: 17.533, y: 4.919), control1: CGPoint(x: 18.171, y: 4.762), control2: CGPoint(x: 17.705, y: 4.838))
        p.addCurve(to: CGPoint(x: 17.371, y: 4.914), control1: CGPoint(x: 17.457, y: 4.957), control2: CGPoint(x: 17.414, y: 4.957))
        p.addCurve(to: CGPoint(x: 17.419, y: 4.857), control1: CGPoint(x: 17.329, y: 4.872), control2: CGPoint(x: 17.338, y: 4.857))
        p.addCurve(to: CGPoint(x: 17.571, y: 4.762), control1: CGPoint(x: 17.476, y: 4.857), control2: CGPoint(x: 17.543, y: 4.814))
        p.addCurve(to: CGPoint(x: 17.548, y: 4.667), control1: CGPoint(x: 17.614, y: 4.686), control2: CGPoint(x: 17.61, y: 4.667))
        p.addCurve(to: CGPoint(x: 17.476, y: 4.619), control1: CGPoint(x: 17.51, y: 4.667), control2: CGPoint(x: 17.476, y: 4.648))
        p.addCurve(to: CGPoint(x: 17.61, y: 4.576), control1: CGPoint(x: 17.476, y: 4.595), control2: CGPoint(x: 17.533, y: 4.576))
        p.addCurve(to: CGPoint(x: 17.905, y: 4.552), control1: CGPoint(x: 17.681, y: 4.576), control2: CGPoint(x: 17.814, y: 4.567))
        p.addCurve(to: CGPoint(x: 17.967, y: 4.562), control1: CGPoint(x: 18.005, y: 4.538), control2: CGPoint(x: 18.029, y: 4.538))
        p.addCurve(to: CGPoint(x: 17.676, y: 4.791), control1: CGPoint(x: 17.848, y: 4.6), control2: CGPoint(x: 17.648, y: 4.757))
        p.addCurve(to: CGPoint(x: 18.405, y: 4.619), control1: CGPoint(x: 17.7, y: 4.81), control2: CGPoint(x: 18.262, y: 4.681))
        p.addCurve(to: CGPoint(x: 18.833, y: 4.476), control1: CGPoint(x: 18.457, y: 4.595), control2: CGPoint(x: 18.652, y: 4.533))
        p.addCurve(to: CGPoint(x: 19.333, y: 3.943), control1: CGPoint(x: 19.819, y: 4.167), control2: CGPoint(x: 20.052, y: 3.914))
        p.addCurve(to: CGPoint(x: 18.914, y: 4.005), control1: CGPoint(x: 19.11, y: 3.952), control2: CGPoint(x: 18.924, y: 3.981))
        p.addCurve(to: CGPoint(x: 18.748, y: 4.048), control1: CGPoint(x: 18.905, y: 4.029), control2: CGPoint(x: 18.829, y: 4.048))
        p.addCurve(to: CGPoint(x: 18.095, y: 4.114), control1: CGPoint(x: 18.662, y: 4.048), control2: CGPoint(x: 18.371, y: 4.081))
        p.addCurve(to: CGPoint(x: 17.557, y: 4.119), control1: CGPoint(x: 17.671, y: 4.172), control2: CGPoint(x: 17.59, y: 4.172))
        p.addCurve(to: CGPoint(x: 16.957, y: 3.924), control1: CGPoint(x: 17.443, y: 3.914), control2: CGPoint(x: 17.376, y: 3.891))
        p.addCurve(to: CGPoint(x: 16.5, y: 3.995), control1: CGPoint(x: 16.733, y: 3.943), control2: CGPoint(x: 16.529, y: 3.976))
        p.addCurve(to: CGPoint(x: 14.705, y: 4.191), control1: CGPoint(x: 16.443, y: 4.043), control2: CGPoint(x: 15.686, y: 4.124))
        p.addCurve(to: CGPoint(x: 13.381, y: 4.624), control1: CGPoint(x: 14.019, y: 4.233), control2: CGPoint(x: 13.533, y: 4.395))
        p.addCurve(to: CGPoint(x: 12.643, y: 4.886), control1: CGPoint(x: 13.343, y: 4.676), control2: CGPoint(x: 12.862, y: 4.848))
        p.addCurve(to: CGPoint(x: 12.386, y: 4.972), control1: CGPoint(x: 12.538, y: 4.905), control2: CGPoint(x: 12.424, y: 4.943))
        p.addCurve(to: CGPoint(x: 11.243, y: 5.029), control1: CGPoint(x: 12.343, y: 5.005), control2: CGPoint(x: 11.962, y: 5.024))
        p.addCurve(to: CGPoint(x: 9.348, y: 5.9), control1: CGPoint(x: 9.89, y: 5.029), control2: CGPoint(x: 9.957, y: 5))
        p.addCurve(to: CGPoint(x: 8.91, y: 7.138), control1: CGPoint(x: 8.805, y: 6.7), control2: CGPoint(x: 8.719, y: 6.934))
        p.addCurve(to: CGPoint(x: 8.638, y: 7.381), control1: CGPoint(x: 9.033, y: 7.272), control2: CGPoint(x: 8.995, y: 7.305))
        p.addCurve(to: CGPoint(x: 8.186, y: 7.357), control1: CGPoint(x: 8.438, y: 7.424), control2: CGPoint(x: 8.357, y: 7.419))
        p.addCurve(to: CGPoint(x: 7.895, y: 7.253), control1: CGPoint(x: 8.071, y: 7.314), control2: CGPoint(x: 7.938, y: 7.267))
        p.addCurve(to: CGPoint(x: 7.81, y: 7.191), control1: CGPoint(x: 7.848, y: 7.238), control2: CGPoint(x: 7.81, y: 7.21))
        p.addCurve(to: CGPoint(x: 7.61, y: 7.067), control1: CGPoint(x: 7.81, y: 7.172), control2: CGPoint(x: 7.719, y: 7.119))
        p.addCurve(to: CGPoint(x: 6.662, y: 6.467), control1: CGPoint(x: 7.381, y: 6.967), control2: CGPoint(x: 6.852, y: 6.633))
        p.addCurve(to: CGPoint(x: 6.876, y: 5.205), control1: CGPoint(x: 6.371, y: 6.214), control2: CGPoint(x: 6.371, y: 6.219))
        p.addCurve(to: CGPoint(x: 7.333, y: 4.248), control1: CGPoint(x: 7.129, y: 4.695), control2: CGPoint(x: 7.333, y: 4.267))
        p.addCurve(to: CGPoint(x: 6.929, y: 4.024), control1: CGPoint(x: 7.333, y: 4.229), control2: CGPoint(x: 7.152, y: 4.124))
        p.addCurve(to: CGPoint(x: 6.571, y: 3.714), control1: CGPoint(x: 6.581, y: 3.862), control2: CGPoint(x: 6.41, y: 3.714))
        p.addCurve(to: CGPoint(x: 6.619, y: 3.752), control1: CGPoint(x: 6.6, y: 3.714), control2: CGPoint(x: 6.619, y: 3.733))
        p.addCurve(to: CGPoint(x: 6.8, y: 3.852), control1: CGPoint(x: 6.619, y: 3.772), control2: CGPoint(x: 6.7, y: 3.819))
        p.addCurve(to: CGPoint(x: 7, y: 3.952), control1: CGPoint(x: 6.895, y: 3.891), control2: CGPoint(x: 6.986, y: 3.933))
        p.addCurve(to: CGPoint(x: 7.548, y: 3.381), control1: CGPoint(x: 7.138, y: 4.152), control2: CGPoint(x: 7.39, y: 3.891))
        p.addCurve(to: CGPoint(x: 8.043, y: 3.038), control1: CGPoint(x: 7.629, y: 3.114), control2: CGPoint(x: 7.762, y: 3.024))
        p.addCurve(to: CGPoint(x: 8.476, y: 2.814), control1: CGPoint(x: 8.31, y: 3.052), control2: CGPoint(x: 8.476, y: 2.967))
        p.addCurve(to: CGPoint(x: 8.095, y: 2.571), control1: CGPoint(x: 8.476, y: 2.667), control2: CGPoint(x: 8.39, y: 2.614))
        p.addCurve(to: CGPoint(x: 7.752, y: 2.457), control1: CGPoint(x: 7.91, y: 2.543), control2: CGPoint(x: 7.776, y: 2.5))
        p.addCurve(to: CGPoint(x: 7.19, y: 2.167), control1: CGPoint(x: 7.681, y: 2.329), control2: CGPoint(x: 7.3, y: 2.133))
        p.addCurve(to: CGPoint(x: 7.095, y: 2.119), control1: CGPoint(x: 7.124, y: 2.191), control2: CGPoint(x: 7.095, y: 2.176))
        p.addCurve(to: CGPoint(x: 6.99, y: 2), control1: CGPoint(x: 7.095, y: 2.081), control2: CGPoint(x: 7.048, y: 2.024))
        p.addCurve(to: CGPoint(x: 6.967, y: 1.957), control1: CGPoint(x: 6.905, y: 1.967), control2: CGPoint(x: 6.9, y: 1.957))
        p.addCurve(to: CGPoint(x: 7.048, y: 1.743), control1: CGPoint(x: 7.029, y: 1.952), control2: CGPoint(x: 7.048, y: 1.91))
        p.addCurve(to: CGPoint(x: 7.243, y: 1.219), control1: CGPoint(x: 7.048, y: 1.367), control2: CGPoint(x: 7.09, y: 1.252))
        p.addCurve(to: CGPoint(x: 7.538, y: 0.6), control1: CGPoint(x: 7.457, y: 1.176), control2: CGPoint(x: 7.548, y: 0.991))
        p.addCurve(to: CGPoint(x: 7.09, y: 0.195), control1: CGPoint(x: 7.519, y: -0.019), control2: CGPoint(x: 7.395, y: -0.129))
        p.addCurve(to: CGPoint(x: 7.067, y: 0.819), control1: CGPoint(x: 6.905, y: 0.39), control2: CGPoint(x: 6.89, y: 0.681))
        p.addCurve(to: CGPoint(x: 7.448, y: 0.843), control1: CGPoint(x: 7.21, y: 0.924), control2: CGPoint(x: 7.448, y: 0.943))
        p.addCurve(to: CGPoint(x: 7.5, y: 0.743), control1: CGPoint(x: 7.448, y: 0.805), control2: CGPoint(x: 7.471, y: 0.757))
        p.addCurve(to: CGPoint(x: 7.533, y: 0.843), control1: CGPoint(x: 7.533, y: 0.719), control2: CGPoint(x: 7.543, y: 0.757))
        p.addCurve(to: CGPoint(x: 7.386, y: 1.01), control1: CGPoint(x: 7.524, y: 0.943), control2: CGPoint(x: 7.486, y: 0.986))
        p.addCurve(to: CGPoint(x: 7.038, y: 0.1), control1: CGPoint(x: 6.867, y: 1.148), control2: CGPoint(x: 6.543, y: 0.3))
        p.addCurve(to: CGPoint(x: 7.09, y: 0.195), control1: CGPoint(x: 7.219, y: 0.029), control2: CGPoint(x: 7.229, y: 0.048))
        p.addCurve(to: CGPoint(x: 6.39, y: 1.305), control1: CGPoint(x: 7.005, y: 0.538), control2: CGPoint(x: 6.471, y: 1.386))
        p.addCurve(to: CGPoint(x: 6.552, y: 1.071), control1: CGPoint(x: 6.376, y: 1.291), control2: CGPoint(x: 6.452, y: 1.186))
        p.addCurve(to: CGPoint(x: 7.043, y: 0.195), control1: CGPoint(x: 6.748, y: 0.857), control2: CGPoint(x: 6.986, y: 0.433))
        p.addCurve(to: CGPoint(x: 7.095, y: 0.067), control1: CGPoint(x: 7.057, y: 0.124), control2: CGPoint(x: 7.086, y: 0.067))
        p.addCurve(to: CGPoint(x: 7.09, y: 0.195), control1: CGPoint(x: 7.11, y: 0.067), control2: CGPoint(x: 7.105, y: 0.124))
        let sc = min(rect.width / 20.0, rect.height / 13.667)
        let t = CGAffineTransform(scaleX: sc, y: sc)
            .concatenating(CGAffineTransform(
                translationX: rect.minX + (rect.width - 20 * sc) / 2,
                y: rect.minY + (rect.height - 14 * sc) / 2))
        return p.applying(t)
    }
}

/// 锁屏圆形（accessoryCircular）：油量数字（无 %）→ 小电池电压 → 缺口内踏板摩托车（车头朝左）。
/// ★ 环几何逐条还原自理想汽车 8.27.0 的 CustomGaugeStyle.makeBody：
///   环外框 52pt、lineWidth 5.4pt、cap/join = round、miterLimit 10、
///   量程 = value × 0.75（3/4 周）、底轨 white×0.4、进度 white、
///   整体旋转 132.4746°（= 2.3121106 rad），使 90° 缺口落在正下方。
@available(iOS 16.0, *)
struct SundiroAccessoryCircularView: View {
    let s: VehicleStatus

    private let gauge: CGFloat = 52          // 理想实测：环外框
    private let lineW: CGFloat = 5.4         // 理想实测：环宽
    private let span: CGFloat = 0.75         // 理想实测：量程 3/4 周
    private let rot: Double = 132.4746       // 理想实测：旋转角（度）

    private var arc: StrokeStyle {
        StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }

    var body: some View {
        ZStack {
            Group {
                // 底轨：白 40%，固定 3/4 周
                Circle().trim(from: 0, to: span)
                    .stroke(Color.white.opacity(0.4), style: arc)
                // 进度：纯白，长度 = 油量 × 3/4 周
                if let f = s.fuel, f > 0 {
                    Circle().trim(from: 0, to: span * CGFloat(max(0, min(100, f))) / 100)
                        .stroke(Color.white, style: arc)
                }
            }
            .rotationEffect(.degrees(rot))          // ★ 只转环，不转字

            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 0.5) {
                    Text(s.fuel.map { "\($0)" } ?? "—")                    // ★ 油量数字
                        .font(.system(size: 20.5, weight: .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("%")                                              // ★ 数字后的小号 %
                        .font(.system(size: 10.5, weight: .semibold))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: 32)   // ★ 自适应：33% 保持 20.5pt，100% 自动缩小
                Text(s.batVolt.map { String(format: "%.1fV", $0) } ?? "—") // ★ 小电池数据：电压
                    .font(.system(size: 7.5, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.top, -2.875)
                MopedShape()                                               // ★ 缺口内踏板摩托车（新图标）
                    .fill(Color.white)
                    .frame(width: 19, height: 13)
                    .padding(.top, 0.875)
            }
            .foregroundColor(.white)
            .offset(y: 3.5)
        }
        .frame(width: gauge, height: gauge)
        .widgetURL(URL(string: "xdzsundiro://open"))
    }
}

/// 单行「左标签 / 右数值」，供锁屏矩形三行复用。
/// 锁屏只渲染单色，所以数值用 widgetAccentable() 提亮、标签降为 secondary 来造层次。
@available(iOS 16.0, *)
private struct AccessoryRow: View {
    let label: String
    let value: String
    var unit: String = ""
    var secondary: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 6)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .widgetAccentable()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                if let sec = secondary {
                    Text(sec)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 3)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
    }
}

/// 锁屏矩形（accessoryRectangular）：油量 / 胎压 / 里程 三行表格。
@available(iOS 16.0, *)
struct SundiroAccessoryRectangularView: View {
    let s: VehicleStatus

    var body: some View {
        Group {
            if !s.hasAccount {
                VStack(alignment: .leading, spacing: 2) {
                    Text("新大洲本田").font(.system(size: 12, weight: .semibold))
                    Text(s.note ?? "打开 App 完成登录")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    // ★ 详细信息（固定布局）：胎压 / 油量 / 电量
                    AccessoryRow(label: "胎压", value: tirePairText, unit: "kPa")
                    Divider()
                    AccessoryRow(label: "油量",
                                 value: s.fuel.map { "\($0)" } ?? "—",
                                 unit: "%",
                                 secondary: s.fuelLiters.flatMap { l in
                                     s.fuelCapL.map { String(format: "%.1f/%.0fL", l, $0) }
                                 })
                    Divider()
                    AccessoryRow(label: "电量",
                                 value: s.batVolt.map { String(format: "%.1f", $0) } ?? "—",
                                 unit: "V")
                }
            }
        }
        .widgetURL(URL(string: "xdzsundiro://open"))
    }

    /// 前后胎压合并一行「172/207」；只有一侧有值时显示「172/—」
    private var tirePairText: String {
        switch (s.tireF, s.tireR) {
        case let (f?, r?): return "\(f)/\(r)"
        case let (f?, nil): return "\(f)/—"
        case let (nil, r?): return "—/\(r)"
        default: return "—"
        }
    }
}

/// 锁屏内联（accessoryInline）：时间上方单行。
/// ★ 只出「一个 Label」—— 官方文档明确 accessoryInline 只保证渲染 Text / Label，
///   套 ViewThatFits / HStack 等布局容器有渲染空白的风险。所以降级在代码里选好
///   再交给系统，而不是让系统去挑。字长按「中文字符算 2」估算上限，绝不出现「…」。
@available(iOS 16.0, *)
struct SundiroAccessoryInlineView: View {
    let s: VehicleStatus

    /// 内联可用宽度约 240pt，中文约 16 字、纯 ASCII 约 30 字。
    private static let charBudget = 24

    var body: some View {
        if !s.hasAccount {
            Label("打开 App 完成登录", systemImage: "scooter")
        } else {
            Label(inlineText, systemImage: "scooter")
        }
    }

    /// 按优先级出文字：油量+里程 → 只油量 → 兜底。
    private var inlineText: String {
        let full = "\(fuelText) · \(odoText)"
        if Self.width(full) <= Self.charBudget { return full }
        if Self.width(fuelText) <= Self.charBudget { return fuelText }
        return "车况"
    }

    /// 估算显示宽度：中文/全角算 2，其余算 1。
    private static func width(_ s: String) -> Int {
        s.reduce(0) { acc, ch in
            acc + (ch.unicodeScalars.first.map { $0.value > 0x2000 ? 2 : 1 } ?? 1)
        }
    }

    private var fuelText: String { s.fuel.map { "油量\($0)%" } ?? "油量—" }
    private var odoText: String { s.odo.map { String(format: "%.0fkm", $0) } ?? "里程—" }
}

struct SundiroWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SundiroEntry
    var body: some View {
        // ★ 内联单独走一条路：它由系统排版在时间旁，绝不能套 frame 撑满，
        //   否则会被当成空布局、渲染成空白。
        if #available(iOS 16.0, *), family == .accessoryInline {
            SundiroAccessoryInlineView(s: entry.status)
        } else if #available(iOS 16.0, *), family == .accessoryCircular {
            // ★ 圆形单独走一条路：它自带 52×52 居中框，绝不能套 topLeading 撑满 frame
            SundiroAccessoryCircularView(s: entry.status)
        } else {
            Group {
                if #available(iOS 16.0, *), family == .accessoryRectangular {
                    SundiroAccessoryRectangularView(s: entry.status)
                } else if family == .systemMedium {
                    SundiroMediumView(s: entry.status)
                } else {
                    SundiroSmallView(s: entry.status)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - Widget --------------------------------------------------------------

@main
struct SundiroWidget: Widget {
    let kind: String = "SundiroStatus"

    /// 桌面小/中号 + 锁屏矩形/内联。
    /// 锁屏配件需要 iOS 16，用 #available 组装，保证 iOS 15 上不引用不存在的枚举。
    private var supportedFamilies: [WidgetFamily] {
        var f: [WidgetFamily] = [.systemSmall, .systemMedium]
        if #available(iOS 16.0, *) {
            f.append(.accessoryCircular)        // ★ 新增：锁屏圆形（环 + 油量 + 小电池 + 踏板摩托）
            f.append(.accessoryRectangular)
            f.append(.accessoryInline)
        }
        return f
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SundiroProvider()) { entry in
            SundiroWidgetView(entry: entry)
        }
        .configurationDisplayName("新大洲本田 无感管家")
        .description("查看车辆油量 / 胎压 / 小电池 / 行程与里程；支持 iOS 16 锁屏圆形、矩形、内联配件；后台自动拉起主 App 做无感解锁。")
        .supportedFamilies(supportedFamilies)
    }
}