import SwiftUI
import MapKit

private struct MealGroup: Identifiable {
    let place: Place
    let meals: [Meal]
    var id: String { place.id }
}

struct MealMap: View {
    let meals: [Meal]
    var canEditMeals = true
    @State private var selected: MealGroup?
    @Binding var composingMap: Bool
    var pinDetail: ((Meal) -> WantedPlaceDetail)?
    @State private var position: MapCameraPosition = .automatic
    @State private var detent: PresentationDetent = .medium

    private var groups: [MealGroup] {
        Dictionary(grouping: meals.filter { $0.place?.coordinate != nil }) { $0.placeKey ?? "" }
            .values.compactMap { meals in
                guard let place = meals.first?.place else { return nil }
                return MealGroup(place: place, meals: meals)
            }
            .sorted { $0.id < $1.id }
    }

    var body: some View {
        Map(position: $position) {
            ForEach(groups) { group in
                if let coordinate = group.place.coordinate, let meal = group.meals.first {
                    Annotation(group.place.name, coordinate: coordinate, anchor: .bottom) {
                        Button {
                            detent = .medium
                            selected = group
                        } label: {
                            let border = pinBorder(for: group)
                            VStack(spacing: -6) {
                                Group {
                                    if meal.wantToVisit == true {
                                        Image(systemName: "fork.knife")
                                            .font(.title3.weight(.semibold))
                                            .foregroundStyle(ink)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .background(paper)
                                    } else {
                                        MealPhoto(data: meal.photo, size: 170)
                                    }
                                }
                                    .frame(width: 54, height: 54)
                                    .clipShape(Circle())
                                    .padding(4)
                                    .background(border, in: Circle())
                                    .overlay(alignment: .topTrailing) {
                                        if group.meals.count > 1 {
                                            Text("\(group.meals.count)")
                                                .font(.caption2.bold().monospacedDigit())
                                                .foregroundStyle(paper)
                                                .padding(.horizontal, 6)
                                                .frame(minHeight: 22)
                                                .background(ink, in: Capsule())
                                                .offset(x: 5, y: -3)
                                        }
                                    }
                                    .zIndex(1)
                                RoundedRectangle(cornerRadius: 3)
                                .fill(border)
                                .frame(width: 12, height: 12)
                                .rotationEffect(.degrees(45))
                            }
                            .padding(.bottom, 3)
                            .shadow(color: ink.opacity(0.24), radius: 5, y: 3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(group.place.name)、\(group.meals.count)件")
                    }
                    .annotationTitles(.hidden)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .ignoresSafeArea()
        .sheet(isPresented: $composingMap) { MapCardComposer(groups: groups) }
        .sheet(item: $selected) { group in
            NavigationStack {
                if let meal = group.meals.first, meal.wantToVisit == true, let pinDetail {
                    pinDetail(meal)
                } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(group.meals) { meal in
                            NavigationLink(value: meal) {
                                VStack(alignment: .leading, spacing: 9) {
                                    if let date = meal.recordedDate {
                                        Text(dayLabel(date)).font(.subheadline.weight(.medium))
                                        .foregroundStyle(ink.opacity(0.65))
                                    }
                                    if meal.wantToVisit != true {
                                    MealPhoto(data: meal.photo, size: 700)
                                        .frame(height: 156)
                                        .clipShape(.rect(cornerRadius: 16))
                                    }
                                    HStack {
                                        Text(meal.title).font(.headline)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption)
                                    }
                                }
                                .foregroundStyle(ink)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("map-meal-\(meal.title)")
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                }
                .background(paper.ignoresSafeArea())
                .navigationTitle(group.place.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(paper, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .navigationDestination(for: Meal.self) { meal in
                    MealDetail(meal: meal, canEdit: canEditMeals).onAppear { detent = .large }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("閉じる") { selected = nil }
                    }
                }
                }
            }
            .presentationBackground(paper)
            .presentationDetents([.medium, .large], selection: $detent)
            .presentationDragIndicator(.visible)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }

    private func pinBorder(for group: MealGroup) -> Color {
        selected?.id == group.id ? tomato : .white
    }

}


private struct MapCardComposer: View {
    let groups: [MealGroup]
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var selection: Set<String>
    @State private var preparing = false
    @State private var failed = false
    @State private var card: ShareCard?

    init(groups: [MealGroup]) {
        self.groups = groups
        _selection = State(initialValue: Set(groups.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("タイトル") {
                    TextField("食事のマップ", text: $title)
                }
                Section("載せる場所") {
                    ForEach(groups) { group in
                        Toggle(isOn: Binding(get: { selection.contains(group.id) }, set: { enabled in
                            if enabled { selection.insert(group.id) } else { selection.remove(group.id) }
                        })) {
                            LabeledContent(group.place.name, value: "\(group.meals.count)件")
                        }
                    }
                }
            }
            .disabled(preparing)
            .navigationTitle("マップを作る")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("プレビュー") { Task { await makeCard() } }
                        .disabled(selection.isEmpty || preparing)
                }
            }
            .overlay {
                if preparing { ProgressView("地図を画像にしています").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) }
            }
            .sheet(item: $card) { SharePreview(card: $0) }
            .alert("マップ画像を作成できませんでした", isPresented: $failed) {
                Button("閉じる", role: .cancel) {}
            }
        }
    }

    @MainActor private func makeCard() async {
        guard !preparing else { return }
        let places = groups.filter { selection.contains($0.id) }
        let coordinates = places.compactMap { $0.place.coordinate }
        guard !coordinates.isEmpty else { return }
        preparing = true
        defer { preparing = false }

        let options = MKMapSnapshotter.Options()
        options.size = CGSize(width: 360, height: 300)
        options.traitCollection = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .light), UITraitCollection(displayScale: 2)
        ])
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = configuration
        let bounds = coordinates.reduce(MKMapRect.null) { result, coordinate in
            let point = MKMapPoint(coordinate)
            return result.union(MKMapRect(x: point.x, y: point.y, width: 1, height: 1))
        }
        let minimumSpan = 700 / MKMetersPerMapPointAtLatitude(coordinates[0].latitude)
        let padding = max(max(bounds.width, bounds.height) * 0.2, minimumSpan / 2)
        options.mapRect = bounds.insetBy(dx: -padding, dy: -padding)

        do {
            let snapshot = try await MKMapSnapshotter(options: options).start()
            let enteredTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cardTitle = enteredTitle.isEmpty ? "食事のマップ" : enteredTitle
            let renderer = ImageRenderer(content:
                VStack(alignment: .leading, spacing: 16) {
                    Text("crumb").font(crumbFont(22))
                    Text(cardTitle).font(.title2.bold())
                    Image(uiImage: snapshot.image)
                        .resizable().frame(width: 360, height: 300)
                        .overlay(alignment: .topLeading) {
                            ForEach(Array(places.enumerated()), id: \.element.id) { index, group in
                                if let coordinate = group.place.coordinate {
                                    let point = snapshot.point(for: coordinate)
                                    Text("\(index + 1)").font(.caption.bold())
                                        .foregroundStyle(ink).frame(minWidth: 24, minHeight: 24)
                                        .background(tomato, in: Circle())
                                        .position(point)
                                }
                            }
                        }
                    ForEach(Array(places.enumerated()), id: \.element.id) { index, group in
                        HStack(spacing: 10) {
                            Text("\(index + 1)").monospacedDigit().foregroundStyle(ink.opacity(0.65))
                            if let meal = group.meals.first {
                                PlatePhoto(meal: meal, pixels: 140).frame(width: 40, height: 40)
                            }
                            Text(group.place.name).font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .foregroundStyle(ink)
                .frame(width: 360, alignment: .leading)
                .padding(20)
                .background(paper)
            )
            renderer.scale = 2
            guard let image = renderer.uiImage else { failed = true; return }
            card = ShareCard(image: image, description: cardTitle)
        } catch {
            failed = true
        }
    }
}
