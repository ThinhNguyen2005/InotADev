import { useEffect, useState } from 'react'
import { Cli } from '../lib/Cli'
import { i18n } from '../lib/I18n'

interface HeaderProps {
  onHelpClick: () => void
  onRefreshClick: () => void
}

export default function Header({ onHelpClick, onRefreshClick }: HeaderProps) {
  const [version, setVersion] = useState('v2.1.0')
  const [currentLang, setCurrentLang] = useState(i18n.lang)

  useEffect(() => {
    Cli.loadVersion().then((v) => {
      if (v) setVersion(v)
    })
  }, [])

  const toggleLanguage = () => {
    const nextLang = currentLang === 'vi' ? 'en' : 'vi'
    i18n.loadTranslations(nextLang).then(() => {
      setCurrentLang(nextLang)
    })
  }

  return (
    <div className="w-full flex items-center justify-between h-header shrink-0 px-4 box-border select-none h-16 border-b border-white/5 bg-surface">
      <div className="flex flex-col justify-center">
        <div className="text-lg font-bold flex flex-row items-center gap-2 text-on-surface">
          AutoToggle ADB
          {version && (
            <span className="text-xs px-2 py-0.5 rounded-full bg-primary/10 text-primary border border-primary/20 font-mono">
              {version}
            </span>
          )}
        </div>
        <span className="text-xs text-outline font-medium">Rust Daemon · KernelSU Next</span>
      </div>

      <div className="flex items-center gap-1">
        <button
          onClick={toggleLanguage}
          className="px-2.5 py-1 text-xs font-bold rounded-lg border border-outline/30 bg-surface-container text-on-surface hover:bg-surface-container-high transition-colors"
          title={i18n.t('language', 'Language')}
        >
          {currentLang.toUpperCase()}
        </button>

        <md-icon-button onClick={onRefreshClick} title={i18n.t('refresh', 'Refresh')}>
          <md-icon>
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" className="fill-current w-5 h-5">
              <path d="M17.65 6.35C16.2 4.9 14.21 4 12 4c-4.42 0-7.99 3.58-7.99 8s3.57 8 7.99 8c3.73 0 6.84-2.55 7.73-6h-2.08c-.82 2.33-3.04 4-5.65 4-3.31 0-6-2.69-6-6s2.69-6 6-6c1.66 0 3.14.69 4.22 1.78L13 11h7V4l-2.35 2.35z"/>
            </svg>
          </md-icon>
        </md-icon-button>

        <md-icon-button onClick={onHelpClick} title={i18n.t('help', 'Help')}>
          <md-icon>
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" className="fill-current w-5 h-5">
              <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm1 15h-2v-6h2v6zm0-8h-2V7h2v2z"/>
            </svg>
          </md-icon>
        </md-icon-button>
      </div>
    </div>
  )
}
