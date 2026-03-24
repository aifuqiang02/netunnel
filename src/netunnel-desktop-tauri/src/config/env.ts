const DEFAULT_HOME_URL = import.meta.env.VITE_DEFAULT_HOME_URL?.trim() || 'http://127.0.0.1:40061'
const DEFAULT_BRIDGE_ADDR = import.meta.env.VITE_DEFAULT_BRIDGE_ADDR?.trim() || '127.0.0.1:40062'
const WECHAT_LOGIN_BASE_URL =
  import.meta.env.VITE_WECHAT_LOGIN_BASE_URL?.trim() ||
  'https://open.tx07.cn/api/v1/apps/app_mmzvo9v9e89cc5bbda9611551902/wechat-login'
const DEFAULT_LOGIN_USERNAME = import.meta.env.VITE_DEFAULT_LOGIN_USERNAME?.trim() || 'admin@netunnel.local'

export const runtimeEnv = {
  defaultHomeUrl: DEFAULT_HOME_URL,
  defaultBridgeAddr: DEFAULT_BRIDGE_ADDR,
  wechatLoginBaseUrl: WECHAT_LOGIN_BASE_URL,
  defaultLoginUsername: DEFAULT_LOGIN_USERNAME,
} as const
