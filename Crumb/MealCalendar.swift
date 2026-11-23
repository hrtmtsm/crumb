import SwiftUI

struct MealCalendar: View {
    let meals: [Meal]
    @Binding var selectedDate: Date
    let addMeal: () -> Void
    @State private var month: Date
    @Environment(\.calendar) private var calendar

    init(meals: [Meal], selectedDate: Binding<Date>, addMeal: @escaping () -> Void) {
        self.meals = meals
        self.addMeal = addMeal
        _selectedDate = selectedDate
        _month = State(initialValue: selectedDate.wrappedValue)
    }

    private var mealsByDay: [Date: [Meal]] {
        Dictionary(grouping: meals.filter { $0.recordedDate != nil }) { calendar.startOfDay(for: $0.date) }
    }

    private var monthDays: [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: month),
              let count = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let cells = ((leading + count + 6) / 7) * 7
        return (0..<cells).compactMap { calendar.date(byAdding: .day, value: $0 - leading, to: interval.start) }
    }

    var body: some View {
        let grouped = mealsByDay
        let dailyMeals = grouped[calendar.startOfDay(for: selectedDate)] ?? []

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(month.formatted(.dateTime.year().month().locale(Locale(identifier: "ja_JP"))))
                        .font(.title2.bold())
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    monthButton(-1, icon: "chevron.left", label: "前の月")
                    monthButton(1, icon: "chevron.right", label: "次の月")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 4) {
                    ForEach(0..<7, id: \.self) { offset in
                        let index = (calendar.firstWeekday - 1 + offset) % 7
                        Text(calendar.shortStandaloneWeekdaySymbols[index])
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(monthDays, id: \.self) { day in
                        dayButton(day, count: grouped[calendar.startOfDay(for: day)]?.count ?? 0)
                    }
                }
                Divider()
                HStack {
                    Text(dayLabel(selectedDate)).font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button(action: addMeal) {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .frame(width: 44, height: 44)
                            .background(.white, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("この日に食事を追加")
                }
                if dailyMeals.isEmpty {
                    Text("この日の食事はまだありません。")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 2), spacing: 20) {
                        ForEach(dailyMeals) { meal in
                            NavigationLink(value: meal) { AlbumTile(meal: meal) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 12)
            .padding(.bottom, 88)
        }
    }

    private func monthButton(_ step: Int, icon: String, label: String) -> some View {
        Button {
            if let start = calendar.dateInterval(of: .month, for: month)?.start,
               let target = calendar.date(byAdding: .month, value: step, to: start) {
                month = target
                selectedDate = target
            }
        } label: {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.white, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func dayButton(_ day: Date, count: Int) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: selectedDate)
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        return Button {
            selectedDate = day
            if !inMonth { month = day }
        } label: {
            Text("\(calendar.component(.day, from: day))")
                .font(.subheadline.weight(selected || count > 0 ? .semibold : .regular))
                .foregroundStyle(selected ? .white : ink.opacity(inMonth ? 1 : 0.48))
                .frame(width: 35, height: 35)
                .background(selected ? ink : ink.opacity(count > 0 ? 0.09 : 0), in: Circle())
                .overlay { Circle().strokeBorder(calendar.isDateInToday(day) && !selected ? ink : .clear) }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(dayLabel(day))、食事\(count)件")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
