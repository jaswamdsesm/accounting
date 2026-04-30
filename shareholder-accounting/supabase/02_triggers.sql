-- ============================================================
-- 触发器与函数脚本
-- 依赖 01_schema.sql 已执行完毕
-- ============================================================

-- ============================================================
-- 函数0：自动计算所属账期（billing_period = YYYY-MM）
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_billing_period()
RETURNS TRIGGER AS $$
BEGIN
  NEW.billing_period := TO_CHAR(NEW.transaction_date, 'YYYY-MM');
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- INSERT 触发器：无条件设置 billing_period
CREATE TRIGGER trg_set_billing_period_insert
  BEFORE INSERT ON public.transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.set_billing_period();

-- UPDATE 触发器：仅在日期变化时更新
CREATE TRIGGER trg_set_billing_period_update
  BEFORE UPDATE ON public.transactions
  FOR EACH ROW
  WHEN (OLD.transaction_date IS DISTINCT FROM NEW.transaction_date)
  EXECUTE FUNCTION public.set_billing_period();

-- ============================================================
-- 函数1：自动生成流水号
-- 格式：TX-YYYYMMDD-XXXXXX（6位序列）
-- ============================================================
CREATE OR REPLACE FUNCTION public.generate_serial_no()
RETURNS TRIGGER AS $$
DECLARE
  v_date_str TEXT;
  v_seq      INT;
  v_serial   TEXT;
BEGIN
  v_date_str := TO_CHAR(NEW.transaction_date, 'YYYYMMDD');
  -- 统计当日已有记录数，生成序号
  SELECT COUNT(*) + 1 INTO v_seq
  FROM public.transactions
  WHERE TO_CHAR(transaction_date, 'YYYYMMDD') = v_date_str;

  v_serial := 'TX-' || v_date_str || '-' || LPAD(v_seq::TEXT, 6, '0');
  
  -- 防重复：若冲突则自增
  WHILE EXISTS (SELECT 1 FROM public.transactions WHERE serial_no = v_serial) LOOP
    v_seq := v_seq + 1;
    v_serial := 'TX-' || v_date_str || '-' || LPAD(v_seq::TEXT, 6, '0');
  END LOOP;
  
  NEW.serial_no := v_serial;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_generate_serial_no
  BEFORE INSERT ON public.transactions
  FOR EACH ROW
  WHEN (NEW.serial_no IS NULL OR NEW.serial_no = '')
  EXECUTE FUNCTION public.generate_serial_no();

-- ============================================================
-- 函数2：收支流水变更时自动更新账户余额
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_account_balance()
RETURNS TRIGGER AS $$
DECLARE
  v_delta NUMERIC(15, 2);
BEGIN
  -- 只处理 正常/冲销/补录 类型的新增或修改
  IF TG_OP = 'INSERT' THEN
    -- 收入 → 余额增加；支出 → 余额减少
    -- 冲销记录 amount 已为负数，直接按收支方向计算即可
    IF NEW.tx_type = 'income' THEN
      v_delta := NEW.amount;
    ELSE
      v_delta := -NEW.amount;
    END IF;

    UPDATE public.accounts
    SET current_balance = current_balance + v_delta,
        updated_at = NOW()
    WHERE id = NEW.account_id;

  ELSIF TG_OP = 'UPDATE' THEN
    -- 修改时：先撤回旧值，再加入新值
    IF OLD.tx_type = 'income' THEN
      v_delta := -OLD.amount;
    ELSE
      v_delta := OLD.amount;
    END IF;
    UPDATE public.accounts
    SET current_balance = current_balance + v_delta,
        updated_at = NOW()
    WHERE id = OLD.account_id;

    IF NEW.tx_type = 'income' THEN
      v_delta := NEW.amount;
    ELSE
      v_delta := -NEW.amount;
    END IF;
    UPDATE public.accounts
    SET current_balance = current_balance + v_delta,
        updated_at = NOW()
    WHERE id = NEW.account_id;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_update_balance
  AFTER INSERT OR UPDATE ON public.transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.update_account_balance();

-- ============================================================
-- 函数3：自动写入审计日志（transactions 表）
-- ============================================================
CREATE OR REPLACE FUNCTION public.log_transaction_audit()
RETURNS TRIGGER AS $$
DECLARE
  v_action TEXT;
  v_before JSONB := NULL;
  v_after  JSONB := NULL;
BEGIN
  IF TG_OP = 'INSERT' THEN
    v_action := CASE NEW.record_type
      WHEN 'reversal'   THEN 'reversal'
      WHEN 'correction' THEN 'correction'
      ELSE 'create'
    END;
    v_after := to_jsonb(NEW);
  ELSIF TG_OP = 'UPDATE' THEN
    -- 判断操作类型
    IF OLD.lock_status != NEW.lock_status THEN
      v_action := CASE NEW.lock_status
        WHEN 'pending_lock' THEN 'pending_lock'
        WHEN 'locked'       THEN 'lock'
        WHEN 'unlocked'     THEN 'unlock'
        ELSE 'update'
      END;
    ELSE
      v_action := 'update';
    END IF;
    v_before := to_jsonb(OLD);
    v_after  := to_jsonb(NEW);
  END IF;

  INSERT INTO public.audit_logs (
    operator_id, operator_name, operator_ip,
    action_type, target_table, target_id, target_serial,
    before_value, after_value
  ) VALUES (
    NEW.creator_id,
    NEW.creator_name,
    current_setting('request.headers', TRUE)::JSONB->>'x-forwarded-for',
    v_action,
    'transactions',
    NEW.id,
    NEW.serial_no,
    v_before,
    v_after
  );

  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER trg_audit_transactions
  AFTER INSERT OR UPDATE ON public.transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.log_transaction_audit();

-- ============================================================
-- 函数4：自动写入审计日志（accounts 表）
-- ============================================================
CREATE OR REPLACE FUNCTION public.log_account_audit()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.audit_logs (
    operator_name, action_type, target_table, target_id,
    before_value, after_value
  ) VALUES (
    'SYSTEM',
    'update',
    'accounts',
    NEW.id,
    to_jsonb(OLD),
    to_jsonb(NEW)
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER trg_audit_accounts
  AFTER UPDATE ON public.accounts
  FOR EACH ROW
  WHEN (OLD.current_balance IS DISTINCT FROM NEW.current_balance)
  EXECUTE FUNCTION public.log_account_audit();

-- ============================================================
-- 函数5：updated_at 自动更新
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at := NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_transactions_updated_at
  BEFORE UPDATE ON public.transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

CREATE TRIGGER trg_accounts_updated_at
  BEFORE UPDATE ON public.accounts
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- ============================================================
-- 函数6：账期批量锁定（每月1号定时任务调用）
-- 将上月所有 unlocked 记录标记为 pending_lock
-- ============================================================
CREATE OR REPLACE FUNCTION public.trigger_period_lock(
  p_billing_period TEXT,  -- 格式 YYYY-MM
  p_operator_id UUID,
  p_operator_name TEXT
)
RETURNS INT AS $$
DECLARE
  v_count INT;
BEGIN
  UPDATE public.transactions
  SET lock_status = 'pending_lock',
      updated_at  = NOW()
  WHERE billing_period = p_billing_period
    AND lock_status = 'unlocked';
  
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================
-- 函数7：审批通过后批量锁定账期
-- ============================================================
CREATE OR REPLACE FUNCTION public.approve_period_lock(
  p_billing_period TEXT,
  p_operator_id UUID,
  p_operator_name TEXT
)
RETURNS INT AS $$
DECLARE
  v_count INT;
BEGIN
  UPDATE public.transactions
  SET lock_status = 'locked',
      updated_at  = NOW()
  WHERE billing_period = p_billing_period
    AND lock_status = 'pending_lock';

  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN v_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
