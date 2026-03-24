CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email TEXT UNIQUE,
    nickname TEXT NOT NULL DEFAULT '',
    avatar_url TEXT,
    password_hash TEXT NOT NULL DEFAULT '',
    wechat_openid TEXT UNIQUE,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS agents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    machine_code TEXT NOT NULL,
    secret_key TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'offline',
    client_version TEXT NOT NULL DEFAULT '',
    os_type TEXT NOT NULL DEFAULT '',
    last_heartbeat_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_agents_user_machine_code
    ON agents(user_id, machine_code);

CREATE TABLE IF NOT EXISTS tunnels (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    agent_id UUID NOT NULL REFERENCES agents(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    type TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'active',
    enabled BOOLEAN NOT NULL DEFAULT TRUE,
    local_host TEXT NOT NULL,
    local_port INTEGER NOT NULL,
    remote_port INTEGER,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_tunnels_user_id_created_at
    ON tunnels(user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_tunnels_agent_id_created_at
    ON tunnels(agent_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_tunnels_enabled_type_remote_port
    ON tunnels(enabled, type, remote_port);

CREATE TABLE IF NOT EXISTS domain_routes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tunnel_id UUID NOT NULL REFERENCES tunnels(id) ON DELETE CASCADE,
    domain TEXT NOT NULL,
    scheme TEXT NOT NULL DEFAULT 'https',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_domain_routes_domain_scheme
    ON domain_routes(lower(domain), scheme);

CREATE INDEX IF NOT EXISTS idx_domain_routes_tunnel_id_created_at
    ON domain_routes(tunnel_id, created_at ASC);

CREATE TABLE IF NOT EXISTS tunnel_connections (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tunnel_id UUID NOT NULL REFERENCES tunnels(id) ON DELETE CASCADE,
    agent_id UUID REFERENCES agents(id) ON DELETE SET NULL,
    protocol TEXT NOT NULL,
    source_addr TEXT NOT NULL DEFAULT '',
    target_addr TEXT NOT NULL DEFAULT '',
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    ended_at TIMESTAMPTZ,
    ingress_bytes BIGINT NOT NULL DEFAULT 0,
    egress_bytes BIGINT NOT NULL DEFAULT 0,
    total_bytes BIGINT NOT NULL DEFAULT 0,
    status TEXT NOT NULL DEFAULT 'open'
);

CREATE INDEX IF NOT EXISTS idx_tunnel_connections_tunnel_started_at
    ON tunnel_connections(tunnel_id, started_at DESC);

CREATE TABLE IF NOT EXISTS traffic_usages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    agent_id UUID REFERENCES agents(id) ON DELETE SET NULL,
    tunnel_id UUID REFERENCES tunnels(id) ON DELETE SET NULL,
    bucket_time TIMESTAMPTZ NOT NULL,
    ingress_bytes BIGINT NOT NULL DEFAULT 0,
    egress_bytes BIGINT NOT NULL DEFAULT 0,
    total_bytes BIGINT NOT NULL DEFAULT 0,
    billed_bytes BIGINT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_traffic_usages_tunnel_bucket_time
    ON traffic_usages(tunnel_id, bucket_time);

CREATE INDEX IF NOT EXISTS idx_traffic_usages_user_bucket_time
    ON traffic_usages(user_id, bucket_time DESC);

CREATE TABLE IF NOT EXISTS accounts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
    balance NUMERIC(20, 4) NOT NULL DEFAULT 0,
    currency TEXT NOT NULL DEFAULT 'CNY',
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS pricing_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    billing_mode TEXT NOT NULL DEFAULT 'traffic',
    price_per_gb NUMERIC(20, 4) NOT NULL DEFAULT 0,
    free_quota_bytes BIGINT NOT NULL DEFAULT 0,
    subscription_price NUMERIC(20, 4) NOT NULL DEFAULT 0,
    included_traffic_bytes BIGINT NOT NULL DEFAULT 0,
    subscription_period TEXT NOT NULL DEFAULT 'none',
    traffic_reset_period TEXT NOT NULL DEFAULT 'none',
    is_unlimited BOOLEAN NOT NULL DEFAULT FALSE,
    status TEXT NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS user_pricing_rules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    pricing_rule_id UUID NOT NULL REFERENCES pricing_rules(id) ON DELETE CASCADE,
    effective_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expired_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_user_pricing_rules_user_effective_at
    ON user_pricing_rules(user_id, effective_at DESC);

CREATE TABLE IF NOT EXISTS user_subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    pricing_rule_id UUID NOT NULL REFERENCES pricing_rules(id) ON DELETE CASCADE,
    status TEXT NOT NULL DEFAULT 'active',
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    current_period_start TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    current_period_end TIMESTAMPTZ,
    current_period_used_bytes BIGINT NOT NULL DEFAULT 0,
    expires_at TIMESTAMPTZ,
    cancelled_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_user_subscriptions_user_started_at
    ON user_subscriptions(user_id, started_at DESC);

CREATE TABLE IF NOT EXISTS user_business_records (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
    type TEXT NOT NULL DEFAULT 'adjust',
    amount NUMERIC(20, 4) NOT NULL DEFAULT 0,
    balance_before NUMERIC(20, 4) NOT NULL DEFAULT 0,
    balance_after NUMERIC(20, 4) NOT NULL DEFAULT 0,
    reference_type TEXT,
    reference_id UUID,
    remark TEXT NOT NULL DEFAULT '',
    record_type TEXT NOT NULL DEFAULT 'unknown',
    related_resource_type TEXT,
    related_resource_id TEXT,
    traffic_bytes BIGINT NOT NULL DEFAULT 0,
    billable_bytes BIGINT NOT NULL DEFAULT 0,
    package_expires_at TIMESTAMPTZ,
    payment_order_biz_id TEXT,
    description TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_user_business_records_user_created_at
    ON user_business_records(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS payment_orders (
    biz_id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    order_type TEXT NOT NULL,
    payment_product_id TEXT NOT NULL,
    pricing_rule_id TEXT,
    recharge_gb INTEGER,
    session_id TEXT,
    notify_url TEXT NOT NULL,
    poll_url TEXT,
    qr_code_url TEXT,
    checkout_url TEXT,
    amount INTEGER NOT NULL DEFAULT 0,
    platform_status TEXT NOT NULL DEFAULT 'pending',
    apply_status TEXT NOT NULL DEFAULT 'pending',
    business_notify_status TEXT,
    business_notify_error TEXT,
    expires_at TIMESTAMPTZ,
    paid_at TIMESTAMPTZ,
    last_polled_at TIMESTAMPTZ,
    apply_error TEXT,
    raw_snapshot TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
