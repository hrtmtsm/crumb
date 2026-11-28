import SwiftUI
import Speech
import AVFoundation

@MainActor
final class RecipeSpeech: ObservableObject {
    @Published var text = ""
    @Published var recording = false
    @Published var starting = false
    @Published var message: String?
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var generation = UUID()

    func start() async {
        guard !starting, !recording else { return }
        starting = true
        message = nil
        let run = UUID()
        generation = run
        defer { if generation == run { starting = false } }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard generation == run, !Task.isCancelled else { return }
        guard authorization == .authorized else { message = "音声認識を許可してください。設定から変更できます。"; return }
        let microphone = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard generation == run, !Task.isCancelled else { return }
        guard microphone else { message = "マイクへのアクセスを許可してください。設定から変更できます。"; return }
        let locales = ["ja": "ja-JP", "en": "en-US", "ko": "ko-KR"]
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locales[AppLanguage.code] ?? "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            message = "この端末・言語では端末内の音声認識を利用できません。キーボードから入力してください。"
            return
        }
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audio.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            self.request = request
            text = ""
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw CocoaError(.featureUnsupported) }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapInstalled = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.generation == run else { return }
                    if let result { self.text = result.bestTranscription.formattedString }
                    if error != nil || result?.isFinal == true {
                        self.stop()
                        if error != nil && self.text.isEmpty { self.message = "音声を読み取れませんでした。もう一度お試しください。" }
                    }
                }
            }
            engine.prepare()
            try engine.start()
            recording = true
        } catch {
            stop()
            message = "録音を開始できませんでした。もう一度お試しください。"
        }
    }

    func stop() {
        generation = UUID()
        starting = false
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

struct RecipeCapture: View {
    enum Mode: String, Identifiable { case voice, link; var id: Self { self } }
    let mode: Mode
    var initialURL = ""
    let didImport: (RecipeDraft) -> Void
    @EnvironmentObject private var account: AccountStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var speech = RecipeSpeech()
    @State private var url = ""
    @State private var text = ""
    @State private var started: Date?
    @State private var draft: RecipeDraft?
    @State private var message: String?
    @State private var working = false
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if mode == .voice {
                        Text("Tell us how you made it.").font(.custom("Nunito-SemiBold", size: 27))
                        if speech.recording, let started {
                            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                                let elapsed = max(0, Int(timeline.date.timeIntervalSince(started)))
                                Text(String(format: "%02d:%02d", elapsed / 60, elapsed % 60)).font(.title.monospacedDigit())
                            }
                        }
                        Button(speech.recording ? "Done" : "Record recipe", systemImage: speech.recording ? "stop.fill" : "mic.fill") {
                            CrumbHaptics.tap()
                            if speech.recording { speech.stop(); text = speech.text; processText() }
                            else { task = Task { await speech.start(); if speech.recording { started = .now } } }
                        }.buttonStyle(.borderedProminent).tint(ink).disabled(speech.starting || working)
                        TextField("Your recipe transcript", text: $text, axis: .vertical)
                            .lineLimit(5...20).padding(14).background(ink.opacity(0.035), in: .rect(cornerRadius: 14))
                            .disabled(speech.recording || working)
                        if !speech.recording && !text.isEmpty {
                            Button("Review transcript") { processText() }.disabled(working)
                        }
                        if !CrumbAssistant.configured {
                            Text("Recipe structuring is unavailable. You can keep the transcript as notes, or use Ingredients and Directions headings.")
                                .font(.footnote).foregroundStyle(secondaryInk)
                        }
                    } else {
                        TextField("Recipe or YouTube URL", text: $url).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(14).background(ink.opacity(0.035), in: .rect(cornerRadius: 14)).disabled(working)
                        Button("Import") { loadLink() }.buttonStyle(.borderedProminent).tint(ink).disabled(working || url.isEmpty)
                    }
                    if working { AssistantWaiting(phase: .recipe).frame(maxWidth: .infinity) }
                    if let message = message ?? speech.message { Text(message).font(.subheadline).foregroundStyle(secondaryInk) }
                    if let draft {
                        Text("Review import").font(.headline)
                        if !draft.title.isEmpty { Text(draft.title).font(.title3) }
                        if !draft.recipe.knowsServings { Text("Servings unknown — confirm in the editor.").font(.footnote) }
                        RecipeContent(recipe: draft.recipe, servings: draft.recipe.servings, showsIngredientTags: false)
                        if !draft.notes.isEmpty { Text(draft.notes).font(.subheadline) }
                        if draft.recipe.isEmpty && draft.notes.isEmpty {
                            Text("No recipe details were available. Keep the source and continue by hand.")
                        }
                        Button("Use this draft") { didImport(draft); dismiss() }.buttonStyle(.borderedProminent).tint(ink)
                    }
                }.padding(22)
            }
            .navigationTitle(mode == .voice ? "Record recipe" : "Import link").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { task?.cancel(); speech.stop(); dismiss() } } }
            .onAppear { url = initialURL }
            .onChange(of: speech.text) { _, new in text = new }
            .onChange(of: scenePhase) { _, phase in if phase == .background { speech.stop() } }
            .onDisappear { task?.cancel(); speech.stop() }
        }
    }
    private func processText() {
        working = true; message = nil
        task = Task { @MainActor in
            defer { working = false }
            do {
                let result = CrumbAssistant.configured ? try await CrumbAssistant.extract(text, account: account) : RecipeImport.transcript(text)
                try Task.checkCancellation(); draft = result
            } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
    }
    private func loadLink() {
        working = true; message = nil
        task = Task { @MainActor in
            defer { working = false }
            do {
                var result = try await RecipeImport.fetchDraft(url)
                if result.recipe.isEmpty && !result.notes.isEmpty && CrumbAssistant.configured {
                    let source = result.source
                    result = try await CrumbAssistant.extract(result.notes, account: account); result.source = source
                }
                try Task.checkCancellation(); draft = result
            } catch {
                guard !Task.isCancelled else { return }
                message = "Could not import this page. Your recipe is unchanged. You can keep its source and continue by hand."
                if let link = URL(string: url), RecipeImport.allowed(link) {
                    var recipe = MealRecipe(); recipe.servingsKnown = false
                    draft = RecipeDraft(title: "", recipe: recipe, source: url)
                }
            }
        }
    }
}
