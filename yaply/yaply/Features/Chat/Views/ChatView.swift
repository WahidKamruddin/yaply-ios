import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    let conversationId: UUID
    let currentUserId: UUID
    let currentUsername: String
    let conversationName: String

    @State private var vm: ChatViewModel
    @State private var messageText = ""
    @State private var showExpression = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var recordingVoice = false
    @State private var photoItem: PhotosPickerItem?
    @State private var threadRoot: DecryptedMessage?
    @State private var scrollToId: UUID?
    @State private var highlightedId: UUID?
    /// The own message whose Sent / Delivered / Seen line is showing (tap to toggle).
    @State private var expandedStatusId: UUID?
    @State private var searchIsActive = false
    @State private var searchQuery = ""
    @State private var showGroupInfo = false
    /// Not read by this view's body, so the timestamp drag doesn't re-evaluate it.
    @State private var swipe = SwipeRevealState()
    // Derived directly in `onScrollGeometryChange` rather than storing the raw
    // offsets: the old version wrote two continuous CGFloats into @State on
    // every scroll tick, which re-evaluated this whole body ~60x a second.
    // Everything downstream only ever wanted this one boolean.
    @State private var isNearBottom = true
    @State private var newMsgCount = 0
    @State private var commandFeedback: String?
    @State private var comingSoon = false

    private var showScrollButton: Bool { !isNearBottom }
    @State private var feedbackDismissTask: Task<Void, Never>?
    @State private var showHelp = false
    @State private var isDropTargeted = false
    @State private var actionsMessage: DecryptedMessage?
    @State private var actionsPosition: BubblePosition = .single
    @State private var actionsAnchorRect: CGRect = .zero
    @State private var messageToDelete: UUID?
    // Deliberately a reference box and not @State. Bubble frames change on
    // every scroll frame, so publishing them into view state re-evaluated this
    // body continuously. Its readers (the long-press overlay anchor and the
    // send flight) are point-in-time reads, so nothing needs to observe the writes.
    @State private var anchorStore = BubbleAnchorStore()
    @State private var hasScrolledInitially = false
    /// True once `vm.onAppear()` has merged the first page; the scroll view is built then.
    @State private var initialLoadDone = false
    @State private var scrollProxy: ScrollViewProxy?
    /// How far the keyboard pushes the list and composer up. A reference, read only by `KeyboardLift`.
    @State private var keyboardLift = KeyboardLiftStore()
    /// The text send currently flying from the composer into its bubble. A
    /// reference store, not a SendFlight @State: only the overlay and the
    /// hidden row observe it, so a flight never re-evaluates this body.
    @State private var flightStore = SendFlightStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppRouter.self) private var router

    private let convRepository = ConversationRepository()

    init(conversationId: UUID, currentUserId: UUID, currentUsername: String, conversationName: String) {
        self.conversationId = conversationId
        self.currentUserId = currentUserId
        self.currentUsername = currentUsername
        self.conversationName = conversationName
        _vm = State(initialValue: ChatViewModel(conversationId: conversationId, currentUserId: currentUserId))
    }

    private var currentOtherMember: MemberSummary? {
        vm.conversationMembers.first(where: { $0.userId != currentUserId })
    }
    private var isOnline: Bool { currentOtherMember?.profile.effectiveOnline ?? false }
    private var displayName: String {
        if vm.isGroupConversation { return vm.groupName ?? conversationName }
        return currentOtherMember?.profile.name ?? conversationName
    }

    /// The precomputed layout for the full history, or a freshly built one for
    /// the filtered subset while a search is active.
    ///
    /// The unfiltered case -- which is every case except the user actively
    /// typing in the search field -- costs nothing here: the view model already
    /// built it when `messages` last changed. The search case rebuilds, but the
    /// result set is small and the user is typing anyway.
    private var layout: MessageListLayout {
        guard !searchQuery.isEmpty else { return vm.layout }
        let filtered = vm.messages.filter { msg in
            !msg.isDeleted && msg.isText && msg.content.localizedCaseInsensitiveContains(searchQuery)
        }
        return MessageListLayout.build(
            filtered,
            isGroupConversation: vm.isGroupConversation,
            currentUserId: currentUserId
        )
    }

    private var replyTargetIsOwn: Bool {
        vm.replyToMessage?.senderId == currentUserId
    }

    var body: some View {

        VStack(spacing: 0) {
                if searchIsActive {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.yaplySecondary)
                        TextField("Search messages…", text: $searchQuery)
                            .font(.system(size: 14))
                        if !searchQuery.isEmpty {
                            Button { searchQuery = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(Color.yaplySecondary)
                            }
                        }
                    }
                    .padding(9)
                    .background(Color.yaplyTint)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yaplyBorder))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let pin = vm.topPinnedMessage {
                    PinnedBannerView(
                        message: pin,
                        count: vm.pinnedMessageIds.count,
                        onTap: { scrollToId = pin.id },
                        onUnpin: { vm.togglePin(messageId: pin.id) }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // The keyboard never resizes the list (see `ignoresSafeArea(.keyboard)`
                // below). Resizing it made SwiftUI re-position a LazyVStack of estimated
                // row heights on every frame of the keyboard animation, which scrolled
                // through the history and back. Instead the list and composer slide up
                // together by the keyboard's height, like one rigid block, so whatever
                // is on screen stays directly above the composer, anywhere in the history.
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                if vm.hasMore {
                                    ProgressView()
                                        .padding()
                                        .onAppear {
                                            // Not until the newest page is loaded and pinned to
                                            // the bottom; the list is at the top while it populates.
                                            guard hasScrolledInitially else { return }
                                            Task { await vm.loadOlderMessages() }
                                        }
                                }

                                let layout = layout
                                ForEach(layout.groups) { group in
                                    DateSeparatorView(date: group.date)
                                    // Keyed by rowId so an own send keeps its identity when the
                                    // server confirms it (temp id → real id). See SendFlight.
                                    ForEach(group.messages, id: \.rowId) { msg in
                                        messageRow(
                                            msg,
                                            layout: layout,
                                            position: layout.positions[msg.id] ?? .single,
                                            startsNewSpeaker: layout.newSpeakerIds.contains(msg.id)
                                        )
                                    }
                                }

                                if !vm.typingUserIds.isEmpty {
                                    // In a DM there's only one person who could ever be typing, so
                                    // use the same currentOtherMember lookup the header avatar
                                    // already relies on rather than matching the broadcast's userId
                                    // against the member list — one less thing that has to line up
                                    // exactly. Groups still need the id-based lookup since there's
                                    // more than one possible typer.
                                    let typingMember = vm.isGroupConversation
                                        ? vm.conversationMembers.first(where: {
                                            $0.userId.uuidString.lowercased() == vm.typingUserIds.first?.lowercased()
                                        })
                                        : currentOtherMember
                                    HStack(alignment: .bottom, spacing: 8) {
                                        AvatarView(
                                            url: typingMember?.profile.avatarUrl,
                                            name: typingMember?.profile.name ?? "?",
                                            size: 28
                                        )
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("placeholder")
                                                .font(.caption)
                                                .fontWeight(.medium)
                                                .hidden()
                                            TypingBubbleView()
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 2)
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                                        removal: .opacity
                                    ))
                                    .id("typing")
                                }

                                Color.clear.frame(height: 10).id("bottom")
                            }
                            .padding(.vertical, 8)
                            .animation(.easeOut(duration: 0.2), value: vm.typingUserIds.isEmpty)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onTapGesture {
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                        // The visible part only (minus any safe-area insets). Stored in the
                        // reference box, not @State, so the keyboard animation doesn't re-evaluate
                        // this body on every frame; the send flight reads it once.
                        .onGeometryChange(for: CGRect.self) { g in
                            let frame = g.frame(in: .global)
                            return CGRect(
                                x: frame.minX,
                                y: frame.minY + g.safeAreaInsets.top,
                                width: frame.width,
                                height: max(0, frame.height - g.safeAreaInsets.top - g.safeAreaInsets.bottom)
                            )
                        } action: { visible in
                            anchorStore.scrollViewFrame = visible
                        }
                        .onScrollGeometryChange(for: Bool.self) { geo in
                            // "Near the bottom" == within one viewport of it, same
                            // rule as before, just evaluated before it reaches @State
                            // so a write only happens when the answer actually flips.
                            let distance = geo.contentSize.height
                                - (geo.contentOffset.y + geo.containerSize.height)
                            return max(0, distance) <= max(1, geo.containerSize.height)
                        } action: { _, nearBottom in
                            isNearBottom = nearBottom
                            if nearBottom {
                                newMsgCount = 0
                                // Back at the bottom: release history far above the
                                // viewport, then re-pin so the removal can't shift it.
                                if vm.trimHistoryIfNeeded() {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            if showScrollButton {
                                ZStack(alignment: .topTrailing) {
                                    Button {
                                        newMsgCount = 0
                                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                                    } label: {
                                        Image(systemName: "chevron.down")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .frame(width: 36, height: 36)
                                            .background(Color.yaplyAccent)
                                            .clipShape(Circle())
                                            .shadow(color: Color.yaplyAccent.opacity(0.35), radius: 6, y: 2)
                                    }
                                    if newMsgCount > 0 {
                                        Text(newMsgCount > 99 ? "99+" : "\(newMsgCount)")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 4)
                                            .frame(minWidth: 18, minHeight: 18)
                                            .background(Color.yaplyDanger)
                                            .clipShape(Capsule())
                                            .offset(x: 6, y: -6)
                                    }
                                }
                                .padding(.trailing, 16)
                                .padding(.bottom, 10)
                                .transition(.scale.combined(with: .opacity))
                            }
                        }
                        .animation(.easeInOut(duration: 0.2), value: showScrollButton)
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 10)
                                .onChanged { value in
                                    let dx = value.translation.width
                                    let dy = value.translation.height
                                    guard abs(dx) > abs(dy) else { return }
                                    swipe.offset = max(-65, min(0, dx))
                                }
                                .onEnded { _ in
                                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                                        swipe.offset = 0
                                    }
                                }
                        )
                        .onChange(of: vm.messages.count) { _, _ in
                            handleMessageCountChange(proxy: proxy)
                        }
                        .onChange(of: vm.typingUserIds.isEmpty) { _, isEmpty in
                            if !isEmpty && isNearBottom {
                                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                            }
                        }
                        .onChange(of: scrollToId) { _, id in
                            guard let id else { return }
                            withAnimation { proxy.scrollTo(rowId(for: id), anchor: .center) }
                            scrollToId = nil
                            highlightedId = id
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                highlightedId = nil
                            }
                        }
                        .opacity(hasScrolledInitially ? 1 : 0)
                        .overlay {
                            if !hasScrolledInitially {
                                ProgressView()
                            }
                        }
                        // The scroll view is rebuilt (`.id`) once the first page is merged, so
                        // its first layout already holds the newest messages and starts at the
                        // bottom. Chasing the bottom with scrollTo(id) on an initially empty
                        // LazyVStack resolved against estimated row heights and landed short.
                        // All roles, not just the initial offset: the anchor also keeps the
                        // bottom pinned when the content height is re-estimated (LazyVStack
                        // rows realizing) and when the keyboard resizes the viewport, natively
                        // and in step with the keyboard. scrollTo(id) in a LazyVStack resolves
                        // against estimates and was the source of the jumps.
                        .defaultScrollAnchor(.bottom)
                        .task {
                            scrollProxy = proxy
                            guard initialLoadDone else { return }
                            // Safety net only; the anchor above does the positioning.
                            proxy.scrollTo("bottom", anchor: .bottom)
                            try? await Task.sleep(nanoseconds: 50_000_000)
                            proxy.scrollTo("bottom", anchor: .bottom)
                            hasScrolledInitially = true
                        }
                        .id(initialLoadDone)
                    }
                    .task {
                        vm.currentUsername = currentUsername
                        newMsgCount = 0
                        await vm.onAppear()
                        initialLoadDone = true
                    }

                    // Command feedback banner
                    if let feedback = commandFeedback {
                        HStack(spacing: 8) {
                            Image(systemName: "terminal")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.yaplySecondary)
                            Text(feedback)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.yaplySecondary)
                            Spacer()
                            Button { commandFeedback = nil } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.yaplySecondary.opacity(0.6))
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.yaplyTint)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yaplyBorder.opacity(0.8)))
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    if vm.myRequestState == "pending" {
                        MessageRequestBarView(
                            conversationId: conversationId,
                            currentUserId: currentUserId,
                            otherUserId: currentOtherMember?.userId,
                            onAccepted: { vm.setMyRequestState("accepted") },
                            onDeclinedOrBlocked: { router.pop() }
                        )
                    } else if recordingVoice {
                        VoiceRecorderBar(
                            onCancel: { recordingVoice = false },
                            onSend: { url, _ in
                                recordingVoice = false
                                Task { await vm.sendVoiceMessage(fileURL: url) }
                            }
                        )
                    } else {
                        MessageInputView(
                            text: $messageText,
                            replyTo: vm.replyToMessage,
                            replyIsOwn: replyTargetIsOwn,
                            onSend: { linkPreview, latePreview in
                                let rawText = messageText.trimmingCharacters(in: .whitespaces)
                                guard !rawText.isBlank else { return }
                                messageText = ""
                                vm.notifyStopTyping()
                                if let cmd = ParsedCommand.parse(rawText) {
                                    latePreview?.cancel()
                                    Task { await handleCommand(cmd) }
                                } else if let pending = vm.beginTextSend(text: rawText, linkPreview: linkPreview) {
                                    startSendFlight(for: pending)
                                    Task { await vm.completeTextSend(pending, latePreview: latePreview) }
                                }
                            },
                            onCancelReply: { vm.replyToMessage = nil },
                            disabled: vm.isSending,
                            onPickFile: { showFileImporter = true },
                            onPickCamera: {
                                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                    showCamera = true
                                } else {
                                    showPhotoPicker = true
                                }
                            },
                            onPickImage: { showPhotoPicker = true },
                            onStartVoice: { recordingVoice = true },
                            onEmoji: { showExpression = true },
                            onTyping: { vm.notifyTyping() },
                            onStopTyping: { vm.notifyStopTyping() },
                            onPasteImage: { image in
                                Task {
                                    if image.hasAlpha {
                                        await vm.sendStickerMessage(image: image)
                                    } else {
                                        if let photo = await MediaEncoding.photoJPEG(image) {
                                            await vm.sendImageMessage(imageData: photo.data, mimeType: "image/jpeg", pixelSize: photo.size)
                                        }
                                    }
                                }
                            },
                            // No onFocusChange scroll: `KeyboardLift` slides the list and
                            // composer up as one piece. A scrollTo(id) on focus made the
                            // LazyVStack re-estimate and land hundreds of points away on device.
                            members: vm.conversationMembers,
                            isGroup: vm.isGroupConversation,
                            onFieldFrame: { anchorStore.composerFieldFrame = $0 },
                            onFieldChromeFrame: { anchorStore.composerChromeFrame = $0 }
                        )
                    }
                }
                .modifier(KeyboardLift(store: keyboardLift))
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background { KeyboardHeightProbe(store: keyboardLift) }
        .background(Color.yaplyBackground.ignoresSafeArea())
        .onDrop(of: [.image], isTargeted: $isDropTargeted) { providers in
            handleDroppedProviders(providers)
        }
        .overlay {
            if isDropTargeted {
                ZStack {
                    Color.yaplyAccent.opacity(0.12).ignoresSafeArea()
                    Text("Drop to send")
                        .font(.chatDisplay(15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(Color.yaplyAccent)
                        .clipShape(Capsule())
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
        .overlay {
            SendFlightLayer(
                store: flightStore,
                mentionMembers: vm.isGroupConversation ? vm.conversationMembers : [],
                currentUserId: currentUserId
            )
        }
        .overlay {
            if let m = actionsMessage {
                MessageActionsOverlay(
                    message: m,
                    isOwn: m.senderId == currentUserId,
                    position: actionsPosition,
                    myReactions: vm.myReactions(for: m.id),
                    isPinned: vm.isPinned(m.id),
                    canDelete: m.senderId == currentUserId,
                    anchorRect: actionsAnchorRect,
                    mentionMembers: vm.isGroupConversation ? vm.conversationMembers : [],
                    currentUserId: currentUserId,
                    onReact: { emoji in vm.toggleReaction(messageId: m.id, emoji: emoji) },
                    onReply: { vm.replyToMessage = m },
                    onCopy: {
                        UIPasteboard.general.string = m.isText ? m.content : (m.mediaUrl ?? "")
                    },
                    onTogglePin: { vm.togglePin(messageId: m.id) },
                    onDelete: { messageToDelete = m.id },
                    onDismiss: { actionsMessage = nil }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: actionsMessage?.id)
        .yaplyConfirm(
            isPresented: Binding(
                get: { messageToDelete != nil },
                set: { if !$0 { messageToDelete = nil } }
            ),
            title: "Delete message",
            message: "This will delete the message for everyone.",
            icon: "trash.fill",
            confirmLabel: "Delete"
        ) {
            if let id = messageToDelete {
                Task { await vm.deleteMessage(id: id) }
            }
            messageToDelete = nil
        }
        .navigationTitle(displayName)
        .navChrome()
        .toolbar {
            ToolbarItem(placement: .principal) {
                headerPrincipalContent
                    .contentShape(Rectangle())
                    .onTapGesture { showGroupInfo = true }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 4) {
                    pillButton(systemName: searchIsActive ? "xmark" : "magnifyingglass",
                               filled: searchIsActive) {
                        withAnimation(.easeInOut(duration: 0.2)) { searchIsActive.toggle() }
                        if !searchIsActive { searchQuery = "" }
                    }
                    // Messenger renders call icons as solid-filled circles;
                    // yaply/iMessage keep the outline style.
                    pillButton(systemName: "phone", filled: ChatStyle.current == .messenger) { comingSoon = true }
                    pillButton(systemName: "video", filled: ChatStyle.current == .messenger) { comingSoon = true }
                    pillButton(systemName: "sidebar.right") { openPanel("tasks") }
                }
            }
        }
        .onAppear { router.activeConversationId = conversationId }
        .onDisappear {
            router.activeConversationId = nil
            vm.onDisappear()
        }
        .sheet(isPresented: $showExpression) {
            ExpressionPickerSheet(onGifSelected: { gif in
                let url = MediaAspectRatio.annotate(gif.url, pixelSize: gif.pixelSize)
                Task { await vm.sendGifMessage(url: url) }
            })
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                Task {
                    if let photo = await MediaEncoding.photoJPEG(image) {
                        await vm.sendImageMessage(imageData: photo.data, mimeType: "image/jpeg", pixelSize: photo.size)
                    }
                }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let photo = await MediaEncoding.photoJPEG(from: data) {
                    await vm.sendImageMessage(imageData: photo.data, mimeType: "image/jpeg", pixelSize: photo.size)
                }
                photoItem = nil
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            Task { await vm.sendFileMessage(data: data, filename: url.lastPathComponent, mimeType: mime) }
        }
        .sheet(isPresented: $showGroupInfo) {
            GroupInfoView(
                conversationId: conversationId,
                conversationName: displayName,
                currentUserId: currentUserId,
                isDirect: !vm.isGroupConversation,
                headerAvatarUrl: vm.isGroupConversation ? nil : currentOtherMember?.profile.avatarUrl,
                onRefresh: { await vm.loadConversationInfo() },
                onDeleted: { router.pop() }
            )
        }
        .sheet(item: $threadRoot) { root in
            ThreadView(
                rootMessage: root,
                conversationId: conversationId,
                currentUserId: currentUserId,
                isGroup: vm.isGroupConversation,
                members: vm.conversationMembers,
                isPresented: Binding(
                    get: { threadRoot != nil },
                    set: { if !$0 { threadRoot = nil } }
                )
            )
        }
        .yaplyAlert(
            isPresented: Binding(get: { vm.error != nil }, set: { if !$0 { vm.error = nil } }),
            title: "Something went wrong",
            message: vm.error ?? ""
        )
        .sheet(isPresented: $showHelp) {
            HelpView()
        }
        .yaplyAlert(
            isPresented: $comingSoon,
            title: "Coming soon",
            message: "Voice and video calls aren't available yet."
        )
    }

    /// Nav-bar header content, style-dependent: yaply/Messenger show the
    /// avatar beside the name (with an online/offline caption for DMs);
    /// iMessage shows a compact centered avatar-above-name layout with no
    /// caption, matching its real header.
    @ViewBuilder
    private var headerPrincipalContent: some View {
        if ChatStyle.current == .imessage {
            VStack(spacing: 3) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(
                        url: vm.isGroupConversation ? nil : currentOtherMember?.profile.avatarUrl,
                        name: displayName,
                        size: 34
                    )
                    if !vm.isGroupConversation && currentOtherMember != nil {
                        PresenceDotView(isOnline: isOnline, borderColor: .yaplySurface, size: 8)
                    }
                }
                Text(displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.yaplyPrimary)
            }
        } else {
            HStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    AvatarView(
                        url: vm.isGroupConversation ? nil : currentOtherMember?.profile.avatarUrl,
                        name: displayName,
                        size: 36
                    )
                    if !vm.isGroupConversation && currentOtherMember != nil {
                        PresenceDotView(isOnline: isOnline, borderColor: .yaplySurface, size: 9)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(displayName)
                        .font(.chatDisplay(16, weight: .semibold))
                        .foregroundStyle(Color.yaplyPrimary)
                    if !vm.isGroupConversation && currentOtherMember != nil {
                        Text(isOnline ? "Online" : "Offline")
                            .font(.caption2)
                            .foregroundStyle(isOnline ? Color.yaplyOnline : Color.yaplySecondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pillButton(systemName: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(filled ? .white : Color.yaplyAccent)
                .frame(width: 30, height: 30)
                .background(filled ? Color.yaplyAccent : Color.clear)
                .clipShape(Circle())
        }
    }


    /// Handles images dropped onto the conversation — a sticker dragged out of the
    /// iOS Stickers drawer, or a photo from Photos/Files. A transparent image is
    /// treated as a sticker (rendered bubble-free); an opaque one as a photo.
    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: UIImage.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
            guard let image = object as? UIImage else { return }
            Task { @MainActor in
                if image.hasAlpha {
                    await vm.sendStickerMessage(image: image)
                } else {
                    guard let photo = await MediaEncoding.photoJPEG(image) else { return }
                    await vm.sendImageMessage(imageData: photo.data, mimeType: "image/jpeg", pixelSize: photo.size)
                }
            }
        }
        return true
    }

    /// Pushes the conversation's productivity panel as a page (Tasks / Notes /
    /// Reminders / Events / Albums / Budgets), rather than presenting a sheet.
    private func openPanel(_ tab: String) {
        router.push(.conversationPanel(
            conversationId: conversationId,
            members: vm.conversationMembers,
            tab: tab
        ))
    }

    /// Opens the item an item-created pill points at. Tasks and reminders
    /// have no detail view, so they open the panel tab; plans/events, albums
    /// and budgets push their own page; notes open in the panel. A deleted
    /// item falls back to its tab (a budget shows its own "deleted" state).
    private func openItem(_ item: SystemItem) async {
        if item.kind.opensInPanelOnly {
            openPanel(item.kind.tab)
            return
        }
        switch item.kind {
        case .plan, .event:
            let events = (try? await EventRepository().fetchEvents(conversationId: conversationId)) ?? []
            if let event = events.first(where: { $0.id == item.id }) {
                router.push(.eventDetail(event))
                return
            }
        case .album:
            let albums = (try? await AlbumRepository().fetchAlbums(conversationId: conversationId)) ?? []
            if let album = albums.first(where: { $0.id == item.id }) {
                let isAdmin = vm.conversationMembers.first { $0.userId == currentUserId }?.isAdmin ?? false
                router.push(.albumDetail(album: album, isCurrentUserAdmin: isAdmin))
                return
            }
        case .budget:
            // The detail page loads by id and shows "deleted" itself if gone.
            router.push(.budgetDetail(budgetId: item.id, conversationId: conversationId, members: vm.conversationMembers))
            return
        case .note:
            router.push(.conversationPanel(
                conversationId: conversationId,
                members: vm.conversationMembers,
                tab: item.kind.tab,
                focusItemId: item.id
            ))
            return
        case .task, .reminder:
            break
        }
        openPanel(item.kind.tab)
    }

    private func handleMessageCountChange(proxy: ScrollViewProxy) {
        // The initial `.task` owns first positioning; don't race it with an animated scroll.
        guard hasScrolledInitially, let last = vm.messages.last else { return }
        if let flight = flightStore.flight, flight.rowId == last.rowId {
            // The flight measures the bubble's final on-screen frame, so the
            // list has to be at rest there — no animated scroll underneath it.
            proxy.scrollTo("bottom", anchor: .bottom)
            return
        }
        if last.senderId == currentUserId || isNearBottom {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        } else {
            newMsgCount += 1
        }
    }

    /// `ScrollViewReader` ids are row ids; own sends keep their temp id as
    /// their row id after confirm, so a message id has to be translated.
    private func rowId(for messageId: UUID) -> UUID {
        vm.layout.messagesById[messageId]?.rowId ?? messageId
    }

    /// Starts the composer → bubble flight for a just-appended text send.
    /// Skipped (the bubble just appears) under Reduce Motion, for link-preview
    /// sends (the card changes the bubble's size mid-flight), or when the
    /// bubble doesn't land fully on screen in time.
    private func startSendFlight(for pending: ChatViewModel.PendingTextSend) {
        let field = anchorStore.composerFieldFrame
        guard !reduceMotion, pending.linkPreview == nil, field != .zero,
              let message = vm.messages.last(where: { $0.id == pending.tempId })
        else { return }
        let rowId = pending.tempId
        let chrome = anchorStore.composerChromeFrame == .zero
            ? field.insetBy(dx: -12, dy: -8)
            : anchorStore.composerChromeFrame
        flightStore.flight = SendFlight(
            rowId: rowId, message: message, fieldFrame: field, chromeFrame: chrome,
            chromeRadius: MessageInputView.fieldChromeRadius(height: chrome.height)
        )

        Task { @MainActor in
            // The row lays out and the list re-pins to the bottom over the next
            // frame or two. Poll briefly for the bubble's settled frame (keyed
            // by message id, which may already be the real id if the send
            // confirmed this fast).
            var target: CGRect?
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(16))
                guard flightStore.flight?.rowId == rowId else { return }
                let current = vm.messages.last(where: { $0.rowId == rowId })
                let rect = anchorStore.frames[rowId] ?? current.flatMap { anchorStore.frames[$0.id] }
                if let rect, rect.height > 0,
                   rect.minY >= anchorStore.scrollViewFrame.minY - 1,
                   rect.maxY <= anchorStore.scrollViewFrame.maxY + 1 {
                    target = rect
                    break
                }
            }
            guard let target else {
                flightStore.flight = nil
                return
            }
            flightStore.flight?.target = target
            flightStore.flight?.position = vm.messages.last(where: { $0.rowId == rowId })
                .flatMap { vm.layout.positions[$0.id] } ?? .single
            // One frame at the start position before animating, or SwiftUI
            // would insert the bubble layer already at its destination.
            try? await Task.sleep(for: .milliseconds(16))
            guard flightStore.flight?.rowId == rowId else { return }
            // Three transactions so X, Y and the colour crossfade each run on
            // their own curve (see SendFlight). Both axes last the same 0.3s.
            withAnimation(SendFlight.fade) {
                flightStore.flight?.filled = true
            }
            withAnimation(SendFlight.curveX) {
                flightStore.flight?.landedX = true
            }
            withAnimation(SendFlight.curveY) {
                flightStore.flight?.landedY = true
            } completion: {
                if flightStore.flight?.rowId == rowId { flightStore.flight = nil }
            }
        }
    }

    /// One message row. Extracted from `body` because inlining it pushed the
    /// body past the Swift type-checker's budget ("unable to type-check this
    /// expression in reasonable time") -- and because a smaller body is cheaper
    /// for SwiftUI to re-evaluate.
    @ViewBuilder
    private func messageRow(
        _ msg: DecryptedMessage,
        layout: MessageListLayout,
        position: BubblePosition,
        startsNewSpeaker: Bool
    ) -> some View {
        VStack(spacing: 0) {
        MessageBubbleView(
            message: msg,
            isOwn: msg.senderId == currentUserId,
            currentUserId: currentUserId,
            replyMessage: msg.replyToId.flatMap { layout.messagesById[$0] },
            threadCount: layout.threadCounts[msg.id] ?? 0,
            statusText: statusText(for: msg),
            onTap: { m in
                withAnimation(.easeOut(duration: 0.15)) {
                    expandedStatusId = expandedStatusId == m.id ? nil : m.id
                }
            },
            reactions: vm.reactionsMap[msg.id] ?? [],
            onReply: { vm.replyToMessage = $0 },
            onDelete: { id in Task { await vm.deleteMessage(id: id) } },
            onReact: { msgId, emoji in vm.toggleReaction(messageId: msgId, emoji: emoji) },
            onOpenThread: { threadRoot = $0 },
            onReplyInThread: { threadRoot = $0 },
            onQuotationClick: { id in scrollToId = id },
            onOpenDetail: { openPanel($0) },
            onOpenItem: { item in Task { await openItem(item) } },
            onLongPress: { m in
                actionsAnchorRect = anchorStore.frames[m.id] ?? .zero
                actionsPosition = position
                actionsMessage = m
            },
            anchorStore: anchorStore,
            groupPosition: position,
            showsSenderName: vm.isGroupConversation,
            startsNewSpeaker: startsNewSpeaker,
            mentionMembers: vm.isGroupConversation ? vm.conversationMembers : [],
            swipe: swipe
        )
        // Gated on the == above, so a ChatView re-evaluation no longer forces
        // every visible bubble to rebuild its body.
        .equatable()
        .opacity(actionsMessage?.id == msg.id ? 0 : 1)
        .modifier(SendFlightHidden(store: flightStore, rowId: msg.rowId))

            if let readers = layout.seenHeads[msg.id] {
                SeenHeadsView(profiles: readers.compactMap { id in
                    vm.conversationMembers.first { $0.userId == id }?.profile
                })
            }
        }
        .id(msg.rowId)
        // The highlight is a rounded background, not a clip: clipping every row
        // just for this cost an offscreen mask pass per row, image rows included.
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(highlightedId == msg.id ? Color.yaplyAccent.opacity(0.12) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.3), value: highlightedId)
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
    }

    /// Own messages only, and only once tapped: Sending… / Sent / Delivered /
    /// Seen. The seen avatars are the only receipt shown without a tap.
    private func statusText(for msg: DecryptedMessage) -> String? {
        guard msg.senderId == currentUserId, !msg.isDeleted, expandedStatusId == msg.id else { return nil }
        let status = ReadReceipts.status(
            of: msg, watermarks: vm.layout.effectiveWatermarks,
            currentUserId: currentUserId, pending: vm.pendingIds.contains(msg.id)
        )
        return ReadReceipts.label(status, isGroup: vm.isGroupConversation) { id in
            vm.conversationMembers.first { $0.userId == id }?.profile.name ?? "Someone"
        }
    }

    private func handleCommand(_ cmd: ParsedCommand) async {
        switch cmd.name {
        case "remind":
            do {
                try await RemindHandler.execute(args: cmd.args, conversationId: conversationId, userId: currentUserId)
                NotificationCenter.default.post(name: .yaplyItemCreated, object: nil, userInfo: ["type": "reminders"])
            } catch {
                showCommandFeedback(error.localizedDescription)
            }
        case "mute":
            do {
                try await MuteHandler.execute(args: cmd.args, conversationId: conversationId, userId: currentUserId)
                let label = cmd.args.first ?? "1h"
                showCommandFeedback("🔇 Muted for \(label)")
            } catch {
                showCommandFeedback("Failed: \(error.localizedDescription)")
            }
        case "task":
            if cmd.rawArgs.isBlank { openPanel("tasks") }
            else { await createItem(type: "task", title: cmd.rawArgs) }
        case "note":
            if cmd.rawArgs.isBlank { openPanel("notes") }
            else { await createItem(type: "note", title: cmd.rawArgs) }
        case "album":
            if cmd.rawArgs.isBlank { openPanel("albums") }
            else { await createItem(type: "album", title: cmd.rawArgs) }
        case "plan":
            if cmd.rawArgs.isBlank { openPanel("events") }
            else { await createItem(type: "plan", title: cmd.rawArgs) }
        case "event":
            openPanel("events")
        case "budget":
            openPanel("budgets")
        case "thread":
            showCommandFeedback("Open a thread by long-pressing a message and tapping Reply in Thread.")
        case "help":
            showHelp = true
        default:
            showCommandFeedback("Unknown command /\(cmd.name)")
        }
    }

    /// The repositories post the item-created pill themselves, so success
    /// needs no local feedback — only a failure does.
    private func createItem(type: String, title: String) async {
        do {
            switch type {
            case "task":
                _ = try await TaskRepository().createTask(conversationId: conversationId, createdBy: currentUserId, title: title)
                NotificationCenter.default.post(name: .yaplyItemCreated, object: nil, userInfo: ["type": "tasks"])
            case "note":
                _ = try await NoteRepository().createNote(conversationId: conversationId, userId: currentUserId, title: title)
                NotificationCenter.default.post(name: .yaplyItemCreated, object: nil, userInfo: ["type": "notes"])
            case "album":
                _ = try await AlbumRepository().createAlbum(conversationId: conversationId, createdBy: currentUserId, name: title)
                NotificationCenter.default.post(name: .yaplyItemCreated, object: nil, userInfo: ["type": "albums"])
            case "plan":
                _ = try await EventRepository().createEvent(conversationId: conversationId, createdBy: currentUserId, name: title, status: "planning")
                NotificationCenter.default.post(name: .yaplyItemCreated, object: nil, userInfo: ["type": "events"])
            default:
                break
            }
        } catch {
            showCommandFeedback("Couldn't create that \(type) — try again.")
        }
    }

    private func showCommandFeedback(_ message: String) {
        feedbackDismissTask?.cancel()
        withAnimation { commandFeedback = message }
        feedbackDismissTask = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled {
                withAnimation { commandFeedback = nil }
            }
        }
    }
}

// Mirrors BubbleContentView's received-bubble styling exactly (yaplyCard fill,
// yaplyBorderSoft stroke, same corner radii) so it reads as a real message
// bubble rather than a one-off shape.
private struct TypingBubbleView: View {
    @State private var animating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.yaplySecondary)
                    .frame(width: 6, height: 6)
                    .scaleEffect(animating ? 1 : 0.85)
                    .opacity(animating ? 1 : 0.4)
                    .offset(y: animating ? -3 : 0)
                    .animation(
                        .easeInOut(duration: 0.7)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.16),
                        value: animating
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.yaplyCard)
        .clipShape(UnevenRoundedRectangle(cornerRadii: .init(
            topLeading: 18, bottomLeading: 4, bottomTrailing: 18, topTrailing: 18
        )))
        .overlay(
            UnevenRoundedRectangle(cornerRadii: .init(
                topLeading: 18, bottomLeading: 4, bottomTrailing: 18, topTrailing: 18
            ))
            .stroke(Color.yaplyBorderSoft, lineWidth: 1)
        )
        // Reduce Motion: static dots instead of the endless bounce.
        .onAppear { if !reduceMotion { animating = true } }
    }
}

private struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Available Commands") {
                    ForEach(YaplyCommand.allCases, id: \.rawValue) { cmd in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text("/\(cmd.rawValue)")
                                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color.yaplyAccent)
                                if let hint = cmd.argHint {
                                    let pattern = hint.components(separatedBy: "  ").first ?? hint
                                    Text(pattern)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundStyle(Color.yaplySecondary.opacity(0.5))
                                }
                            }
                            Text(cmd.description)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.yaplySecondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Commands")
            .navChrome()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.yaplyAccent)
                }
            }
        }
    }
}

// MARK: - Bubble anchor tracking (for the long-press actions overlay)

/// Messenger's "seen" avatars: the members whose read watermark lands on this
/// message, right-aligned under it. As they read further, the layout moves them
/// down to a later message (placement is `ReadReceipts.seenHeads`).
private struct SeenHeadsView: View {
    let profiles: [Profile]
    private static let maxShown = 4

    var body: some View {
        if !profiles.isEmpty {
            HStack(spacing: 3) {
                Spacer(minLength: 0)
                HStack(spacing: -4) {
                    ForEach(profiles.prefix(Self.maxShown)) { profile in
                        AvatarView(url: profile.avatarUrl, name: profile.name, size: 14)
                            .overlay(Circle().stroke(Color.yaplyBackground, lineWidth: 1))
                    }
                }
                if profiles.count > Self.maxShown {
                    Text("+\(profiles.count - Self.maxShown)")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.yaplySecondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .transition(.opacity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Seen by \(profiles.map(\.name).joined(separator: ", "))")
        }
    }
}

/// Bubble frames in global coordinates, written by each visible
/// `MessageBubbleView` and read only on demand.
///
/// This replaces a `PreferenceKey` that carried the same data. A preference
/// propagates up the entire view tree and lands in `@State`, so publishing a
/// `.frame(in: .global)` through one meant a full tree walk plus a body
/// invalidation for every visible row on every frame of every scroll. Nothing
/// actually observes these values -- they are read once when a long press opens
/// the actions overlay, and once when the keyboard appears -- so a plain
/// reference type with no observation is the right storage.
final class BubbleAnchorStore {
    var frames: [UUID: CGRect] = [:]
    /// The composer TextField's global frame (for the send flight).
    var composerFieldFrame: CGRect = .zero
    /// The rounded chrome around it — the box the flight morphs into the bubble.
    var composerChromeFrame: CGRect = .zero
    /// The message list's visible global frame, excluding the composer/keyboard inset.
    var scrollViewFrame: CGRect = .zero
}

// MARK: - Keyboard lift

/// The keyboard's current overlap with the chat, above the home-indicator area.
/// Its own observable so a keyboard frame only re-renders `KeyboardLift`, not `ChatView`.
@Observable
final class KeyboardLiftStore {
    var lift: CGFloat = 0
}

/// Measures the keyboard: placed outside the view that ignores it, so its bottom
/// safe-area inset is how far the keyboard reaches up the screen.
private struct KeyboardHeightProbe: View {
    let store: KeyboardLiftStore

    private static var homeIndicatorInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.safeAreaInsets.bottom ?? 0
    }

    var body: some View {
        Color.clear
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { total in
                // The home-indicator area is part of the inset but the keyboard
                // covers it too, so it isn't part of the lift. Read from the window:
                // measuring it here caught a 0 before the first layout.
                let resting = Self.homeIndicatorInset
                // Plus a 3pt breathing gap above the keyboard while it's up.
                let overlap = total - resting
                let height = overlap > 0.5 ? overlap + 3 : 0
                let delta = abs(height - store.lift)
                guard delta > 0.5 else { return }
                // A show or hide is one step: ride the keyboard's own curve. An
                // interactive drag arrives frame by frame: follow the finger.
                if delta > 40 {
                    withAnimation(.interpolatingSpring(mass: 3, stiffness: 1000, damping: 500)) {
                        store.lift = height
                    }
                } else {
                    store.lift = height
                }
            }
    }
}

/// Slides the list and composer up by the keyboard's height without touching
/// their layout, clipping whatever passes above the list's top edge.
private struct KeyboardLift: ViewModifier {
    let store: KeyboardLiftStore

    func body(content: Content) -> some View {
        content
            .offset(y: -store.lift)
            .clipped()
    }
}

// MARK: - Pinned message banner

private struct PinnedBannerView: View {
    let message: DecryptedMessage
    let count: Int
    let onTap: () -> Void
    let onUnpin: () -> Void

    private var preview: String { message.previewText }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pin.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color.yaplyAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text(count > 1 ? "\(count) pinned messages" : "Pinned message")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.yaplyAccent)
                Text(preview)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.yaplyPrimary)
                    .lineLimit(1)
            }
            Spacer()
            Button(action: onUnpin) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.yaplySecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.yaplyTint)
        .overlay(Rectangle().fill(Color.yaplyBorderSoft).frame(height: 0.5), alignment: .bottom)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
