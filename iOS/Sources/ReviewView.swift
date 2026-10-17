import InkRelayCore
import SwiftUI
import UIKit

/// The Mac's read-later stack, one card at a time: swipe right or tap Done, swipe left or tap Later.
/// Choices are written to this device's file in the shared folder; the Mac applies them on its next pass.
struct ReviewView: View {
    @State private var today: PhoneReviewStack.Today?
    @State private var message: String?
    @State private var choosing = false
    @State private var hasFolder = MobileRelay.shared.ledgerFolderName != nil
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if !hasFolder {
                    ContentUnavailableView {
                        Label("Review on your phone", systemImage: "rectangle.stack")
                    } description: {
                        Text("Pick the InkRelay folder in iCloud Drive that your Mac shares, and the review stack shows up here.")
                    } actions: {
                        Button("Choose Folder…") { choosing = true }.buttonStyle(.borderedProminent)
                    }
                } else if let today, !today.published {
                    ContentUnavailableView(
                        "Nothing shared yet",
                        systemImage: "icloud.and.arrow.down",
                        description: Text("Turn on \"Share with InkRelay on iPhone and iPad\" in InkRelay on your Mac. Cards appear here after its next sync.")
                    )
                } else if let today, let card = today.cards.first {
                    VStack(spacing: 12) {
                        Text("\(today.due) to review").font(.subheadline).foregroundStyle(.secondary)
                        SwipeCard(card: card) { action in decide(card, action) }
                            .id(card.id + card.contentHash)
                        actions(for: card, canAddEvents: today.canAddEvents)
                    }
                    .padding()
                } else if today != nil {
                    ContentUnavailableView("All caught up", systemImage: "checkmark.circle", description: Text("New pages from your tablet land here."))
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if hasFolder {
                    Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Refresh")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let message {
                    Text(message).font(.footnote).foregroundStyle(.secondary).padding(.bottom, 6)
                }
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                do {
                    try MobileRelay.shared.setLedgerFolder(result.get())
                    hasFolder = true
                    reload()
                } catch {
                    message = error.localizedDescription
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
    }

    @ViewBuilder
    private func actions(for card: ReviewCard, canAddEvents: Bool) -> some View {
        HStack(spacing: 12) {
            Button { decide(card, .later) } label: {
                Label("Later", systemImage: "clock.arrow.circlepath").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            if card.kind == .event, canAddEvents {
                Button { decide(card, .accept) } label: {
                    Label("Add to Calendar", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            Button { decide(card, .done) } label: {
                Label("Done", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
    }

    private func reload() {
        guard hasFolder else { return }
        Task.detached(priority: .userInitiated) {
            let result = Result { try MobileRelay.shared.withReviewStack { $0.today() } }
            await MainActor.run {
                switch result {
                case .success(let fresh):
                    today = fresh
                    message = nil
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
        }
    }

    /// Takes the card off at once, records the choice, then reloads to bring in the next one.
    private func decide(_ card: ReviewCard, _ action: ReviewDecision.Action) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy) {
            today?.cards.removeAll { $0.id == card.id }
            today?.due -= 1
        }
        Task.detached(priority: .userInitiated) {
            let result = Result { try MobileRelay.shared.withReviewStack { try $0.decide(card, action) } }
            await MainActor.run {
                if case .failure(let error) = result { message = error.localizedDescription }
                reload()
            }
        }
    }
}

/// One card: the page as written, what was read from it, and a drag that decides it.
private struct SwipeCard: View {
    let card: ReviewCard
    let onDecide: (ReviewDecision.Action) -> Void

    @State private var image: UIImage?
    @State private var drag: CGSize = .zero
    private let threshold: CGFloat = 110

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title).font(.headline).lineLimit(2)
                Text(card.subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            if card.hasImage {
                ZStack {
                    Color(white: 0.97)
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(maxHeight: .infinity)
            }
            if !card.text.isEmpty {
                ScrollView {
                    Text(card.text).font(.body).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                .frame(maxHeight: card.hasImage ? 120 : .infinity)
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
        .overlay(alignment: drag.width > 0 ? .topLeading : .topTrailing) { badge }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
        .offset(x: drag.width, y: drag.height / 4)
        .rotationEffect(.degrees(Double(drag.width / 25)))
        .gesture(
            DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    if value.translation.width > threshold {
                        onDecide(.done)
                    } else if value.translation.width < -threshold {
                        onDecide(.later)
                    } else {
                        withAnimation(.snappy) { drag = .zero }
                    }
                }
        )
        .task(id: card.id + card.contentHash) {
            let card = card
            let data = await Task.detached { try? MobileRelay.shared.withReviewStack { $0.imageData(for: card) } }.value
            image = data.flatMap { $0 }.flatMap(UIImage.init(data:))
        }
        .accessibilityAction(named: "Done") { onDecide(.done) }
        .accessibilityAction(named: "Later") { onDecide(.later) }
    }

    @ViewBuilder
    private var badge: some View {
        let progress = min(abs(drag.width) / threshold, 1)
        if progress > 0.15 {
            Text(drag.width > 0 ? "DONE" : "LATER")
                .font(.headline.weight(.heavy))
                .foregroundStyle(drag.width > 0 ? Color.green : Color.orange)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(drag.width > 0 ? Color.green : Color.orange, lineWidth: 2))
                .rotationEffect(.degrees(drag.width > 0 ? -12 : 12))
                .padding(20)
                .opacity(progress)
        }
    }
}
