-- ============================================================
-- 小公司内部记账与股东对账系统 - Supabase 数据库建表脚本
-- 执行顺序：01_schema.sql → 02_triggers.sql → 03_rls.sql
-- ============================================================

-- 启用 UUID 扩展
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- 表1：用户/角色表（映射飞书用户）
-- ============================================================
CREATE TABLE IF NOT EXISTS public.app_users (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  feishu_uid   TEXT UNIQUE NOT NULL,          -- 飞书 open_id
  name         TEXT NOT NULL,                  -- 显示名称
  role         TEXT NOT NULL DEFAULT 'shareholder_bookkeeper'
               CHECK (role IN (
                 'shareholder_bookkeeper',     -- 股东记账员（当前阶段）
                 'bookkeeper',                 -- 财务记账员（未来）
                 'shareholder_viewer'          -- 股东查看者（未来）
               )),
  is_active    BOOLEAN NOT NULL DEFAULT TRUE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.app_users IS '系统用户表，通过飞书免登映射';
COMMENT ON COLUMN public.app_users.role IS '角色：shareholder_bookkeeper=股东记账员, bookkeeper=财务记账员, shareholder_viewer=股东查看者';

-- ============================================================
-- 表2：账户余额表
-- ============================================================
CREATE TABLE IF NOT EXISTS public.accounts (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  account_name    TEXT UNIQUE NOT NULL,        -- 账户名称（如：对公账户、库存现金、支付宝）
  current_balance NUMERIC(15, 2) NOT NULL DEFAULT 0.00,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.accounts IS '账户余额表';

-- 插入默认账户
INSERT INTO public.accounts (account_name, current_balance) VALUES
  ('对公账户', 0.00),
  ('库存现金', 0.00),
  ('支付宝',   0.00)
ON CONFLICT (account_name) DO NOTHING;

-- ============================================================
-- 表3：收支流水表
-- ============================================================
CREATE TABLE IF NOT EXISTS public.transactions (
  id               UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  serial_no        TEXT UNIQUE NOT NULL,       -- 流水号（自动生成）
  transaction_date DATE NOT NULL,              -- 发生日期
  tx_type          TEXT NOT NULL               -- 收支类型
                   CHECK (tx_type IN ('income', 'expense')),
  amount           NUMERIC(15, 2) NOT NULL,    -- 金额（冲销时为负数）
  category         TEXT NOT NULL               -- 分类
                   CHECK (category IN (
                     '营业收入', '营业外收入',
                     '采购成本', '人力成本', '办公费', '业务招待费', '税费',
                     '其他收入', '其他支出'
                   )),
  account_id       UUID NOT NULL REFERENCES public.accounts(id),
  counterparty     TEXT NOT NULL,              -- 交易对方
  description      TEXT,                       -- 交易说明
  attachment_urls  JSONB DEFAULT '[]'::JSONB,  -- 凭证附件 URL 列表
  billing_period   TEXT,                     -- 所属账期（YYYY-MM，触发器自动计算）
  lock_status      TEXT NOT NULL DEFAULT 'unlocked'
                   CHECK (lock_status IN ('unlocked', 'pending_lock', 'locked')),
  record_type      TEXT NOT NULL DEFAULT 'normal'
                   CHECK (record_type IN ('normal', 'reversal', 'correction')),
  related_serial   TEXT,                       -- 关联原流水号（冲销/补录时填入）
  creator_id       UUID NOT NULL REFERENCES public.app_users(id),
  creator_name     TEXT NOT NULL,              -- 冗余存储创建人姓名（审计用）
  created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.transactions IS '收支流水表';
COMMENT ON COLUMN public.transactions.serial_no IS '流水号，格式：TX-YYYYMMDD-XXXXXX';
COMMENT ON COLUMN public.transactions.lock_status IS 'unlocked=未锁定, pending_lock=待锁定, locked=已锁定';
COMMENT ON COLUMN public.transactions.record_type IS 'normal=正常, reversal=冲销, correction=补录';

-- 索引
CREATE INDEX IF NOT EXISTS idx_transactions_date ON public.transactions(transaction_date DESC);
CREATE INDEX IF NOT EXISTS idx_transactions_period ON public.transactions(billing_period);
CREATE INDEX IF NOT EXISTS idx_transactions_account ON public.transactions(account_id);
CREATE INDEX IF NOT EXISTS idx_transactions_lock ON public.transactions(lock_status);
CREATE INDEX IF NOT EXISTS idx_transactions_type ON public.transactions(record_type);
CREATE INDEX IF NOT EXISTS idx_transactions_creator ON public.transactions(creator_id);

-- ============================================================
-- 表4：审计日志表
-- ============================================================
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  operated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),   -- 操作时间
  operator_id     UUID REFERENCES public.app_users(id), -- 操作人ID
  operator_name   TEXT NOT NULL,                        -- 操作人姓名
  operator_ip     TEXT,                                 -- 操作人IP
  action_type     TEXT NOT NULL                         -- 操作类型
                  CHECK (action_type IN (
                    'create', 'update', 'reversal', 'correction',
                    'lock', 'unlock', 'pending_lock'
                  )),
  target_table    TEXT NOT NULL,                        -- 操作对象表
  target_id       UUID NOT NULL,                        -- 操作对象ID
  target_serial   TEXT,                                 -- 操作对象流水号（便于查阅）
  before_value    JSONB,                                -- 变更前内容
  after_value     JSONB                                 -- 变更后内容
);

COMMENT ON TABLE public.audit_logs IS '审计日志表，所有人仅可查看，不可修改或删除';

-- 索引
CREATE INDEX IF NOT EXISTS idx_audit_operated_at ON public.audit_logs(operated_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_operator ON public.audit_logs(operator_id);
CREATE INDEX IF NOT EXISTS idx_audit_target ON public.audit_logs(target_id);

-- ============================================================
-- 表5：审批记录表（账期锁定 / 修改已锁定记录）
-- ============================================================
CREATE TABLE IF NOT EXISTS public.approvals (
  id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  approval_type   TEXT NOT NULL
                  CHECK (approval_type IN ('period_lock', 'modify_locked')),
  title           TEXT NOT NULL,               -- 审批标题
  billing_period  TEXT,                        -- 相关账期（period_lock 时填写）
  target_tx_id    UUID REFERENCES public.transactions(id), -- modify_locked 时的目标流水
  reason          TEXT,                        -- 申请原因
  attachment_urls JSONB DEFAULT '[]'::JSONB,   -- 佐证附件
  status          TEXT NOT NULL DEFAULT 'pending'
                  CHECK (status IN ('pending', 'approved', 'rejected')),
  initiated_by    UUID NOT NULL REFERENCES public.app_users(id),
  initiated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at     TIMESTAMPTZ,
  votes           JSONB DEFAULT '[]'::JSONB    -- [{user_id, name, vote, voted_at}]
);

COMMENT ON TABLE public.approvals IS '审批记录表（账期锁定 / 修改已锁定记录）';
