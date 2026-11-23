import SwiftUI
import LinkPresentation

struct InstagramPreview: View {
    let url: URL
    let useTitle: (String) -> Void
    @State private var title: String?
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 120)
                    .clipShape(.rect(cornerRadius: 10))
            }
            if let title, !title.isEmpty {
                Text(title).font(.footnote).lineLimit(3)
                Button("タイトルを検索に使う") { useTitle(title) }
                    .font(.footnote)
            }
            Link("Instagramで開く", destination: url)
        }
        .task(id: url) {
            title = nil
            image = nil
            let provider = LPMetadataProvider()
            provider.timeout = 5
            guard let metadata = try? await provider.startFetchingMetadata(for: url),
                  !Task.isCancelled else { return }
            title = metadata.title
            guard let item = metadata.imageProvider,
                  let object = try? await item.loadItem(forTypeIdentifier: "public.image"),
                  !Task.isCancelled else { return }
            if let preview = object as? UIImage { image = preview }
            else if let data = object as? Data { image = UIImage(data: data) }
            else if let file = object as? URL, file.isFileURL { image = UIImage(contentsOfFile: file.path) }
        }
    }
}
