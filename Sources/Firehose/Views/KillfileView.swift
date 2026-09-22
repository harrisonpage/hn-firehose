import SwiftUI

/// Sheet for editing the killfile: an add row on top, the rules beneath,
/// swipe to delete. Same voice as the rest of the app — Archivo, flush
/// left, 2px rules, nothing rounded.
struct KillfileView: View {
    let killfile: KillfileStore
    let hiddenCount: Int
    let loadedCount: Int
    let dismiss: () -> Void

    @State private var input = ""
    /// Set when the user taps Site/Word explicitly; otherwise the kind is
    /// guessed from the input. Cleared when the field is emptied.
    @State private var manualKind: KillRule.Kind?
    @State private var rejected = false
    @FocusState private var fieldFocused: Bool

    private var kind: KillRule.Kind { manualKind ?? KillRule.guessKind(for: input) }

    var body: some View {
        VStack(spacing: 0) {
            header
            addRow
            statusLine
            rules
        }
        .background(Theme.ground.ignoresSafeArea())
        .onChange(of: input) { _, new in
            if new.isEmpty { manualKind = nil }
            rejected = false
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("KILLFILE")
                .font(Theme.wordmark)
                .kerning(2.4)
                .foregroundStyle(Theme.headerInk)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Text("Done")
                    .font(Theme.meta)
                    .foregroundStyle(Theme.headerInk)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .frame(height: 36)
        .background(Theme.headerFill)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.headerRule).frame(height: 2)
        }
    }

    // MARK: Add

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Site or word to hide", text: $input)
                    .font(Theme.headline)
                    .foregroundStyle(Theme.ink)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(kind == .domain ? .URL : .default)
                    .submitLabel(.done)
                    .focused($fieldFocused)
                    .onSubmit(add)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .border(rejected ? Theme.accent : Theme.ink, width: 2)
                Button(action: add) {
                    Text("Add")
                        .font(Theme.meta)
                        .foregroundStyle(input.isEmpty ? Theme.metaGrey : Theme.ink)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .border(input.isEmpty ? Theme.metaGrey : Theme.ink, width: 2)
                }
                .buttonStyle(.plain)
                .disabled(input.isEmpty)
            }
            HStack(spacing: 0) {
                ForEach(KillRule.Kind.allCases, id: \.self) { candidate in
                    kindButton(candidate)
                }
                Spacer(minLength: 8)
                Text(kindHint)
                    .font(Theme.meta)
                    .foregroundStyle(rejected ? Theme.accentText : Theme.metaGrey)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    private func kindButton(_ candidate: KillRule.Kind) -> some View {
        let selected = candidate == kind
        return Button {
            manualKind = candidate
        } label: {
            Text(candidate.label)
                .font(Theme.meta)
                .foregroundStyle(selected ? Theme.ground : Theme.ink)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(selected ? Theme.ink : Theme.ground)
                .border(Theme.ink, width: 2)
                .padding(.trailing, -2)  // shared border between the pair
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var kindHint: String {
        if rejected { return "Nothing to add" }
        switch kind {
        case .domain: return "Hides the site and its subdomains"
        case .phrase: return "Hides titles containing the word"
        }
    }

    private func add() {
        guard let rule = KillRule(kind: kind, input: input) else {
            rejected = true
            return
        }
        killfile.add(rule)
        input = ""
        manualKind = nil
    }

    // MARK: Status

    private var statusLine: some View {
        HStack(spacing: 8) {
            Text(hiddenLabel)
            Text("·").foregroundStyle(Theme.dots)
            Text(killfile.isCloudBacked ? "Syncs via iCloud" : "This device only")
            Spacer(minLength: 0)
        }
        .font(Theme.meta)
        .foregroundStyle(Theme.metaGrey)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.headerRule).frame(height: 2)
        }
    }

    private var hiddenLabel: String {
        guard loadedCount > 0 else { return "Nothing loaded yet" }
        return "\(hiddenCount) of \(loadedCount) loaded stories hidden"
    }

    // MARK: Rules

    @ViewBuilder
    private var rules: some View {
        if killfile.rules.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Nothing hidden.")
                    .font(Theme.headline)
                    .foregroundStyle(Theme.ink)
                Text("Add a site or a word above, or long-press any story to hide its site.")
                    .font(Theme.body13)
                    .foregroundStyle(Theme.metaGrey)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            List {
                ForEach(killfile.rules) { rule in
                    row(rule)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Theme.ground)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                killfile.remove(rule)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
                .onDelete { killfile.remove(atOffsets: $0) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private func row(_ rule: KillRule) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(rule.value)
                .font(Theme.headline)
                .kerning(-0.2)
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
            Spacer(minLength: 8)
            Text(rule.kind.label.uppercased())
                .font(Theme.stamp)
                .kerning(0.66)
                .foregroundStyle(Theme.metaGrey)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.rowRule).frame(height: 2)
        }
    }
}
