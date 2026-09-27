import SwiftUI
import PhotosUI
import ADCore
import ADRouter
#if canImport(UIKit)
import UIKit
#endif

/// Same-screen walkthrough after a bumper tap or a house problem: a photo,
/// what it shows, handwritten steps, the number to call, and the same words spoken.
/// Not a chat window.
struct PhotoGuideView: View {
    @Environment(AppModel.self) private var model
    let kind: Kind
    enum Kind { case vehicle, home }

    @State private var picker: PhotosPickerItem?
    @State private var image: UIImage?
    @State private var reading: SceneReading?
    @State private var working = false
    @State private var cameraOpen = false

    var body: some View {
        Section {
            CivicPrimaryButton(title: model.app("app.next.start")) { applyDemo() }
            PhotosPicker(selection: $picker, matching: .images) {
                Label { AppText("app.scene.album") } icon: { Image(systemName: "photo.on.rectangle").accessibilityHidden(true) }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .foregroundStyle(CivicTheme.midnight)
            }
            .tint(CivicTheme.midnight)
            Button { cameraOpen = true } label: {
                Label { AppText("app.scene.camera") } icon: { Image(systemName: "camera").accessibilityHidden(true) }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .foregroundStyle(CivicTheme.midnight)
            }
            .buttonStyle(.plain)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(Text(verbatim: "Selected photo"))
            }
            if working { ProgressView() }
        } header: { AppText("app.scene.photo") }
        .onChange(of: picker) { _, item in
            Task { await load(item) }
        }
        .sheet(isPresented: $cameraOpen) {
            CameraPicker { img in
                cameraOpen = false
                if let img { Task { await classify(img) } }
            }
        }

        Section {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, line in
                Text(verbatim: "\(i + 1). \(line)")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            Button {
                model.speakPlain(spokenScript, language: model.surface)
            } label: {
                Label { AppText("app.scene.speak") } icon: { Image(systemName: "speaker.wave.2").accessibilityHidden(true) }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
        } header: { AppText("app.scene.steps") }

        Section {
            ForEach(callRows, id: \.desk) { row in
                SceneCallRow(titleKey: row.titleKey, systemImage: row.systemImage, id: row.id, desk: row.desk)
            }
        } header: { AppText("app.scene.call") }

        if let reading {
            Section {
                Text(verbatim: reading.visible).font(.body.weight(.semibold))
                if !reading.whereInFrame.isEmpty {
                    Text(verbatim: reading.whereInFrame).foregroundStyle(.secondary)
                }
                Text(verbatim: model.app(reading.pack.cannotProveKey)).font(.footnote)
            } header: { AppText("app.scene.shows") }
        }
    }

    private var pack: ScenePack {
        reading?.pack ?? (kind == .vehicle ? .vehicle : .home)
    }

    private var steps: [String] {
        switch pack {
        case .vehicle:
            return [
                model.app("app.scene.vehicle.snap"),
                model.app("app.scene.vehicle.law"),
                model.app("app.scene.vehicle.exchange"),
                model.app("app.scene.vehicle.fault"),
                model.app("app.scene.vehicle.insurance"),
                model.app("app.scene.vehicle.photo"),
                model.app("app.scene.vehicle.forms"),
            ]
        case .home:
            return [
                model.app("app.scene.home.snap"),
                model.app("app.scene.home.311"),
                model.app("app.scene.home.flood"),
                model.app("app.scene.home.cannot"),
            ]
        case .unreadable:
            return [model.app("app.scene.unreadable.step")]
        case .person:
            return [model.app("app.scene.person.step")]
        }
    }

    private struct CallSpec: Identifiable {
        let titleKey: String
        let systemImage: String
        let id: String
        let desk: DeskID
    }

    private var callRows: [CallSpec] {
        var rows = [
            CallSpec(titleKey: "app.scene.call.911", systemImage: "sos", id: "scene.call.911", desk: "us.911"),
        ]
        if kind == .vehicle {
            rows.append(CallSpec(titleKey: "app.scene.call.police", systemImage: "phone", id: "scene.call.police",
                                 desk: "us-fl-miamidade.mdpd"))
        }
        rows.append(CallSpec(titleKey: "app.scene.call.311", systemImage: "phone", id: "scene.call.311",
                             desk: "us-fl-miamidade.311"))
        if kind == .vehicle {
            rows.append(CallSpec(titleKey: "app.scene.call.flhsmv", systemImage: "phone", id: "scene.call.flhsmv",
                                 desk: "us-fl.flhsmv"))
        }
        return rows
    }

    private var spokenScript: String {
        let head = [reading?.visible, model.app(pack.cannotProveKey)].compactMap { $0 }.joined(separator: ". ")
        let body = steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: " ")
        let calls = callRows.compactMap { row -> String? in
            guard let shown = model.phonesToShow(for: row.desk) else { return nil }
            return "\(model.app(row.titleKey)) \(shown)"
        }.joined(separator: ". ")
        return [head, body, calls].filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func applyDemo() {
        reading = SceneReading(
            pack: kind == .vehicle ? .vehicle : .home,
            visible: model.app(kind == .vehicle ? "app.scene.demo.visible.vehicle" : "app.scene.demo.visible.home"),
            whereInFrame: model.app(kind == .vehicle ? "app.scene.demo.where.vehicle" : "app.scene.demo.where.home")
        )
        model.speakPlain(spokenScript, language: model.surface)
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) else { return }
        await classify(img)
    }

    private func classify(_ img: UIImage) async {
        image = img
        working = true
        defer { working = false }
        if let key = SecretEnv.gemini, let jpeg = img.jpegData(compressionQuality: 0.7) {
            if let got = await SceneClassify.run(jpeg: jpeg, key: key) {
                reading = got
                model.speakPlain(spokenScript, language: model.surface)
                return
            }
        }
        applyDemo()
    }
}

/// Desk name plus the ledger number this row will dial after confirm.
struct SceneCallRow: View {
    @Environment(AppModel.self) private var model
    let titleKey: String
    let systemImage: String
    let id: String
    let desk: DeskID

    var body: some View {
        Button {
            model.router.perform(.callDesk(desk), from: .touch)
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        AppText(titleKey).foregroundStyle(.primary)
                        if let shown = trailingNumber {
                            Text(verbatim: shown)
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: systemImage).foregroundStyle(.tint).accessibilityHidden(true)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .identifier(id)
        .accessibilityInputLabels([Text(verbatim: model.app(titleKey))])
        .accessibilityValue(Text(verbatim: model.phonesToShow(for: desk) ?? ""))
    }

    private var trailingNumber: String? {
        guard let shown = model.phonesToShow(for: desk) else { return nil }
        let title = model.app(titleKey)
        let parts = shown.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 1, title.contains(parts[0]) { return nil }
        return shown
    }
}

enum SceneClassify {
    static func run(jpeg: Data, key: String) async -> SceneReading? {
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=\(key)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let b64 = jpeg.base64EncodedString()
        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": SceneGuide.classifyPrompt],
                    ["inline_data": ["mime_type": "image/jpeg", "data": b64]],
                ]
            ]],
            "generationConfig": ["temperature": 0, "responseMimeType": "application/json"],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return SceneGuide.parse(data)
    }
}

#if canImport(UIKit)
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage?) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coord { Coord(onImage: onImage) }
    final class Coord: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImage: (UIImage?) -> Void
        init(onImage: @escaping (UIImage?) -> Void) { self.onImage = onImage }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onImage(nil) }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onImage(info[.originalImage] as? UIImage)
        }
    }
}
#endif
