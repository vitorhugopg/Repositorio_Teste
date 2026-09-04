# CRM Base — Clínica que Converte

> Este documento registra o CRM (`index.html`) como a **base técnica padrão** da frente "Soluções de sistemas". Ele nasceu como um protótipo sob medida para um cliente específico, mas ficou bom o suficiente para virar o ponto de partida de todos os próximos projetos de CRM da Clínica que Converte — em vez de reconstruir do zero a cada cliente novo.

## Contexto e decisão

O arquivo foi desenvolvido exclusivamente para uma clínica/cliente. Na avaliação do protótipo, ficou claro que a base de dados, a lógica de funil e a interface já resolvem bem o problema central (organizar leads, consultas e conversão) — o que falta é a camada de infraestrutura (banco online, login, multi-clínica) para ele deixar de ser um protótipo local e virar produto.

**Decisão:** este HTML deixa de ser "o CRM do cliente X" e passa a ser "o CRM-base da Clínica que Converte". Cada novo cliente que precisar de solução de sistema/CRM parte deste template, adaptando campos e configurações — não recomeçando do zero.

## Estado atual do protótipo (o que já funciona)

**Navegação / módulos:**
- Assistente de Vendas (copiloto de conversa com o lead)
- Pacientes (cadastro e listagem, com filtros por origem, procedimento, responsável e status)
- Kanban (funil visual)
- Indicações (rastreamento de pacientes indicados por outros pacientes)
- Dashboard
- Agenda
- Configurações (dados da clínica, funcionários, procedimentos, origens, motivos de perda, etapas do funil, backup)

**Modelo de dados (por clínica):** clínica, usuário atual, funcionários, procedimentos (com valor médio), origens de lead, motivos de perda, etapas do funil (nome/cor customizáveis) e pacientes. Cada paciente carrega um registro bem completo: dados de contato, origem, procedimento, responsável, datas de contato, próxima ação, consulta (marcada/compareceu), avaliação (exames, plano, orçamento apresentado), financeiro (orçamento, fechamento), motivo de perda, indicação, histórico de interações, anotações e campos personalizados.

**Funil automático:** o status do paciente (novo lead → em atendimento → consulta marcada → compareceu/não compareceu → plano apresentado → pendente → fechado/perdido/não precisa) é **calculado automaticamente** a partir dos dados preenchidos, não exige que a secretária mude status manualmente. Existe também um sistema de urgência (atrasado / próximo / em dia) baseado em dias sem contato e na data da próxima ação.

**Assistente de Vendas:** hoje é **simulado** — as respostas são geradas localmente por regras (chips de objeções comuns, modos de ação), sem IA real conectada. O código já deixa um ponto preparado para futuramente plugar uma API de IA. Também já existe uma seção de "limites éticos" (não diagnostica, não promete resultado clínico, não cria urgência falsa).

**Backup:** exportação/importação de backup completo em JSON e exportação de pacientes em CSV — funciona hoje mesmo sem banco online.

**Design system:** tokens de cor (tons "ink" e "gold"), tipografia própria (Fraunces para títulos, Manrope para corpo), suporte a modo escuro. Essa identidade visual pode ser mantida como o "rosto" padrão dos CRMs da Clínica que Converte.

## Limitações atuais — não está pronto para pacientes reais

| Item | Status |
|---|---|
| Interface | ✅ |
| Cadastro de pacientes | ✅ |
| Kanban | ✅ |
| Agenda | ✅ |
| Dashboard | ✅ |
| Configurações | ✅ |
| Funcionários | ✅ |
| Exportação/backup | ✅ |
| Assistente comercial | ⚠️ Simulado (sem IA real) |
| Banco de dados online | ❌ |
| Login real | ❌ |
| Usuários autenticados | ❌ |
| Multi-clínica seguro | ❌ |
| Backup online | ❌ |
| Controle de permissões | ❌ |
| Pronto para pacientes reais | ❌ |

**Causa raiz técnica:** todo o estado (`DB`) é salvo apenas no `localStorage` do navegador (`cqc_crm_state_v1`). Isso inclui dados pessoais de pacientes (telefone, e-mail, nascimento, cidade, observações) e dados comerciais. Como consequência: dois computadores/dispositivos nunca veem os mesmos dados, e não existe autenticação real — o "usuário atual" exibido é só um nome/cargo salvo no próprio estado, sem senha ou verificação.

## Caminho de evolução: de protótipo local para produto multi-clínica

**Decisão estrutural importante:** não construir um CRM exclusivo por cliente. O modelo de dados já usa os conceitos certos (clínica, funcionários, procedimentos, pacientes, origens, configurações) para virar um sistema **multi-tenant** — um único CRM que atende várias clínicas com isolamento total de dados entre elas, via um campo `clinica_id` em toda entidade (pacientes, funcionários, agenda, kanban, configurações etc.). Definir isso agora, na estrutura do banco, evita retrabalho grande depois.

### Etapa 1 — Banco de dados
Criar o banco (Supabase) com tabelas aproximadamente assim: `CLINICAS`, `USUARIOS`, `PACIENTES`, `FUNCIONARIOS`, `PROCEDIMENTOS`, `NOTAS`, `INTERACOES`, `CONSULTAS`, `FOLLOWUPS`, `CONFIGURACOES`.

### Etapa 2 — Login
Tela de autenticação (e-mail/senha) antes do acesso ao CRM. Ninguém entra sem autenticação real.

### Etapa 3 — Conectar o CRM ao banco
A transformação principal: sai `localStorage.setItem(...)`, entram operações no banco online. A interface pode permanecer praticamente igual.

### Etapa 4 — Permissões
Perfis de acesso (ex: Administrador, Dentista, Secretária, Comercial), cada um com um conjunto definido do que pode ver/fazer.

### Etapa 5 — Hospedagem
Publicar em um serviço de hospedagem, idealmente com domínio próprio (ex: `crm.clinicaqueconverte.com.br`).

### Etapa 6 — Backup, segurança e LGPD
Antes de qualquer clínica usar com pacientes reais: revisar permissões, política de backup, exportação/recuperação de acesso, e a separação de dados entre clínicas (`clinica_id`).

## Regra de uso deste template em novos projetos

Sempre que a frente **"Soluções de sistemas"** for recomendada e envolver CRM:

1. Parta deste protótipo como base — não construa um CRM novo do zero.
2. Adapte campos, procedimentos, origens e etapas do funil à especialidade e à realidade do novo cliente, mantendo a estrutura de dados original.
3. Nunca entregue a versão apenas com `localStorage` para uso com pacientes reais — antes de produção, pelo menos as Etapas 1 e 2 do roadmap (banco + login) precisam estar prontas.
4. Priorize migrar para a versão multi-tenant (com `clinica_id`) em vez de manter uma instância isolada por cliente — isso facilita manutenção e evolução do produto como um todo.

## O que manter sempre, independentemente da evolução técnica

- Exportação/importação de backup em JSON e exportação de pacientes em CSV.
- A estrutura de dados rica do paciente (histórico, anotações, avaliação, financeiro, indicação).
- O sistema de status automático do funil (o funil se atualiza sozinho conforme os dados são preenchidos).
- O design system (tokens visuais, tipografia Fraunces/Manrope) como identidade visual padrão dos CRMs entregues.
