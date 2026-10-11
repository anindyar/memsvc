create extension if not exists vector;

-- One table for every memory, whatever the storage mode:
--   source = 'md'  row is an index entry derived from a markdown file (path + line point back to it)
--   source = 'pg'  row IS the memory (no file); pgvector is the store
--   source = 'doc' / 'fact' reserved for RAG documents and extracted facts
create table if not exists memory (
  id        bigserial primary key,
  tenant    text not null,
  source    text not null,
  path      text,
  line      int,
  content   text not null,
  tags      text[] not null default '{}',
  embedding vector(768) not null,
  created   timestamptz not null default now()
);
create index if not exists memory_hnsw on memory using hnsw (embedding vector_cosine_ops);
create index if not exists memory_tenant on memory (tenant, source, path);

-- The service connects as memsvc (not the table owner), so row-level security applies to it.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'memsvc') then
    create role memsvc login password 'memsvc';
  end if;
end $$;
grant select, insert, update, delete on memory to memsvc;
grant usage on sequence memory_id_seq to memsvc;
alter table memory enable row level security;
drop policy if exists tenant_isolation on memory;
create policy tenant_isolation on memory
  using (tenant = current_setting('app.tenant', true))
  with check (tenant = current_setting('app.tenant', true));
