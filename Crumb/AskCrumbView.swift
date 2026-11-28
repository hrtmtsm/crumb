import SwiftUI
import SwiftData

@MainActor
final class AskCrumbSession: ObservableObject {
    @Published var turns: [AssistantTurn] = []
    @Published var phase: AssistantWaiting.Phase?
    @Published var error: String?
    private let provider: any AssistantServing
    init(provider: (any AssistantServing)? = nil) { self.provider = provider ?? LiveAssistantService() }
    private var task: Task<Void, Never>?
    private var images: [UUID: Task<Void, Never>] = [:]
    private var generation = UUID()
    private var defaults: UserDefaults = .standard
    private var key = ""
    private var retryText: String?
    private var retryIntent: String?

    func configure(meal: Meal?, account: AccountStore) {
        let next = "ask-crumb." + (meal?.id.uuidString ?? "explore")
        guard key != next else { return }
        defaults = account.signedIn ? UserDefaults(suiteName: account.preferenceSuite) ?? .standard : .standard
        key = next
        if let data = defaults.data(forKey: key), var saved = try? JSONDecoder().decode([AssistantTurn].self, from: data) {
            for index in saved.indices where saved[index].proposal != nil {
                saved[index].proposal?.previewError = "Preview not loaded. Review now or retry the image."
            }
            turns = saved
        }
    }
    private func persist() {
        var copy = Array(turns.suffix(30))
        for i in copy.indices {
            copy[i].proposal?.preview = nil
            copy[i].proposal?.draft.previewData = nil
        }
        if let data = try? JSONEncoder().encode(copy), data.count < 2_000_000 { defaults.set(data, forKey: key) }
    }
    func send(_ text: String, intent: String?, meal: Meal?, library: [Meal], account: AccountStore, retry: Bool = false) {
        guard phase == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let run = UUID(); generation = run
        error = nil; retryText = text; retryIntent = intent
        if !retry { turns.append(AssistantTurn(role: "user", text: text)); persist() }
        phase = intent == "variation" ? .recipe : intent == "meal" ? .meal : .thinking
        task = Task { @MainActor in
            defer { if generation == run { phase = nil } }
            do {
                var history = Array(turns.suffix(10))
                for index in history.indices { history[index].proposal?.preview = nil; history[index].proposal?.draft.previewData = nil }
                let menu = Array(library.filter { $0.wantToVisit != true && !MealRecipe(contents: $0.structuredRecipe).isMeal }.prefix(30)).map { meal in
                    var value = Self.snapshot(meal)
                    value.recipe.steps = Array(value.recipe.steps.prefix(4)).map { String($0.prefix(300)) }
                    value.notes = String(value.notes.prefix(200))
                    return value
                }
                let context = AssistantContext(current: meal.map(Self.snapshot), menu: menu, conversation: history)
                let planned: String
                if let intent { planned = intent }
                else { planned = try await provider.classify(text, context: context, account: account) }
                try Task.checkCancellation()
                if generation != run { return }
                phase = planned == "variation" ? .recipe : planned == "meal" ? .meal : .thinking
                let reply = try await provider.reply(text, context: context, account: account)
                try Task.checkCancellation()
                guard generation == run else { return }
                #if DEBUG
                print("AskCrumb reply: kind=\(reply.kind), recipe=\(reply.recipe != nil), dishes=\(reply.dishes.count)")
                #endif
                let proposal = try makeProposal(reply, meal: meal, library: library)
                turns.append(AssistantTurn(role: "assistant", text: reply.message, proposal: proposal))
                persist()
                if let proposal { startImage(proposal, library: library, account: account) }
            } catch {
                if !Task.isCancelled && generation == run { self.error = error.localizedDescription }
            }
        }
    }
    func retry(meal: Meal?, library: [Meal], account: AccountStore) {
        guard let retryText else { return }
        send(retryText, intent: retryIntent, meal: meal, library: library, account: account, retry: true)
    }
    func cancel() {
        generation = UUID(); task?.cancel(); phase = nil
        error = "Stopped. Your conversation and drafts are kept."
        persist()
    }
    func close() { task?.cancel(); generation = UUID(); phase = nil; for value in images.values { value.cancel() }; images.removeAll(); persist() }
    static func snapshot(_ meal: Meal) -> RecipeDraft {
        var draft = RecipeDraft(title: meal.title, recipe: MealRecipe(contents: meal.structuredRecipe), notes: [meal.note,meal.recipe].filter { !$0.isEmpty }.joined(separator: "\n"), source: meal.recipeURL.isEmpty ? nil : meal.recipeURL)
        draft.id = meal.id
        return draft
    }
    private func makeProposal(_ reply: AssistantReply, meal: Meal?, library: [Meal]) throws -> AssistantProposal? {
        if reply.kind == "answer" { return nil }
        if reply.kind == "variation", let recipe = reply.resolvedRecipe {
            var draft = try recipe.draft(origin: meal?.id)
            draft.changes = reply.changes
            return AssistantProposal(kind: "variation", draft: draft, components: [], changes: reply.changes)
        }
        if reply.kind == "meal", !reply.dishes.isEmpty, reply.dishes.count <= 8 {
            let previous = turns.reversed().compactMap(\.proposal).first(where: { $0.kind == "meal" })
            var components: [MealComponent] = []
            for dish in reply.dishes {
                guard dish.portionPerPerson.isFinite, dish.portionPerPerson > 0, dish.portionPerPerson <= 10 else { throw AssistantFailure.invalid }
                if let value = dish.existingRecipeID, let id = UUID(uuidString: value) {
                    guard let existing = library.first(where: { $0.id == id }) else { throw AssistantFailure.invalid }
                    if components.contains(where: { $0.recipeID == id }) { continue }
                    components.append(MealComponent(recipeID: id, title: existing.title, portionPerPerson: dish.portionPerPerson))
                } else if let recipe = dish.recipe {
                    if var old = previous?.components.first(where: { component in
                        guard component.recipeID == nil, let saved = component.draft,
                              saved.title.caseInsensitiveCompare(recipe.title) == .orderedSame,
                              saved.recipe.servings == (recipe.servings ?? 1),
                              saved.recipe.knowsServings == (recipe.servings != nil),
                              saved.recipe.steps == recipe.steps.map(\.text),
                              saved.notes == recipe.notes,
                              saved.recipe.ingredients.count == recipe.ingredients.count else { return false }
                        return zip(saved.recipe.ingredients, recipe.ingredients).allSatisfy { pair in
                            pair.0.name == pair.1.name && pair.0.amount == pair.1.amount && pair.0.unit == pair.1.unit
                        }
                    }) {
                        old.portionPerPerson = dish.portionPerPerson; components.append(old)
                    } else {
                        let draft = try recipe.draft()
                        components.append(MealComponent(draft: draft, title: draft.title, portionPerPerson: dish.portionPerPerson))
                    }
                } else { throw AssistantFailure.invalid }
            }
            if let meal, !MealRecipe(contents: meal.structuredRecipe).isMeal && !components.contains(where: { $0.recipeID == meal.id }) {
                components.insert(MealComponent(recipeID: meal.id, title: meal.title), at: 0)
            }
            var recipe = MealRecipe()
            recipe.servings = meal.map { MealRecipe(contents: $0.structuredRecipe).servings } ?? 1
            recipe.mealComponents = components
            let draft = RecipeDraft(title: reply.mealTitle ?? (meal.map { "\($0.title) dinner" } ?? "My meal"), recipe: recipe)
            return AssistantProposal(kind: "meal", draft: draft, components: components, changes: reply.changes)
        }
        throw AssistantFailure.invalid
    }
    func startImage(_ proposal: AssistantProposal, library: [Meal], account: AccountStore) {
        images[proposal.id]?.cancel()
        if let index = turns.firstIndex(where: { $0.proposal?.id == proposal.id }) { turns[index].proposal?.previewError = nil }
        var hydrated = proposal
        for index in hydrated.components.indices {
            if let id = hydrated.components[index].recipeID, let meal = library.first(where: { $0.id == id }) {
                hydrated.components[index].draft = Self.snapshot(meal)
            }
        }
        images[proposal.id] = Task { @MainActor in
            do {
                let data = try await provider.image(for: hydrated, account: account)
                try Task.checkCancellation()
                guard let index = turns.firstIndex(where: { $0.proposal?.id == proposal.id }) else { return }
                turns[index].proposal?.preview = data
                turns[index].proposal?.previewError = nil
            } catch {
                guard !Task.isCancelled, let index = turns.firstIndex(where: { $0.proposal?.id == proposal.id }) else { return }
                turns[index].proposal?.previewError = "Preview unavailable. You can still review and save."
            }
            images[proposal.id] = nil
        }
    }
    func markSaved(_ proposalID: UUID, record: Meal) {
        if let index = turns.firstIndex(where: { $0.proposal?.id == proposalID }) { turns[index].proposal?.savedID = record.id; persist() }
    }
}

struct AskCrumbView: View {
    var meal: Meal? = nil
    var embedded = false
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var plus: PlusStore
    @EnvironmentObject private var cloud: CloudLibrary
    @Environment(\.dismiss) private var dismiss
    @AppStorage("menuBooks") private var storedBooks = "[]"
    @AppStorage("selectedMenuBook") private var selectedBookID = MenuBook.defaultID
    @Query private var library: [Meal]
    @StateObject private var session = AskCrumbSession()
    @State private var input = ""
    @State private var scrollToReply = false
    @State private var reviewing: AssistantProposal?
    private var destinationBook: String {
        let id = meal.map { $0.menuBookID ?? MenuBook.defaultID } ?? selectedBookID
        let book = MenuBook.decode(storedBooks).first { $0.id == id } ?? .defaultBook
        return PlanPolicy.canEdit(book: cloud.resolved(book), viewer: account.session?.userID, plus: plus.hasPlus) ? id : MenuBook.defaultID
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if meal != nil {
                HStack(spacing: 10) {
                    Image("CrumbAvatar").resizable().scaledToFit().frame(width: 30, height: 30)
                    Text(meal?.title ?? "Ask Crumb").font(.custom("Nunito-SemiBold", size: 18)).lineLimit(2)
                    Spacer()
                }.padding(.horizontal, 22).padding(.bottom, 12)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if meal == nil {
                                exploreWelcome
                            } else if session.turns.isEmpty {
                                Text("What would you like to cook?").font(.custom("Nunito-SemiBold", size: 25))
                                if meal != nil {
                                    Button("Make a variation") { send("Help me make a variation of this recipe.", intent: "variation") }
                                } else {
                                    Button("Find something to cook") { send("Help me decide what to cook. Ask about my ingredients, available time and preferences first.", intent: nil) }
                                }
                                Button("Build a meal") { send(meal == nil ? "Help me plan a meal. Ask about my ingredients, servings and available time first." : "Build a balanced home-cooked meal around this dish. Ask about my ingredients and time if needed.", intent: "meal") }
                                Text("Suggestions are drafts. Review ingredients and cooking instructions before saving.").font(.footnote).foregroundStyle(secondaryInk)
                            }
                            ForEach(session.turns) { turn in
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(turn.role == "user" ? "You" : "Crumb").font(.caption.weight(.semibold)).foregroundStyle(secondaryInk)
                                    Text(turn.text).textSelection(.enabled)
                                    if let proposal = turn.proposal { proposalCard(proposal) }
                                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(turn.role == "user" ? ink.opacity(0.04) : Color.clear, in: .rect(cornerRadius: 18))
                                    .id(turn.id)
                            }
                            if let phase = session.phase {
                                AssistantWaiting(phase: phase).frame(maxWidth: .infinity)
                                Button("Stop") { session.cancel() }.frame(maxWidth: .infinity)
                            }
                            if let error = session.error {
                                Text(error).font(.subheadline).foregroundStyle(secondaryInk)
                                Button("Retry") { session.retry(meal: meal, library: library, account: account) }
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(22)
                    }
                    // Wait for the new row to enter layout. Animated scrolls during
                    // image/placeholder replacement can re-enter lazy layout on iOS.
                    .task(id: session.turns.count) {
                        await Task.yield()
                        guard !Task.isCancelled, scrollToReply else { return }
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }.background(paper).foregroundStyle(ink)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .navigationTitle(embedded ? "" : "Ask Crumb").navigationBarTitleDisplayMode(.inline)
            .toolbar(embedded ? .hidden : .visible, for: .navigationBar)
            .toolbar { if !embedded { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } } }
            .sheet(item: $reviewing) { selected in
                let proposal = session.turns.compactMap(\.proposal).first(where: { $0.id == selected.id }) ?? selected
                if proposal.kind == "meal" {
                    MealReviewView(proposal: proposal, bookID: destinationBook) { record in session.markSaved(proposal.id, record: record) }
                } else {
                    recipeReview(proposal)
                }
            }
            .onAppear { session.configure(meal: meal, account: account) }
            .onDisappear { session.close() }
        }
    }
    private var exploreWelcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(spacing: 12) {
                Image("CrumbAvatar").resizable().scaledToFit()
                    .frame(width: 104, height: 104).accessibilityHidden(true)
                Text("Ask Crumb").font(.custom("Nunito-SemiBold", size: 30))
                Text("Dinner ideas, ingredient swaps, and a little help in the kitchen.")
                    .font(.subheadline).foregroundStyle(secondaryInk).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity).padding(.top, 12).padding(.bottom, 8)
            Text("Try asking").font(.subheadline.weight(.semibold))
            starter("What can I make with tofu and cabbage?", symbol: "carrot", intent: nil)
            starter("Plan a 20-minute dinner for two.", symbol: "fork.knife", intent: "meal")
            starter("What can I use instead of butter?", symbol: "arrow.triangle.2.circlepath", intent: nil)
            Text("Or ask anything about cooking below.")
                .font(.footnote).foregroundStyle(secondaryInk)
        }
    }
    private func starter(_ question: String, symbol: String, intent: String?) -> some View {
        Button { send(question, intent: intent) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 24)
                Text(verbatim: question).font(.subheadline).multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right").font(.caption)
            }
            .foregroundStyle(ink).padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(ink.opacity(0.04), in: .rect(cornerRadius: 16))
        }.buttonStyle(.plain).disabled(session.phase != nil)
    }
    private var composer: some View {
                HStack(alignment: .bottom, spacing: 12) {
                    TextField(meal == nil ? "Ask Crumb…" : "Ask about this recipe…", text: $input, axis: .vertical).lineLimit(1...5)
                        .padding(12).background(ink.opacity(0.04), in: .rect(cornerRadius: 18))
                    Button { send(input, intent: nil) } label: { Image(systemName: "arrow.up").frame(width: 44, height: 44).foregroundStyle(.white).background(ink, in: .circle) }
                        .disabled(session.phase != nil || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Send")
                }.padding(18)
        .background(paper)
    }
    private func recipeReview(_ proposal: AssistantProposal) -> some View {
        var draft = proposal.draft
        draft.previewData = proposal.preview
        return MealEditor(meal: nil, initialBookID: destinationBook, draft: draft) { record in
            session.markSaved(proposal.id, record: record)
        }
    }
    private func send(_ text: String, intent: String?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        CrumbHaptics.tap(); input = ""; scrollToReply = true
        session.send(text, intent: intent, meal: meal, library: library, account: account)
    }
    private func proposalCard(_ proposal: AssistantProposal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let bytes = proposal.preview, let image = UIImage(data: bytes) {
                Image(uiImage: image).resizable().aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity).clipShape(.rect(cornerRadius: 15))
                Text("AI preview").font(.caption).foregroundStyle(secondaryInk)
            } else {
                HStack { Image(systemName: "photo"); Text(proposal.previewError ?? "Preparing an AI preview…") }.font(.footnote).foregroundStyle(secondaryInk)
            }
            Text(proposal.draft.title).font(.custom("Nunito-SemiBold", size: 23))
            if !proposal.changes.isEmpty { Text(proposal.changes).font(.subheadline) }
            if proposal.kind == "meal" {
                ForEach(proposal.components) { Text($0.title).font(.subheadline) }
            } else { Text(proposal.draft.recipe.ingredients.map(\.name).joined(separator: ", ")).font(.subheadline).foregroundStyle(secondaryInk) }
            if proposal.savedID != nil { Label("Saved to My Menu", systemImage: "checkmark.circle") }
            Button(proposal.kind == "meal" ? "Review meal" : "Review recipe") { reviewing = proposal }
                .buttonStyle(.borderedProminent).tint(ink).disabled(proposal.savedID != nil)
            if proposal.previewError != nil { Button("Retry image") { session.startImage(proposal, library: library, account: account) } }
        }.padding(16).overlay(RoundedRectangle(cornerRadius: 18).stroke(fieldBorder))
    }
}
