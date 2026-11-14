-- =====================================================================
-- RouteAlerte — base de données Supabase (phase de test multi-testeurs)
-- À exécuter une seule fois : Supabase → SQL Editor → New query → Run.
-- Le script peut être relancé sans danger (il remplace les fonctions).
-- =====================================================================

-- 1. Extension géographique (calculs de distance en mètres)
create extension if not exists postgis with schema extensions;

-- 2. Les dangers : la carte commune partagée par tous les testeurs
create table if not exists public.hazards (
  id            text primary key,                 -- identifiant créé par le téléphone
  type          text not null check (type in (
                  'dos_dane','nid_poule','portion_degradee','betail',
                  'deviation','pont_etroit','zone_inondable')),
  geom          extensions.geography(Geometry, 4326) not null,  -- point ou tronçon
  created_at    timestamptz not null default now(),
  last_seen     timestamptz not null default now(),  -- dernier relevé ou confirmation
  confirmations integer     not null default 1,      -- nombre de relevés au même endroit
  accuracy      integer,                             -- précision GPS du 1er relevé (m)
  speed_kmh     integer,
  heading       integer,
  length_m      integer,                             -- longueur (tronçons)
  source        text,                                -- terrain / carte / import
  created_by    uuid default auth.uid() references auth.users(id) on delete set null
);
create index if not exists hazards_geom_idx on public.hazards using gist (geom);
create index if not exists hazards_type_idx on public.hazards (type);

-- 3. Les relevés bruts : chaque observation envoyée par un téléphone.
--    Garde l'historique et empêche qu'un même relevé soit compté deux fois
--    si le téléphone le renvoie (réseau coupé pendant l'envoi).
create table if not exists public.reports (
  id          text primary key,                  -- identifiant créé par le téléphone
  hazard_id   text references public.hazards(id) on delete set null,
  user_id     uuid default auth.uid(),
  type        text not null,
  geom        extensions.geography(Geometry, 4326) not null,
  observed_at timestamptz not null,
  received_at timestamptz not null default now(),
  accuracy    integer,
  speed_kmh   integer,
  heading     integer,
  source      text,
  result      text not null                      -- 'new' ou 'confirmed'
);
create index if not exists reports_hazard_idx on public.reports (hazard_id);

-- 4. Sécurité : lecture libre de la carte, écriture uniquement via les fonctions
alter table public.hazards enable row level security;
alter table public.reports enable row level security;

drop policy if exists "Lecture de la carte" on public.hazards;
create policy "Lecture de la carte" on public.hazards
  for select to anon, authenticated using (true);
-- Aucune politique d'écriture directe : tout passe par report_hazard / delete_hazard.
-- La table reports n'est pas lisible depuis l'appli (historique interne).
revoke all on public.hazards, public.reports from anon, authenticated;
grant select on public.hazards to anon, authenticated;

-- 5. Vue de lecture : géométrie au format GeoJSON, prête pour l'appli
create or replace view public.hazards_geojson
with (security_invoker = true) as
select id, type,
       extensions.st_asgeojson(geom, 6)::jsonb as geometry,
       created_at, last_seen, confirmations, accuracy, speed_kmh, heading,
       length_m, source, created_by
from public.hazards;

grant select on public.hazards_geojson to anon, authenticated;

-- 6. Enregistrer un relevé : crée un danger, ou confirme le danger existant
--    - point : même type à moins de 30 m  → confirmation, position moyennée
--    - tronçon : même type, recouvrement ≥ 60 % (à 40 m près) → confirmation,
--      on garde le tracé le plus long
create or replace function public.report_hazard(
  p_id          text,
  p_type        text,
  p_geometry    jsonb,
  p_observed_at timestamptz default now(),
  p_accuracy    integer default null,
  p_speed_kmh   integer default null,
  p_heading     integer default null,
  p_source      text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  g        geography;
  gkind    text;
  v_len    double precision;
  ex       record;
  v_hazard text;
  v_result text;
  v_conf   integer;
begin
  if auth.uid() is null then
    raise exception 'Connexion requise';
  end if;
  if p_id is null or length(p_id) < 4 or length(p_id) > 64 then
    raise exception 'Identifiant invalide';
  end if;
  if p_type not in ('dos_dane','nid_poule','portion_degradee','betail',
                    'deviation','pont_etroit','zone_inondable') then
    raise exception 'Type de danger inconnu : %', p_type;
  end if;

  -- Relevé déjà reçu (renvoi après coupure réseau) : on ne compte pas deux fois
  select r.hazard_id, r.result into ex from reports r where r.id = p_id;
  if found then
    return jsonb_build_object('hazard_id', ex.hazard_id, 'result', ex.result, 'already_received', true);
  end if;
  -- Danger déjà présent avec cet identifiant (ré-import d'un export) : rien à faire
  if exists (select 1 from hazards h where h.id = p_id) then
    return jsonb_build_object('hazard_id', p_id, 'result', 'exists', 'already_received', true);
  end if;

  g := st_setsrid(st_geomfromgeojson(p_geometry::text), 4326)::geography;
  gkind := geometrytype(g::geometry);
  if gkind not in ('POINT', 'LINESTRING') then
    raise exception 'Géométrie non prise en charge : %', gkind;
  end if;
  if gkind = 'LINESTRING' and st_npoints(g::geometry) > 5000 then
    raise exception 'Tronçon trop long';
  end if;

  -- Un seul enregistrement à la fois par type : évite deux doublons simultanés
  perform pg_advisory_xact_lock(hashtext('routealerte:' || p_type));

  if gkind = 'POINT' then
    select h.id, h.geom, h.confirmations into ex
    from hazards h
    where h.type = p_type
      and geometrytype(h.geom::geometry) = 'POINT'
      and st_dwithin(h.geom, g, 30)
    order by st_distance(h.geom, g)
    limit 1;

    if found then
      v_conf := ex.confirmations;
      update hazards set
        geom = st_setsrid(st_makepoint(
                 (st_x(ex.geom::geometry) * v_conf + st_x(g::geometry)) / (v_conf + 1),
                 (st_y(ex.geom::geometry) * v_conf + st_y(g::geometry)) / (v_conf + 1)), 4326)::geography,
        confirmations = v_conf + 1,
        last_seen = greatest(last_seen, p_observed_at)
      where id = ex.id;
      v_hazard := ex.id; v_result := 'confirmed';
    end if;

  else
    v_len := st_length(g);
    select c.id, c.length_m, c.confirmations into ex
    from (
      select h.id, h.length_m, h.confirmations,
             greatest(
               st_length(st_intersection(g::geometry, st_buffer(h.geom, 40)::geometry)::geography)
                 / nullif(v_len, 0),
               st_length(st_intersection(h.geom::geometry, st_buffer(g, 40)::geometry)::geography)
                 / nullif(st_length(h.geom), 0)
             ) as share
      from hazards h
      where h.type = p_type
        and geometrytype(h.geom::geometry) = 'LINESTRING'
        and st_dwithin(h.geom, g, 40)
    ) c
    where c.share >= 0.6
    order by c.share desc
    limit 1;

    if found then
      update hazards set
        confirmations = confirmations + 1,
        last_seen = greatest(last_seen, p_observed_at),
        geom      = case when v_len > coalesce(length_m, 0) then g else geom end,
        length_m  = case when v_len > coalesce(length_m, 0) then round(v_len)::int else length_m end
      where id = ex.id;
      v_hazard := ex.id; v_result := 'confirmed';
    end if;
  end if;

  if v_hazard is null then
    insert into hazards (id, type, geom, created_at, last_seen, accuracy, speed_kmh, heading, length_m, source, created_by)
    values (p_id, p_type, g, p_observed_at, p_observed_at, p_accuracy, p_speed_kmh, p_heading,
            case when gkind = 'LINESTRING' then round(st_length(g))::int end, p_source, auth.uid());
    v_hazard := p_id; v_result := 'new';
  end if;

  insert into reports (id, hazard_id, user_id, type, geom, observed_at, accuracy, speed_kmh, heading, source, result)
  values (p_id, v_hazard, auth.uid(), p_type, g, p_observed_at, p_accuracy, p_speed_kmh, p_heading, p_source, v_result);

  return jsonb_build_object('hazard_id', v_hazard, 'result', v_result);
end;
$$;

-- 7. Supprimer un danger : uniquement ceux que l'on a soi-même créés
create or replace function public.delete_hazard(p_id text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare n integer;
begin
  if auth.uid() is null then
    raise exception 'Connexion requise';
  end if;
  delete from hazards where id = p_id and created_by = auth.uid();
  get diagnostics n = row_count;
  return n > 0;
end;
$$;

-- 8. Ping : appelé par GitHub Actions pour éviter la mise en pause du projet gratuit
create or replace function public.ping()
returns jsonb
language sql
security definer
set search_path = public
as $$
  select jsonb_build_object('ok', true, 'hazards', (select count(*) from hazards), 'at', now());
$$;

-- 9. Droits d'exécution
revoke all on function public.report_hazard(text, text, jsonb, timestamptz, integer, integer, integer, text) from public, anon;
revoke all on function public.delete_hazard(text) from public, anon;
grant execute on function public.report_hazard(text, text, jsonb, timestamptz, integer, integer, integer, text) to authenticated;
grant execute on function public.delete_hazard(text) to authenticated;
grant execute on function public.ping() to anon, authenticated;
