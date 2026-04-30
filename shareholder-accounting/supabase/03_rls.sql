-- ============================================================
-- RLS（行级安全策略）脚本
-- 依赖 01_schema.sql + 02_triggers.sql 已执行完毕
-- ============================================================

-- 启用 RLS
ALTER TABLE public.app_users     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.accounts      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.transactions  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.approvals     ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- 辅助函数：获取当前用户角色（通过 JWT claim 中的 feishu_uid）
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_current_user_role()
RETURNS TEXT AS $$
  SELECT role FROM public.app_users
  WHERE feishu_uid = auth.jwt() ->> 'sub'
  LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION public.get_current_user_id()
RETURNS UUID AS $$
  SELECT id FROM public.app_users
  WHERE feishu_uid = auth.jwt() ->> 'sub'
  LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ============================================================
-- app_users 表策略
-- ============================================================
-- 所有登录用户可查看用户列表（需显示操作人姓名等）
CREATE POLICY "users_select_all" ON public.app_users
  FOR SELECT USING (TRUE);

-- 只有本人可更新自己的记录（名称等）
CREATE POLICY "users_update_self" ON public.app_users
  FOR UPDATE USING (feishu_uid = auth.jwt() ->> 'sub');

-- 系统服务可插入（飞书免登时自动注册）
CREATE POLICY "users_insert_service" ON public.app_users
  FOR INSERT WITH CHECK (TRUE);

-- ============================================================
-- accounts 表策略
-- ============================================================
-- 所有有效用户可查看账户
CREATE POLICY "accounts_select" ON public.accounts
  FOR SELECT USING (
    public.get_current_user_role() IS NOT NULL
  );

-- 只有记账员角色可以通过触发器更新余额（直接 UPDATE 不开放给前端）
-- 余额更新仅通过触发器（SECURITY DEFINER）完成，前端无直接 UPDATE 权限
CREATE POLICY "accounts_update_trigger_only" ON public.accounts
  FOR UPDATE USING (FALSE);  -- 前端无法直接 UPDATE，由触发器负责

-- ============================================================
-- transactions 表策略
-- ============================================================
-- 所有有效用户可查看
CREATE POLICY "tx_select_all" ON public.transactions
  FOR SELECT USING (
    public.get_current_user_role() IS NOT NULL
  );

-- 记账员和股东记账员可新增记录
CREATE POLICY "tx_insert" ON public.transactions
  FOR INSERT WITH CHECK (
    public.get_current_user_role() IN (
      'shareholder_bookkeeper', 'bookkeeper'
    )
  );

-- 只能修改未锁定记录，且只有记账角色
CREATE POLICY "tx_update_unlocked" ON public.transactions
  FOR UPDATE USING (
    public.get_current_user_role() IN (
      'shareholder_bookkeeper', 'bookkeeper'
    )
    AND lock_status = 'unlocked'
  );

-- 锁定状态变更（pending_lock / locked）由 SECURITY DEFINER 函数完成
-- 此处不单独开放 UPDATE lock_status 给前端

-- 禁止所有角色直接删除（彻底封死）
CREATE POLICY "tx_no_delete" ON public.transactions
  FOR DELETE USING (FALSE);

-- ============================================================
-- audit_logs 表策略
-- ============================================================
-- 所有有效用户仅可查看
CREATE POLICY "audit_select" ON public.audit_logs
  FOR SELECT USING (
    public.get_current_user_role() IS NOT NULL
  );

-- 禁止所有前端写入（由触发器 SECURITY DEFINER 负责）
CREATE POLICY "audit_no_insert" ON public.audit_logs
  FOR INSERT WITH CHECK (FALSE);

CREATE POLICY "audit_no_update" ON public.audit_logs
  FOR UPDATE USING (FALSE);

CREATE POLICY "audit_no_delete" ON public.audit_logs
  FOR DELETE USING (FALSE);

-- ============================================================
-- approvals 表策略
-- ============================================================
-- 所有有效用户可查看审批
CREATE POLICY "approvals_select" ON public.approvals
  FOR SELECT USING (
    public.get_current_user_role() IS NOT NULL
  );

-- 记账角色可发起审批
CREATE POLICY "approvals_insert" ON public.approvals
  FOR INSERT WITH CHECK (
    public.get_current_user_role() IN (
      'shareholder_bookkeeper', 'bookkeeper'
    )
  );

-- 参与投票：更新 votes 字段
CREATE POLICY "approvals_vote" ON public.approvals
  FOR UPDATE USING (
    public.get_current_user_role() IS NOT NULL
    AND status = 'pending'
  );

-- 禁止删除审批记录
CREATE POLICY "approvals_no_delete" ON public.approvals
  FOR DELETE USING (FALSE);
