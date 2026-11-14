import QuickLookThumbnailing
import AppKit

final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let size = request.maximumSize
        // Fast path: slicer-embedded preview image.
        if let data = ModelLoader.embeddedThumbnail(url: request.fileURL), let image = NSImage(data: data) {
            handler(reply(image, size), nil); return
        }
        do {
            let model = try ModelLoader.load(url: request.fileURL)
            let result = SceneBuilder.build(model)
            guard let image = SceneBuilder.snapshot(result, size: CGSize(width: size.width * request.scale,
                                                                          height: size.height * request.scale)) else {
                handler(nil, nil); return
            }
            handler(reply(image, size), nil)
        } catch {
            handler(nil, error)
        }
    }

    private func reply(_ image: NSImage, _ maxSize: CGSize) -> QLThumbnailReply {
        // Aspect-fit into the requested box.
        let s = image.size
        let k = min(maxSize.width / max(s.width, 1), maxSize.height / max(s.height, 1))
        let size = CGSize(width: s.width * k, height: s.height * k)
        return QLThumbnailReply(contextSize: size, currentContextDrawing: {
            image.draw(in: CGRect(origin: .zero, size: size))
            return true
        })
    }
}
