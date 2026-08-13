-- ============================================================================
-- 013_bulksms_owner_phone.sql
-- 1) Captures the owner's phone number at signup so renters can contact them.
-- 2) Defaults the messaging provider to bulkSMSBD (Bangladesh).
--
-- bulkSMSBD is dispatched by the Vercel serverless function /api/dispatch-sms
-- (see README). Set on Vercel: BULKSMSBD_API_KEY, BULKSMSBD_SENDER_ID,
-- SUPABASE_SERVICE_ROLE_KEY.
-- ============================================================================

-- Store the phone number provided at registration on the owner record.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_business_name text;
  v_kind          text;
  v_phone         text;
  v_owner_id      uuid;
  v_kind_ok       text;
begin
  v_business_name := coalesce(new.raw_user_meta_data->>'business_name', 'My Property Business');
  v_kind          := coalesce(new.raw_user_meta_data->>'property_kind', 'apartment');
  v_kind_ok       := case when v_kind in ('apartment','cottage','both') then v_kind else 'apartment' end;
  v_phone         := nullif(btrim(new.raw_user_meta_data->>'phone'), '');

  insert into public.owners (id, user_id, business_name, contact_email, contact_phone, property_kind)
  values (new.id, new.id, v_business_name, new.email, v_phone, v_kind_ok::public.property_kind)
  on conflict (user_id) do nothing
  returning id into v_owner_id;

  if v_owner_id is null then
    select id into v_owner_id from public.owners where user_id = new.id;
  end if;

  insert into public.owner_settings (owner_id)
  values (v_owner_id)
  on conflict (owner_id) do nothing;

  insert into public.subscriptions (owner_id)
  values (v_owner_id)
  on conflict (owner_id) do nothing;

  return new;
end;
$$;

-- New owner accounts default to the bulkSMSBD provider.
alter table public.owner_settings alter column message_provider set default 'bulksmsbd';
