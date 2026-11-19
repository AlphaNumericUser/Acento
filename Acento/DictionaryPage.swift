import SwiftUI

struct DictionaryPage: View {
    @Environment(\.locale) private var locale
    @ObservedObject var model: AppModel
    @State private var search = ""
    @State private var searching = false
    @State private var ascending = true
    @State private var editing = false
    @State private var editingID: UUID?
    @State private var spoken = ""
    @State private var written = ""
    @State private var mode: DictionaryMode = .contextual

    private var visibleTerms: [DictionaryTerm] {
        model.terms.filter { term in
            search.isEmpty || term.display.localizedCaseInsensitiveContains(search)
        }.sorted { ascending ? $0.display.localizedStandardCompare($1.display) == .orderedAscending : $0.display.localizedStandardCompare($1.display) == .orderedDescending }
    }

    private var canSaveTerm: Bool {
        !spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !written.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 28) {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Dictionary")
                            .font(AppFonts.figtree(size: 28, weight: .semibold))
                        Text("Personalize your dictation with your own words and terms. Correct common errors and automatically replace one word or phrase with another.")
                            .font(AppFonts.figtree(size: 14))
                            .foregroundStyle(Color.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button { openEditor(nil) } label: {
                        Text("Add new")
                            .font(AppFonts.figtree(size: 14, weight: .semibold))
                            .foregroundStyle(Color.onAccent)
                            .padding(.horizontal, 18).padding(.vertical, 11)
                            .background(Color.inkPrimary, in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(FlowButtonStyle())
                }
                .padding(.bottom, 14)

                HStack(spacing: 26) {
                    Text("Personal words")
                        .font(AppFonts.figtree(size: 14, weight: .medium))
                        .padding(.bottom, 12)
                        .overlay(alignment: .bottom) { Color.inkPrimary.frame(height: 2) }
                    Spacer()
                    if searching {
                        TextField("Search words", text: $search)
                            .textFieldStyle(.roundedBorder).frame(width: 170)
                    }
                    HoverIconButton(symbol: searching ? "xmark" : "magnifyingglass", tooltip: searching ? "Close search" : "Search dictionary") {
                        searching.toggle()
                        if !searching { search = "" }
                    }
                    HoverIconButton(symbol: "arrow.up.arrow.down", tooltip: ascending ? "Sort descending" : "Sort ascending") {
                        ascending.toggle()
                    }
                    HoverIconButton(symbol: "arrow.clockwise", tooltip: "Refresh list") {
                        search = ""
                    }
                }
                .overlay(alignment: .bottom) { Color.cardBorder.frame(height: 1) }

                VStack(spacing: 0) {
                    if visibleTerms.isEmpty {
                        Text("No words found. Add a word to get started.")
                            .foregroundStyle(Color.inkSecondary)
                            .frame(maxWidth: .infinity).padding(34)
                    }
                    ForEach(Array(visibleTerms.enumerated()), id: \.element.id) { index, term in
                        if index > 0 { Color.cardBorder.frame(height: 1) }
                        DictionaryTermRow(term: term, edit: { openEditor(term) }, delete: {
                            model.deleteTerm(term.id)
                        })
                    }
                }
                .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(Color.cardBorder))
            }
            .foregroundStyle(Color.inkPrimary)
            .padding(38)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .sheet(isPresented: $editing) {
            VStack(alignment: .leading, spacing: 18) {
                Text(LocalizedStringKey(editingID == nil ? "Add new word" : "Edit word"))
                    .font(AppFonts.figtree(size: 23, weight: .semibold))
                Text("Spoken word or phrase").font(AppFonts.figtree(size: 13, weight: .medium))
                TextField("What you say", text: $spoken).textFieldStyle(.roundedBorder)
                Text("Write as").font(AppFonts.figtree(size: 13, weight: .medium))
                TextField("How it should appear", text: $written).textFieldStyle(.roundedBorder)
                FlowMenuPicker(title: "Correction mode", selection: $mode, items: DictionaryMode.allCases,
                               label: { L10n.text($0.title, locale: locale) })
                Text(LocalizedStringKey(mode == .contextual
                    ? "AI uses the sentence to decide whether to correct this term. Ambiguous words stay unchanged. Requires AI Processing to be enabled and configured."
                    : "Always replaces the recognized word or phrase, even without AI Processing."))
                    .font(AppFonts.figtree(size: 12))
                    .foregroundStyle(Color.inkSecondary)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                        .buttonStyle(FlowButtonStyle())
                    Button {
                        let term = DictionaryTerm(id: editingID ?? UUID(), spoken: spoken.trimmingCharacters(in: .whitespacesAndNewlines), written: written.trimmingCharacters(in: .whitespacesAndNewlines), mode: mode)
                        if let index = model.terms.firstIndex(where: { $0.id == term.id }) {
                            model.terms[index] = term
                        } else {
                            model.terms.append(term)
                        }
                        editing = false
                    } label: {
                        Text("Save")
                            .font(AppFonts.figtree(size: 12, weight: .semibold))
                            .foregroundStyle(canSaveTerm ? Color.onAccent : Color.inkPrimary)
                            .padding(.horizontal, 18)
                            .frame(height: 34)
                            .background(canSaveTerm ? Color.inkPrimary : Color.disabledBackground, in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(FlowButtonStyle(enabled: canSaveTerm))
                    .disabled(!canSaveTerm)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(28).frame(width: 440)
            .foregroundStyle(Color.inkPrimary)
            .background(Color.cardBackground)
            .presentationBackground(Color.cardBackground)
            .appAppearance()
        }
    }

    private func openEditor(_ term: DictionaryTerm?) {
        editingID = term?.id
        spoken = term?.spoken ?? ""
        written = term?.written ?? ""
        mode = term?.mode ?? .contextual
        editing = true
    }
}

private struct DictionaryTermRow: View {
    let term: DictionaryTerm
    let edit: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(term.display).font(AppFonts.figtree(size: 15))
                Text(LocalizedStringKey(term.mode.title))
                    .font(AppFonts.figtree(size: 11))
                    .foregroundStyle(Color.inkSecondary)
            }
            Spacer()
            if hovering {
                HoverIconButton(symbol: PencilGlyph.name, tooltip: "Edit word", weight: .light, action: edit)
                HoverIconButton(symbol: "trash", tooltip: "Delete word", weight: .light, action: delete)
            }
        }
        .padding(.horizontal, 18).frame(minHeight: 58)
        .background(hovering ? Color.rowHoverBackground : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
