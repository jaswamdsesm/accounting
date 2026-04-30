// Supabase Edge Function：飞书免登鉴权
// 文件位置：supabase/functions/feishu-auth/index.ts
// 部署命令：supabase functions deploy feishu-auth

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const FEISHU_APP_ID     = Deno.env.get('FEISHU_APP_ID')!
const FEISHU_APP_SECRET = Deno.env.get('FEISHU_APP_SECRET')!
const SUPABASE_URL      = Deno.env.get('SUPABASE_URL')!
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

serve(async (req) => {
  const corsHeaders = {
    'Access-Control-Allow-Origin':  '*',
    'Access-Control-Allow-Headers': 'authorization, content-type',
  }

  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { code } = await req.json()

    // Step1: 获取 app_access_token
    const tokenRes = await fetch(
      'https://open.feishu.cn/open-apis/auth/v3/app_access_token/internal',
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ app_id: FEISHU_APP_ID, app_secret: FEISHU_APP_SECRET }),
      }
    )
    const tokenData = await tokenRes.json()
    const appAccessToken = tokenData.app_access_token

    // Step2: code 换取用户 access_token
    const userTokenRes = await fetch(
      'https://open.feishu.cn/open-apis/authen/v1/access_token',
      {
        method: 'POST',
        headers: {
          'Content-Type':  'application/json',
          'Authorization': `Bearer ${appAccessToken}`,
        },
        body: JSON.stringify({ grant_type: 'authorization_code', code }),
      }
    )
    const userTokenData = await userTokenRes.json()
    const { access_token, open_id, name } = userTokenData.data

    // Step3: 在 app_users 表里查找或创建用户
    const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY)

    let { data: user, error } = await sb
      .from('app_users')
      .select('*')
      .eq('feishu_uid', open_id)
      .single()

    if (!user) {
      // 首次登录，自动注册
      const { data: newUser } = await sb
        .from('app_users')
        .insert({ feishu_uid: open_id, name, role: 'shareholder_bookkeeper' })
        .select()
        .single()
      user = newUser
    }

    return new Response(
      JSON.stringify({ user, feishu_access_token: access_token }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  } catch (err) {
    return new Response(
      JSON.stringify({ error: err.message }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
    )
  }
})
