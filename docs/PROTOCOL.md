# Giao thức mạng (tương thích Barrier 1.6)

One Cursor nói **đúng giao thức của Barrier / Synergy 1.x / Input Leap (phiên bản 1.6)**. Nhờ vậy:

- App Android có thể kết nối tới server **Barrier, Input Leap hoặc Synergy 1** chạy trên Windows/Linux/macOS.
- Server macOS của One Cursor nhận được client **Barrier / Input Leap** trên Windows và Linux.

Tài liệu này tóm tắt những gì hai bản cài đặt (`android/protocol` bằng Kotlin và `macos/Sources/OneCursorCore` bằng Swift) hiện thực. Cả hai có bộ test với cùng các mảng byte mẫu.

## Khung (framing)

Mọi thông điệp — kể cả lời chào — được gửi trong một khung: **độ dài 4 byte big-endian** rồi tới nội dung. Độ dài tối đa 4 MiB.

Trong nội dung, số nguyên là big-endian:

| Ký hiệu | Ý nghĩa |
|---|---|
| `%1i` `%2i` `%4i` | số nguyên 1/2/4 byte (toạ độ, kích thước, delta là số có dấu 16 bit) |
| `%s` | độ dài 4 byte + các byte (UTF-8) |
| `%4I` | số phần tử 4 byte + các số 4 byte |

## Bắt tay

```
server → client   "Barrier" %2i major %2i minor            (Hello, 1.6)
client → server   "Barrier" %2i major %2i minor %s name    (HelloBack)
server → client   QINF                                      (hỏi kích thước màn hình)
server → client   CROP, DSOP %4I                            (reset + đặt tuỳ chọn)
client → server   DINF %2i x y w h warp mx my               (thông tin màn hình)
server → client   CIAK                                      (đã nhận DINF)
```

Client chỉ thoát chế độ bắt tay khi nhận được `DSOP`, nên server luôn gửi `DSOP` (kể cả danh sách rỗng). Tên client phải có trong bố cục của server, nếu không server trả `EUNK`; tên đang được dùng thì trả `EBSY`; phiên bản cũ hơn 1.6 thì `EICV`. Server chấp nhận cả chuỗi chào `"Synergy"`.

## Thông điệp

| Mã | Chiều | Tham số | Ý nghĩa |
|---|---|---|---|
| `CINN` | S→C | `%2i x, %2i y, %4i seq, %2i mods` | con trỏ đi vào màn hình client |
| `COUT` | S→C | | con trỏ rời màn hình client |
| `CALV` | S↔C | | keep-alive; client trả lời lại `CALV`. Mặc định 3 s, ngắt sau 3 lần lỡ |
| `CNOP` | | | không làm gì |
| `CBYE` | S→C | | đóng kết nối |
| `CCLP` | S↔C | `%1i id, %4i seq` | màn hình vừa chiếm clipboard |
| `DCLP` | S↔C | `%1i id, %4i seq, %1i mark, %s data` | dữ liệu clipboard (xem bên dưới) |
| `DMMV` | S→C | `%2i x, %2i y` | di chuột (toạ độ tuyệt đối của client) |
| `DMRM` | S→C | `%2i dx, %2i dy` | di chuột tương đối (tuỳ chọn `relativeMouseMoves`) |
| `DMDN`/`DMUP` | S→C | `%1i button` | 1 trái, 2 giữa, 3 phải, 4/5 nút phụ |
| `DMWM` | S→C | `%2i dx, %2i dy` | cuộn; +120 = một nấc lên/phải |
| `DKDN`/`DKUP` | S→C | `%2i keyID, %2i mods, %2i button` | phím xuống/lên |
| `DKRP` | S→C | `%2i keyID, %2i mods, %2i count, %2i button` | phím lặp |
| `DSOP` | S→C | `%4I` cặp (option, value) | tuỳ chọn, vd. `MMFR=2` (Super→Ctrl), `HART` (chu kỳ keep-alive, ms) |
| `QINF`/`DINF`/`CIAK` | | | kích thước màn hình (xem bắt tay); client gửi lại `DINF` khi xoay màn hình |
| `EICV` `EBSY` `EUNK` `EBAD` | S→C | | lỗi |

`keyID` là mã Unicode cho ký tự in được và vùng `0xE000–0xEFFF` cho phím đặc biệt (keysym X11 với `0xFF00` dời về `0xEF00`, ví dụ Backspace `0xEF08`, Enter `0xEF0D`, mũi tên `0xEF51–0xEF54`). `mods`: Shift `0x01`, Ctrl `0x02`, Alt `0x04`, Meta `0x08`, Super `0x10` (phím Command trên Mac), AltGr `0x20`, CapsLock `0x1000`. `button` là mã phím vật lý bên server, dùng để ghép phím xuống với phím lên.

## Clipboard

Nội dung clipboard được đóng gói: `%4i số định dạng`, rồi với mỗi định dạng `%4i loại, %4i độ dài, dữ liệu` (0 = văn bản UTF-8 xuống dòng LF, 1 = HTML, 2 = bitmap).

Bản 1.6 gửi theo khối bằng nhiều `DCLP`: `mark = 1` mang tổng độ dài dạng chuỗi thập phân, `mark = 2` mang từng khối tối đa 32 KiB, `mark = 3` kết thúc (rỗng). Client phải dùng `seq` của lần `CINN` gần nhất khi gửi `CCLP`/`DCLP`; server luôn dùng 0.

## TLS

Barrier và Input Leap mặc định bọc kết nối bằng TLS với chứng chỉ tự ký. Không có CA: client **ghim fingerprint** của chứng chỉ (lần đầu kết nối người dùng xác nhận fingerprint hiển thị trên server). One Cursor hiển thị fingerprint SHA-256 (và SHA-1 trong `onecursor fingerprint`) để so với Barrier.

## Bonjour (riêng One Cursor)

Server macOS quảng bá `_onecursor._tcp` với bản ghi TXT `tls=1|0`, để app Android tự tìm thấy. Server Barrier không quảng bá dịch vụ này — hãy nhập địa chỉ thủ công.
