# Ốp Mực – app gửi ảnh lên ốp lưng mực điện tử NFC

App iPhone tự làm cho ốp lưng e-ink nội địa Trung (3,97 inch, 480×800, 4 màu, NFC thụ động, iPhone 12–16).

## Tính năng
- **Ảnh**: chọn ảnh, kéo/chụm để cắt theo khung ốp (tỉ lệ 3:5), chỉnh sáng/tương phản/độ đậm màu, chế độ *Ảnh chụp* (chấm trộn màu) hoặc *Tranh / chữ* (màu khối), xem trước đúng 4 màu mực (đen, trắng, vàng, đỏ), rồi **Gửi lên ốp**.
- **Ảnh thử 4 màu**: để kiểm tra chiều và thứ tự màu.
- **Kiểm tra**: đọc thông tin ốp, gửi lệnh APDU thủ công, xem/sao chép nhật ký.
- **Cài đặt**: kích thước, số màu, xoay 180°, lật gương, đổi chiều bộ nhớ, thứ tự màu.

## Giao thức
ISO 14443-A + APDU ISO 7816, họ màn NFC e-paper Good Display / FMSC (tài liệu mở của niw, MIT):
xác thực `00 20 00 01 04 20 09 12 10` → đọc thông tin `00 D1 00 00 00` → dữ liệu ảnh `F0 D3` (khối 2000 byte, nén LZO1X-1, mảnh 250 byte) → làm mới `F0 D4 85 00 00`.
iOS giới hạn mỗi lần kết nối NFC ~20 giây, app tự kết nối lại giữa chừng.

## Build
GitHub Actions (`.github/workflows/build.yml`) tạo `OpMuc-unsigned.ipa` ở mục Releases.

## Ký và cài
- Chứng chỉ / provisioning profile **phải bật quyền NFC Tag Reading** (`com.apple.developer.nfc.readersession.formats = TAG`), nếu không app không mở được NFC.
- Ký bằng zsign (có thể chỉ định file `OpMuc-entitlements.plist` đi kèm) rồi cài bằng Sideloadly.

## Nếu ốp không nhận
Mở tab **Kiểm tra** → **Đọc thông tin ốp** → **Sao chép** nhật ký và gửi lại để chỉnh app cho đúng giao thức của ốp.
