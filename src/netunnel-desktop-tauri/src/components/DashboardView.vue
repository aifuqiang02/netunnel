<script setup lang="ts">
import { ElMessage } from 'element-plus'
import QRCode from 'qrcode'
import NetunnelWorkspace from '@/components/NetunnelWorkspace.vue'
import { runtimeEnv } from '@/config/env'
import SettingsPanel from '@/components/SettingsPanel.vue'
import { createApiClient } from '@/services/api'
import { fetchDashboardSummary } from '@/services/dashboard'
import { fetchBillingProfile, fetchPricingRules, fetchBusinessRecords } from '@/services/billing'
import { createPaymentOrder, pollPaymentOrder, type PaymentOrderSnapshot } from '@/services/payments'
import { fetchUserProfile } from '@/services/users'
import { useWindowControls } from '@/composables/useWindowControls'
import { log } from '@/services/logger'
import { computed, onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { invoke, isTauri } from '@tauri-apps/api/core'
import type { BillingProfile, PricingRule, UserBusinessRecord } from '@/types/netunnel'

const store = useStore()
const workspaceRef = ref<InstanceType<typeof NetunnelWorkspace> | null>(null)
const rechargeDialogVisible = ref(false)
const businessRecordsDialogVisible = ref(false)
const paymentDialogVisible = ref(false)
const billingLoading = ref(false)
const businessRecordsLoading = ref(false)
const pricingRules = ref<PricingRule[]>([])
const billingProfile = ref<BillingProfile | null>(null)
const businessRecords = ref<UserBusinessRecord[]>([])
const businessRecordsPage = ref(1)
const businessRecordsPageSize = ref(10)
const trafficRechargeOptions = [2, 10, 20] as const
const DYNAMIC_PAYMENT_PRODUCT_ID = 'cmn1vuv3k008p5cdwku0vbvmc'
const PAYMENT_POLL_INTERVAL_MS = 2500
const TRAFFIC_PRICE_PER_GB_CENTS = 50
const workspaceStorageKey = 'netunnel-desktop-tauri-workspace'
const lastLoginStorageKey = 'netunnel-desktop-tauri-last-login-map'
const localAgentState = ref({
  running: false,
  executablePath: '',
  pid: null as number | null,
  lastExit: '',
  registeredAgentId: '',
})
const userLastLoginAt = ref('')
let agentStatusTimer: number | null = null
let paymentPollTimer: ReturnType<typeof setInterval> | null = null

const { isWindowMaximized, minimizeWindow, toggleMaximizeWindow, closeWindow, startDraggingWindow } = useWindowControls()

const getSessionIconClass = (icon: string) => `i-mdi-${icon}`

const currentQuotaBytes = computed(() => {
  if (!billingProfile.value) return 0
  if (billingProfile.value.pricing_rule.is_unlimited) return 0
  return billingProfile.value.pricing_rule.included_traffic_bytes
})

const trafficUsageLabel = computed(() => {
  if (!store.summary) {
    return '--'
  }
  if (!billingProfile.value) {
    return formatBytes(store.summary.recentTrafficBytes)
  }
  if (billingProfile.value.pricing_rule.is_unlimited) {
    return `${formatBytes(store.summary.recentTrafficBytes)} / 不限量`
  }
  if (billingProfile.value.pricing_rule.included_traffic_bytes > 0) {
    return `${formatBytes(store.summary.recentTrafficBytes)} / ${formatBytes(billingProfile.value.pricing_rule.included_traffic_bytes)}`
  }
  return `${formatBytes(store.summary.recentTrafficBytes)} / 按量计费`
})

const trafficUsagePercent = computed(() => {
  if (!store.summary || !billingProfile.value) return 0
  const quotaBytes = billingProfile.value.pricing_rule.included_traffic_bytes
  if (billingProfile.value.pricing_rule.is_unlimited || quotaBytes <= 0) {
    return 100
  }
  return Math.min((store.summary.recentTrafficBytes / quotaBytes) * 100, 100)
})

const agentStatusDotClass = computed(() => (localAgentState.value.running ? 'bg-green-500' : 'bg-red-500'))

const agentStatusTooltip = computed(() => {
  const lines = [localAgentState.value.running ? '本地 agent 运行中' : '本地 agent 未运行']

  if (localAgentState.value.executablePath) {
    lines.push(`可执行文件: ${localAgentState.value.executablePath}`)
  }
  if (localAgentState.value.pid !== null) {
    lines.push(`PID: ${localAgentState.value.pid}`)
  }
  if (localAgentState.value.registeredAgentId) {
    lines.push(`已注册 Agent ID: ${localAgentState.value.registeredAgentId}`)
    if (localAgentState.value.running) {
      lines.push(`本地 agent 运行中，已完成补偿注册：${localAgentState.value.registeredAgentId}`)
    }
  }
  if (localAgentState.value.lastExit) {
    lines.push(`最近退出: ${localAgentState.value.lastExit}`)
  }

  return lines.join('\n')
})

interface FixedPricingPlan {
  key: 'traffic' | 'month' | 'year'
  title: string
  description: string
  priceLabel: string
  actionLabel: string
  rule?: PricingRule
  current: boolean
}

interface TrafficRechargeOption {
  gb: (typeof trafficRechargeOptions)[number]
  amountCent: number
  amountLabel: string
}

const monthlyPricingRule = computed(() =>
  pricingRules.value.find(
    (rule) => rule.billing_mode === 'subscription' && rule.subscription_period === 'month' && rule.is_unlimited,
  ),
)

const yearlyPricingRule = computed(() =>
  pricingRules.value.find(
    (rule) => rule.billing_mode === 'subscription' && rule.subscription_period === 'year' && rule.is_unlimited,
  ),
)

const trafficPricingRule = computed(() =>
  pricingRules.value.find((rule) => rule.billing_mode === 'traffic') ??
  pricingRules.value.find((rule) => rule.name === 'default-traffic'),
)
const trafficRechargePlanOptions = computed<TrafficRechargeOption[]>(() =>
  trafficRechargeOptions.map((gb) => ({
    gb,
    amountCent: gb * TRAFFIC_PRICE_PER_GB_CENTS,
    amountLabel: formatPaymentAmount(gb * TRAFFIC_PRICE_PER_GB_CENTS),
  })),
)
const paymentQRCodeDataUrl = ref('')
const paymentSnapshot = ref<PaymentOrderSnapshot | null>(null)
const paymentStatus = ref<'idle' | 'pending' | 'paid' | 'expired' | 'closed' | 'error'>('idle')
const paymentMessage = ref('请选择套餐并发起支付')

const fixedPricingPlans = computed<FixedPricingPlan[]>(() => [
  {
    key: 'traffic',
    title: '按流量充值',
    description: '按 0.5 元 / GB 计费，可直接购买 2GB、10GB、20GB 流量包。',
    priceLabel: '0.5 元 / GB',
    actionLabel: '快捷充值',
    current: billingProfile.value?.pricing_rule.billing_mode === 'traffic',
  },
  {
    key: 'month',
    title: '不限量包月',
    description: monthlyPricingRule.value?.description || '不限量包月套餐，固定 5 元。未到期续费，将会延长到期时间。',
    priceLabel: monthlyPricingRule.value ? `${formatPricingAmount(monthlyPricingRule.value.subscription_price)} / 月` : '--',
    actionLabel: monthlyPricingRule.value ? '续费购买' : '暂不可用',
    rule: monthlyPricingRule.value,
    current: billingProfile.value?.pricing_rule.id === monthlyPricingRule.value?.id,
  },
  {
    key: 'year',
    title: '不限量包年',
    description: yearlyPricingRule.value?.description || '不限量包年套餐，固定 40 元。未到期续费，将会延长到期时间。',
    priceLabel: yearlyPricingRule.value ? `${formatPricingAmount(yearlyPricingRule.value.subscription_price)} / 年` : '--',
    actionLabel: yearlyPricingRule.value ? '续费购买' : '暂不可用',
    rule: yearlyPricingRule.value,
    current: billingProfile.value?.pricing_rule.id === yearlyPricingRule.value?.id,
  },
])

const trafficPlan = computed(() => fixedPricingPlans.value.find((plan) => plan.key === 'traffic'))
const monthlyPlan = computed(() => fixedPricingPlans.value.find((plan) => plan.key === 'month'))
const yearlyPlan = computed(() => fixedPricingPlans.value.find((plan) => plan.key === 'year'))

function planFeatureList(planKey: FixedPricingPlan['key']) {
  switch (planKey) {
    case 'traffic':
      return ['灵活充值，按需购买', '已购流量长期有效']
    case 'month':
      return ['全球高速节点任意切换', '无限流量使用不限速']
    case 'year':
      return ['包含全部包月权益', '365 天稳定可用']
    default:
      return []
  }
}

function planActionText(plan?: FixedPricingPlan) {
  if (!plan?.rule) {
    return '暂不可用'
  }
  return plan.current ? '续费购买' : plan.actionLabel
}

const handleHeaderMouseDown = (event: MouseEvent) => {
  const target = event.target as HTMLElement | null
  if (!target || target.closest('button, input, textarea, select, a')) {
    return
  }

  void startDraggingWindow()
}

async function loadSummary() {
  log('INFO', `loadSummary called, userId=${store.session.userId}, accessToken=${store.session.accessToken ? 'exists' : 'missing'}, baseUrl=${store.session.baseUrl}`)
  if (!store.session.userId || !store.session.accessToken) {
    log('WARN', 'loadSummary skipped: userId or accessToken is empty')
    return
  }
  try {
    log('INFO', `fetchDashboardSummary start, baseUrl=${store.session.baseUrl}`)
    const client = createApiClient({ baseUrl: store.session.baseUrl, accessToken: store.session.accessToken })
    const res = await fetchDashboardSummary(client, store.session.userId)
    log('INFO', `fetchDashboardSummary success: ${JSON.stringify(res.summary)}`)
    store.summary = {
      totalUsers: res.summary.total_users,
      onlineUsers: res.summary.online_users,
      onlineAgents: res.summary.online_agents,
      totalAgents: res.summary.total_agents,
      enabledTunnels: res.summary.enabled_tunnels,
      totalTunnels: res.summary.total_tunnels,
      recentTrafficBytes: res.summary.recent_traffic_bytes_24h,
    }
  } catch (e) {
    log('ERROR', `fetchDashboardSummary failed: ${e}`)
  }
}

async function autoStartAgent() {
  if (!store.session.userId || !store.session.accessToken) {
    log('WARN', 'autoStartAgent skipped: not logged in yet')
    return
  }

  type NativeAgentStatus = {
    running: boolean
    executablePath?: string
    arguments?: string[]
    pid?: number | null
    lastExit?: string | null
  }

  async function launchAgent(machineCode: string) {
    const serverUrl = store.session.baseUrl || store.settings.homeUrl || runtimeEnv.defaultHomeUrl
    const bridgeAddr = store.settings.bridgeAddr || runtimeEnv.defaultBridgeAddr
    const userId = store.session.userId
    const executablePath = store.settings.agentExecutablePath?.trim() || undefined
    const args = [
      '-server-url', serverUrl,
      '-bridge-addr', bridgeAddr,
      '-user-id', userId,
      '-agent-name', 'desktop-agent',
      '-machine-code', machineCode,
      '-client-version', '0.1.0',
      '-os-type', 'windows',
      '-sync-interval', '10',
    ]
    log('INFO', `autoStartAgent: starting agent with args: ${JSON.stringify(args)}`)
    await invoke('start_local_agent', {
      input: {
        executablePath,
        arguments: args,
      },
    })
  }

  try {
    log('INFO', 'autoStartAgent: checking agent status')
    const status = await invoke<NativeAgentStatus>('agent_status')
    if (status.running) {
      log('INFO', 'autoStartAgent: agent already running')
      return
    }
  } catch {
    log('WARN', 'autoStartAgent: could not check status, trying to start')
  }

  try {
    const machineCode = await invoke<string>('get_or_create_agent_id')
    await launchAgent(machineCode)
    log('INFO', 'autoStartAgent: agent started successfully')
  } catch (e) {
    log('ERROR', `autoStartAgent failed: ${e}`)
  }
}

function readWorkspaceAgentId() {
  if (typeof window === 'undefined') {
    return ''
  }

  try {
    const raw = window.localStorage.getItem(workspaceStorageKey)
    if (!raw) {
      return ''
    }
    const parsed = JSON.parse(raw) as { registeredAgentId?: string }
    return parsed.registeredAgentId ?? ''
  } catch {
    return ''
  }
}

function getTodayKey(date: Date) {
  const year = date.getFullYear()
  const month = String(date.getMonth() + 1).padStart(2, '0')
  const day = String(date.getDate()).padStart(2, '0')
  return `${year}-${month}-${day}`
}

function readLastLoginMap(): Record<string, string> {
  if (typeof window === 'undefined') {
    return {}
  }
  try {
    const raw = window.localStorage.getItem(lastLoginStorageKey)
    if (!raw) {
      return {}
    }
    const parsed = JSON.parse(raw) as Record<string, string>
    return parsed && typeof parsed === 'object' ? parsed : {}
  } catch {
    return {}
  }
}

function writeLastLoginMap(value: Record<string, string>) {
  if (typeof window === 'undefined') {
    return
  }
  window.localStorage.setItem(lastLoginStorageKey, JSON.stringify(value))
}

function refreshLastLoginDisplay() {
  const userID = store.session.userId?.trim()
  if (!userID) {
    userLastLoginAt.value = ''
    return
  }
  const loginMap = readLastLoginMap()
  userLastLoginAt.value = loginMap[userID] ?? ''
}

function recordDailyLastLogin() {
  const userID = store.session.userId?.trim()
  if (!userID || typeof window === 'undefined') {
    userLastLoginAt.value = ''
    return
  }

  const loginMap = readLastLoginMap()
  const now = new Date()
  const existing = loginMap[userID]
  if (existing) {
    const parsed = new Date(existing)
    if (!Number.isNaN(parsed.getTime()) && getTodayKey(parsed) === getTodayKey(now)) {
      userLastLoginAt.value = existing
      return
    }
  }

  const nextValue = now.toISOString()
  loginMap[userID] = nextValue
  writeLastLoginMap(loginMap)
  userLastLoginAt.value = nextValue
}

async function refreshLocalAgentStatus() {
  localAgentState.value.registeredAgentId = readWorkspaceAgentId()

  if (!isTauri()) {
    localAgentState.value.running = false
    localAgentState.value.executablePath = ''
    localAgentState.value.pid = null
    localAgentState.value.lastExit = ''
    return
  }

  try {
    const status = await invoke<{
      running: boolean
      executablePath?: string
      pid?: number | null
      lastExit?: string | null
    }>('agent_status')

    localAgentState.value.running = status.running
    localAgentState.value.executablePath = status.executablePath ?? ''
    localAgentState.value.pid = status.pid ?? null
    localAgentState.value.lastExit = status.lastExit ?? ''
  } catch (error) {
    localAgentState.value.running = false
    localAgentState.value.pid = null
    localAgentState.value.lastExit = String(error)
  }
}

function createBillingClient() {
  return createApiClient({ baseUrl: store.session.baseUrl, accessToken: store.session.accessToken })
}

async function loadBillingProfile() {
  if (!store.session.userId || !store.session.accessToken) {
    return
  }
  try {
    const profile = await fetchBillingProfile(createBillingClient(), store.session.userId)
    billingProfile.value = profile
    store.user.plan = formatPricingRuleLabel(profile.pricing_rule)
  } catch (error) {
    log('ERROR', `fetchBillingProfile failed: ${error}`)
  }
}

async function loadUserProfile() {
  if (!store.session.userId || !store.session.accessToken) {
    return
  }
  try {
    const profile = await fetchUserProfile(createBillingClient(), store.session.userId)
    store.user.name = profile.user.nickname || store.user.name
    store.user.avatarUrl = profile.user.avatar_url || ''
    if (profile.user.email) {
      store.user.email = profile.user.email
    }
  } catch (error) {
    log('ERROR', `fetchUserProfile failed: ${error}`)
  }
}

async function loadPricingPlans() {
  const response = await fetchPricingRules(createBillingClient())
  pricingRules.value = response.pricing_rules
}

function formatBusinessRecordType(recordType: string) {
  switch (recordType) {
    case 'traffic_recharge':
      return '流量充值'
    case 'subscription_purchase':
      return '套餐购买'
    case 'subscription_renew':
      return '套餐续费'
    case 'subscription_traffic_settlement':
      return '套餐内流量'
    case 'traffic_settlement':
      return '流量扣减'
    default:
      return recordType || '--'
  }
}

function isLegacyIncludedTrafficRecord(row: UserBusinessRecord) {
  return row.record_type === 'traffic_settlement' && Number(row.change_amount) === 0
}

function formatTrafficValue(bytes?: number) {
  if (!bytes) {
    return '--'
  }
  return formatTrafficAmount(bytes)
}

function formatTrafficBalance(value?: string | number) {
  if (value === undefined || value === null || value === '') {
    return '--'
  }
  const bytes = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(bytes)) {
    return String(value)
  }
  return formatTrafficAmount(bytes)
}

function formatDateTime(value?: string) {
  if (!value) {
    return '--'
  }
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) {
    return value
  }
  return parsed.toLocaleString('zh-CN', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  })
}

async function openRechargeDialog() {
  if (!store.session.userId || !store.session.accessToken) {
    return
  }
  billingLoading.value = true
  try {
    await Promise.all([loadBillingProfile(), loadPricingPlans()])
    rechargeDialogVisible.value = true
  } finally {
    billingLoading.value = false
  }
}

async function openBusinessRecordsDialog() {
  if (!store.session.userId || !store.session.accessToken) {
    return
  }
  businessRecordsLoading.value = true
  try {
    const response = await fetchBusinessRecords(createBillingClient(), store.session.userId, 100)
    businessRecords.value = response.business_records
    businessRecordsPage.value = 1
    businessRecordsDialogVisible.value = true
  } catch (error) {
    ElMessage.error(String(error))
  } finally {
    businessRecordsLoading.value = false
  }
}

function stopPaymentPolling() {
  if (!paymentPollTimer) {
    return
  }
  clearInterval(paymentPollTimer)
  paymentPollTimer = null
}

async function renderPaymentQRCode(url: string) {
  paymentQRCodeDataUrl.value = await QRCode.toDataURL(url, {
    width: 220,
    margin: 1,
  })
}

function closePaymentDialog() {
  stopPaymentPolling()
  paymentDialogVisible.value = false
}

function formatPaymentAmount(amount?: number) {
  if (typeof amount !== 'number' || Number.isNaN(amount)) {
    return '--'
  }
  return `¥${(amount / 100).toFixed(2)}`
}

function paymentStatusLabel(status: typeof paymentStatus.value) {
  switch (status) {
    case 'pending':
      return '待支付'
    case 'paid':
      return '支付成功'
    case 'expired':
      return '已过期'
    case 'closed':
      return '已关闭'
    case 'error':
      return '异常'
    default:
      return '未开始'
  }
}

async function syncPaymentStatus(bizId: string, options?: { silent?: boolean }) {
  const snapshot = await pollPaymentOrder(createBillingClient(), bizId)
  paymentSnapshot.value = snapshot

  const sessionStatus = snapshot.session?.status ?? snapshot.order.platform_status
  paymentStatus.value = (sessionStatus as typeof paymentStatus.value) || 'pending'

  if (sessionStatus === 'paid') {
    if (snapshot.applied) {
      paymentMessage.value = '支付成功，套餐已生效。'
      stopPaymentPolling()
      await Promise.all([loadBillingProfile(), loadSummary(), loadPricingPlans()])
      ElMessage.success('支付成功')
      return
    }
    paymentMessage.value = snapshot.applyError || '支付成功，正在同步业务订单...'
    return
  }

  if (sessionStatus === 'expired') {
    paymentMessage.value = '二维码已过期，请重新发起支付。'
    stopPaymentPolling()
    return
  }

  if (sessionStatus === 'closed') {
    paymentMessage.value = '支付已关闭，请重新发起支付。'
    stopPaymentPolling()
    return
  }

  paymentMessage.value = '请使用微信扫码完成支付。'
  if (!options?.silent && snapshot.applyError) {
    ElMessage.warning(snapshot.applyError)
  }
}

async function startPaymentFlow(payload: {
  order_type: 'traffic_recharge' | 'pricing_rule'
  payment_product_id: string
  amount: number
  pricing_rule_id?: string
  recharge_gb?: number
}) {
  if (!store.session.userId) return

  billingLoading.value = true
  try {
    paymentSnapshot.value = null
    paymentQRCodeDataUrl.value = ''
    paymentStatus.value = 'pending'
    paymentMessage.value = '正在创建支付订单...'

    const snapshot = await createPaymentOrder(createBillingClient(), {
      user_id: store.session.userId,
      ...payload,
    })
    paymentSnapshot.value = snapshot
    rechargeDialogVisible.value = false
    paymentDialogVisible.value = true
    paymentStatus.value = snapshot.session?.status ?? 'pending'
    paymentMessage.value = '请使用微信扫码完成支付。'

    const qrSource = snapshot.session?.qrCodeUrl || snapshot.session?.checkoutUrl
    if (!qrSource) {
      throw new Error('支付二维码生成失败')
    }
    await renderPaymentQRCode(qrSource)

    stopPaymentPolling()
    paymentPollTimer = setInterval(() => {
      void syncPaymentStatus(snapshot.order.biz_id, { silent: true }).catch((error) => {
        paymentStatus.value = 'error'
        paymentMessage.value = String(error)
        stopPaymentPolling()
      })
    }, PAYMENT_POLL_INTERVAL_MS)
  } catch (error) {
    paymentStatus.value = 'error'
    paymentMessage.value = String(error)
    ElMessage.error(String(error))
  } finally {
    billingLoading.value = false
  }
}

async function purchaseTrafficPlan(amountGb: (typeof trafficRechargeOptions)[number]) {
  await startPaymentFlow({
    order_type: 'traffic_recharge',
    payment_product_id: DYNAMIC_PAYMENT_PRODUCT_ID,
    amount: amountGb * TRAFFIC_PRICE_PER_GB_CENTS,
    recharge_gb: amountGb,
  })
}

async function purchasePricingRule(rule?: PricingRule) {
  if (!rule) {
    ElMessage.warning('当前没有可购买的套餐，请稍后再试')
    return
  }

  await startPaymentFlow({
    order_type: 'pricing_rule',
    payment_product_id: DYNAMIC_PAYMENT_PRODUCT_ID,
    amount: Math.round(Number(rule.subscription_price) * 100),
    pricing_rule_id: rule.id,
  })
}

function formatBytes(bytes: number) {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`
}

function formatIntegerAmount(amount: string | number) {
  const numericAmount = typeof amount === 'number' ? amount : Number(amount)
  if (!Number.isFinite(numericAmount)) {
    return String(amount)
  }
  return `${Math.round(numericAmount)}`
}

function formatPricingAmount(amount: string | number) {
  return `${formatIntegerAmount(amount)} 元`
}

function formatTrafficAmount(bytes: number) {
  if (bytes <= 0) {
    return '0 B'
  }
  if (bytes < 1024) {
    return `${bytes} B`
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / 1024 / 1024).toFixed(2)} MB`
  }
  return `${(bytes / 1024 / 1024 / 1024).toFixed(3)} GB`
}

const remainingTrafficLabel = computed(() => {
  if (!billingProfile.value) {
    return '--'
  }

  return formatTrafficBalance(billingProfile.value.account.balance)
})

const expiryLabel = computed(() => {
  if (!billingProfile.value) {
    return '--'
  }

  const expiresAt = billingProfile.value.subscription?.expires_at
  if (!expiresAt) {
    return '--'
  }

  const parsed = new Date(expiresAt)
  if (Number.isNaN(parsed.getTime())) {
    return expiresAt
  }
  return parsed.toLocaleString('zh-CN', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  })
})

const pagedBusinessRecords = computed(() => {
  const start = (businessRecordsPage.value - 1) * businessRecordsPageSize.value
  return businessRecords.value.slice(start, start + businessRecordsPageSize.value)
})

function formatPricingRuleLabel(rule: PricingRule) {
  if (rule.display_name) {
    return rule.display_name
  }
  if (rule.billing_mode === 'traffic') {
    return `按量 ${rule.price_per_gb}/GB`
  }
  const periodLabel = rule.subscription_period === 'year' ? '包年' : '包月'
  if (rule.is_unlimited) {
    return `${periodLabel} 不限量`
  }
  return `${periodLabel} ${formatBytes(rule.included_traffic_bytes)}`
}

onMounted(() => {
  log('INFO', 'DashboardView mounted')
  recordDailyLastLogin()
  void loadSummary()
  void loadBillingProfile()
  void loadUserProfile()
  void autoStartAgent()
  void refreshLocalAgentStatus()
  agentStatusTimer = window.setInterval(() => {
    void refreshLocalAgentStatus()
  }, 10000)
})

onBeforeUnmount(() => {
  if (agentStatusTimer !== null) {
    window.clearInterval(agentStatusTimer)
    agentStatusTimer = null
  }
  stopPaymentPolling()
})

watch(
  () => store.session.userId,
  () => {
    recordDailyLastLogin()
    refreshLastLoginDisplay()
  },
)
</script>

<template>
  <div class="dashboard-shell">
    <aside class="dashboard-sidebar dashboard-sidebar--compact dashboard-sidebar--design">
      <div class="dashboard-brand">
        <div class="dashboard-brand__icon">
          <img src="/logo.png" alt="Netunnel logo" class="dashboard-brand__logo" />
        </div>
        <h1 class="dashboard-brand__title">Netunnel Desktop</h1>
      </div>

      <div class="flex-1 overflow-auto px-2">
        <div class="space-y-3 py-2">
          <div class="rounded-xl border border-[var(--line)] bg-[var(--surface)] p-4">
            <p class="text-xs text-[var(--text-muted)]">
              <span v-if="store.summary">所有用户：{{ store.summary.totalUsers }}</span>
              <span v-else>所有用户：--</span>
            </p>
            <p class="mt-2 text-xs text-[var(--text-soft)]">
              <span v-if="store.summary">今日活跃用户：{{ store.summary.onlineUsers }}</span>
              <span v-else>今日活跃用户：--</span>
            </p>
          </div>

          <div class="rounded-xl border border-[var(--line)] bg-[var(--surface)] p-4">
            <div class="flex items-center justify-between gap-3">
              <p class="text-xs text-[var(--text-muted)]">剩余流量</p>
              <button
                class="text-xs font-medium text-sky-600 transition-colors hover:text-sky-500"
                type="button"
                @click="openBusinessRecordsDialog"
              >
                明细
              </button>
            </div>
            <p class="mt-1 text-xl font-bold">
              {{ remainingTrafficLabel }}
            </p>
            <p class="mt-2 text-xs text-[var(--text-soft)]">
              不限额到期时间：{{ expiryLabel }}
            </p>
            <p class="mt-1 text-xs text-[var(--text-soft)]">
              套餐有效期内优先使用套餐，不扣减剩余流量余额。
            </p>
          </div>

          <button class="w-full rounded-xl bg-[var(--brand)] py-3 text-sm font-semibold text-white shadow-lg transition-all hover:opacity-90 active:scale-[0.98]" type="button" @click="openRechargeDialog">
            充值 / 购买套餐
          </button>

        </div>
      </div>

      <div class="border-t border-[var(--line)]">
        <button class="nav-link nav-link--design" type="button" @click="store.openSettingsModal()">
          <span class="i-mdi-cog-outline"></span>
          <span class="text-sm font-medium">设置</span>
        </button>

        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-3 min-w-0">
            <div class="w-8 h-8 rounded-full bg-[var(--brand-soft)] flex items-center justify-center overflow-hidden text-[var(--brand)]">
              <img v-if="store.user.avatarUrl" :src="store.user.avatarUrl" class="h-full w-full rounded-full object-cover" />
              <span v-else class="i-mdi-account-outline text-sm"></span>
            </div>
            <div class="flex flex-col min-w-0">
              <span class="text-xs font-semibold text-[var(--text-strong)]">{{ store.user.name }}</span>
            </div>
          </div>
          <button class="text-[11px] font-medium text-[var(--text-soft)] hover:text-[var(--brand)] transition-colors" type="button" @click="store.logout()">
            退出
          </button>
        </div>
      </div>
    </aside>

    <main class="dashboard-main dashboard-main--flat overflow-hidden" :class="{ 'is-blurred': store.isSettingsModalOpen }">
      <header class="dashboard-header dashboard-header--flat">
        <div class="dashboard-header__content flex items-center justify-between w-full" @mousedown.left="handleHeaderMouseDown">
          <div class="window-drag-region flex items-center gap-2 ml-4 flex-1 min-w-0" data-tauri-drag-region>
            <div class="flex min-w-0 flex-col">
              <span class="text-xs font-semibold uppercase tracking-[0.14em] text-[var(--text-muted)]">Workspace</span>
              <span class="text-sm font-semibold text-[var(--text-strong)]">{{ store.pageTitle }}</span>
            </div>
          </div>

          <div class="window-controls">
            <button class="window-control-button" type="button" @click="minimizeWindow">
              <span class="i-mdi-window-minimize"></span>
            </button>
            <button class="window-control-button" type="button" @click="toggleMaximizeWindow">
              <span :class="isWindowMaximized ? 'i-mdi-window-restore' : 'i-mdi-checkbox-blank-outline'"></span>
            </button>
            <button class="window-control-button window-control-button--close" type="button" @click="closeWindow">
              <span class="i-mdi-close"></span>
            </button>
          </div>
        </div>
      </header>

      <section
        v-if="store.updater.available && store.updater.promptVisible"
        class="mx-6 mt-4 rounded-3xl border border-emerald-500/20 bg-emerald-500/8 px-5 py-4 text-sm text-[var(--text-strong)]"
      >
        <div class="flex items-start justify-between gap-4">
          <div class="space-y-1">
            <p class="font-semibold text-emerald-600">更新已下载完成 v{{ store.updater.available.version }}</p>
            <p class="text-[var(--text-soft)]">你现在可以直接安装，也可以稍后再处理。</p>
          </div>
          <div class="flex items-center gap-2 shrink-0">
            <button class="nav-link nav-link--design" type="button" @click="store.openSettingsModal()">
              去安装
            </button>
            <button class="text-xs font-medium text-[var(--text-muted)] hover:text-[var(--text-strong)]" type="button" @click="store.dismissUpdatePrompt()">
              稍后
            </button>
          </div>
        </div>
      </section>

      <section class="min-h-0 flex-1 overflow-auto p-6">
        <NetunnelWorkspace ref="workspaceRef" :page="store.currentSession" @refresh-summary="loadSummary" />
      </section>

      <footer class="dashboard-footer dashboard-footer--flat">
        <div class="flex items-center gap-4">
          <el-tooltip placement="top-start">
            <template #content>
              <div class="whitespace-pre-line text-xs leading-6">{{ agentStatusTooltip }}</div>
            </template>
            <span class="flex items-center gap-1">
              <span class="w-2 h-2 rounded-full" :class="agentStatusDotClass"></span>
            </span>
          </el-tooltip>
        </div>
        <div class="flex items-center gap-4">
          <span>版本 {{ store.version }}</span>
          <span>QQ群：307460844</span>
        </div>
      </footer>
    </main>

    <div v-if="store.isSettingsModalOpen" class="modal-overlay" @click.self="store.closeSettingsModal()">
      <SettingsPanel mode="modal" @close="store.closeSettingsModal()" />
    </div>

    <el-dialog v-model="rechargeDialogVisible" title="充值与套餐购买" width="880" class="recharge-dialog" modal-class="recharge-dialog-overlay">
      <div class="recharge-upgrade space-y-4">
        <section class="recharge-upgrade__hero">
          <div class="recharge-upgrade__hero-glow"></div>
          <div class="recharge-upgrade__hero-main">
            <div class="recharge-upgrade__hero-label">
              <span class="i-mdi-database-outline text-lg text-[var(--brand)]"></span>
              <span>当前剩余流量</span>
            </div>
            <div class="recharge-upgrade__hero-value">
              <span class="recharge-upgrade__hero-number">{{ remainingTrafficLabel.replace(/\s*GB$/i, '') }}</span>
              <span class="recharge-upgrade__hero-unit">GB</span>
            </div>
          </div>
          <div class="recharge-upgrade__hero-side">
            <div class="recharge-upgrade__status">
              <span class="recharge-upgrade__status-dot"></span>
              <span>账户状态：正常运行中</span>
            </div>
            <span class="recharge-upgrade__pill recharge-upgrade__pill--side">
              <span class="i-mdi-calendar-check-outline text-sm"></span>
              <span>到期时间：{{ expiryLabel }}</span>
            </span>
          </div>
        </section>

        <section class="space-y-4">
          <div class="flex items-center gap-3">
            <h3 class="text-lg font-semibold text-[var(--text-strong)]">可选购套餐</h3>
            <div class="h-px flex-1 bg-[var(--line)]"></div>
          </div>

          <div class="grid gap-3 md:grid-cols-3">
            <article class="recharge-card recharge-card--traffic">
              <div class="recharge-card__badge recharge-card__badge--traffic">按量付费</div>
              <div class="recharge-card__price-row">
                <span class="recharge-card__price">0.5</span>
                <span class="recharge-card__price-suffix">元 / GB</span>
              </div>
              <p class="recharge-card__description">{{ trafficPlan?.description }}</p>
              <ul class="recharge-card__feature-list">
                <li v-for="feature in planFeatureList('traffic')" :key="feature">{{ feature }}</li>
              </ul>
              <div class="recharge-card__traffic-options">
                <button
                  v-for="option in trafficRechargePlanOptions"
                  :key="option.gb"
                  class="recharge-card__traffic-chip"
                  type="button"
                  :disabled="billingLoading"
                  @click="purchaseTrafficPlan(option.gb)"
                >
                  <span class="recharge-card__traffic-chip-size">{{ option.gb }}GB</span>
                  <span class="recharge-card__traffic-chip-price">{{ option.amountLabel }}</span>
                </button>
              </div>
              <button
                class="recharge-card__action recharge-card__action--ghost"
                type="button"
                :disabled="billingLoading"
                @click="purchaseTrafficPlan(trafficRechargePlanOptions[1]?.gb ?? trafficRechargeOptions[0])"
              >
                选择并支付
                <span class="i-mdi-chevron-right text-lg"></span>
              </button>
            </article>

            <article class="recharge-card recharge-card--featured">
              <div class="recharge-card__corner">HOT</div>
              <div class="recharge-card__badge recharge-card__badge--featured">不限量包月</div>
              <div class="recharge-card__price-row recharge-card__price-row--featured">
                <span class="recharge-card__price recharge-card__price--featured">{{ monthlyPlan?.rule ? formatIntegerAmount(monthlyPlan.rule.subscription_price) : '--' }}</span>
                <span class="recharge-card__price-suffix recharge-card__price-suffix--featured">元 / 月</span>
              </div>
              <p class="recharge-card__description recharge-card__description--strong">{{ monthlyPlan?.description }}</p>
              <ul class="recharge-card__feature-list recharge-card__feature-list--featured">
                <li v-for="feature in planFeatureList('month')" :key="feature">{{ feature }}</li>
              </ul>
              <button
                class="recharge-card__action recharge-card__action--primary"
                type="button"
                :disabled="!monthlyPlan?.rule || billingLoading"
                @click="purchasePricingRule(monthlyPlan?.rule)"
              >
                <span class="i-mdi-flash text-base"></span>
                {{ planActionText(monthlyPlan) }}
              </button>
            </article>

            <article class="recharge-card recharge-card--yearly">
              <div class="flex items-center justify-between gap-3">
                <div class="recharge-card__badge recharge-card__badge--yearly">不限量包年</div>
                <span class="recharge-card__saving">立省 20 元</span>
              </div>
              <div class="recharge-card__price-row">
                <span class="recharge-card__price">{{ yearlyPlan?.rule ? formatIntegerAmount(yearlyPlan.rule.subscription_price) : '--' }}</span>
                <span class="recharge-card__price-suffix">元 / 年</span>
              </div>
              <p class="recharge-card__description">{{ yearlyPlan?.description }}</p>
              <ul class="recharge-card__feature-list">
                <li v-for="feature in planFeatureList('year')" :key="feature">{{ feature }}</li>
              </ul>
              <button
                class="recharge-card__action recharge-card__action--dark"
                type="button"
                :disabled="!yearlyPlan?.rule || billingLoading"
                @click="purchasePricingRule(yearlyPlan?.rule)"
              >
                {{ planActionText(yearlyPlan) }}
                <span class="i-mdi-cart-outline text-base"></span>
              </button>
            </article>
          </div>
        </section>

      </div>
    </el-dialog>

    <el-dialog v-model="paymentDialogVisible" title="微信支付" width="420" @closed="closePaymentDialog">
      <div class="flex flex-col items-center gap-4 py-2">
        <div class="text-center">
          <p class="text-base font-semibold text-[var(--text-strong)]">
            {{ paymentSnapshot?.session?.paymentProduct.name || '待支付订单' }}
          </p>
          <p class="mt-1 text-sm text-[var(--text-soft)]">
            {{ paymentSnapshot?.session?.paymentProduct.description || paymentMessage }}
          </p>
          <p class="mt-1 text-sm font-medium text-[var(--brand)]">
            {{ formatPaymentAmount(paymentSnapshot?.session?.amount) }}
          </p>
        </div>

        <div class="flex h-[220px] w-[220px] items-center justify-center rounded-2xl border border-[var(--line)] bg-white p-3">
          <img v-if="paymentQRCodeDataUrl" :src="paymentQRCodeDataUrl" alt="支付二维码" class="h-full w-full object-contain" />
          <div v-else class="text-sm text-[var(--text-soft)]">二维码生成中...</div>
        </div>

        <div class="w-full rounded-2xl bg-[var(--brand-soft)]/40 px-4 py-3 text-sm text-[var(--text-soft)]">
          <p>状态：{{ paymentStatusLabel(paymentStatus) }}</p>
          <p v-if="paymentSnapshot?.session?.bizId" class="mt-1 break-all">订单号：{{ paymentSnapshot.session.bizId }}</p>
          <p v-if="paymentSnapshot?.session?.expiresAt" class="mt-1">过期时间：{{ paymentSnapshot.session.expiresAt }}</p>
          <p v-if="paymentSnapshot?.session?.paidAt" class="mt-1">支付时间：{{ paymentSnapshot.session.paidAt }}</p>
          <p class="mt-1 break-all">{{ paymentMessage }}</p>
        </div>

        <div class="flex w-full justify-end gap-3">
          <el-button @click="closePaymentDialog">关闭</el-button>
          <el-button
            type="primary"
            :disabled="!paymentSnapshot?.order?.biz_id || billingLoading"
            @click="paymentSnapshot?.order?.biz_id && syncPaymentStatus(paymentSnapshot.order.biz_id)"
          >
            刷新状态
          </el-button>
        </div>
      </div>
    </el-dialog>

    <el-dialog v-model="businessRecordsDialogVisible" title="用户业务记录" width="950">
      <div class="space-y-4">
        <el-table :data="pagedBusinessRecords" height="420" v-loading="businessRecordsLoading" style="width: 100%">
          <el-table-column prop="record_type" label="类型" min-width="120">
            <template #default="{ row }">{{ isLegacyIncludedTrafficRecord(row) ? '套餐内流量' : formatBusinessRecordType(row.record_type) }}</template>
          </el-table-column>
          <el-table-column prop="traffic_balance_after" label="剩余流量" min-width="110">
            <template #default="{ row }">{{ formatTrafficBalance(row.traffic_balance_after) }}</template>
          </el-table-column>
          <el-table-column prop="traffic_bytes" label="总结算流量" min-width="120">
            <template #default="{ row }">{{ formatTrafficValue(row.traffic_bytes) }}</template>
          </el-table-column>
          <el-table-column prop="billable_bytes" label="计费流量" min-width="120">
            <template #default="{ row }">{{ formatTrafficValue(row.billable_bytes) }}</template>
          </el-table-column>
          <el-table-column prop="package_expires_at" label="到期时间" min-width="170">
            <template #default="{ row }">{{ formatDateTime(row.package_expires_at) }}</template>
          </el-table-column>
          <el-table-column prop="created_at" label="时间" min-width="170">
            <template #default="{ row }">{{ formatDateTime(row.created_at) }}</template>
          </el-table-column>
        </el-table>

        <div class="flex justify-end">
          <el-pagination
            v-model:current-page="businessRecordsPage"
            :page-size="businessRecordsPageSize"
            layout="prev, pager, next, total"
            :total="businessRecords.length"
          />
        </div>
      </div>
    </el-dialog>
  </div>
</template>

<style scoped>
:deep(.recharge-dialog-overlay) {
  display: flex;
  align-items: center;
  justify-content: center;
  overflow: hidden;
  padding: 20px;
}

:deep(.recharge-dialog-overlay .el-overlay-dialog) {
  display: flex;
  align-items: center;
  justify-content: center;
  overflow: hidden;
}

:deep(.recharge-dialog) {
  margin: 0 !important;
  max-height: calc(100vh - 40px);
  overflow: hidden;
}

:deep(.recharge-dialog .el-dialog__body) {
  max-height: calc(100vh - 140px);
  overflow: hidden;
}

.recharge-upgrade {
  padding: 2px;
}

.recharge-upgrade__hero {
  position: relative;
  display: flex;
  justify-content: space-between;
  gap: 16px;
  overflow: hidden;
  border: 1px solid color-mix(in srgb, var(--brand) 10%, transparent);
  border-radius: 28px;
  background: linear-gradient(135deg, rgba(255, 255, 255, 0.98) 0%, rgba(244, 248, 255, 0.96) 100%);
  box-shadow: 0 20px 40px rgba(12, 36, 64, 0.06), 0 8px 18px rgba(12, 36, 64, 0.04);
  padding: 18px 20px;
}

.recharge-upgrade__hero-glow {
  position: absolute;
  top: -60px;
  right: -40px;
  width: 180px;
  height: 180px;
  border-radius: 999px;
  background: rgba(64, 139, 255, 0.12);
  filter: blur(18px);
}

.recharge-upgrade__hero-main,
.recharge-upgrade__hero-side {
  position: relative;
  z-index: 1;
}

.recharge-upgrade__hero-main {
  min-width: 0;
}

.recharge-upgrade__hero-label {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  color: var(--text-soft);
  font-size: 12px;
  font-weight: 600;
}

.recharge-upgrade__hero-value {
  display: flex;
  align-items: baseline;
  gap: 8px;
  margin-top: 10px;
}

.recharge-upgrade__hero-number {
  font-size: clamp(30px, 5vw, 44px);
  line-height: 1;
  font-weight: 800;
  letter-spacing: -0.04em;
  color: var(--text-strong);
}

.recharge-upgrade__hero-unit {
  color: var(--brand);
  font-size: 18px;
  font-weight: 700;
}

.recharge-upgrade__pill {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  border-radius: 999px;
  background: rgba(15, 23, 42, 0.04);
  padding: 7px 10px;
  color: var(--text-soft);
  font-size: 11px;
  font-weight: 600;
}

.recharge-upgrade__pill--side {
  align-self: flex-end;
}

.recharge-upgrade__hero-side {
  display: flex;
  min-width: 210px;
  flex-direction: column;
  align-items: flex-end;
  justify-content: center;
  gap: 8px;
}

.recharge-upgrade__status {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  border: 1px solid rgba(34, 197, 94, 0.16);
  border-radius: 18px;
  background: rgba(34, 197, 94, 0.08);
  padding: 8px 12px;
  color: #15803d;
  font-size: 12px;
  font-weight: 700;
}

.recharge-upgrade__status-dot {
  width: 8px;
  height: 8px;
  border-radius: 999px;
  background: #22c55e;
  box-shadow: 0 0 0 4px rgba(34, 197, 94, 0.14);
}

.recharge-card {
  position: relative;
  display: flex;
  min-height: 100%;
  flex-direction: column;
  border: 1px solid rgba(15, 23, 42, 0.06);
  border-radius: 22px;
  background: linear-gradient(180deg, rgba(255, 255, 255, 0.98) 0%, rgba(247, 249, 252, 0.98) 100%);
  box-shadow: 0 18px 36px rgba(15, 23, 42, 0.05);
  padding: 16px;
}

.recharge-card--featured {
  transform: scale(1.02);
  border-color: rgba(37, 99, 235, 0.18);
  background: linear-gradient(180deg, rgba(234, 244, 255, 0.92) 0%, rgba(247, 250, 255, 0.98) 100%);
  box-shadow: 0 24px 48px rgba(37, 99, 235, 0.12);
}

.recharge-card__corner {
  position: absolute;
  top: 10px;
  right: -32px;
  transform: rotate(18deg);
  border-radius: 999px;
  background: linear-gradient(135deg, #ea580c 0%, #f97316 100%);
  padding: 5px 30px;
  color: white;
  font-size: 10px;
  font-weight: 800;
  letter-spacing: 0.08em;
}

.recharge-card__badge {
  display: inline-flex;
  align-items: center;
  border-radius: 10px;
  padding: 5px 9px;
  font-size: 11px;
  font-weight: 700;
}

.recharge-card__badge--traffic {
  background: rgba(56, 189, 248, 0.14);
  color: #0369a1;
}

.recharge-card__badge--featured {
  background: rgba(37, 99, 235, 0.14);
  color: var(--brand);
}

.recharge-card__badge--yearly {
  background: rgba(245, 158, 11, 0.14);
  color: #b45309;
}

.recharge-card__price-row {
  display: flex;
  align-items: baseline;
  gap: 6px;
  margin-top: 14px;
}

.recharge-card__price-row--featured {
  margin-top: 18px;
}

.recharge-card__price {
  font-size: 32px;
  line-height: 1;
  font-weight: 800;
  letter-spacing: -0.05em;
  color: var(--text-strong);
}

.recharge-card__price--featured {
  font-size: 36px;
  color: var(--brand);
}

.recharge-card__price-suffix {
  color: var(--text-soft);
  font-size: 13px;
  font-weight: 600;
}

.recharge-card__price-suffix--featured {
  color: color-mix(in srgb, var(--brand) 72%, white);
}

.recharge-card__description {
  margin-top: 10px;
  color: var(--text-soft);
  font-size: 12px;
  line-height: 1.6;
}

.recharge-card__description--strong {
  color: var(--text-strong);
}

.recharge-card__feature-list {
  display: flex;
  flex: 1;
  flex-direction: column;
  gap: 8px;
  margin: 14px 0 16px;
  padding: 0;
  list-style: none;
}

.recharge-card__feature-list li {
  position: relative;
  padding-left: 18px;
  color: var(--text-soft);
  font-size: 12px;
  line-height: 1.5;
}

.recharge-card__feature-list li::before {
  content: '';
  position: absolute;
  left: 0;
  top: 6px;
  width: 6px;
  height: 6px;
  border-radius: 999px;
  background: color-mix(in srgb, var(--brand) 82%, white);
  box-shadow: 0 0 0 3px color-mix(in srgb, var(--brand) 12%, transparent);
}

.recharge-card__feature-list--featured li {
  color: var(--text-strong);
  font-weight: 500;
}

.recharge-card__traffic-options {
  display: grid;
  grid-template-columns: repeat(3, minmax(0, 1fr));
  gap: 8px;
  margin: 2px 0 14px;
}

.recharge-card__traffic-chip {
  display: flex;
  min-height: 56px;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  gap: 2px;
  border: 1px solid rgba(15, 23, 42, 0.08);
  border-radius: 14px;
  background: rgba(15, 23, 42, 0.04);
  color: var(--text-strong);
  transition: all 0.2s ease;
}

.recharge-card__traffic-chip:hover:not(:disabled) {
  transform: translateY(-1px);
  border-color: rgba(37, 99, 235, 0.18);
  background: rgba(37, 99, 235, 0.08);
}

.recharge-card__traffic-chip:disabled {
  opacity: 0.6;
  cursor: not-allowed;
}

.recharge-card__traffic-chip-size {
  font-size: 12px;
  font-weight: 800;
}

.recharge-card__traffic-chip-price {
  color: var(--text-soft);
  font-size: 11px;
  font-weight: 600;
}

.recharge-card__saving {
  color: #c2410c;
  font-size: 11px;
  font-weight: 700;
}

.recharge-card__action {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  width: 100%;
  min-height: 42px;
  border: none;
  border-radius: 15px;
  font-size: 13px;
  font-weight: 700;
  transition: all 0.2s ease;
}

.recharge-card__action:disabled {
  opacity: 0.55;
  cursor: not-allowed;
}

.recharge-card__action--ghost {
  background: rgba(37, 99, 235, 0.08);
  color: var(--brand);
}

.recharge-card__action--ghost:hover:not(:disabled) {
  background: rgba(37, 99, 235, 0.14);
}

.recharge-card__action--primary {
  background: linear-gradient(135deg, #0b63ce 0%, #1d7df2 100%);
  color: white;
  box-shadow: 0 14px 26px rgba(37, 99, 235, 0.24);
}

.recharge-card__action--primary:hover:not(:disabled) {
  transform: translateY(-1px);
}

.recharge-card__action--dark {
  background: rgba(15, 23, 42, 0.08);
  color: var(--text-strong);
}

.recharge-card__action--dark:hover:not(:disabled) {
  background: rgba(15, 23, 42, 0.12);
}

@media (max-width: 960px) {
  .recharge-upgrade__hero {
    flex-direction: column;
  }

  .recharge-upgrade__hero-side {
    min-width: 0;
    align-items: flex-start;
  }

  .recharge-upgrade__pill--side {
    align-self: flex-start;
  }

  .recharge-card--featured {
    transform: none;
  }
}

@media (max-width: 640px) {
  .recharge-card__traffic-options {
    grid-template-columns: 1fr;
  }
}
</style>
