# FOOTBALL QUIZ WORLD — site público com Supabase

Arquivos: `index.html` (site), `config.js` (suas chaves públicas), `schema.sql` (tabelas, RLS, funções e 71 perguntas).
Sem `config.js` preenchido o site continua funcionando em modo local, sem login.

## 1. Criar o projeto Supabase (grátis)
1. supabase.com → New project (guarde a senha do banco).
2. **SQL Editor** → New query → cole todo o `schema.sql` → Run. Rode uma única vez.
3. **Authentication → Providers → Email**: ligado. Para testar rápido, desligue "Confirm email"; em produção deixe ligado.
4. **Authentication → URL Configuration**: Site URL = endereço final do seu site (e adicione-o em Redirect URLs).
5. (Opcional) **Providers → Google**: crie um OAuth Client no Google Cloud, use o Callback URL que o Supabase mostra e cole Client ID/Secret.

## 2. Chaves (o que colocar e onde)
Em **Project Settings → API** copie:
- **Project URL** → `SUPABASE_URL`
- **anon public key** → `SUPABASE_ANON_KEY`

Cole os dois em `config.js`. A chave anon é pública por desenho: quem protege os dados é o RLS do `schema.sql`.
**Nunca** use a chave `service_role` no site. Como o site é estático, não há variáveis de ambiente.
(Se migrar para Vite/React, use `VITE_SUPABASE_URL` e `VITE_SUPABASE_ANON_KEY`.)

## 3. Publicar
Suba a pasta (`index.html` + `config.js`) em Netlify, Vercel, Cloudflare Pages ou GitHub Pages. Qualquer pessoa cria conta e joga; ninguém precisa ser colaborador.

## 4. Como a segurança funciona
- Clientes não escrevem em nenhuma tabela. Só as funções `start_match`, `answer_question`, `finish_match` e `set_username` escrevem.
- O servidor sorteia as perguntas e guarda as respostas certas (tabela `questions` sem acesso de clientes). Cada resposta é conferida no servidor, uma vez por pergunta e na ordem.
- Partida finalizada duas vezes não duplica XP. Há limite de 10 partidas por minuto e 1 Desafio do dia por dia.
- Limite conhecido: o tempo de resposta (bônus de velocidade) é informado pelo navegador; o servidor o limita (mínimo 0,6 s, máximo do modo), então a fraude possível é pequena e limitada, mas não nula.

## 5. Teste depois de configurar
Crie 2 contas em navegadores diferentes, jogue, e confira o ranking Global/Semanal nos dois e o perfil em outro aparelho.
