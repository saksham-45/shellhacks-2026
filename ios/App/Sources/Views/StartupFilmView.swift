import SwiftUI
import AVKit

/// 9:16 Brickell follow-cam on launch. Skipped in UI tests, screenshot routes, and Reduce Motion.
struct StartupFilmView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onFinished: () -> Void

    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                SilentPlayer(player: player)
                    .ignoresSafeArea()
                    .accessibilityLabel(Text(verbatim: "myMiami"))
            }
            VStack {
                Spacer()
                Button(action: finish) {
                    AppText("app.startup.skip")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(CivicTheme.cream)
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 20)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 28)
            }
        }
        .onTapGesture(perform: finish)
        .onAppear(perform: start)
        .onDisappear { player?.pause() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { _ in
            finish()
        }
    }

    private func start() {
        if reduceMotion {
            finish()
            return
        }
        guard let url = Bundle.main.url(forResource: "brickell-ride", withExtension: "mp4") else {
            finish()
            return
        }
        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)
        p.isMuted = true
        player = p
        p.play()
    }

    private func finish() {
        player?.pause()
        onFinished()
    }
}

/// 9:16 film, no system playback chrome. Bike stays centered.
private struct SilentPlayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
