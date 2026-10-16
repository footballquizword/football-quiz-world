-- FOOTBALL QUIZ WORLD: schema Supabase (rode inteiro no SQL Editor)
create table public.profiles(
  id uuid primary key references auth.users on delete cascade,
  username text not null check (username ~ '^[A-Za-z0-9_]{3,20}$'),
  xp int not null default 0, best_score int not null default 0, best_streak int not null default 0,
  games int not null default 0, correct int not null default 0, answered int not null default 0,
  created_at timestamptz not null default now());
create unique index profiles_username_key on public.profiles(lower(username));

create table public.questions(
  id serial primary key, cat text not null, diff smallint not null, q text not null,
  options jsonb not null, correct smallint not null, explanation text, visual text, source text,
  active boolean not null default true, updated_at timestamptz not null default now());

create table public.matches(
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users on delete cascade,
  mode text not null, cat text not null, question_ids int[] not null,
  started_at timestamptz not null default now(), last_event_at timestamptz not null default now(),
  finished_at timestamptz, score int not null default 0, correct int not null default 0,
  answered int not null default 0, streak int not null default 0, max_streak int not null default 0);
create index on public.matches(user_id, started_at desc);
create index on public.matches(finished_at, score desc);

create table public.match_answers(
  match_id uuid not null references public.matches on delete cascade,
  question_id int not null references public.questions,
  choice smallint, correct boolean not null, points int not null, ms int not null,
  answered_at timestamptz not null default now(),
  primary key(match_id, question_id));

-- RLS: tudo ligado; clientes só leem perfis (público) e as próprias partidas.
alter table public.profiles enable row level security;
alter table public.questions enable row level security;
alter table public.matches enable row level security;
alter table public.match_answers enable row level security;
revoke all on public.profiles, public.questions, public.matches, public.match_answers from anon, authenticated;
grant select on public.profiles to anon, authenticated;
grant select on public.matches to authenticated;
create policy profiles_read on public.profiles for select using (true);
create policy matches_own_read on public.matches for select to authenticated using (user_id = auth.uid());
-- Nenhuma política de INSERT/UPDATE/DELETE: só as funções abaixo (security definer) escrevem.
-- questions e match_answers não têm política: clientes nunca veem as respostas certas.

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare u text := coalesce(new.raw_user_meta_data->>'username','');
begin
  if u !~ '^[A-Za-z0-9_]{3,20}$' or exists(select 1 from profiles where lower(username)=lower(u)) then
    u := 'jogador' || substr(replace(new.id::text,'-',''),1,8);
  end if;
  insert into profiles(id, username) values (new.id, u);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.set_username(p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login_required'; end if;
  if p_name !~ '^[A-Za-z0-9_]{3,20}$' then raise exception 'invalid_name'; end if;
  update profiles set username = p_name where id = auth.uid();
end $$;

create or replace function public.start_match(p_mode text, p_cat text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); ids int[]; seen int[]; n int; mid uuid;
begin
  if uid is null then raise exception 'login_required'; end if;
  if p_mode not in ('classico','cronometro','sobrevivencia','diario') then raise exception 'bad_mode'; end if;
  if (select count(*) from matches where user_id = uid and started_at > now() - interval '1 minute') >= 10 then
    raise exception 'rate_limited'; end if;
  if p_mode = 'diario' and exists(select 1 from matches where user_id = uid and mode = 'diario'
     and finished_at is not null and finished_at::date = current_date) then raise exception 'daily_done'; end if;
  n := case when p_mode = 'sobrevivencia' then 30 else 10 end;
  select coalesce(array_agg(question_id), '{}') into seen from (
    select ma.question_id from match_answers ma join matches m on m.id = ma.match_id
    where m.user_id = uid order by ma.answered_at desc limit 300) s;
  select array_agg(id) into ids from (
    select id from questions
    where active and (p_cat = 'todas' or p_mode = 'diario' or cat = p_cat)
    order by case when p_mode = 'diario' then 0 else (id = any(seen))::int end,
             case when p_mode = 'diario' then md5(current_date::text || id::text) else md5(random()::text || id::text) end
    limit n) s;
  if ids is null then raise exception 'no_questions'; end if;
  insert into matches(user_id, mode, cat, question_ids) values (uid, p_mode, p_cat, ids) returning id into mid;
  return jsonb_build_object('match_id', mid, 'timer', case when p_mode = 'cronometro' then 8 else 15 end,
    'questions', (select jsonb_agg(jsonb_build_object('id', q.id, 'cat', q.cat, 'diff', q.diff, 'q', q.q,
       'options', q.options, 'visual', q.visual) order by array_position(ids, q.id))
       from questions q where q.id = any(ids)));
end $$;

create or replace function public.answer_question(p_match uuid, p_q int, p_choice int, p_ms int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m matches%rowtype; qq questions%rowtype; ok boolean; t int; ms int; pts int := 0; st int;
begin
  select * into m from matches where id = p_match and user_id = auth.uid() for update;
  if not found or m.finished_at is not null then raise exception 'invalid_match'; end if;
  if m.question_ids[m.answered + 1] is distinct from p_q then raise exception 'out_of_order'; end if;
  if now() - m.last_event_at < interval '300 milliseconds' then raise exception 'too_fast'; end if;
  select * into qq from questions where id = p_q;
  t := case when m.mode = 'cronometro' then 8 else 15 end;
  ms := least(greatest(coalesce(p_ms, t * 1000), 600), t * 1000);
  ok := p_choice is not null and p_choice = qq.correct;
  st := case when ok then m.streak + 1 else 0 end;
  if ok then pts := 100 + round((t * 1000 - ms) / 1000.0 * 5)::int + least(st, 10) * 10; end if;
  insert into match_answers(match_id, question_id, choice, correct, points, ms) values (p_match, p_q, p_choice, ok, pts, ms);
  update matches set answered = answered + 1, correct = correct + (case when ok then 1 else 0 end),
    score = score + pts, streak = st, max_streak = greatest(max_streak, st), last_event_at = now() where id = p_match;
  return jsonb_build_object('correct', ok, 'answer', qq.correct, 'explanation', qq.explanation, 'points', pts);
end $$;

create or replace function public.finish_match(p_match uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare m matches%rowtype; xpg int;
begin
  select * into m from matches where id = p_match and user_id = auth.uid() for update;
  if not found then raise exception 'invalid_match'; end if;
  xpg := round(m.score / 4.0)::int + m.correct * 5;
  if m.finished_at is null then  -- idempotente: finalizar duas vezes não duplica XP nem partida
    update matches set finished_at = now() where id = p_match;
    update profiles set xp = xp + xpg, best_score = greatest(best_score, m.score),
      best_streak = greatest(best_streak, m.max_streak), games = games + 1,
      correct = correct + m.correct, answered = answered + m.answered where id = auth.uid();
  end if;
  return jsonb_build_object('score', m.score, 'correct', m.correct, 'answered', m.answered,
                            'max_streak', m.max_streak, 'xp_gained', xpg);
end $$;

create or replace function public.get_leaderboard(p_period text, p_limit int default 50)
returns table(pos bigint, username text, xp int, score int, games int)
language sql stable security definer set search_path = public as $$
  select row_number() over (order by s.score desc, p.username), p.username, p.xp, s.score, p.games
  from (select user_id, max(score) as score from matches
        where finished_at is not null and (p_period <> 'weekly' or finished_at >= date_trunc('week', now()))
        group by user_id) s join profiles p on p.id = s.user_id
  order by 1 limit least(p_limit, 100)
$$;

revoke all on function public.start_match, public.answer_question, public.finish_match, public.set_username, public.get_leaderboard from public, anon, authenticated;
grant execute on function public.start_match, public.answer_question, public.finish_match, public.set_username to authenticated;
grant execute on function public.get_leaderboard to anon, authenticated;

-- Perguntas iniciais (71). Novas perguntas: insira em public.questions (via painel Table Editor).
insert into public.questions(cat,diff,q,options,correct,explanation,visual) values
('selecoes',1,'Qual seleção venceu a Copa do Mundo de 2022?','["França","Argentina","Croácia","Brasil"]'::jsonb,1,'A Argentina venceu a França nos pênaltis na final, no Catar.',null),
('selecoes',1,'Qual seleção tem mais títulos da Copa do Mundo masculina?','["Alemanha","Itália","Brasil","Argentina"]'::jsonb,2,'O Brasil é pentacampeão (1958, 1962, 1970, 1994 e 2002).',null),
('competicoes',1,'Em que país foi disputada a Copa do Mundo de 2014?','["África do Sul","Brasil","Rússia","Alemanha"]'::jsonb,1,'A Copa de 2014 foi no Brasil; a Alemanha foi campeã.',null),
('historia',2,'Quem é o maior artilheiro da história das Copas do Mundo masculinas (até 2022)?','["Ronaldo Fenômeno","Pelé","Miroslav Klose","Gerd Müller"]'::jsonb,2,'Klose marcou 16 gols em Copas, recorde mantido até a edição de 2022.',null),
('selecoes',2,'Qual seleção foi a campeã da primeira Copa do Mundo, em 1930?','["Argentina","Uruguai","Brasil","Itália"]'::jsonb,1,'O Uruguai venceu a Argentina por 4 a 2 em Montevidéu.',null),
('competicoes',1,'Qual clube tem mais títulos da UEFA Champions League/Copa dos Campeões?','["Milan","Bayern de Munique","Liverpool","Real Madrid"]'::jsonb,3,'O Real Madrid é o maior campeão do torneio, com 15 títulos até 2024.',null),
('competicoes',2,'Qual clube tem mais títulos da Copa Libertadores?','["Boca Juniors","Independiente","Peñarol","River Plate"]'::jsonb,1,'O Independiente (Argentina) foi campeão 7 vezes.',null),
('clubes',2,'Qual clube foi campeão invicto da Premier League em 2003-04?','["Chelsea","Manchester United","Arsenal","Liverpool"]'::jsonb,2,'O Arsenal, de Arsène Wenger, ficou conhecido como "The Invincibles".',null),
('competicoes',1,'Quem venceu a Eurocopa de 2024?','["Inglaterra","Espanha","França","Alemanha"]'::jsonb,1,'A Espanha venceu a Inglaterra na final, em Berlim.',null),
('competicoes',1,'Quem venceu a Copa América de 2024?','["Colômbia","Brasil","Argentina","Uruguai"]'::jsonb,2,'A Argentina venceu a Colômbia na final, nos EUA.',null),
('selecoes',2,'Em qual país Pelé conquistou sua primeira Copa, em 1958?','["México","Suécia","Chile","Inglaterra"]'::jsonb,1,'Pelé tinha 17 anos e foi campeão na Suécia.',null),
('historia',3,'Qual é a maior goleada da história das Copas do Mundo masculinas (placar da vitória)?','["Hungria 10 x 1 El Salvador","Brasil 9 x 0 Haiti","Alemanha 8 x 0 Arábia Saudita","Áustria 7 x 5 Suíça"]'::jsonb,0,'Hungria 10 x 1 El Salvador, em 1982, é o maior placar de vitória em Copas.',null),
('selecoes',2,'Qual seleção foi campeã da primeira Copa do Mundo feminina, em 1991?','["Noruega","Alemanha","Estados Unidos","Suécia"]'::jsonb,2,'Os EUA venceram a Noruega por 2 a 1 na China.',null),
('jogadores',2,'Quantas Bolas de Ouro Lionel Messi havia conquistado até 2023?','["6","7","8","9"]'::jsonb,2,'Messi ganhou em 2009, 2010, 2011, 2012, 2015, 2019, 2021 e 2023.',null),
('selecoes',1,'De qual país é esta bandeira? 🇯🇵','["China","Coreia do Sul","Japão","Vietnã"]'::jsonb,2,'Bandeira do Japão.',null),
('selecoes',1,'De qual país é esta bandeira? 🇭🇷','["Croácia","Sérvia","Eslováquia","Rússia"]'::jsonb,0,'Croácia, vice-campeã em 2018 e terceira em 2022.',null),
('selecoes',2,'De qual país é esta bandeira? 🇲🇦','["Tunísia","Turquia","Argélia","Marrocos"]'::jsonb,3,'Marrocos foi a primeira seleção africana em uma semifinal de Copa, em 2022.',null),
('selecoes',1,'De qual país é esta bandeira? 🇨🇭','["Suíça","Dinamarca","Áustria","Inglaterra"]'::jsonb,0,'Bandeira da Suíça.',null),
('jogadores',2,'Em quantas Copas do Mundo Pelé foi campeão?','["2","3","4","5"]'::jsonb,1,'Em 1958, 1962 e 1970.',null),
('clubes',1,'Qual clube manda seus jogos no estádio Old Trafford?','["Manchester City","Liverpool","Manchester United","Everton"]'::jsonb,2,'Old Trafford é a casa do Manchester United.',null),
('clubes',1,'Qual clube joga no estádio Anfield?','["Liverpool","Chelsea","Arsenal","Tottenham"]'::jsonb,0,'Anfield fica em Liverpool e é a casa do Liverpool FC.',null),
('clubes',1,'Qual clube joga no Camp Nou?','["Real Madrid","Atlético de Madrid","Valencia","Barcelona"]'::jsonb,3,'O Camp Nou é a casa do FC Barcelona.',null),
('competicoes',2,'Qual clube tem mais títulos da Ligue 1 francesa?','["Olympique de Marseille","Paris Saint-Germain","Saint-Étienne","Lyon"]'::jsonb,1,'O PSG é o maior campeão da Ligue 1.',null),
('competicoes',2,'Qual clube tem mais títulos da Serie A italiana?','["Milan","Inter de Milão","Juventus","Napoli"]'::jsonb,2,'A Juventus lidera em títulos da Serie A.',null),
('competicoes',1,'Qual clube tem mais títulos da Bundesliga?','["Borussia Dortmund","Bayern de Munique","Werder Bremen","Schalke 04"]'::jsonb,1,'O Bayern de Munique é o maior campeão alemão.',null),
('competicoes',2,'Qual clube é o maior campeão do Brasileirão (contagem da CBF)?','["Flamengo","Corinthians","Palmeiras","Santos"]'::jsonb,2,'O Palmeiras lidera a contagem da CBF. O número muda a cada temporada.',null),
('historia',2,'Em 1986, contra qual seleção Maradona marcou o gol da "Mão de Deus"?','["Inglaterra","Alemanha","Bélgica","Brasil"]'::jsonb,0,'Foi nas quartas de final, no Estádio Azteca, México.',null),
('historia',3,'Em que cidade fica o estádio do Maracanã?','["São Paulo","Rio de Janeiro","Belo Horizonte","Brasília"]'::jsonb,1,'O Maracanã fica no Rio de Janeiro e foi palco das finais de 1950 e 2014.',null),
('clubes',2,'Em qual estádio o Bayern de Munique joga?','["Signal Iduna Park","Allianz Arena","Olympiastadion","Veltins-Arena"]'::jsonb,1,'A Allianz Arena é a casa do Bayern desde 2005.',null),
('clubes',1,'Qual clube é apelidado de "Los Blancos"?','["Real Madrid","Valencia","Sevilla","Atlético de Madrid"]'::jsonb,0,'O branco do uniforme deu o apelido ao Real Madrid.','c:#fff:#e8e8e8:RM'),
('clubes',1,'Qual clube inglês é conhecido como "Red Devils"?','["Liverpool","Manchester United","Arsenal","Nottingham Forest"]'::jsonb,1,'Red Devils é o apelido do Manchester United.','c:#da020e:#a00:MUN'),
('clubes',1,'Qual clube italiano é chamado de "Velha Senhora"?','["Roma","Lazio","Juventus","Torino"]'::jsonb,2,'La Vecchia Signora é a Juventus, de camisa listrada preta e branca.','c:#000:#fff:JUV'),
('clubes',2,'Qual clube foi fundado por Joan Gamper em 1899?','["Espanyol","Barcelona","Real Madrid","Valencia"]'::jsonb,1,'Gamper fundou o FC Barcelona em 29 de novembro de 1899.','c:#004d98:#a50044:FCB'),
('clubes',1,'Quais são as cores principais do uniforme do Flamengo?','["Verde e branco","Azul e branco","Vermelho e preto","Preto e branco"]'::jsonb,2,'O Flamengo é conhecido pelo rubro-negro.','c:#c8102e:#000:FLA'),
('clubes',2,'Qual clube brasileiro venceu o Liverpool na final do Mundial de 1981?','["Santos","Flamengo","Grêmio","São Paulo"]'::jsonb,1,'O Flamengo venceu por 3 a 0, em Tóquio.',null),
('clubes',2,'Qual clube o Corinthians derrotou na final do Mundial de Clubes de 2012?','["Bayern de Munique","Real Madrid","Chelsea","Barcelona"]'::jsonb,2,'O Corinthians venceu o Chelsea por 1 a 0, com gol de Guerrero.',null),
('clubes',3,'Quantos títulos mundiais (Intercontinental e Mundial FIFA) o São Paulo possui?','["1","2","3","4"]'::jsonb,2,'O São Paulo foi campeão em 1992, 1993 e 2005.',null),
('clubes',2,'Qual clube joga no estádio Santiago Bernabéu?','["Real Madrid","Barcelona","Atlético de Madrid","Sevilla"]'::jsonb,0,'O Bernabéu fica em Madri e é a casa do Real Madrid.',null),
('clubes',3,'Em qual cidade ocorre o clássico "Old Firm", entre Celtic e Rangers?','["Edimburgo","Glasgow","Dundee","Aberdeen"]'::jsonb,1,'Celtic e Rangers são de Glasgow, na Escócia.',null),
('clubes',2,'Qual estádio é compartilhado por Milan e Inter de Milão?','["San Siro","Allianz Stadium","Olímpico","Maradona"]'::jsonb,0,'O San Siro, oficialmente Giuseppe Meazza, é usado pelos dois clubes.',null),
('jogadores',2,'Quantas Bolas de Ouro Cristiano Ronaldo havia conquistado até 2023?','["3","4","5","6"]'::jsonb,2,'Ele ganhou em 2008, 2013, 2014, 2016 e 2017.',null),
('jogadores',2,'Em que ano Ronaldinho Gaúcho conquistou a Bola de Ouro?','["2004","2005","2006","2007"]'::jsonb,1,'Ronaldinho foi eleito o melhor do mundo em 2005, pelo Barcelona.',null),
('jogadores',2,'Qual brasileiro ganhou a Bola de Ouro em 2007?','["Kaká","Ronaldinho","Robinho","Adriano"]'::jsonb,0,'Kaká era do Milan e foi campeão da Champions em 2006-07.',null),
('jogadores',2,'Quantos gols Zidane marcou na final da Copa de 1998, contra o Brasil?','["1","2","3","0"]'::jsonb,1,'Ele marcou duas vezes de cabeça; a França venceu por 3 a 0.',null),
('jogadores',2,'Por qual clube italiano Maradona foi campeão nacional?','["Juventus","Napoli","Roma","Inter de Milão"]'::jsonb,1,'O Napoli foi campeão italiano em 1986-87 e 1989-90.',null),
('jogadores',3,'Quantos gols Messi marcou na Copa do Mundo de 2022?','["5","6","7","8"]'::jsonb,2,'Messi fez 7 gols e foi eleito o melhor jogador do torneio.',null),
('jogadores',2,'Quantos gols Mbappé marcou na final da Copa de 2022?','["1","2","3","4"]'::jsonb,2,'Mbappé fez três gols e foi o artilheiro do torneio, com 8.',null),
('jogadores',3,'Quantas vezes Marta foi eleita melhor jogadora do mundo pela FIFA?','["4","5","6","7"]'::jsonb,2,'Seis vezes: cinco seguidas (2006 a 2010) e em 2018.',null),
('jogadores',3,'Qual é o único goleiro a ganhar a Bola de Ouro?','["Gianluigi Buffon","Lev Yashin","Manuel Neuer","Oliver Kahn"]'::jsonb,1,'O soviético Lev Yashin venceu em 1963.',null),
('jogadores',3,'Por qual valor Neymar foi transferido ao PSG em 2017?','["€ 150 milhões","€ 180 milhões","€ 222 milhões","€ 250 milhões"]'::jsonb,2,'A multa de 222 milhões de euros foi paga ao Barcelona.',null),
('selecoes',1,'Qual seleção venceu a Copa do Mundo de 2018?','["Croácia","França","Bélgica","Brasil"]'::jsonb,1,'A França venceu a Croácia por 4 a 2, na Rússia.',null),
('selecoes',2,'Quem foi o campeão da Copa de 2010, na África do Sul?','["Holanda","Alemanha","Uruguai","Espanha"]'::jsonb,3,'A Espanha venceu a Holanda por 1 a 0, com gol de Iniesta.',null),
('selecoes',2,'Quais países sediaram juntos a Copa do Mundo de 2002?','["Japão e Coreia do Sul","China e Japão","Tailândia e Vietnã","Coreia do Sul e China"]'::jsonb,0,'Foi a primeira Copa em dois países; o Brasil foi pentacampeão.',null),
('selecoes',1,'Qual placar a Alemanha aplicou no Brasil na semifinal da Copa de 2014?','["5 a 0","7 a 1","6 a 2","4 a 0"]'::jsonb,1,'Foi 7 a 1, no Mineirão, em Belo Horizonte.',null),
('selecoes',3,'Qual Copa deu ao Brasil a posse definitiva da Taça Jules Rimet?','["1958","1962","1970","1994"]'::jsonb,2,'O tricampeonato de 1970, no México, garantiu a taça ao Brasil.',null),
('selecoes',1,'De qual país é esta bandeira?','["Bélgica","Países Baixos","Luxemburgo","França"]'::jsonb,1,'Bandeira dos Países Baixos (Holanda).','🇳🇱'),
('selecoes',2,'De qual país é esta bandeira?','["Senegal","Mali","Gana","Camarões"]'::jsonb,0,'Bandeira do Senegal, com estrela verde ao centro.','🇸🇳'),
('selecoes',1,'De qual país é esta bandeira?','["Paraguai","Uruguai","Argentina","Chile"]'::jsonb,1,'Bandeira do Uruguai, bicampeão mundial (1930 e 1950).','🇺🇾'),
('competicoes',2,'Qual clube tem mais títulos da Premier League?','["Manchester City","Liverpool","Arsenal","Manchester United"]'::jsonb,3,'O Manchester United tem 20 títulos ingleses da era da liga principal.',null),
('competicoes',1,'Qual clube tem mais títulos de La Liga?','["Barcelona","Real Madrid","Atlético de Madrid","Athletic Bilbao"]'::jsonb,1,'O Real Madrid é o maior campeão espanhol.',null),
('competicoes',2,'Qual clube venceu a Libertadores de 2023?','["Boca Juniors","Fluminense","Flamengo","Palmeiras"]'::jsonb,1,'O Fluminense venceu o Boca no Maracanã e foi campeão pela 1ª vez.',null),
('competicoes',3,'Qual clube ganhou a Champions League 2022-23, vencendo a Inter na final?','["Real Madrid","Manchester City","Bayern de Munique","Chelsea"]'::jsonb,1,'O City venceu por 1 a 0, em Istambul, e levou o troféu pela 1ª vez.',null),
('competicoes',2,'Quem venceu a Copa do Mundo feminina de 2023?','["Inglaterra","Estados Unidos","Espanha","Suécia"]'::jsonb,2,'A Espanha venceu a Inglaterra por 1 a 0, na Austrália.',null),
('competicoes',2,'Qual seleção venceu a Eurocopa disputada em 2021?','["Itália","Inglaterra","Espanha","Bélgica"]'::jsonb,0,'A Itália venceu a Inglaterra nos pênaltis, em Wembley.',null),
('historia',2,'Quem é o maior artilheiro da história da Champions League?','["Lionel Messi","Karim Benzema","Cristiano Ronaldo","Robert Lewandowski"]'::jsonb,2,'Cristiano Ronaldo lidera, com 140 gols.',null),
('historia',3,'Quem marcou 13 gols na Copa de 1958, recorde de uma única edição?','["Pelé","Just Fontaine","Sándor Kocsis","Garrincha"]'::jsonb,1,'O francês Just Fontaine fez 13 gols, marca ainda não superada.',null),
('historia',3,'Qual seleção foi a primeira campeã da Eurocopa, em 1960?','["Espanha","Iugoslávia","União Soviética","França"]'::jsonb,2,'A União Soviética venceu a Iugoslávia na final, em Paris.',null),
('historia',4,'Qual clube foi o primeiro campeão da Copa Libertadores, em 1960?','["Peñarol","Santos","Boca Juniors","Nacional"]'::jsonb,0,'O Peñarol, do Uruguai, venceu o Olimpia na final.',null),
('historia',3,'Qual clube venceu a Premier League 2015-16 como azarão?','["Tottenham","Leicester City","Everton","West Ham"]'::jsonb,1,'O Leicester, de Claudio Ranieri, foi campeão inglês pela única vez.',null),
('historia',4,'Em que ano foi fundada a FIFA?','["1894","1904","1914","1924"]'::jsonb,1,'A FIFA foi criada em Paris, em 1904.',null),
('historia',4,'Quem foi o campeão da final de 1950, no Maracanã?','["Brasil","Uruguai","Suécia","Espanha"]'::jsonb,1,'O Uruguai venceu por 2 a 1, no jogo conhecido como Maracanazo.',null);
