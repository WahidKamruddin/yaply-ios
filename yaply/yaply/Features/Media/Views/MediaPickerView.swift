import SwiftUI
import PhotosUI

struct MediaPickerView: View {
    var onImageSelected: ((Data, String) -> Void)?
    var onGifSelected: ((GiphyGif) -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab = 0
    @State private var photoItem: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab bar
                HStack(spacing: 0) {
                    ForEach(["Photos", "GIFs"], id: \.self) { tab in
                        let idx = ["Photos", "GIFs"].firstIndex(of: tab)!
                        Button(action: { selectedTab = idx }) {
                            Text(tab)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(selectedTab == idx ? Color.yaplyAccent : Color.yaplySecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .overlay(
                                    Rectangle()
                                        .fill(selectedTab == idx ? Color.yaplyAccent : Color.clear)
                                        .frame(height: 2),
                                    alignment: .bottom
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .overlay(Rectangle().fill(Color.yaplyBorder).frame(height: 1), alignment: .bottom)

                // Tab content
                if selectedTab == 0 {
                    // Photos tab — use system picker
                    VStack {
                        Spacer()
                        PhotosPicker(
                            selection: $photoItem,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            VStack(spacing: 12) {
                                Image(systemName: "photo.on.rectangle")
                                    .font(.system(size: 48))
                                    .foregroundStyle(Color.yaplyAccent)
                                Text("Choose from Library")
                                    .font(.subheadline)
                                    .foregroundStyle(Color.yaplyTertiary)
                            }
                        }
                        .onChange(of: photoItem) { _, item in
                            guard let item else { return }
                            Task {
                                if let data = try? await item.loadTransferable(type: Data.self),
                                   let original = UIImage(data: data) {
                                    let resized = original.resized(maxDimension: 1280)
                                    let compressed = resized.jpegData(compressionQuality: 0.82) ?? data
                                    onImageSelected?(compressed, "image/jpeg")
                                    dismiss()
                                }
                            }
                        }
                        Spacer()
                    }
                } else {
                    // GIFs tab
                    GifPickerView { gif in
                        onGifSelected?(gif)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Attach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.yaplyAccent)
                }
            }
            .background(Color.yaplyBackground)
        }
    }
}
