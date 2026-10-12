# One Cursor

Dùng **một bộ chuột và bàn phím** cho máy Mac, điện thoại/máy tính bảng Android và các máy tính khác — giống [Barrier](https://github.com/debauchee/barrier), nhưng hỗ trợ **macOS** và **Android**.

Đưa chuột qua mép màn hình Mac là con trỏ sang điện thoại: nhấp để chạm, kéo để vuốt, cuộn chuột để cuộn trang, gõ phím để nhập chữ (kể cả **tiếng Việt Telex**). Văn bản copy trên máy này paste được ở máy kia.

*English: One Cursor is a Barrier-compatible keyboard/mouse sharing tool with a native macOS server/client (Swift) and an Android client (Kotlin). It speaks Barrier protocol 1.6, so the Android app also works with existing Barrier / Input Leap servers and the Mac server accepts Barrier / Input Leap clients.*

```
         chuột + bàn phím
               │
      ┌────────▼────────┐   Barrier 1.6 (TCP/TLS)   ┌──────────────────┐
      │  Mac — server   │ ───────────────────────── │ Android — client │
      │ (One Cursor app)│ ─────────────┐            │ (trợ năng)       │
      └─────────────────┘              │            └──────────────────┘
                                       │            ┌──────────────────┐
                                       └─────────── │ Windows / Linux  │
                                                    │ Barrier/InputLeap│
                                                    └──────────────────┘
```

## Tính năng

| | macOS | Android |
|---|---|---|
| Làm **server** (chia sẻ chuột/bàn phím của máy này) | ✅ | — ¹ |
| Làm **client** (được điều khiển) | ✅ | ✅ |
| Tương thích Barrier / Input Leap / Synergy 1 | ✅ | ✅ |
| Mã hoá TLS, ghim fingerprint chứng chỉ | ✅ | ✅ |
| Đồng bộ clipboard (văn bản, HTML) | ✅ | ✅ ² |
| Tự tìm server trong mạng LAN (Bonjour) | quảng bá | tìm |
| Nhiều màn hình, nối một phần cạnh (`left(0,50)`), đổi phím bổ trợ (`super = ctrl`) | ✅ | — |
| Đọc file cấu hình `barrier.conf` có sẵn | ✅ | — |
| Gõ tiếng Việt Telex từ bàn phím máy tính | (dùng bộ gõ của macOS) | ✅ |

¹ Android không cho ứng dụng thường bắt chuột/bàn phím toàn hệ thống, nên điện thoại chỉ làm client.
² Từ Android 10, ứng dụng chạy nền không được đọc clipboard. Máy tính → điện thoại luôn hoạt động; điện thoại → máy tính dùng nút *Gửi clipboard*, menu *Chia sẻ → Gửi sang máy tính*, hoặc bật tuỳ chọn tự gửi khi con trỏ rời điện thoại.

## Cài đặt

Bản build sẵn có trong mục **Artifacts** của mỗi lần chạy [GitHub Actions](../../actions) (`one-cursor-macos`, `one-cursor-android`).

### macOS (13 Ventura trở lên)

1. Giải nén `OneCursor-macos.zip`, kéo **OneCursor.app** vào *Applications*. Vì app chưa được notarize, lần đầu hãy **chuột phải → Open**.
2. Mở app (biểu tượng con trỏ trên thanh menu) → **Settings… → Permissions**, cấp quyền **Accessibility** và **Input Monitoring** trong *System Settings → Privacy & Security*.
3. Tab **Screens**: thêm tên màn hình của điện thoại (vd. `pixel-8`) và chọn vị trí (bên phải Mac…).
4. Tab **General**: chọn *Server*, bấm **Start**. Ghi lại fingerprint chứng chỉ để so trên điện thoại.

Tự build: `cd macos && ./scripts/build-app.sh` (cần Xcode 15+ hoặc Command Line Tools với Swift 5.9+). Kết quả ở `macos/dist/`.

Dòng lệnh (có sẵn trong app tại `OneCursor.app/Contents/MacOS/onecursor`):

```sh
onecursor server --right pixel-8                 # điện thoại ở bên phải Mac
onecursor server --config ~/barrier.conf         # dùng lại cấu hình Barrier
onecursor client 192.168.1.20 --name macbook     # Mac được một server Barrier điều khiển
onecursor fingerprint                            # in fingerprint chứng chỉ server
```

### Android (8.0 trở lên; nên dùng 13+)

1. Cài `app-release.apk`.
2. Mở **One Cursor** → **Mở cài đặt trợ năng** → bật **Con trỏ One Cursor**.
3. Chọn server trong danh sách *Server trong mạng này*, hoặc nhập địa chỉ IP của máy server, cổng `24800`, **tên màn hình** (phải trùng tên đã thêm trên server) → **Kết nối**.
4. Lần đầu kết nối TLS, app hiện fingerprint của server — so với fingerprint trên Mac rồi bấm **Tin cậy**.

Tự build: `cd android && ./gradlew assembleRelease` (JDK 17, Android SDK 35).

### Dùng với Barrier / Input Leap có sẵn

- **Server Barrier (Windows/Linux) + điện thoại**: trong cấu hình Barrier, thêm một màn hình tên trùng với tên trên điện thoại và đặt nó cạnh màn hình khác. Nếu Barrier tắt mã hoá (*Enable SSL* bỏ chọn) thì cũng tắt TLS trên điện thoại.
- **Mac làm server cho máy Windows/Linux chạy Barrier client**: thêm tên máy đó vào tab *Screens*. Muốn Cmd+C trên Mac thành Ctrl+C trên Windows, import một `barrier.conf` có dòng `super = ctrl` dưới màn hình Windows.

## Điều khiển điện thoại bằng chuột và bàn phím

| Trên máy tính | Trên Android |
|---|---|
| Nhấp chuột trái | Chạm |
| Giữ chuột trái | Nhấn giữ |
| Kéo (giữ chuột trái và di) | Vuốt / kéo thả |
| Con lăn | Cuộn (đổi chiều, tốc độ trong cài đặt) |
| Chuột phải / chuột giữa | Quay lại / Màn hình chính (đổi được: gần đây, thông báo, nhấn giữ) |
| Nút phụ chuột (back/forward) | Quay lại / Ứng dụng gần đây |
| Gõ phím | Nhập vào ô đang chọn |
| Cmd/Ctrl + C, X, V, A, Z | Sao chép, cắt, dán, chọn tất cả, hoàn tác |
| Mũi tên, Home/End, Backspace, Delete, Tab, Enter | Như trên máy tính (Android 13+) |
| Esc | Quay lại |
| Cmd/Ctrl + Space | Mở thanh thông báo |
| Phím âm lượng / phát nhạc | Âm lượng / điều khiển nhạc |

Trên Mac: **Control + Option + Command + Esc** luôn đưa con trỏ về Mac.

Phím từ máy tính được gửi ở mức phím thô, nên bộ gõ tiếng Việt của macOS/Windows không tác động lên điện thoại. Bật **Gõ tiếng Việt (Telex)** trong app Android để gõ dấu (`aa`→`â`, `dd`→`đ`, `s f r x j`→ dấu, `z` xoá dấu).

## Giới hạn đã biết

- Android không có con trỏ chuột "thật": không có hiệu ứng hover, và cử chỉ được mô phỏng qua dịch vụ trợ năng.
- Trước Android 13, gõ phím dùng thao tác trợ năng trên ô nhập (không gửi được phím mũi tên ngoài ô nhập, một số app không hỗ trợ).
- Android không làm được server; Android chưa hỗ trợ kéo-thả file.
- macOS: mỗi lần build lại app ký ad-hoc, cần cấp lại quyền Accessibility.

## Cấu trúc mã nguồn

```
android/
  protocol/   Thư viện Kotlin thuần: giao thức Barrier, client, TLS, Telex (+ unit test, build độc lập)
  app/        App Android: dịch vụ trợ năng (con trỏ, cử chỉ, bàn phím), giao diện Compose
macos/
  Sources/OneCursorCore/  Swift thuần: giao thức, cấu hình bố cục, ServerEngine/ClientEngine (+ test)
  Sources/OneCursorMac/   Tích hợp macOS: event tap, chèn sự kiện, Network.framework, TLS, clipboard
  Sources/onecursor/      Công cụ dòng lệnh
  Sources/OneCursorApp/   App thanh menu (SwiftUI)
docs/PROTOCOL.md          Mô tả giao thức
```

Chạy test:

```sh
cd android/protocol && ../gradlew test      # Kotlin: codec, client, clipboard, Telex
cd macos && swift test                      # Swift: codec, cấu hình, logic chuyển màn hình
```

## Ghi chú

Mã nguồn viết mới, không chứa mã của Barrier; chỉ hiện thực lại giao thức mạng công khai của nó để tương thích. Repo chưa có file `LICENSE` — hãy chọn giấy phép trước khi phát hành.
