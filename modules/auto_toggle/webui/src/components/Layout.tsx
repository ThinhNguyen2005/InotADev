import type { ReactNode } from 'react'

interface LayoutProps {
  header: ReactNode
  children: ReactNode
}

export default function Layout({ header, children }: LayoutProps) {
  return (
    <>
      <div className='pt-safe' />
      {header}
      <section
        className='w-full flex-1 min-h-0 flex flex-col overflow-y-auto overflow-x-hidden'
        style={{ paddingBottom: 'calc(16px + var(--bottom-inset, 0px))' }}
      >
        <main className="w-full max-w-full px-3 sm:px-4 box-border flex flex-col flex-1 min-h-0 gap-2 landscape:flex-row items-center landscape:items-stretch landscape:justify-center overflow-x-hidden">
          {children}
        </main>
      </section>
    </>
  )
}
