-- =====================================================================
-- 12: الذمم المدينة والتحصيل
--  - الذمة = فاتورة أو إشعار مدين بطريقة دفع «آجل»؛ غيرها يُعد مسدداً عند الإصدار
--  - المتبقي = الإجمالي − الإشعارات الدائنة المرتبطة − الدفعات المطبّقة (غير الملغاة)
--  - سند القبض لا يُعدَّل ولا يُحذف؛ يُلغى بسبب مكتوب ويبقى أثره
--  - لا يمس الفواتير الصادرة ولا بصمتها
-- =====================================================================

-- ---------------------------------------------------------------- إعدادات وحقول العميل
alter table public.customers add column credit_limit numeric(14,2) check (credit_limit >= 0);
alter table public.customers add column payment_terms_days int not null default 30 check (payment_terms_days between 0 and 365);

create table public.finance_settings (
  id                   int primary key default 1 check (id = 1),
  default_terms_days   int not null default 30 check (default_terms_days between 0 and 365),
  enforce_credit_limit boolean not null default true,
  updated_at           timestamptz not null default now(),
  updated_by           uuid references auth.users(id)
);
insert into public.finance_settings default values;

-- ---------------------------------------------------------------- الاستحقاق
create table public.invoice_terms (
  invoice_id uuid primary key references public.invoices(id),
  terms_days int  not null check (terms_days between 0 and 3650),
  due_date   date not null,
  set_by     uuid references auth.users(id),
  set_at     timestamptz not null default now()
);
create index invoice_terms_due_idx on public.invoice_terms (due_date);

-- ---------------------------------------------------------------- سندات القبض وتطبيقها
create table public.payments (
  id          uuid primary key default gen_random_uuid(),
  number      text not null unique,
  customer_id uuid not null references public.customers(id),
  received_on date not null,
  amount      numeric(14,2) not null check (amount > 0),
  method      text not null check (method in ('نقدي','تحويل بنكي','شبكة / مدى','شيك')),
  reference   text check (length(reference) <= 80),
  notes       text check (length(notes) <= 300),
  branch_id   uuid references public.branches(id),
  created_by  uuid not null references auth.users(id),
  created_at  timestamptz not null default now(),
  voided_at   timestamptz,
  voided_by   uuid references auth.users(id),
  void_reason text check (length(void_reason) <= 300)
);
create index payments_customer_idx on public.payments (customer_id, received_on);
create index payments_created_by_idx on public.payments (created_by);

create table public.payment_allocations (
  id         bigint generated always as identity primary key,
  payment_id uuid not null references public.payments(id),
  invoice_id uuid not null references public.invoices(id),
  amount     numeric(14,2) not null check (amount > 0),
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);
create index payment_allocations_payment_idx on public.payment_allocations (payment_id);
create index payment_allocations_invoice_idx on public.payment_allocations (invoice_id);

-- حماية: التطبيقات لا تُعدَّل، والسند لا يُحذف ولا يتغير إلا بإلغائه مرة واحدة
create or replace function private.block_mutation() returns trigger language plpgsql set search_path = '' as $$
begin raise exception 'هذا السجل المالي لا يمكن تعديله أو حذفه'; end $$;
create or replace function private.payment_guard() returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'DELETE' then raise exception 'لا يمكن حذف سند قبض؛ استخدم الإلغاء'; end if;
  if old.voided_at is not null then raise exception 'السند ملغى مسبقاً'; end if;
  if (to_jsonb(new) - 'voided_at' - 'voided_by' - 'void_reason') <> (to_jsonb(old) - 'voided_at' - 'voided_by' - 'void_reason') then
    raise exception 'لا يمكن تعديل سند القبض؛ ألغه وأصدر سنداً جديداً'; end if;
  return new;
end $$;
create trigger payments_guard before update or delete on public.payments for each row execute function private.payment_guard();
create trigger payments_no_truncate before truncate on public.payments for each statement execute function private.block_mutation();
create trigger payment_allocations_immutable before update or delete on public.payment_allocations for each row execute function private.block_mutation();
create trigger payment_allocations_no_truncate before truncate on public.payment_allocations for each statement execute function private.block_mutation();

do $$
declare t text;
begin
  foreach t in array array['finance_settings','invoice_terms','payments','payment_allocations'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke insert, update, delete, truncate, references, trigger on public.%I from authenticated', t);
    execute format('create policy %I on public.%I for select to authenticated using ((select private.my_role()) is not null)', t||'_read', t);
  end loop;
end $$;

-- ---------------------------------------------------------------- أدوات داخلية
create or replace function private.today() returns date language sql stable set search_path = '' as $$
  select (now() at time zone 'Asia/Riyadh')::date $$;

/* عميل المستند: من لقطة الإصدار، ثم الربط القديم، ثم عميل الفاتورة الأصلية (للإشعارات) */
create or replace function private.doc_customer(p_invoice uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select customer_id from public.invoice_buyer_ids where invoice_id = i.id),
    (select customer_id from public.invoice_customer where invoice_id = i.id),
    (select customer_id from public.invoice_buyer_ids where invoice_id = i.ref_invoice_id),
    (select customer_id from public.invoice_customer where invoice_id = i.ref_invoice_id))
  from public.invoices i where i.id = p_invoice
$$;

/* بنود الذمم كما هي في تاريخ معيّن */
create or replace function private.ar_items(p_as_of date)
returns table (invoice_id uuid, customer_id uuid, number text, doc_type text, buyer_name text, branch_id uuid,
               issued_on date, due_date date, total numeric, credited numeric, paid numeric, outstanding numeric, days_overdue int)
language sql stable security definer set search_path = '' as $$
  with docs as (
    select i.id, private.doc_customer(i.id) as customer_id, i.number, i.doc_type, i.buyer_name,
           coalesce(ib.branch_id, (select id from public.branches where is_main limit 1)) as branch_id,
           (i.issued_at at time zone 'Asia/Riyadh')::date as issued_on, t.due_date, i.total
    from public.invoices i
    join public.invoice_terms t on t.invoice_id = i.id
    left join public.invoice_branch ib on ib.invoice_id = i.id
    where i.doc_type in ('invoice','debit_note') and i.payment_method = 'آجل'
      and (i.issued_at at time zone 'Asia/Riyadh')::date <= p_as_of)
  select d.id, d.customer_id, d.number, d.doc_type, d.buyer_name, d.branch_id, d.issued_on, d.due_date, d.total,
         cr.amt, pa.amt, d.total - cr.amt - pa.amt, greatest(p_as_of - d.due_date, 0)
  from docs d
  cross join lateral (select coalesce(sum(c.total), 0) as amt from public.invoices c
                      where c.ref_invoice_id = d.id and c.doc_type = 'credit_note' and (c.issued_at at time zone 'Asia/Riyadh')::date <= p_as_of) cr
  cross join lateral (select coalesce(sum(a.amount), 0) as amt from public.payment_allocations a join public.payments p on p.id = a.payment_id
                      where a.invoice_id = d.id and p.voided_at is null and p.received_on <= p_as_of) pa
$$;

/* الرصيد الدائن غير المطبّق لعميل (دفعات زادت عن الفواتير) */
create or replace function private.unapplied(p_customer uuid, p_as_of date) returns numeric
language sql stable security definer set search_path = '' as $$
  select coalesce(sum(p.amount - coalesce((select sum(a.amount) from public.payment_allocations a where a.payment_id = p.id), 0)), 0)
  from public.payments p where p.customer_id = p_customer and p.voided_at is null and p.received_on <= p_as_of
$$;

-- ---------------------------------------------------------------- الاستحقاق والحد الائتماني تلقائياً عند الإصدار
create or replace function private.ar_on_invoice() returns trigger
language plpgsql security definer set search_path = '' as $$
declare d int;
begin
  if new.doc_type in ('invoice','debit_note') and new.payment_method = 'آجل' then
    select default_terms_days into d from public.finance_settings where id = 1;
    insert into public.invoice_terms(invoice_id, terms_days, due_date, set_by)
    values (new.id, coalesce(d, 30), (new.issued_at at time zone 'Asia/Riyadh')::date + coalesce(d, 30), new.created_by);
  end if;
  return null;
end $$;
create trigger invoices_ar_terms after insert on public.invoices for each row execute function private.ar_on_invoice();

create or replace function private.ar_on_buyer() returns trigger
language plpgsql security definer set search_path = '' as $$
declare c public.customers; t public.invoice_terms; i public.invoices; v_bal numeric; v_enf boolean;
begin
  if new.customer_id is null then return null; end if;
  select * into t from public.invoice_terms where invoice_id = new.invoice_id;
  if t.invoice_id is null then return null; end if;          -- ليست ذمة (نقدي/شبكة/تحويل)
  select * into c from public.customers where id = new.customer_id;
  select * into i from public.invoices where id = new.invoice_id;
  update public.invoice_terms set terms_days = c.payment_terms_days,
         due_date = (i.issued_at at time zone 'Asia/Riyadh')::date + c.payment_terms_days
   where invoice_id = new.invoice_id;
  select enforce_credit_limit into v_enf from public.finance_settings where id = 1;
  if c.credit_limit is not null and coalesce(v_enf, true) and coalesce(private.my_role(), '') <> 'admin' then
    select coalesce(sum(outstanding), 0) - private.unapplied(c.id, private.today()) into v_bal
      from private.ar_items(private.today()) where customer_id = c.id;
    if v_bal > c.credit_limit then
      raise exception 'تجاوز الحد الائتماني للعميل %: الحد % ريال، والرصيد بعد هذا المستند % ريال. يلزم اعتماد المدير.',
        c.name, to_char(c.credit_limit, 'FM999,999,990.00'), to_char(v_bal, 'FM999,999,990.00');
    end if;
  end if;
  return null;
end $$;
create trigger invoice_buyer_ids_ar after insert on public.invoice_buyer_ids for each row execute function private.ar_on_buyer();

-- مستندات آجلة صدرت قبل هذه المرحلة: استحقاق = تاريخ الإصدار + مدة العميل (أو الافتراضي)
insert into public.invoice_terms(invoice_id, terms_days, due_date)
select i.id, coalesce(c.payment_terms_days, 30), (i.issued_at at time zone 'Asia/Riyadh')::date + coalesce(c.payment_terms_days, 30)
from public.invoices i left join public.customers c on c.id = private.doc_customer(i.id)
where i.doc_type in ('invoice','debit_note') and i.payment_method = 'آجل'
on conflict (invoice_id) do nothing;

-- ---------------------------------------------------------------- ملف العميل: الحد الائتماني ومدة السداد
create or replace function public.save_customer(p jsonb) returns uuid
language plpgsql security definer set search_path = '' as $$
declare v public.customers; v_old public.customers; v_id uuid := nullif(p->>'id','')::uuid;
  f text := 'name,vat_number,cr_number,city,district,street,building_no,postal_code,phone,email,default_kind,code'; k text;
begin
  perform private.require_role(array['admin','issuer']);
  if v_id is not null then
    select * into v_old from public.customers where id = v_id for update;
    if v_old.id is null then raise exception 'العميل غير موجود'; end if;
    v := v_old;
  end if;
  foreach k in array string_to_array(f, ',') loop
    if p ? k then v := jsonb_populate_record(v, jsonb_build_object(k, nullif(trim(coalesce(p->>k, '')), ''))); end if;
  end loop;
  -- الحد الائتماني ومدة السداد: للمدير فقط
  if (p ? 'credit_limit' or p ? 'payment_terms_days') and private.my_role() = 'admin' then
    if p ? 'credit_limit' then
      if nullif(trim(coalesce(p->>'credit_limit', '')), '') is null then v.credit_limit := null;
      elsif not private.num_ok(p->>'credit_limit', 2) then raise exception 'الحد الائتماني: رقم موجب بمنزلتين عشريتين كحد أقصى';
      else v.credit_limit := round((p->>'credit_limit')::numeric, 2); end if;
    end if;
    if p ? 'payment_terms_days' then
      if coalesce(p->>'payment_terms_days', '') !~ '^[0-9]{1,3}$' or (p->>'payment_terms_days')::int > 365 then raise exception 'مدة السداد: من 0 إلى 365 يوماً'; end if;
      v.payment_terms_days := (p->>'payment_terms_days')::int;
    end if;
  elsif v_id is null then
    v.payment_terms_days := coalesce((select default_terms_days from public.finance_settings where id = 1), 30);
  end if;
  v.payment_terms_days := coalesce(v.payment_terms_days, 30);
  v.vat_number := replace(v.vat_number, ' ', ''); v.email := lower(v.email);
  v.default_kind := coalesce(v.default_kind, 'simplified');
  if v.name is null then raise exception 'اسم العميل مطلوب'; end if;
  if length(v.name) > 150 then raise exception 'اسم العميل أطول من 150 حرفاً'; end if;
  if v.vat_number is not null and v.vat_number !~ '^3[0-9]{13}3$' then raise exception 'الرقم الضريبي: 15 رقماً يبدأ بـ 3 وينتهي بـ 3'; end if;
  if v.cr_number is not null and v.cr_number !~ '^[0-9]{10}$' then raise exception 'السجل التجاري: 10 أرقام'; end if;
  if v.building_no is not null and v.building_no !~ '^[0-9]{4}$' then raise exception 'رقم المبنى: 4 أرقام'; end if;
  if v.postal_code is not null and v.postal_code !~ '^[0-9]{5}$' then raise exception 'الرمز البريدي: 5 أرقام'; end if;
  if v.email is not null and v.email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'البريد الإلكتروني غير صالح'; end if;
  if v.default_kind = 'standard' and (v.vat_number is null or v.city is null or v.district is null or v.street is null or v.building_no is null or v.postal_code is null) then
    raise exception 'عميل الفواتير الضريبية يحتاج: الرقم الضريبي، المدينة، الحي، الشارع، رقم المبنى، الرمز البريدي';
  end if;
  v.updated_at := now(); v.updated_by := auth.uid();
  if v_id is not null then v.code := coalesce(v.code, v_old.code); end if;
  begin
    if v_id is null then
      v.id := gen_random_uuid(); v.created_at := now(); v.active := true;
      v.code := coalesce(v.code, 'C-' || lpad(nextval('private.customer_code_seq')::text, 5, '0'));
      insert into public.customers select v.*;
      perform private.log('create', 'customer', v.code, jsonb_build_object('name', v.name, 'credit_limit', v.credit_limit, 'terms', v.payment_terms_days));
    else
      update public.customers set code = v.code, name = v.name, vat_number = v.vat_number, cr_number = v.cr_number, city = v.city,
        district = v.district, street = v.street, building_no = v.building_no, postal_code = v.postal_code, phone = v.phone,
        email = v.email, default_kind = v.default_kind, credit_limit = v.credit_limit, payment_terms_days = v.payment_terms_days,
        updated_at = v.updated_at, updated_by = v.updated_by where id = v_id;
      perform private.log('update', 'customer', v.code, jsonb_build_object('name', v.name,
        'credit_limit', jsonb_build_object('from', v_old.credit_limit, 'to', v.credit_limit),
        'terms', jsonb_build_object('from', v_old.payment_terms_days, 'to', v.payment_terms_days)));
    end if;
  exception when unique_violation then
    raise exception 'يوجد عميل آخر بنفس الرقم الضريبي أو الرمز';
  end;
  return v.id;
end $$;

create or replace function public.save_finance_settings(p jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare v public.finance_settings;
begin
  perform private.require_role(array['admin']);
  select * into v from public.finance_settings where id = 1 for update;
  if p ? 'default_terms_days' then
    if coalesce(p->>'default_terms_days', '') !~ '^[0-9]{1,3}$' or (p->>'default_terms_days')::int > 365 then raise exception 'مدة السداد الافتراضية: من 0 إلى 365 يوماً'; end if;
    v.default_terms_days := (p->>'default_terms_days')::int;
  end if;
  if p ? 'enforce_credit_limit' then v.enforce_credit_limit := coalesce((p->>'enforce_credit_limit')::boolean, true); end if;
  update public.finance_settings set default_terms_days = v.default_terms_days, enforce_credit_limit = v.enforce_credit_limit,
         updated_at = now(), updated_by = auth.uid() where id = 1;
  perform private.log('update', 'finance_settings', '1', jsonb_build_object('default_terms_days', v.default_terms_days, 'enforce_credit_limit', v.enforce_credit_limit));
end $$;

-- ---------------------------------------------------------------- سند القبض
/* يوزّع مبلغاً على المستندات المفتوحة للعميل: يدوياً أو تلقائياً (الأقدم استحقاقاً أولاً) */
create or replace function private.apply_allocations(p_payment public.payments, p_alloc jsonb, p_auto boolean, p_budget numeric) returns numeric
language plpgsql security definer set search_path = '' as $$
declare v_left numeric := p_budget; r record; a jsonb; v_amt numeric; v_out numeric; v_seen uuid[] := '{}';
begin
  if p_auto then
    for r in select * from private.ar_items(private.today()) where customer_id = p_payment.customer_id and outstanding > 0 order by due_date, issued_on, number loop
      exit when v_left <= 0;
      v_amt := least(v_left, r.outstanding);
      insert into public.payment_allocations(payment_id, invoice_id, amount, created_by) values (p_payment.id, r.invoice_id, v_amt, auth.uid());
      v_left := v_left - v_amt;
    end loop;
  elsif jsonb_typeof(p_alloc) = 'array' then
    for a in select * from jsonb_array_elements(p_alloc) loop
      if not private.num_ok(a->>'amount', 2) or (a->>'amount')::numeric <= 0 then raise exception 'مبلغ التطبيق يجب أن يكون رقماً موجباً بمنزلتين عشريتين'; end if;
      v_amt := round((a->>'amount')::numeric, 2);
      begin select outstanding into v_out from private.ar_items(private.today())
              where invoice_id = (a->>'invoice_id')::uuid and customer_id = p_payment.customer_id;
      exception when others then v_out := null; end;
      if v_out is null then raise exception 'المستند المحدد ليس ذمة مفتوحة لهذا العميل'; end if;
      if (a->>'invoice_id')::uuid = any(v_seen) then raise exception 'المستند مكرر في التوزيع'; end if;
      v_seen := v_seen || (a->>'invoice_id')::uuid;
      if v_amt > v_out then raise exception 'المبلغ المطبّق (%) أكبر من المتبقي على المستند (%)', v_amt, v_out; end if;
      if v_amt > v_left then raise exception 'مجموع التوزيع أكبر من المبلغ المتاح'; end if;
      insert into public.payment_allocations(payment_id, invoice_id, amount, created_by) values (p_payment.id, (a->>'invoice_id')::uuid, v_amt, auth.uid());
      v_left := v_left - v_amt;
    end loop;
  end if;
  return v_left;
end $$;

create or replace function public.record_payment(p jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.payments; c public.customers; v_year int; v_seq int; v_left numeric; v_user_branch uuid;
begin
  perform private.require_role(array['admin','issuer']);
  perform pg_advisory_xact_lock(770012);
  begin select * into c from public.customers where id = (p->>'customer_id')::uuid; exception when others then c := null; end;
  if c.id is null then raise exception 'اختر العميل'; end if;
  if not private.num_ok(p->>'amount', 2) or (p->>'amount')::numeric <= 0 then raise exception 'المبلغ يجب أن يكون رقماً موجباً بمنزلتين عشريتين كحد أقصى'; end if;
  begin v.received_on := (p->>'received_on')::date; exception when others then v.received_on := null; end;
  if v.received_on is null then raise exception 'تاريخ القبض مطلوب'; end if;
  if v.received_on > private.today() then raise exception 'تاريخ القبض لا يكون في المستقبل'; end if;
  if v.received_on < private.today() - 365 then raise exception 'تاريخ القبض أقدم من سنة؛ راجع التاريخ'; end if;
  v.method := trim(coalesce(p->>'method', ''));
  if v.method not in ('نقدي','تحويل بنكي','شبكة / مدى','شيك') then raise exception 'طريقة القبض غير صالحة'; end if;
  v.reference := nullif(trim(coalesce(p->>'reference', '')), '');
  if v.method in ('شيك', 'تحويل بنكي') and v.reference is null then raise exception 'اكتب رقم الشيك أو مرجع التحويل'; end if;
  v.notes := nullif(trim(coalesce(p->>'notes', '')), '');
  if length(v.reference) > 80 or length(v.notes) > 300 then raise exception 'المرجع أو الملاحظات أطول من المسموح'; end if;
  select branch_id into v_user_branch from public.profiles where user_id = auth.uid();
  v.branch_id := coalesce(v_user_branch, (select id from public.branches where is_main limit 1));
  v_year := extract(year from v.received_on)::int;
  insert into private.doc_counters(doc_type, year, last_seq) values ('payment', v_year, 1)
    on conflict (doc_type, year) do update set last_seq = private.doc_counters.last_seq + 1 returning last_seq into v_seq;
  v.id := gen_random_uuid(); v.number := 'RCV-' || v_year || '-' || lpad(v_seq::text, 6, '0');
  v.customer_id := c.id; v.amount := round((p->>'amount')::numeric, 2); v.created_by := auth.uid(); v.created_at := now();
  insert into public.payments(id, number, customer_id, received_on, amount, method, reference, notes, branch_id, created_by, created_at)
  values (v.id, v.number, v.customer_id, v.received_on, v.amount, v.method, v.reference, v.notes, v.branch_id, v.created_by, v.created_at);
  v_left := private.apply_allocations(v, p->'allocations', coalesce((p->>'auto')::boolean, false), v.amount);
  perform private.log('receive', 'payment', v.number, jsonb_build_object('customer', c.code, 'amount', v.amount, 'method', v.method, 'unapplied', v_left));
  return jsonb_build_object('id', v.id, 'number', v.number, 'allocated', v.amount - v_left, 'unapplied', v_left);
end $$;

/* تطبيق الرصيد المتبقي من سند سابق على مستندات مفتوحة */
create or replace function public.allocate_payment(p_payment uuid, p_allocations jsonb, p_auto boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v public.payments; v_free numeric; v_left numeric;
begin
  perform private.require_role(array['admin','issuer']);
  perform pg_advisory_xact_lock(770012);
  select * into v from public.payments where id = p_payment;
  if v.id is null then raise exception 'السند غير موجود'; end if;
  if v.voided_at is not null then raise exception 'السند ملغى'; end if;
  v_free := v.amount - coalesce((select sum(amount) from public.payment_allocations where payment_id = v.id), 0);
  if v_free <= 0 then raise exception 'لا يوجد رصيد غير مطبّق في هذا السند'; end if;
  v_left := private.apply_allocations(v, p_allocations, p_auto, v_free);
  perform private.log('allocate', 'payment', v.number, jsonb_build_object('allocated', v_free - v_left));
  return jsonb_build_object('allocated', v_free - v_left, 'unapplied', v_left);
end $$;

create or replace function public.void_payment(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = '' as $$
declare v public.payments; r text := nullif(trim(coalesce(p_reason, '')), '');
begin
  perform private.require_role(array['admin']);
  if r is null or length(r) < 3 then raise exception 'اكتب سبب الإلغاء'; end if;
  if length(r) > 300 then raise exception 'سبب الإلغاء أطول من 300 حرف'; end if;
  select * into v from public.payments where id = p_id for update;
  if v.id is null then raise exception 'السند غير موجود'; end if;
  if v.voided_at is not null then raise exception 'السند ملغى مسبقاً'; end if;
  update public.payments set voided_at = now(), voided_by = auth.uid(), void_reason = r where id = p_id;
  perform private.log('void', 'payment', v.number, jsonb_build_object('amount', v.amount, 'reason', r));
end $$;

create or replace function public.set_due_date(p_invoice uuid, p_due date) returns void
language plpgsql security definer set search_path = '' as $$
declare t public.invoice_terms; i public.invoices; v_issued date;
begin
  perform private.require_role(array['admin']);
  select * into t from public.invoice_terms where invoice_id = p_invoice for update;
  if t.invoice_id is null then raise exception 'هذا المستند ليس آجلاً'; end if;
  select * into i from public.invoices where id = p_invoice;
  v_issued := (i.issued_at at time zone 'Asia/Riyadh')::date;
  if p_due is null or p_due < v_issued then raise exception 'تاريخ الاستحقاق لا يسبق تاريخ الإصدار'; end if;
  update public.invoice_terms set due_date = p_due, terms_days = p_due - v_issued, set_by = auth.uid(), set_at = now() where invoice_id = p_invoice;
  perform private.log('due_date', 'invoice', i.number, jsonb_build_object('from', t.due_date, 'to', p_due));
end $$;

-- ---------------------------------------------------------------- القراءة والتقارير
/* حالة السداد لمجموعة مستندات (لقائمة المستندات وعرض الفاتورة) */
create or replace function public.doc_payment_status(p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role(array['admin','issuer','viewer']);
  if cardinality(p_ids) > 500 then raise exception 'عدد المستندات كبير'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('invoice_id', x.id, 'customer_id', coalesce(a.customer_id, private.doc_customer(x.id)), 'status',
            case when a.invoice_id is null then 'cash'
                 when a.outstanding <= 0 then 'paid'
                 when a.days_overdue > 0 then 'overdue'
                 when a.paid + a.credited > 0 then 'partial' else 'unpaid' end,
            'due_date', a.due_date, 'outstanding', coalesce(a.outstanding, 0), 'paid', coalesce(a.paid, 0),
            'credited', coalesce(a.credited, 0), 'days_overdue', coalesce(a.days_overdue, 0),
            'payments', (select coalesce(jsonb_agg(jsonb_build_object('number', p.number, 'received_on', p.received_on, 'amount', pa.amount, 'method', p.method) order by p.received_on, p.number), '[]'::jsonb)
                         from public.payment_allocations pa join public.payments p on p.id = pa.payment_id
                         where pa.invoice_id = x.id and p.voided_at is null))), '[]'::jsonb)
          from unnest(p_ids) as x(id)
          join public.invoices i on i.id = x.id and i.doc_type in ('invoice','debit_note')
          left join private.ar_items(private.today()) a on a.invoice_id = x.id);
end $$;

/* رصيد العميل وحده الائتماني (للمحرر وصفحة الحساب) */
create or replace function public.customer_credit(p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c public.customers; v_out numeric; v_over numeric; v_max int; v_un numeric; v_enf boolean;
begin
  perform private.require_role(array['admin','issuer','viewer']);
  select * into c from public.customers where id = p_customer;
  if c.id is null then raise exception 'العميل غير موجود'; end if;
  select coalesce(sum(outstanding), 0), coalesce(sum(outstanding) filter (where days_overdue > 0), 0), coalesce(max(days_overdue) filter (where outstanding > 0), 0)
    into v_out, v_over, v_max from private.ar_items(private.today()) where customer_id = c.id and outstanding > 0;
  v_un := private.unapplied(c.id, private.today());
  select enforce_credit_limit into v_enf from public.finance_settings where id = 1;
  return jsonb_build_object('outstanding', v_out, 'overdue', v_over, 'max_days_overdue', v_max, 'unapplied', v_un,
    'balance', v_out - v_un, 'credit_limit', c.credit_limit, 'terms_days', c.payment_terms_days,
    'available', case when c.credit_limit is null then null else c.credit_limit - (v_out - v_un) end, 'enforce', coalesce(v_enf, true));
end $$;

/* حساب العميل: الرصيد + المستندات المفتوحة + آخر السندات */
create or replace function public.customer_account(p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c public.customers;
begin
  perform private.require_role(array['admin','issuer','viewer']);
  select * into c from public.customers where id = p_customer;
  if c.id is null then raise exception 'العميل غير موجود'; end if;
  return jsonb_build_object(
    'customer', jsonb_build_object('id', c.id, 'code', c.code, 'name', c.name, 'vat_number', c.vat_number, 'phone', c.phone, 'email', c.email,
                                   'credit_limit', c.credit_limit, 'terms_days', c.payment_terms_days, 'city', c.city),
    'credit', public.customer_credit(p_customer),
    'open', (select coalesce(jsonb_agg(jsonb_build_object('invoice_id', a.invoice_id, 'number', a.number, 'doc_type', a.doc_type, 'issued_on', a.issued_on,
                 'due_date', a.due_date, 'total', a.total, 'credited', a.credited, 'paid', a.paid, 'outstanding', a.outstanding, 'days_overdue', a.days_overdue)
               order by a.due_date, a.issued_on, a.number), '[]'::jsonb)
             from private.ar_items(private.today()) a where a.customer_id = c.id and a.outstanding > 0),
    'payments', (select coalesce(jsonb_agg(x order by x.received_on desc, x.number desc), '[]'::jsonb) from (
               select p.id, p.number, p.received_on, p.amount, p.method, p.reference, p.notes, p.voided_at, p.void_reason,
                      p.customer_id, p.amount - coalesce((select sum(a.amount) from public.payment_allocations a where a.payment_id = p.id), 0) as unapplied,
                      (select coalesce(jsonb_agg(jsonb_build_object('number', i.number, 'amount', a.amount) order by i.number), '[]'::jsonb)
                         from public.payment_allocations a join public.invoices i on i.id = a.invoice_id where a.payment_id = p.id) as allocations
               from public.payments p where p.customer_id = c.id order by p.received_on desc, p.number desc limit 50) x));
end $$;

/* كشف حساب لفترة: رصيد افتتاحي + الحركات + رصيد جارٍ */
create or replace function public.customer_statement(p_customer uuid, p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare c public.customers;
begin
  perform private.require_role(array['admin','issuer','viewer']);
  select * into c from public.customers where id = p_customer;
  if c.id is null then raise exception 'العميل غير موجود'; end if;
  if p_from is null or p_to is null or p_to < p_from then raise exception 'فترة غير صالحة'; end if;
  if p_to - p_from > 1100 then raise exception 'الفترة أطول من 3 سنوات'; end if;
  return (with st as (
      -- مدين: الفواتير والإشعارات المدينة الآجلة
      select (i.issued_at at time zone 'Asia/Riyadh')::date as d, i.doc_type as kind, i.number, null::text as ref, i.total as debit, 0::numeric as credit, 1 as ord
        from public.invoices i join public.invoice_terms t on t.invoice_id = i.id
        where private.doc_customer(i.id) = c.id and (i.issued_at at time zone 'Asia/Riyadh')::date <= p_to
      union all
      -- دائن: الإشعارات الدائنة على مستندات آجلة
      select (cn.issued_at at time zone 'Asia/Riyadh')::date, 'credit_note', cn.number, r.number, 0, cn.total, 2
        from public.invoices cn join public.invoices r on r.id = cn.ref_invoice_id join public.invoice_terms t on t.invoice_id = r.id
        where cn.doc_type = 'credit_note' and private.doc_customer(r.id) = c.id and (cn.issued_at at time zone 'Asia/Riyadh')::date <= p_to
      union all
      -- دائن: سندات القبض غير الملغاة
      select p.received_on, 'payment', p.number, p.method || coalesce(' — ' || p.reference, ''), 0, p.amount, 3
        from public.payments p where p.customer_id = c.id and p.voided_at is null and p.received_on <= p_to),
    op as (select coalesce(sum(debit - credit), 0) as v from st where d < p_from),
    per as (select * from st where d between p_from and p_to)
    select jsonb_build_object(
      'customer', jsonb_build_object('code', c.code, 'name', c.name, 'vat_number', c.vat_number, 'credit_limit', c.credit_limit, 'terms_days', c.payment_terms_days),
      'from', p_from, 'to', p_to, 'opening', (select v from op),
      'lines', (select coalesce(jsonb_agg(jsonb_build_object('date', x.d, 'kind', x.kind, 'number', x.number, 'ref', x.ref, 'debit', x.debit, 'credit', x.credit, 'balance', x.bal)
                       order by x.d, x.ord, x.number), '[]'::jsonb)
                from (select per.*, (select v from op) + sum(debit - credit) over (order by d, ord, number rows unbounded preceding) as bal from per) x),
      'debits', (select coalesce(sum(debit), 0) from per), 'credits', (select coalesce(sum(credit), 0) from per),
      'closing', (select v from op) + (select coalesce(sum(debit - credit), 0) from per)));
end $$;

/* أعمار الديون لكل عميل في تاريخ معيّن (اختيارياً لفرع) */
create or replace function public.report_aging(p_as_of date, p_branch uuid default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role(array['admin','issuer','viewer']);
  if p_as_of is null then raise exception 'حدد التاريخ'; end if;
  return (with a as (select * from private.ar_items(p_as_of) where outstanding > 0 and (p_branch is null or branch_id = p_branch)),
          g as (select a.customer_id,
                  sum(outstanding) filter (where days_overdue = 0) as cur, sum(outstanding) filter (where days_overdue between 1 and 30) as b30,
                  sum(outstanding) filter (where days_overdue between 31 and 60) as b60, sum(outstanding) filter (where days_overdue between 61 and 90) as b90,
                  sum(outstanding) filter (where days_overdue > 90) as b91, sum(outstanding) as total, max(days_overdue) as max_days, count(*) as docs
                from a group by a.customer_id)
          select jsonb_build_object('as_of', p_as_of, 'rows', coalesce(jsonb_agg(jsonb_build_object(
              'customer_id', g.customer_id, 'code', c.code, 'name', coalesce(c.name, 'بدون عميل'), 'credit_limit', c.credit_limit, 'terms_days', c.payment_terms_days,
              'current', coalesce(g.cur, 0), 'd1_30', coalesce(g.b30, 0), 'd31_60', coalesce(g.b60, 0), 'd61_90', coalesce(g.b90, 0), 'd90', coalesce(g.b91, 0),
              'total', g.total, 'unapplied', case when g.customer_id is null then 0 else private.unapplied(g.customer_id, p_as_of) end,
              'max_days', g.max_days, 'docs', g.docs) order by g.total desc), '[]'::jsonb))
          from g left join public.customers c on c.id = g.customer_id);
end $$;

/* مؤشرات شاشة التحصيل */
create or replace function public.ar_summary(p_branch uuid default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_today date := private.today();
begin
  perform private.require_role(array['admin','issuer','viewer']);
  return (with a as (select * from private.ar_items(v_today) where outstanding > 0 and (p_branch is null or branch_id = p_branch))
    select jsonb_build_object(
      'outstanding', coalesce((select sum(outstanding) from a), 0),
      'overdue', coalesce((select sum(outstanding) from a where days_overdue > 0), 0),
      'overdue_customers', (select count(distinct customer_id) from a where days_overdue > 0),
      'due_7d', coalesce((select sum(outstanding) from a where due_date between v_today and v_today + 7), 0),
      'customers', (select count(distinct customer_id) from a),
      'collected_month', coalesce((select sum(amount) from public.payments where voided_at is null and received_on >= date_trunc('month', v_today)::date
                                     and (p_branch is null or branch_id = p_branch)), 0),
      'unapplied', coalesce((select sum(private.unapplied(c.id, v_today)) from public.customers c
                              where exists (select 1 from public.payments p where p.customer_id = c.id and p.voided_at is null)), 0)));
end $$;

/* قائمة السندات لفترة */
create or replace function public.list_payments(p_from date, p_to date, p_customer uuid default null) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.require_role(array['admin','issuer','viewer']);
  if p_from is null or p_to is null or p_to < p_from then raise exception 'فترة غير صالحة'; end if;
  return (select coalesce(jsonb_agg(x order by x.received_on desc, x.number desc), '[]'::jsonb) from (
    select p.id, p.number, p.received_on, p.amount, p.method, p.reference, p.notes, p.voided_at, p.void_reason, p.customer_id,
           c.code as customer_code, c.name as customer_name,
           p.amount - coalesce((select sum(a.amount) from public.payment_allocations a where a.payment_id = p.id), 0) as unapplied,
           (select coalesce(jsonb_agg(jsonb_build_object('number', i.number, 'amount', a.amount) order by i.number), '[]'::jsonb)
              from public.payment_allocations a join public.invoices i on i.id = a.invoice_id where a.payment_id = p.id) as allocations,
           (select coalesce(full_name, email) from public.profiles where user_id = p.created_by) as created_by_name
    from public.payments p join public.customers c on c.id = p.customer_id
    where p.received_on between p_from and p_to and (p_customer is null or p.customer_id = p_customer)
    limit 2000) x);
end $$;

-- ---------------------------------------------------------------- رابط العميل يعرض تاريخ الاستحقاق للمستندات الآجلة
create or replace function public.shared_invoice(p_token text) returns jsonb
language plpgsql volatile security definer set search_path = '' as $$
declare s public.invoice_shares; i public.invoices; z public.zatca_documents; v_qr text; st public.invoice_settings;
begin
  if p_token is null or p_token !~ '^[A-Za-z0-9_-]{43}$' then raise exception 'رابط غير صالح'; end if;
  select * into s from public.invoice_shares where token_hash = encode(sha256(convert_to(p_token, 'UTF8')), 'hex');
  if s.id is null or s.revoked_at is not null or s.expires_at < now() then raise exception 'الرابط غير صالح أو انتهت صلاحيته'; end if;
  if private.deliverable_reason(s.invoice_id) is not null then raise exception 'المستند غير متاح حالياً'; end if;
  update public.invoice_shares set views = views + 1, last_viewed_at = now() where id = s.id;
  select * into i from public.invoices where id = s.invoice_id;
  select * into z from public.zatca_documents where invoice_id = i.id;
  select * into st from public.invoice_settings where id = 1;
  v_qr := coalesce(substring(z.cleared_xml from '<cbc:ID>QR</cbc:ID>[\s\S]*?<cbc:EmbeddedDocumentBinaryObject[^>]*>([^<]+)<'), z.qr, i.qr);
  return jsonb_build_object(
    'number', i.number, 'doc_type', i.doc_type, 'kind', i.kind, 'issued_at', i.issued_at, 'supply_date', i.supply_date,
    'payment_method', i.payment_method, 'reason', i.reason, 'seller', i.seller, 'vat_rate_bp', i.vat_rate_bp,
    'buyer', jsonb_build_object('name', i.buyer_name, 'vat', i.buyer_vat, 'city', i.buyer_city, 'street', i.buyer_street,
              'building', i.buyer_building, 'postal', i.buyer_postal,
              'district', (select buyer_district from public.invoice_ext e where e.invoice_id = i.id),
              'cr', (select x.buyer_cr from public.invoice_buyer_ids x where x.invoice_id = i.id),
              'code', (select x.customer_code from public.invoice_buyer_ids x where x.invoice_id = i.id)),
    'ref_number', (select r.number from public.invoices r where r.id = i.ref_invoice_id),
    'subtotal', i.subtotal, 'discount', i.discount, 'taxable', i.taxable, 'vat', i.vat, 'total', i.total,
    'lines', (select jsonb_agg(jsonb_build_object('line_no', l.line_no, 'description', l.description, 'qty', l.qty, 'unit_price', l.unit_price,
                'gross', l.gross, 'discount', l.discount, 'net', l.net, 'vat', l.vat, 'total', l.total,
                'category', coalesce(t.category, 'S'), 'rate_bp', coalesce(t.rate_bp, i.vat_rate_bp), 'exemption_code', t.exemption_code, 'exemption_reason', t.exemption_reason)
                order by l.line_no)
              from public.invoice_lines l left join public.invoice_line_tax t on t.invoice_id = l.invoice_id and t.line_no = l.line_no
              where l.invoice_id = i.id),
    'branch', (select b.branch from public.invoice_branch b where b.invoice_id = i.id),
    'layout', jsonb_build_object('name', case when i.kind = 'standard' then st.layout_standard else st.layout_simplified end,
              'accent', st.accent_color, 'logo', st.logo, 'footer_note', st.footer_note, 'show_bank', st.show_bank),
    'due_date', (select t.due_date from public.invoice_terms t where t.invoice_id = i.id),
    'qr', v_qr, 'zatca_status', z.status, 'uuid', i.id, 'icv', i.icv, 'expires_at', s.expires_at);
end $$;
revoke all on function public.shared_invoice(text) from public;
grant execute on function public.shared_invoice(text) to anon, authenticated;

-- ---------------------------------------------------------------- الصلاحيات
revoke all on function private.block_mutation(), private.payment_guard(), private.today(), private.doc_customer(uuid), private.ar_items(date),
  private.unapplied(uuid, date), private.ar_on_invoice(), private.ar_on_buyer(), private.apply_allocations(public.payments, jsonb, boolean, numeric)
  from public, anon, authenticated;
revoke all on function public.save_customer(jsonb), public.save_finance_settings(jsonb), public.record_payment(jsonb), public.allocate_payment(uuid, jsonb, boolean),
  public.void_payment(uuid, text), public.set_due_date(uuid, date), public.doc_payment_status(uuid[]), public.customer_credit(uuid),
  public.customer_account(uuid), public.customer_statement(uuid, date, date), public.report_aging(date, uuid), public.ar_summary(uuid),
  public.list_payments(date, date, uuid) from public, anon;
grant execute on function public.save_customer(jsonb), public.save_finance_settings(jsonb), public.record_payment(jsonb), public.allocate_payment(uuid, jsonb, boolean),
  public.void_payment(uuid, text), public.set_due_date(uuid, date), public.doc_payment_status(uuid[]), public.customer_credit(uuid),
  public.customer_account(uuid), public.customer_statement(uuid, date, date), public.report_aging(date, uuid), public.ar_summary(uuid),
  public.list_payments(date, date, uuid) to authenticated;

-- ---------------------------------------------------------------- النسخة الاحتياطية تشمل الذمم
create or replace function public.backup_snapshot() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then perform private.require_role(array['admin']); end if;
  return jsonb_build_object(
    'generated_at', now(), 'format', 'tax-invoice-backup-v5',
    'company_profiles', (select coalesce(jsonb_agg(to_jsonb(c) order by version), '[]') from public.company_profiles c),
    'branches',         (select coalesce(jsonb_agg(to_jsonb(b) order by code), '[]') from public.branches b),
    'invoices',         (select coalesce(jsonb_agg(to_jsonb(i) order by icv), '[]') from public.invoices i),
    'invoice_lines',    (select coalesce(jsonb_agg(to_jsonb(l) order by invoice_id, line_no), '[]') from public.invoice_lines l),
    'invoice_line_tax', (select coalesce(jsonb_agg(to_jsonb(t) order by invoice_id, line_no), '[]') from public.invoice_line_tax t),
    'invoice_ext',      (select coalesce(jsonb_agg(to_jsonb(e)), '[]') from public.invoice_ext e),
    'invoice_branch',   (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from public.invoice_branch x),
    'invoice_buyer_ids',(select coalesce(jsonb_agg(to_jsonb(x)), '[]') from public.invoice_buyer_ids x),
    'invoice_customer', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from public.invoice_customer x),
    'invoice_terms',    (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from public.invoice_terms x),
    'payments',         (select coalesce(jsonb_agg(to_jsonb(x) order by number), '[]') from public.payments x),
    'payment_allocations', (select coalesce(jsonb_agg(to_jsonb(x) order by id), '[]') from public.payment_allocations x),
    'finance_settings', (select to_jsonb(s) from public.finance_settings s where id = 1),
    'customers',        (select coalesce(jsonb_agg(to_jsonb(c) order by code), '[]') from public.customers c),
    'items',            (select coalesce(jsonb_agg(to_jsonb(it) order by code), '[]') from public.items it),
    'zatca_documents',  (select coalesce(jsonb_agg(to_jsonb(z) order by zicv), '[]') from public.zatca_documents z),
    'invoice_settings', (select to_jsonb(s) from public.invoice_settings s where id = 1),
    'audit_log',        (select coalesce(jsonb_agg(to_jsonb(a) order by id), '[]') from public.audit_log a),
    'profiles',         (select coalesce(jsonb_agg(jsonb_build_object('user_id', user_id, 'email', email, 'role', role, 'active', active, 'branch_id', branch_id)), '[]') from public.profiles)
  );
end $$;
