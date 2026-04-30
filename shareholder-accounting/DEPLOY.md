# 飞书工作台部署完整操作指引

## 文件清单

```
D:\WORKBUDDY\shareholder-accounting\
├── index.html                          # 前端主文件（单文件SPA）
├── supabase\
│   ├── 01_schema.sql                   # 建表脚本
│   ├── 02_triggers.sql                 # 触发器 + 业务函数
│   ├── 03_rls.sql                      # 行级安全策略
│   └── functions\
│       └── feishu-auth\
│           └── index.ts               # 飞书免登 Edge Function
```

---

## 第一步：初始化 Supabase 数据库

### 1.1 创建 Supabase 项目

1. 登录 [supabase.com](https://supabase.com)
2. 创建新项目，命名如 `shareholder-accounting`
3. 记录以下信息备用：
   - **Project URL**：`https://xxxxxxxx.supabase.co`
   - **anon public key**：在 Settings → API 中查看
   - **service_role key**：在 Settings → API 中查看（保密！）

### 1.2 执行建表脚本

在 Supabase 控制台 → SQL Editor 中**依次**执行：

1. 粘贴 `01_schema.sql` 全部内容 → 点击 Run
2. 粘贴 `02_triggers.sql` 全部内容 → 点击 Run
3. 粘贴 `03_rls.sql` 全部内容 → 点击 Run

> ⚠️ 必须按顺序执行，不可跳过

### 1.3 创建 Storage Bucket

在 Supabase 控制台 → Storage → New bucket：
- Bucket name: `attachments`
- Public bucket: ✅（凭证文件需要公开访问）

---

## 第二步：创建飞书企业自建应用

### 2.1 进入飞书开放平台

访问 [open.feishu.cn](https://open.feishu.cn) → 开发者后台 → 创建企业自建应用

填写信息：
- 应用名称：**股东记账系统**
- 应用描述：小公司内部收支记账与股东对账

### 2.2 获取凭证

进入应用 → **凭证与基础信息**，记录：
- `App ID`（格式：cli_xxxxxxxxxxxxxxxx）
- `App Secret`

### 2.3 配置权限

进入 **权限管理** → 开通以下权限：
- `contact:user.base:readonly`（获取用户基本信息）
- `authen`（用户身份验证/免登）

### 2.4 配置重定向 URL（H5免登）

进入 **安全设置** → 重定向URL，添加你的部署域名：
```
https://your-app.vercel.app
```

---

## 第三步：部署 Edge Function（飞书免登后端）

### 3.1 安装 Supabase CLI

```bash
npm install -g supabase
supabase login
```

### 3.2 初始化并部署

```bash
cd D:\WORKBUDDY\shareholder-accounting
supabase init
supabase link --project-ref YOUR_PROJECT_REF
```

### 3.3 配置环境变量

```bash
supabase secrets set FEISHU_APP_ID=cli_xxxxxxxxxxxxxxxx
supabase secrets set FEISHU_APP_SECRET=your_app_secret
```

### 3.4 部署函数

```bash
supabase functions deploy feishu-auth
```

部署成功后会返回函数 URL，格式：
```
https://YOUR_PROJECT.supabase.co/functions/v1/feishu-auth
```

---

## 第四步：部署前端到 Vercel

### 4.1 修改 index.html 配置项

打开 `index.html`，找到顶部配置区，替换三个值：

```javascript
const SUPABASE_URL  = 'https://YOUR_PROJECT.supabase.co';  // 替换
const SUPABASE_ANON = 'YOUR_ANON_KEY';                     // 替换
const FEISHU_APP_ID = 'cli_xxxxxxxxxxxxxxxx';              // 替换
```

### 4.2 Vercel 部署（推荐）

**方法A：拖拽部署**
1. 访问 [vercel.com](https://vercel.com) → 注册/登录
2. 点击 **Add New → Project**
3. 将 `D:\WORKBUDDY\shareholder-accounting\` 文件夹拖入（或 Import Git Repo）
4. 部署成功后获得域名，如 `https://shareholder-accounting.vercel.app`

**方法B：命令行部署**
```bash
npm install -g vercel
cd D:\WORKBUDDY\shareholder-accounting
vercel --prod
```

> 💡 Vercel 免费套餐完全够用，无需信用卡

---

## 第五步：配置飞书工作台

### 5.1 设置 H5 应用链接

在飞书开放平台 → 你的应用 → **应用功能** → 网页应用：

填写：
- **桌面端主页 URL**：`https://shareholder-accounting.vercel.app`
- **移动端主页 URL**：`https://shareholder-accounting.vercel.app`
- **PC端自适应**：勾选

### 5.2 配置 JSBridge（飞书免登）

在应用 → **安全设置** → H5 可信域名，添加：
```
shareholder-accounting.vercel.app
```

### 5.3 发布应用

1. 进入应用 → **版本管理与发布** → 创建版本
2. 填写版本号（如 1.0.0）和更新说明
3. 点击申请发布（企业自建应用无需审核，直接发布）
4. 进入 **工作台** → 应用管理，将应用添加到工作台

### 5.4 添加用户

在应用 → **成员管理** → 添加三位股东的飞书账号

---

## 第六步：初始化业务数据

### 6.1 添加账户

首次打开应用后：
1. 点击底部「余额」或侧边栏「账户余额」
2. 点击「新增账户」，依次添加：
   - 对公账户（填入实际余额）
   - 库存现金（填入实际余额）
   - 支付宝（填入实际余额）

### 6.2 注册用户

三位股东分别在飞书客户端打开应用，系统自动通过飞书账号完成注册。
首次登录后均默认为「股东记账员」角色。

---

## 每月账期锁定流程

| 时间 | 触发者 | 动作 |
|------|--------|------|
| 每月1日打开应用 | 任意一人 | 系统自动检测并发起上月锁定审批 |
| 收到审批通知 | 全体股东 | 在「审批中心」查看并投票 |
| 2票同意 | 系统 | 自动将上月所有记录锁定 |
| 有异议 | 有异议的股东 | 拒绝审批，线下沟通后重新发起 |

---

## 未来：加入专职财务后的角色切换

1. 打开应用 → 侧边栏「角色配置」
2. 将财务人员的飞书账号注册后，角色设为「财务记账员」
3. 将三位股东的角色从「股东记账员」改为「股东查看者」
4. 完成！财务负责录入，股东只读并参与审批

---

## 常见问题

**Q：非飞书环境能否使用？**
A：可以。用浏览器直接打开 Vercel URL，系统会进入开发模式（使用数据库第一个用户），适合电脑端浏览器临时使用。生产环境建议在飞书内打开。

**Q：附件上传失败？**
A：检查 Supabase Storage 的 `attachments` bucket 是否为 Public，以及 Storage Policy 是否允许写入。

**Q：余额计算不对？**
A：检查 `02_triggers.sql` 中的 `trg_update_balance` 触发器是否成功创建（在 Supabase 控制台 → Database → Functions 查看）。

**Q：账期锁定审批没有自动发起？**
A：当前逻辑是「每月1日首次打开应用时」触发。若三人都没在1日打开，可手动在「审批中心」页面下拉刷新，或配置 Supabase Cron Job（见下方高级配置）。

---

## 高级配置：Supabase Cron Job（可选）

在 Supabase SQL Editor 执行以下脚本，实现每月1日9:00自动触发账期锁定：

```sql
-- 需要先启用 pg_cron 扩展
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- 每月1日09:00执行
SELECT cron.schedule(
  'monthly-period-lock',
  '0 9 1 * *',
  $$
    SELECT public.trigger_period_lock(
      TO_CHAR(NOW() - INTERVAL '1 month', 'YYYY-MM'),
      NULL,
      'SYSTEM'
    );
  $$
);
```

> 注：Supabase pg_cron 在 Pro 计划及以上支持。免费计划可忽略，用手动触发代替。
