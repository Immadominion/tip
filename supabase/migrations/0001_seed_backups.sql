-- One encrypted recovery phrase per account.
--
-- The server stores a blob it cannot open. The phrase inside is sealed on the
-- device with Argon2id and AES-GCM under a password only the user knows, so a
-- breach of this table yields ciphertext and an offline guessing problem
-- rather than anybody's funds.
--
-- Nothing identifying is stored beside it. No wallet address, no public key,
-- no chain. The row is already tied to an account, and adding the address
-- would hand this database the exact link between a person and their on-chain
-- history that the rest of the project exists to avoid.

create table if not exists public.seed_backups (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  blob        text not null,
  updated_at  timestamptz not null default now(),

  -- A sealed 24 word phrase is a few hundred bytes. Four kilobytes is room to
  -- spare and a cheap way to stop the table being used as free storage.
  constraint seed_backups_blob_size check (char_length(blob) between 1 and 4096)
);

alter table public.seed_backups enable row level security;

-- Four separate policies rather than one permissive rule, so that a mistake in
-- any single verb cannot quietly widen the others.

drop policy if exists "read own backup" on public.seed_backups;
create policy "read own backup"
  on public.seed_backups for select
  using (auth.uid() = user_id);

drop policy if exists "create own backup" on public.seed_backups;
create policy "create own backup"
  on public.seed_backups for insert
  with check (auth.uid() = user_id);

drop policy if exists "replace own backup" on public.seed_backups;
create policy "replace own backup"
  on public.seed_backups for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

drop policy if exists "delete own backup" on public.seed_backups;
create policy "delete own backup"
  on public.seed_backups for delete
  using (auth.uid() = user_id);

-- Keeps updated_at honest without trusting the client to send it.
create or replace function public.touch_seed_backup()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists seed_backups_touch on public.seed_backups;
create trigger seed_backups_touch
  before update on public.seed_backups
  for each row execute function public.touch_seed_backup();
