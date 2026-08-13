-- ============================================================================
-- 015_default_message_templates.sql
-- Guarantees the default tenant-facing message templates exist so the
-- tenant-detail "Send message" picker always has templates to offer,
-- even when seed.sql was not run (idempotent: keeps the seed inserts).
-- ============================================================================

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
