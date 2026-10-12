-- =====================================================================
-- AI 工作台 · 数据库初始化脚本
-- 适用环境：腾讯云开发 CloudBase「SQL 型数据库（PostgreSQL）」
-- 使用方法：控制台 → SQL 型数据库 → SQL 编辑器，整段粘贴执行
-- 说明：auth.uid() 为平台内置函数（开启匿名登录后返回当前用户 ID）
-- 校准状态：全部 5 张表、约束与 4 个函数已按线上实例 DDL 逐字校准
--           （2026-10-12，来源：information_schema / pg_constraint /
--           pg_get_functiondef 实测结果）
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. 私有 schema（存放幂等请求表与变更历史表，不暴露给 REST API）
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS awb_private;

-- ---------------------------------------------------------------------
-- 1. 工作空间表：一个 id 对应一个独立的工作台
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.awb_workspaces (
  id       text PRIMARY KEY,
  name     text NOT NULL,
  revision bigint NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------------
-- 2. 成员表：owner 可管成员，editor 可改数据，viewer 只读
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.awb_members (
  workspace_id text NOT NULL REFERENCES public.awb_workspaces(id),
  user_id      text NOT NULL,
  display_name text NOT NULL DEFAULT '',
  role         text NOT NULL
    CONSTRAINT awb_members_role_check
    CHECK (role IN ('owner','editor','viewer')),
  enabled      boolean NOT NULL DEFAULT true,
  PRIMARY KEY (workspace_id, user_id)
);

-- ---------------------------------------------------------------------
-- 3. 记录表：任务 / 需求池 / 提醒 / 设置 / 附件统一存这里
--    软删除（deleted=true 进回收站）+ 乐观锁（version）
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.awb_records (
  workspace_id text NOT NULL REFERENCES public.awb_workspaces(id),
  kind         text NOT NULL
    CONSTRAINT awb_records_kind_check
    CHECK (kind IN ('tasks','raws','reminders','settings','attachments')),
  id           text NOT NULL,
  data         jsonb NOT NULL
    CONSTRAINT awb_records_data_check
    CHECK (jsonb_typeof(data) = 'object'),
  version      bigint NOT NULL DEFAULT 1,
  deleted      boolean NOT NULL DEFAULT false,
  updated_at   timestamp with time zone NOT NULL DEFAULT now(),
  updated_by   text,
  PRIMARY KEY (workspace_id, kind, id)
);

-- ---------------------------------------------------------------------
-- 4. 幂等请求表：同一 request_id 重复提交直接返回上次结果，不重复执行
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS awb_private.requests (
  workspace_id text NOT NULL,
  user_id      text NOT NULL,
  request_id   uuid NOT NULL,
  body         jsonb NOT NULL,
  response     jsonb NOT NULL,
  created_at   timestamp with time zone NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, user_id, request_id)
);

-- ---------------------------------------------------------------------
-- 5. 变更历史表：每次 put / delete / restore 自动留痕
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS awb_private.history (
  event_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workspace_id  text NOT NULL,
  kind          text NOT NULL,
  record_id     text NOT NULL,
  actor         text NOT NULL,
  action        text NOT NULL,
  before_record jsonb,
  after_record  jsonb,
  created_at    timestamp with time zone NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 6. 快照函数：拉取全部记录；p_since 与当前 revision 相同时只回 "unchanged"
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.awb_snapshot(p_workspace text, p_since bigint DEFAULT '-1'::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  v_role text;
  v_revision bigint;
  v_uid text := auth.uid();
  v_records jsonb;
BEGIN
  SELECT revision INTO v_revision
  FROM public.awb_workspaces
  WHERE id=p_workspace
  FOR SHARE;

  SELECT role INTO v_role
  FROM public.awb_members
  WHERE workspace_id=p_workspace
    AND user_id=v_uid
    AND enabled;

  IF v_role IS NULL THEN
    RAISE EXCEPTION 'AWB_FORBIDDEN: not a workspace member'
      USING ERRCODE='42501';
  END IF;

  IF p_since=v_revision THEN
    RETURN jsonb_build_object(
      'revision',v_revision,
      'role',v_role,
      'unchanged',true,
      'user_id',v_uid
    );
  END IF;

  SELECT coalesce(
    jsonb_agg(to_jsonb(r) ORDER BY r.kind,r.id),
    '[]'::jsonb
  ) INTO v_records
  FROM public.awb_records r
  WHERE workspace_id=p_workspace;

  RETURN jsonb_build_object(
    'revision',v_revision,
    'role',v_role,
    'records',v_records,
    'user_id',v_uid
  );
END $function$;

-- ---------------------------------------------------------------------
-- 7. 写入函数：批量 put / delete / restore
--    乐观锁 + 幂等 + 服务端校验 + 历史留痕，全部在一个事务里
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.awb_apply(p_workspace text, p_request uuid, p_ops jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  v_uid text := auth.uid();
  v_role text;
  v_revision bigint;
  v_op jsonb;
  v_kind text;
  v_id text;
  v_action text;
  v_expected bigint;
  v_old public.awb_records%ROWTYPE;
  v_new public.awb_records%ROWTYPE;
  v_exists boolean;
  v_response jsonb;
  v_prior_body jsonb;
  v_changed jsonb := '[]'::jsonb;
BEGIN
  SELECT revision INTO v_revision
  FROM public.awb_workspaces
  WHERE id=p_workspace
  FOR UPDATE;

  SELECT role INTO v_role
  FROM public.awb_members
  WHERE workspace_id=p_workspace
    AND user_id=v_uid
    AND enabled;

  IF v_role IS NULL OR v_role NOT IN ('owner','editor') THEN
    RAISE EXCEPTION 'AWB_FORBIDDEN: edit permission required'
      USING ERRCODE='42501';
  END IF;

  SELECT body,response INTO v_prior_body,v_response
  FROM awb_private.requests
  WHERE workspace_id=p_workspace
    AND user_id=v_uid
    AND request_id=p_request;

  IF FOUND THEN
    IF v_prior_body IS DISTINCT FROM p_ops THEN
      RAISE EXCEPTION 'AWB_INVALID: request ID reused';
    END IF;
    RETURN v_response;
  END IF;

  IF jsonb_typeof(p_ops) IS DISTINCT FROM 'array'
    OR jsonb_array_length(p_ops)<1
    OR jsonb_array_length(p_ops)>1100 THEN
    RAISE EXCEPTION 'AWB_INVALID: operation count';
  END IF;

  IF EXISTS(
    SELECT 1
    FROM jsonb_array_elements(p_ops) o
    GROUP BY o->>'kind',o->>'id'
    HAVING count(*)>1
  ) THEN
    RAISE EXCEPTION 'AWB_INVALID: duplicate record in batch';
  END IF;

  FOR v_op IN SELECT value FROM jsonb_array_elements(p_ops) LOOP
    v_kind:=v_op->>'kind';
    v_id:=v_op->>'id';
    v_action:=v_op->>'action';

    IF v_kind IS NULL
      OR v_kind NOT IN ('tasks','raws','reminders','settings','attachments')
      OR v_id IS NULL
      OR v_id !~ '^[A-Za-z0-9_:.\-]{1,120}$'
      OR v_action IS NULL
      OR v_action NOT IN ('put','delete','restore')
      OR (v_op->>'expected') IS NULL
      OR (v_op->>'expected') !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'AWB_INVALID: invalid operation';
    END IF;

    v_expected:=(v_op->>'expected')::bigint;

    IF v_kind='settings'
      AND (v_id NOT IN ('meta','projects','note') OR v_action<>'put') THEN
      RAISE EXCEPTION 'AWB_INVALID: protected setting';
    END IF;

    SELECT * INTO v_old
    FROM public.awb_records
    WHERE workspace_id=p_workspace
      AND kind=v_kind
      AND id=v_id
    FOR UPDATE;

    v_exists:=FOUND;

    IF (v_exists AND v_old.version<>v_expected)
      OR (NOT v_exists AND v_expected<>0) THEN
      RAISE EXCEPTION 'AWB_CONFLICT: %/% changed on another device',
        v_kind,v_id USING ERRCODE='P0001';
    END IF;

    IF v_action='put' THEN
      IF v_exists AND v_old.deleted THEN
        RAISE EXCEPTION 'AWB_CONFLICT: record is in recycle bin';
      END IF;

      IF jsonb_typeof(v_op->'data') IS DISTINCT FROM 'object'
        OR octet_length((v_op->'data')::text)>262144 THEN
        RAISE EXCEPTION 'AWB_INVALID: invalid record body';
      END IF;

      IF v_kind<>'settings'
        AND (v_op->'data'->>'id') IS DISTINCT FROM v_id THEN
        RAISE EXCEPTION 'AWB_INVALID: record ID mismatch';
      END IF;

      IF v_kind='tasks'
        AND (
          coalesce(length(btrim(v_op->'data'->>'title')),0)=0
          OR coalesce(v_op->'data'->>'status','')
            NOT IN ('todo','doing','wait','done')
        ) THEN
        RAISE EXCEPTION 'AWB_INVALID: title or task status';
      END IF;

      IF v_kind='tasks' AND EXISTS(
        SELECT 1
        FROM jsonb_each(v_op->'data') f
        WHERE f.key IN (
          'title','project','owner','type','source','fact',
          'description','next','waiting','priority','link',
          'due','follow'
        )
        AND jsonb_typeof(f.value)<>'string'
      ) THEN
        RAISE EXCEPTION 'AWB_INVALID: task text field type';
      END IF;

      IF v_kind IN ('tasks','reminders') AND EXISTS(
        SELECT 1
        FROM jsonb_each(v_op->'data') f
        WHERE f.key IN ('due','follow','date')
          AND f.value#>>'{}'<>''
          AND (f.value#>>'{}') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
      ) THEN
        RAISE EXCEPTION 'AWB_INVALID: date field';
      END IF;

      IF v_kind='settings' AND v_id='note'
        AND jsonb_typeof(v_op->'data'->'value') IS DISTINCT FROM 'string' THEN
        RAISE EXCEPTION 'AWB_INVALID: note';
      END IF;

      IF v_kind='settings' AND v_id='projects' THEN
        IF jsonb_typeof(v_op->'data'->'items') IS DISTINCT FROM 'array' THEN
          RAISE EXCEPTION 'AWB_INVALID: projects';
        END IF;

        IF EXISTS(
          SELECT 1
          FROM jsonb_array_elements(v_op->'data'->'items') f
          WHERE jsonb_typeof(f)<>'string'
        ) THEN
          RAISE EXCEPTION 'AWB_INVALID: project name';
        END IF;
      END IF;

      INSERT INTO public.awb_records(
        workspace_id,kind,id,data,version,updated_by
      )
      VALUES(p_workspace,v_kind,v_id,v_op->'data',1,v_uid)
      ON CONFLICT(workspace_id,kind,id) DO UPDATE
      SET data=EXCLUDED.data,
          version=awb_records.version+1,
          updated_at=now(),
          updated_by=v_uid
      RETURNING * INTO v_new;
    ELSE
      IF NOT v_exists
        OR (v_action='restore' AND NOT v_old.deleted)
        OR (v_action='delete' AND v_old.deleted) THEN
        RAISE EXCEPTION 'AWB_CONFLICT: deletion state changed';
      END IF;

      UPDATE public.awb_records
      SET deleted=(v_action='delete'),
          version=version+1,
          updated_at=now(),
          updated_by=v_uid
      WHERE workspace_id=p_workspace
        AND kind=v_kind
        AND id=v_id
      RETURNING * INTO v_new;
    END IF;

    INSERT INTO awb_private.history(
      workspace_id,kind,record_id,actor,action,before_record,after_record
    )
    VALUES(
      p_workspace,v_kind,v_id,v_uid,v_action,
      CASE WHEN v_exists THEN to_jsonb(v_old) END,
      to_jsonb(v_new)
    );

    v_changed:=v_changed||jsonb_build_array(to_jsonb(v_new));
  END LOOP;

  UPDATE public.awb_workspaces
  SET revision=revision+1
  WHERE id=p_workspace
  RETURNING revision INTO v_revision;

  v_response:=jsonb_build_object(
    'revision',v_revision,
    'records',v_changed
  );

  INSERT INTO awb_private.requests(
    workspace_id,user_id,request_id,body,response
  )
  VALUES(p_workspace,v_uid,p_request,p_ops,v_response);

  RETURN v_response;
END $function$;

-- ---------------------------------------------------------------------
-- 8. 成员列表（仅 owner 可查）
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.awb_members_list(p_workspace text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
  IF NOT EXISTS(
    SELECT 1 FROM public.awb_members
    WHERE workspace_id=p_workspace
      AND user_id=auth.uid()
      AND enabled AND role='owner'
  ) THEN
    RAISE EXCEPTION 'AWB_FORBIDDEN: owner required'
      USING ERRCODE='42501';
  END IF;

  RETURN (
    SELECT coalesce(
      jsonb_agg(to_jsonb(m) ORDER BY m.display_name),
      '[]'::jsonb
    )
    FROM public.awb_members m
    WHERE workspace_id=p_workspace
  );
END $function$;

-- ---------------------------------------------------------------------
-- 9. 成员管理（仅 owner；不能通过本函数改动另一位 owner）
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.awb_member_set(p_workspace text, p_user text, p_name text, p_role text, p_enabled boolean)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
BEGIN
  PERFORM 1 FROM public.awb_workspaces
  WHERE id=p_workspace FOR UPDATE;

  IF NOT EXISTS(
    SELECT 1 FROM public.awb_members
    WHERE workspace_id=p_workspace
      AND user_id=auth.uid()
      AND enabled AND role='owner'
  ) THEN
    RAISE EXCEPTION 'AWB_FORBIDDEN: owner required'
      USING ERRCODE='42501';
  END IF;

  IF p_user=auth.uid()
    OR p_role IS NULL
    OR p_role NOT IN ('editor','viewer')
    OR p_enabled IS NULL
    OR coalesce(length(p_user),0) NOT BETWEEN 1 AND 64
    OR coalesce(length(p_name),0)>80 THEN
    RAISE EXCEPTION 'AWB_INVALID: invalid member';
  END IF;

  IF EXISTS(
    SELECT 1 FROM public.awb_members
    WHERE workspace_id=p_workspace
      AND user_id=p_user AND role='owner'
  ) THEN
    RAISE EXCEPTION 'AWB_INVALID: cannot modify another owner here';
  END IF;

  INSERT INTO public.awb_members(
    workspace_id,user_id,display_name,role,enabled
  )
  VALUES(
    p_workspace,p_user,coalesce(p_name,''),p_role,p_enabled
  )
  ON CONFLICT(workspace_id,user_id) DO UPDATE
  SET display_name=EXCLUDED.display_name,
      role=EXCLUDED.role,
      enabled=EXCLUDED.enabled;

  UPDATE public.awb_workspaces
  SET revision=revision+1
  WHERE id=p_workspace;
END $function$;

-- =====================================================================
-- 初始化你的第一个工作空间（建库后必做，否则页面无法写入）
-- 1) 先在 CloudBase 控制台开启「身份认证 → 匿名登录」，打开一次网页完成登录
-- 2) 到「身份认证 → 用户管理」复制你的用户 ID，替换下面 <你的用户ID>
-- 3) 取消注释后在 SQL 编辑器执行
-- =====================================================================
-- INSERT INTO public.awb_workspaces(id,name) VALUES('main','我的工作台');
-- INSERT INTO public.awb_members(workspace_id,user_id,display_name,role,enabled)
-- VALUES('main','<你的用户ID>','管理员','owner',true);
