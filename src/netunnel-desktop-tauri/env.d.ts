/// <reference types="vite/client" />

interface ImportMetaEnv {
  /**
   * Automatically read from package.json version field
   */
  readonly VITE_APP_VERSION: string
  readonly VITE_APP_BUILD_EPOCH?: string
  readonly VITE_DEFAULT_HOME_URL?: string
  readonly VITE_DEFAULT_BRIDGE_ADDR?: string
  readonly VITE_WECHAT_LOGIN_BASE_URL?: string
  readonly VITE_DEFAULT_LOGIN_USERNAME?: string
}
interface ImportMeta {
  readonly env: ImportMetaEnv
}
