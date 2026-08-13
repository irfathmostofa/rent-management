-- ============================================================================
-- 003_bulk_creation.sql
-- Bulk unit generation from a numbering pattern, and template snapshotting.
-- Template values are copied onto units at creation time so later edits to a
-- template never retroactively change existing records.
-- ============================================================================

-- Render a unit number from a pattern. '{n}' is replaced with a zero-padded
-- index; otherwise the pattern acts as a prefix.
create or replace function public.render_unit_number(p_pattern text, p_index integer, p_width integer)
returns text
language plpgsql
immutable
as $$
declare
  v_num text := lpad(p_index::text, greatest(p_width, 1), '0');
begin
  if p_pattern like '%{n}%' then
    return replace(p_pattern, '{n}', v_num);
  else
    return p_pattern || v_num;
  end if;
end;
$$;

-- Copy template values onto a unit (used at creation and on explicit
-- "apply template" actions). Existing unit values are overwritten.
create or replace function public.apply_unit_template(p_unit_id uuid, p_template_id uuid)
returns void
language plpgsql
as $$
declare
  v_owner uuid;
  v_tpl   record;
begin
  select owner_id into v_owner from public.units where id = p_unit_id;

  if v_owner is null then
    raise exception 'unit not found';
  end if;

  select * into v_tpl from public.unit_templates where id = p_template_id and owner_id = v_owner;
  if v_tpl is null then
    raise exception 'template not found for this owner';
  end if;

  update public.units
     set dimension        = v_tpl.dimension,
         bedrooms         = v_tpl.bedrooms,
         bathrooms        = v_tpl.bathrooms,
         rent_amount      = v_tpl.default_rent,
         deposit_amount   = v_tpl.deposit_amount,
         facilities       = v_tpl.facilities,
         rules            = v_tpl.rules,
         charges          = v_tpl.charges,
         template_id      = p_template_id,
         template_snapshot = jsonb_build_object(
           'template_id',   p_template_id,
           'template_name', v_tpl.name,
           'applied_at',    now()
         )
   where id = p_unit_id;
end;
$$;

-- Bulk-create units for a property.
-- p_count: number of units to create.
-- p_pattern: numbering pattern (may contain '{n}').
-- p_template_id: optional unit template whose values are snapshotted.
-- p_dimension / p_default_rent / p_deposit: overrides applied on top of any
-- template values.
create or replace function public.create_units_bulk(
  p_property_id uuid,
  p_count       integer,
  p_pattern     text default 'Unit ',
  p_template_id uuid default null,
  p_dimension   text default null,
  p_default_rent numeric(12,2) default null,
  p_deposit     numeric(12,2) default null
)
returns setof public.units
language plpgsql
as $$
declare
  v_owner    uuid;
  v_existing integer;
  v_width    integer;
  v_i        integer;
  v_number   text;
  v_dim      text;
  v_rent     numeric(12,2);
  v_deposit  numeric(12,2);
  v_tpl      record;
begin
  if p_count is null or p_count < 1 or p_count > 500 then
    raise exception 'p_count must be between 1 and 500';
  end if;

  select owner_id into v_owner from public.properties where id = p_property_id;
  if v_owner is null then
    raise exception 'property not found';
  end if;

  select count(*) into v_existing from public.units where property_id = p_property_id;
  v_width := length((v_existing + p_count)::text);

  if p_template_id is not null then
    select * into v_tpl from public.unit_templates where id = p_template_id and owner_id = v_owner;
    if v_tpl is null then
      raise exception 'template not found for this owner';
    end if;
  end if;

  for v_i in 1..p_count loop
    v_number := public.render_unit_number(p_pattern, v_existing + v_i, v_width);

    v_dim    := coalesce(p_dimension,   v_tpl.dimension);
    v_rent   := coalesce(p_default_rent, v_tpl.default_rent);
    v_deposit:= coalesce(p_deposit,     v_tpl.deposit_amount);

    return query
      insert into public.units
        (owner_id, property_id, template_id, unit_number,
         dimension, rent_amount, deposit_amount,
         facilities, rules, charges,
         template_snapshot)
      values
        (v_owner, p_property_id, p_template_id, v_number,
         v_dim, v_rent, v_deposit,
         coalesce(v_tpl.facilities, '[]'::jsonb),
         coalesce(v_tpl.rules, '[]'::jsonb),
         coalesce(v_tpl.charges, '[]'::jsonb),
         case when v_tpl.id is not null then
           jsonb_build_object(
             'template_id', v_tpl.id,
             'template_name', v_tpl.name,
             'applied_at', now()
           )
         else null end)
      returning *;
  end loop;

  update public.properties
     set unit_count = (select count(*) from public.units where property_id = p_property_id)
   where id = p_property_id;
end;
$$;

-- Create a unit (single) with an optional template snapshot.
create or replace function public.create_unit(
  p_property_id uuid,
  p_unit_number text,
  p_dimension   text default null,
  p_rent        numeric(12,2) default null,
  p_deposit     numeric(12,2) default null,
  p_template_id uuid default null
)
returns public.units
language plpgsql
as $$
declare
  v_owner uuid;
  v_unit  record;
begin
  select owner_id into v_owner from public.properties where id = p_property_id;
  if v_owner is null then
    raise exception 'property not found';
  end if;

  insert into public.units
    (owner_id, property_id, template_id, unit_number, dimension, rent_amount, deposit_amount)
  values
    (v_owner, p_property_id, p_template_id, p_unit_number, p_dimension,
     coalesce(p_rent, 0), coalesce(p_deposit, 0))
  returning * into v_unit;

  update public.properties
     set unit_count = (select count(*) from public.units where property_id = p_property_id)
   where id = p_property_id;

  return v_unit;
end;
$$;
