-- ============================================================================
-- seed.sql
-- System lookup defaults, default billing plan and message templates.
-- Run once after migrations (e.g. `supabase db seed` or in the SQL editor).
-- ============================================================================

insert into public.property_types (key, name) values
  ('apartment', 'Apartment'),
  ('cottage', 'Cottage')
on conflict (key) do nothing;

insert into public.charge_types (key, name) values
  ('rent', 'Rent'),
  ('deposit', 'Deposit'),
  ('utility', 'Utilities'),
  ('fine', 'Fine'),
  ('late_fee', 'Late fee'),
  ('other', 'Other')
on conflict (key) do nothing;

insert into public.invoice_types (key, name) values
  ('rent', 'Rent'),
  ('fine', 'Fine'),
  ('deposit', 'Deposit'),
  ('utility', 'Utility'),
  ('other', 'Other')
on conflict (key) do nothing;

insert into public.invoice_statuses (key, name) values
  ('draft', 'Draft'),
  ('open', 'Open'),
  ('partially_paid', 'Partially paid'),
  ('paid', 'Paid'),
  ('overdue', 'Overdue'),
  ('void', 'Void')
on conflict (key) do nothing;

insert into public.payment_methods (key, name) values
  ('cash', 'Cash'),
  ('bank_transfer', 'Bank transfer'),
  ('card', 'Card'),
  ('mobile_money', 'Mobile money'),
  ('other', 'Other')
on conflict (key) do nothing;

insert into public.numbering_patterns (key, pattern, description) values
  ('unit', 'Unit ', 'Unit 01, Unit 02, …'),
  ('apartment_a', 'A-', 'A-01, A-02, …'),
  ('apartment_b', 'B-', 'B-01, B-02, …'),
  ('room', 'Room ', 'Room 01, Room 02, …'),
  ('number', '{n}', '01, 02, …'),
  ('wing', 'W-{n}-1', 'W-01-1, W-02-1, …')
on conflict (key) do nothing;

insert into public.currencies (owner_id, key, name, symbol) values
  (null, 'BDT', 'Bangladeshi Taka', '৳'),
  (null, 'EUR', 'Euro', '€'),
  (null, 'USD', 'US Dollar', '$'),
  (null, 'GBP', 'British Pound', '£'),
  (null, 'PLN', 'Polish Złoty', 'zł'),
  (null, 'CZK', 'Czech Koruna', 'Kč'),
  (null, 'SEK', 'Swedish Krona', 'kr'),
  (null, 'NOK', 'Norwegian Krone', 'kr'),
  (null, 'DKK', 'Danish Krone', 'kr'),
  (null, 'CHF', 'Swiss Franc', 'CHF'),
  (null, 'TRY', 'Turkish Lira', '₺')
on conflict (key) where owner_id is null do nothing;

insert into public.unit_room_types (owner_id, key, name, property_kind) values
  (null, 'bedroom',      'Bedroom',      null),
  (null, 'drawing',      'Drawing room', 'apartment'),
  (null, 'dining',       'Dining area',  null),
  (null, 'living_room',  'Living room',  null),
  (null, 'bathroom',     'Bathroom',     null),
  (null, 'kitchen',      'Kitchen',      null),
  (null, 'balcony',      'Balcony',      'apartment'),
  (null, 'hall',         'Hall',         'apartment'),
  (null, 'corridor',     'Corridor',     'apartment'),
  (null, 'utility',      'Utility room', null),
  (null, 'terrace',      'Terrace',      'cottage'),
  (null, 'garden',       'Garden',       'cottage'),
  (null, 'porch',        'Porch',        'cottage'),
  (null, 'storage',      'Storage room', null),
  (null, 'study',        'Study',        null),
  (null, 'ensuite',      'En-suite',     null)
on conflict (key) where owner_id is null do nothing;

insert into public.facility_templates (owner_id, name, category) values
  (null, 'Parking spot', 'parking'),
  (null, 'WiFi included', 'internet'),
  (null, 'Garden access', 'outdoor'),
  (null, 'Furnished', 'furnishing'),
  (null, 'Washing machine', 'appliance'),
  (null, 'Attached bathroom', 'bathroom'),
  (null, 'Running water', 'water'),
  (null, 'Electricity', 'utility'),
  (null, 'CCTV surveillance', 'security'),
  (null, 'Balcony', 'structure'),
  (null, 'Kitchen access', 'kitchen'),
  (null, 'Bed & mattress', 'furnishing'),
  (null, 'Room cleaner', 'service'),
  (null, 'Geyser / hot water', 'water'),
  (null, 'Gym access', 'facility'),
  (null, 'Study table', 'furnishing'),
  (null, 'Cupboard / wardrobe', 'furnishing'),
  (null, 'Guard / doorman', 'security'),
  (null, 'Generator backup', 'utility')
on conflict (name) where owner_id is null do nothing;

insert into public.rule_templates (owner_id, title, body) values
  (null, 'No smoking', 'Smoking is not permitted inside the unit.'),
  (null, 'Pets on request', 'Pets are allowed only with prior written approval.'),
  (null, 'No subletting', 'Subletting or short-term rentals are prohibited.')
on conflict (title) where owner_id is null do nothing;

insert into public.billing_plans (key, name, monthly_amount, description) values
  ('monthly', 'Monthly', 19.00, 'Recurring monthly plan after the free trial'),
  ('annual', 'Annual', 190.00, 'Discounted annual plan (not used by default)')
on conflict (key) do nothing;

insert into public.message_templates (owner_id, key, channel_group, subject, body) values
  (null, 'payment_reminder', 'tenant_facing', 'Payment reminder',
   'Dear {name}, this is a friendly reminder that invoice {invoice} of {amount} is due. Balance: {balance}.'),
  (null, 'payment_warning', 'tenant_facing', 'Payment warning',
   'Dear {name}, invoice {invoice} is {days} days overdue. Please settle the balance of {balance}.'),
  (null, 'overdue_escalation', 'tenant_facing', 'Overdue escalation',
   'Dear {name}, your account is significantly overdue. Please arrange payment of {balance} immediately.'),
  (null, 'rent_increase', 'tenant_facing', 'Rent increase notice',
   'Dear {name}, as of {date} your rent will increase. Regards, your landlord.'),
  (null, 'announcement', 'tenant_facing', 'Announcement', '{body}')
on conflict (key) where owner_id is null do nothing;
