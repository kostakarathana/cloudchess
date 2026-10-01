import SwiftUI
import UIKit

struct ProfileJob:Decodable {
    let id:String
    let status:String
    let error:String?
}
struct ProfileReport:Codable {
    struct Coverage:Codable {let importedGames:Int;let analysedGames:Int;let completeGameDecisions:Int}
    struct Rating:Codable {let performanceEstimate:Int;let interval95:[Int];let games:Int}
    struct Skill:Codable,Identifiable {
        let tag:String
        let priority:Double
        let games:Int
        let errorRate:Double
        let status:String
        var id:String {tag}
        var symbol:String {
            if tag.contains("fork") {return "arrow.triangle.branch"}
            if tag.contains("mate") || tag.contains("Mate") {return "crown"}
            if tag.contains("opening") || tag.contains("eco:") {return "book.closed"}
            if tag.contains("endgame") || tag.contains("promotion") {return "flag.checkered"}
            if tag.contains("Pin") || tag.contains("defense") {return "shield.lefthalf.filled"}
            if tag.contains("knight") {return "arrow.turn.up.right"}
            if tag.contains("pawn") {return "arrow.up"}
            if tag.contains("king") || tag.contains("Check") {return "shield"}
            return "scope"
        }
    }
    let account:String
    let coverage:Coverage
    let ratings:[String:Rating]
    let skills:[Skill]
}

@MainActor final class ProfileAnalysisModel:ObservableObject {
    @Published private(set) var job:ProfileJob?
    @Published private(set) var report:ProfileReport?
    @Published private(set) var working=false
    @Published private(set) var error:String?
    private var worker:Task<Void,Never>?
    private let defaults:UserDefaults
    private let jobKey="cloudchess.profileJob"
    private let reportKey="cloudchess.profileReport"
    private var generation=UUID()
    private var testing:Bool {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--uitesting")
        #else
        return false
        #endif
    }
    var running:Bool {working || ["queued","importing","analysing","modelling"].contains(job?.status ?? "")}
    var state:String {error != nil ? "error":job?.status ?? "empty"}

    init() {
        #if DEBUG
        let testing=ProcessInfo.processInfo.arguments.contains("--uitesting")
        defaults=testing ? UserDefaults(suiteName:"com.maroon.CloudChess.profile-tests")!:UserDefaults.standard
        if testing && !ProcessInfo.processInfo.arguments.contains("--preserve-profile") {defaults.removePersistentDomain(forName:"com.maroon.CloudChess.profile-tests")}
        #else
        defaults=UserDefaults.standard
        #endif
        if let data=defaults.data(forKey:reportKey) {report=try? JSONDecoder().decode(ProfileReport.self,from:data)}
        #if DEBUG
        if testing,let argument=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--profile-job=")}) {
            defaults.set(String(argument.dropFirst(14)),forKey:jobKey)
        }
        #endif
    }
    private func request(_ path:String,body:[String:Any]?=nil) async throws -> Data {
        let service=OnDeviceProfiles.shared
        let parts=path.split(separator:"/").map(String.init)
        let result:[String:Any]
        if parts==["jobs"],let link=body?["profile"] as? String {
            var limit:Int?=nil
            #if DEBUG
            if testing,let argument=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--profile-limit=")}) {limit=Int(argument.dropFirst(16))}
            #endif
            result=try await service.start(link,limit:limit)
        } else if parts.count>=2 {
            let id=parts[1]
            if parts.count==2 {result=try await service.status(id)}
            else if parts[2]=="report" {result=try await service.report(id)}
            else if parts[2]=="resume" {result=try await service.resume(id)}
            else if parts[2]=="cancel" {result=try await service.cancel(id)}
            else {throw URLError(.badURL)}
        } else {throw URLError(.badURL)}
        return try JSONSerialization.data(withJSONObject:result)
    }
    private func launch(_ operation:@escaping (UUID) async throws -> Void) {
        worker?.cancel();generation=UUID();let current=generation
        error=nil;working=true
        worker=Task { [weak self] in
            do {try await operation(current)}
            catch {
                if !Task.isCancelled,self?.generation==current {self?.error=error.localizedDescription}
            }
            if self?.generation==current {self?.working=false}
        }
    }
    func start(username:String,provider:ChessProfileProvider) {
        guard !running else{return}
        guard let url=provider.profileURL(username:username) else {
            error="Enter just your username, using letters, numbers, hyphens or underscores.";return
        }
        start(url.absoluteString)
    }
    private func start(_ link:String) {
        guard !running else {return}
        guard let url=URL(string:link.trimmingCharacters(in:.whitespacesAndNewlines)),url.scheme=="https",
              ["lichess.org","www.lichess.org","chess.com","www.chess.com"].contains(url.host?.lowercased() ?? "") else {
            error="Enter a Chess.com or Lichess profile link.";return
        }
        launch { [weak self] current in
            guard let self else {return}
            let data=try await self.request("/jobs",body:["profile":url.absoluteString])
            let created=try JSONDecoder().decode(ProfileJob.self,from:data)
            // Save the receipt even if the panel closed while the POST was in
            // flight, so an accepted server job is not accidentally orphaned.
            self.defaults.set(created.id,forKey:self.jobKey)
            guard self.generation==current else {return}
            self.job=created;self.report=nil;self.defaults.removeObject(forKey:self.reportKey)
            try await self.watch(created.id,current:current)
        }
    }
    func open() {
        #if DEBUG
        if testing,defaults.string(forKey:jobKey)==nil,let argument=ProcessInfo.processInfo.arguments.first(where:{$0.hasPrefix("--profile-autostart=")}) {
            start(String(argument.dropFirst(20)));return
        }
        #endif
        guard let id=defaults.string(forKey:jobKey) else {return}
        launch { [weak self] current in try await self?.watch(id,current:current) }
    }
    func resume() {
        guard let id=defaults.string(forKey:jobKey) else {return}
        launch { [weak self] current in
            guard let self else {return}
            let data=try await self.request("/jobs/"+id+"/resume",body:[:])
            guard self.generation==current else {return}
            self.job=try JSONDecoder().decode(ProfileJob.self,from:data)
            try await self.watch(id,current:current)
        }
    }
    func cancel() {
        guard let id=defaults.string(forKey:jobKey) else {return}
        launch { [weak self] current in
            guard let self else {return}
            _=try await self.request("/jobs/"+id+"/cancel",body:[:])
            try await self.watch(id,current:current)
        }
    }
    func stopWatching() {
        worker?.cancel();worker=nil;generation=UUID();working=false
    }
    private func watch(_ id:String,current:UUID) async throws {
        while !Task.isCancelled && generation==current {
            let data=try await request("/jobs/"+id)
            try Task.checkCancellation()
            guard generation==current else {return}
            let value=try JSONDecoder().decode(ProfileJob.self,from:data);job=value
            if value.status=="completed" {
                let reportData=try await request("/jobs/"+id+"/report")
                try Task.checkCancellation()
                guard generation==current else {return}
                report=try JSONDecoder().decode(ProfileReport.self,from:reportData)
                defaults.set(reportData,forKey:reportKey)
                return
            }
            if ["failed","cancelled","interrupted"].contains(value.status) {
                error=value.error;return
            }
            try await Task.sleep(for:.seconds(3))
        }
    }
}

/// Account entry, progress, and the report remain entirely icon/graphic based.
/// VoiceOver exposes the precise estimates, sample sizes, and uncertainty.
struct ProfileAnalysisPanel:View {
    @StateObject private var model=ProfileAnalysisModel()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cloudMotion) private var motion
    let close:()->Void
    private let ink=Color(red:0.10,green:0.18,blue:0.29)
    @State private var username=""
    @State private var provider:ChessProfileProvider = .chesscom
    @FocusState private var editing:Bool
    private func analyse() {
        let value=username.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !value.isEmpty,!model.running else{return}
        editing=false;model.start(username:value,provider:provider)
    }
    var body:some View {
        CloudPopup(title:"Profile analysis",symbol:"person.crop.circle",dismiss:close) {
            VStack(spacing:20) {
                Text("Discover patterns in your Chess.com or Lichess games.")
                    .font(.body).foregroundStyle(ink.opacity(0.7))
                HStack(spacing:6) {
                    ForEach(ChessProfileProvider.allCases,id:\.self) {source in
                        Button {withAnimation(reduceMotion || !motion ? nil:.easeInOut(duration:0.18)){provider=source}} label:{
                            Text(source.title).font(.system(.subheadline,design:.rounded,weight:.semibold))
                                .frame(maxWidth:.infinity,minHeight:46)
                                .foregroundStyle(provider==source ? ink:ink.opacity(0.55))
                                .background(provider==source ? .white:Color.clear,in:RoundedRectangle(cornerRadius:13))
                        }.buttonStyle(CloudPressStyle()).disabled(model.running)
                            .accessibilityAddTraits(provider==source ? .isSelected:[])
                            .accessibilityIdentifier("profile-provider-"+source.rawValue)
                    }
                }.padding(4).background(ink.opacity(0.07),in:RoundedRectangle(cornerRadius:17))
                HStack(spacing:8) {
                    TextField("Username",text:$username).keyboardType(.asciiCapable).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.go).focused($editing).onSubmit(analyse).accessibilityIdentifier("profile-username").disabled(model.running)
                        .frame(minHeight:48)
                    Button {username=UIPasteboard.general.string ?? ""} label:{Image(systemName:"doc.on.clipboard").frame(width:44,height:44)}
                        .disabled(model.running).accessibilityLabel("Paste username").accessibilityHint("Paste your username, then choose Analyse.")
                }.padding(.horizontal,12).background(.white.opacity(0.8),in:RoundedRectangle(cornerRadius:16))
                if model.running {
                    HStack(spacing:12) {ProgressView();Text("Analysing your games…").font(.subheadline);Spacer()}
                    Text("You can close this panel. Analysis resumes when you’re away from the board.").font(.footnote).foregroundStyle(ink.opacity(0.65))
                }
                if let error=model.error {
                    Label(error,systemImage:"exclamationmark.circle").font(.callout).foregroundStyle(Color(rgb:0xA83B4E)).fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("profile-error")
                }
                if let report=model.report {reportView(report)}
            }.accessibilityElement(children:.contain)
                .accessibilityIdentifier("profile-analysis-status").accessibilityValue(model.error ?? model.state)
        } actions: {
            VStack(spacing:8) {
                Button(action:analyse) {Text("Analyse profile").frame(maxWidth:.infinity)}.buttonStyle(CloudActionStyle())
                    .disabled(model.running || username.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty).accessibilityIdentifier("analyse-profile")
                if model.running {
                    Button {model.cancel()} label:{Label("Pause analysis",systemImage:"pause").frame(minHeight:44)}.accessibilityLabel("Pause profile analysis")
                } else if model.job != nil {
                    Button {if ["failed","cancelled","interrupted"].contains(model.job?.status ?? "") {model.resume()} else {model.open()}} label:{Label("Resume analysis",systemImage:"arrow.clockwise").frame(minHeight:44)}.accessibilityLabel("Resume profile analysis")
                }
            }
        }.foregroundStyle(ink).accessibilityIdentifier("profile-panel")
            .onAppear{model.open()}.onDisappear{model.stopWatching()}
            .onChange(of:scenePhase){_,phase in if phase == .active {model.open()} else {model.stopWatching();Task{await OnDeviceProfiles.shared.pause()}}}
    }
    @ViewBuilder private func reportView(_ report:ProfileReport)->some View {
        VStack(spacing:20) {
            HStack(spacing:18) {
                ForEach(Array(report.ratings.keys.sorted{report.ratings[$0]!.games>report.ratings[$1]!.games}.prefix(3)),id:\.self) {speed in
                    if let rating=report.ratings[speed] {
                        ZStack {
                            Circle().stroke(ink.opacity(0.09),lineWidth:4)
                            Circle().trim(from:0,to:min(1,Double(rating.performanceEstimate)/3000)).stroke(ink.opacity(0.68),style:StrokeStyle(lineWidth:4,lineCap:.round)).rotationEffect(.degrees(-90))
                            Image(systemName:speed=="bullet" ? "bolt":speed=="blitz" ? "flame":"clock").font(.system(size:19,weight:.light))
                        }.frame(width:52,height:52).accessibilityElement(children:.ignore)
                            .accessibilityLabel(speed+" estimated skill")
                            .accessibilityValue("\(rating.performanceEstimate), estimated interval \(rating.interval95.map(String.init).joined(separator:" to ")), from \(rating.games) games. Provisional.")
                    }
                }
            }
            HStack(alignment:.bottom,spacing:12) {
                ForEach(Array(report.skills.prefix(6))) {skill in
                    VStack(spacing:8) {
                        Capsule().fill(skill.status=="likely_weakness" ? Color.orange.opacity(0.65):ink.opacity(0.3))
                            .frame(width:16,height:12+60*max(0,min(1,skill.errorRate)))
                        Image(systemName:skill.symbol).font(.system(size:16,weight:.light)).frame(width:30,height:30)
                    }.accessibilityElement(children:.ignore).accessibilityLabel(skill.tag)
                        .accessibilityValue("\(Int(skill.errorRate*100)) percent observed errors in \(skill.games) games. \(skill.status.replacingOccurrences(of:"_",with:" ")).")
                }
            }.frame(height:110,alignment:.bottom)
        }.accessibilityElement(children:.contain).accessibilityIdentifier("profile-analysis-report")
            .accessibilityLabel("\(report.account), \(report.coverage.analysedGames) games analysed out of \(report.coverage.importedGames) imported, \(report.coverage.completeGameDecisions) decisions. Estimated weaknesses; not a calibrated official rating.")
    }
}
