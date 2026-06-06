import type { CapacitorConfig } from '@capacitor/cli'

const config: CapacitorConfig = {
  appId: 'top.fancytech.sf',
  appName: 'SafeBrowser Parent',
  // webDir holds a fallback bundle shown only if the remote URL is unreachable.
  webDir: 'www',
  server: {
    url: 'https://lovemin.fancytech.top:21000/',
    // Hostnames the WebView may navigate to in-app (hostname only, no scheme/port).
    allowNavigation: ['lovemin.fancytech.top']
  }
}

export default config
