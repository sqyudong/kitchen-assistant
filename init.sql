 -- ============================================================
 -- 食材管理 - Supabase 建表脚本
 -- 在 Supabase SQL Editor 中完整执行
 -- ============================================================
 
 -- 扩展
 create extension if not exists "pgcrypto";
 
 -- ============================================================
 -- 1. accounts - 用户账号
 -- ============================================================
 create table if not exists accounts (
   id uuid default gen_random_uuid() primary key,
   username text unique not null,
   password text not null,
   role text not null default 'user' check (role in ('user', 'admin')),
   created_at timestamptz default now()
 );
 
 -- ============================================================
 -- 2. warehouses - 仓库
 -- ============================================================
 create table if not exists warehouses (
   id uuid default gen_random_uuid() primary key,
   name text not null,
   owner_id uuid references accounts(id) not null,
   created_at timestamptz default now()
 );
 
 -- ============================================================
 -- 3. warehouse_members - 仓库成员关系
 -- ============================================================
 create table if not exists warehouse_members (
   id uuid default gen_random_uuid() primary key,
   warehouse_id uuid references warehouses(id) on delete cascade not null,
   user_id uuid references accounts(id) on delete cascade not null,
   role text not null check (role in ('owner', 'staff')),
   unique(warehouse_id, user_id)
 );
 create index if not exists idx_wm_warehouse on warehouse_members(warehouse_id);
 create index if not exists idx_wm_user on warehouse_members(user_id);
 
 -- ============================================================
 -- 4. locations - 位置（常温/冷藏/冷冻）
 -- ============================================================
 create table if not exists locations (
   id uuid default gen_random_uuid() primary key,
   warehouse_id uuid references warehouses(id) on delete cascade not null,
   name text not null,
   type text not null check (type in ('常温', '冷藏', '冷冻')),
   unique(warehouse_id, name)
 );
 create index if not exists idx_locations_warehouse on locations(warehouse_id);
 
 -- ============================================================
 -- 5. inventory - 库存
 -- ============================================================
 create table if not exists inventory (
   id uuid default gen_random_uuid() primary key,
   warehouse_id uuid references warehouses(id) on delete cascade not null,
   name text not null,
   qty text not null,
   location_id uuid references locations(id) on delete set null,
   warning boolean default false,
   created_at timestamptz default now()
 );
 create index if not exists idx_inventory_warehouse on inventory(warehouse_id);
 
 -- ============================================================
 -- 6. recipes - 菜谱
 -- ============================================================
 create table if not exists recipes (
   id uuid default gen_random_uuid() primary key,
   warehouse_id uuid references warehouses(id) on delete cascade not null,
   name text not null,
   ingredients jsonb default '[]'::jsonb,
   steps text default '',
   created_at timestamptz default now()
 );
 create index if not exists idx_recipes_warehouse on recipes(warehouse_id);
 
 -- ============================================================
 -- 7. logs - 操作日志
 -- ============================================================
 create table if not exists logs (
   id uuid default gen_random_uuid() primary key,
   warehouse_id uuid references warehouses(id) on delete cascade not null,
   user_id uuid references accounts(id) on delete set null,
   action text not null,
   detail text default '',
   log_type text default 'info',
   created_at timestamptz default now()
 );
 create index if not exists idx_logs_warehouse on logs(warehouse_id);
 create index if not exists idx_logs_created on logs(created_at desc);
 
 -- ============================================================
 -- RPC: delete_warehouse_cascade - 级联删除仓库
 -- ============================================================
 create or replace function delete_warehouse_cascade(p_warehouse_id uuid, p_user_id uuid)
 returns void
 language plpgsql
 security definer
 as $$
 begin
   -- 权限检查：必须是仓库 owner 或系统 admin
   if not exists (
     select 1 from warehouse_members
     where warehouse_id = p_warehouse_id
       and user_id = p_user_id
       and role = 'owner'
   ) and not exists (
     select 1 from accounts
     where id = p_user_id and role = 'admin'
   ) then
     raise exception '无权限删除此仓库';
   end if;
   delete from warehouses where id = p_warehouse_id;
 end;
 $$;
 
 -- ============================================================
 -- RPC: delete_user_cascade - 级联删除用户（仅 admin）
 -- ============================================================
 create or replace function delete_user_cascade(p_admin_id uuid, p_target_id uuid)
 returns void
 language plpgsql
 security definer
 as $$
 begin
   if not exists (select 1 from accounts where id = p_admin_id and role = 'admin') then
     raise exception '仅管理员可删除用户';
   end if;
   delete from accounts where id = p_target_id;
 end;
 $$;
 
 -- ============================================================
 -- RPC: transfer_ownership - 转让仓库所有权
 -- ============================================================
 create or replace function transfer_ownership(p_warehouse_id uuid, p_owner_id uuid, p_new_owner_id uuid)
 returns void
 language plpgsql
 security definer
 as $$
 begin
   -- 验证当前 owner
   if not exists (
     select 1 from warehouse_members
     where warehouse_id = p_warehouse_id
       and user_id = p_owner_id
       and role = 'owner'
   ) and not exists (
     select 1 from accounts where id = p_owner_id and role = 'admin'
   ) then
     raise exception '无权限转让所有权';
   end if;
   -- 新 owner 必须是仓库成员
   if not exists (
     select 1 from warehouse_members
     where warehouse_id = p_warehouse_id and user_id = p_new_owner_id
   ) then
     raise exception '新老板必须是仓库成员';
   end if;
   -- 旧 owner -> staff
   update warehouse_members set role = 'staff'
   where warehouse_id = p_warehouse_id and user_id = p_owner_id;
   -- 新 owner -> owner
   update warehouse_members set role = 'owner'
   where warehouse_id = p_warehouse_id and user_id = p_new_owner_id;
   -- 更新 warehouses 表的 owner_id
   update warehouses set owner_id = p_new_owner_id where id = p_warehouse_id;
 end;
 $$;
 
 -- ============================================================
 -- RPC: create_warehouse - 创建仓库（含默认位置）
 -- ============================================================
 create or replace function create_warehouse(p_name text, p_user_id uuid)
 returns uuid
 language plpgsql
 security definer
 as $$
 declare
   v_warehouse_id uuid;
 begin
   insert into warehouses (name, owner_id) values (p_name, p_user_id)
   returning id into v_warehouse_id;
   insert into warehouse_members (warehouse_id, user_id, role)
   values (v_warehouse_id, p_user_id, 'owner');
   -- 默认4个位置
   insert into locations (warehouse_id, name, type) values
     (v_warehouse_id, '常温货架', '常温'),
     (v_warehouse_id, '冰箱冷藏', '冷藏'),
     (v_warehouse_id, '冰箱冷冻', '冷冻'),
     (v_warehouse_id, '调料柜', '常温');
   return v_warehouse_id;
 end;
 $$;
 
 -- ============================================================
 -- RPC: add_member - 添加仓库成员
 -- ============================================================
 create or replace function add_member(p_warehouse_id uuid, p_username text, p_operator_id uuid)
 returns text
 language plpgsql
 security definer
 as $$
 declare
   v_target_id uuid;
 begin
   -- 权限检查
   if not exists (
     select 1 from warehouse_members
     where warehouse_id = p_warehouse_id
       and user_id = p_operator_id
       and role = 'owner'
   ) and not exists (
     select 1 from accounts where id = p_operator_id and role = 'admin'
   ) then
     return '无权限';
   end if;
   -- 查找目标用户
   select id into v_target_id from accounts where username = p_username;
   if v_target_id is null then
     return '用户不存在';
   end if;
   -- 检查是否已是成员
   if exists (
     select 1 from warehouse_members
     where warehouse_id = p_warehouse_id and user_id = v_target_id
   ) then
     return '已是成员';
   end if;
   insert into warehouse_members (warehouse_id, user_id, role)
   values (p_warehouse_id, v_target_id, 'staff');
   return 'ok';
 end;
 $$;
 
 -- ============================================================
 -- RLS: 行级安全策略
 -- 注意：这里使用宽松的 RLS，实际权限控制由前端 JS + RPC 函数保障
 -- 生产环境建议集成 Supabase Auth 替换
 -- ============================================================
 
 alter table accounts enable row level security;
 alter table warehouses enable row level security;
 alter table warehouse_members enable row level security;
 alter table locations enable row level security;
 alter table inventory enable row level security;
 alter table recipes enable row level security;
 alter table logs enable row level security;
 
 -- accounts: 注册公开，查询/更新需身份
 drop policy if exists "accounts_select" on accounts;
 create policy "accounts_select" on accounts for select using (true);
 drop policy if exists "accounts_insert" on accounts;
 create policy "accounts_insert" on accounts for insert with check (true);
 drop policy if exists "accounts_update" on accounts;
 create policy "accounts_update" on accounts for update using (true);
 drop policy if exists "accounts_delete" on accounts;
 create policy "accounts_delete" on accounts for delete using (true);
 
 -- warehouses: 通过 warehouse_members 或 admin 可查看
 drop policy if exists "warehouses_select" on warehouses;
 create policy "warehouses_select" on warehouses for select using (true);
 drop policy if exists "warehouses_insert" on warehouses;
 create policy "warehouses_insert" on warehouses for insert with check (true);
 drop policy if exists "warehouses_update" on warehouses;
 create policy "warehouses_update" on warehouses for update using (true);
 drop policy if exists "warehouses_delete" on warehouses;
 create policy "warehouses_delete" on warehouses for delete using (true);
 
 -- warehouse_members
 drop policy if exists "wm_select" on warehouse_members;
 create policy "wm_select" on warehouse_members for select using (true);
 drop policy if exists "wm_insert" on warehouse_members;
 create policy "wm_insert" on warehouse_members for insert with check (true);
 drop policy if exists "wm_update" on warehouse_members;
 create policy "wm_update" on warehouse_members for update using (true);
 drop policy if exists "wm_delete" on warehouse_members;
 create policy "wm_delete" on warehouse_members for delete using (true);
 
 -- locations / inventory / recipes / logs: 仓库成员可操作
 drop policy if exists "locations_access" on locations;
 create policy "locations_access" on locations for all using (true);
 drop policy if exists "inventory_access" on inventory;
 create policy "inventory_access" on inventory for all using (true);
 drop policy if exists "recipes_access" on recipes;
 create policy "recipes_access" on recipes for all using (true);
 drop policy if exists "logs_access" on logs;
 create policy "logs_access" on logs for all using (true);
 
 -- ============================================================
 -- 初始化管理员（可选：取消注释以创建默认管理员）
 -- 用户名: admin, 密码: admin123
 -- ============================================================
 -- insert into accounts (username, password, role) values ('admin', 'admin123', 'admin');
