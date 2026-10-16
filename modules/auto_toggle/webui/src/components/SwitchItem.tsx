import { type ReactNode } from 'react'
import ListItem from './ListItem'

interface SwitchItemProps {
  label: string
  description?: string
  selected?: boolean
  disabled?: boolean
  onChange?: (selected: boolean) => void
  leading?: ReactNode
  index?: number
  count?: number
  className?: string
}

export default function SwitchItem({
  label,
  description,
  selected,
  disabled,
  onChange,
  leading,
  index,
  count,
  className,
}: SwitchItemProps) {
  return (
    <ListItem
      leading={leading}
      trailing={<md-switch icons selected={selected} disabled={disabled} style={{ pointerEvents: 'none' }} />}
      onClick={() => onChange?.(!selected)}
      disabled={disabled}
      index={index}
      count={count}
      className={`py-3 ${className || ''}`}
    >
      <div className="flex flex-col min-w-0 py-0.5">
        <span className="truncate text-sm font-medium text-on-surface">{label}</span>
        {description && <span className="text-xs text-outline line-clamp-1">{description}</span>}
      </div>
    </ListItem>
  )
}
