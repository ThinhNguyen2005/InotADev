import { useRef, useCallback, useEffect } from 'react'
import { setupDialogAnimation } from '../../hooks/useDialogAnimation'
import type { MdDialog } from '@material/web/dialog/dialog.js'

interface HelpDialogProps {
  dialogRef: (el: MdDialog | null) => void
  onDismiss?: () => void
}

export default function HelpDialog({ dialogRef, onDismiss }: HelpDialogProps) {
  const localRef = useRef<MdDialog | null>(null)

  useEffect(() => {
    if (localRef.current) setupDialogAnimation(localRef.current)
  }, [])

  const handleDialogClose = useCallback(() => {
    onDismiss?.()
  }, [onDismiss])

  useEffect(() => {
    const el = localRef.current
    if (!el) return
    el.addEventListener('close', handleDialogClose)
    return () => el.removeEventListener('close', handleDialogClose)
  }, [handleDialogClose])

  return (
    <md-dialog
      id="help-dialog"
      ref={el => {
        dialogRef(el as MdDialog | null)
        localRef.current = el as MdDialog | null
      }}
    >
      <div slot="headline">AutoToggle ADB</div>
      <form id="form" slot="content" method="dialog" className="text-sm space-y-4">
        <div>
          <p className="font-bold text-on-surface mb-1">Cơ chế hoạt động (Rust Daemon)</p>
          <p className="text-on-surface-variant text-xs">
            Daemon chạy ngầm bằng ngôn ngữ Rust, bắt các sự kiện uevent từ Kernel Netlink thời gian thực.
            Khi phát hiện máy tính (PC) được cắm vào cổng USB, Daemon tự động kích hoạt ADB.
            Khi rút cáp, ADB được tự động ngắt để bảo vệ thiết bị.
          </p>
        </div>

        <div>
          <p className="font-bold text-on-surface mb-1">Chế độ hoạt động (Mode)</p>
          <ul className="list-disc list-inside text-xs text-on-surface-variant space-y-1">
            <li><strong>Auto:</strong> Bật ADB khi cắm PC, tắt khi rút cáp.</li>
            <li><strong>ON:</strong> Giữ ADB luôn bật thủ công.</li>
            <li><strong>OFF:</strong> Luôn tắt ADB.</li>
          </ul>
        </div>

        <div>
          <p className="font-bold text-on-surface mb-1">Bảo vệ sạc công cộng</p>
          <p className="text-xs text-on-surface-variant">
            Bật tùy chọn <em>&quot;Chỉ bật khi đã mở khóa màn hình&quot;</em> để tránh bị khai thác dữ liệu qua cổng USB khi cắm sạc ở nơi công cộng.
          </p>
        </div>

        <div>
          <p className="font-bold text-on-surface mb-1">Thời gian trễ ngắt (Debounce)</p>
          <p className="text-xs text-on-surface-variant">
            Chống tắt ADB đột ngột khi cổng USB hoặc cáp Type-C bị chập chờn / re-enumerate.
          </p>
        </div>
      </form>
      <div slot="actions">
        <md-text-button onClick={() => localRef.current?.close()}>
          Đóng
        </md-text-button>
      </div>
    </md-dialog>
  )
}
