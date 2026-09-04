# Briefing Preenchido — Mori Ortodontia

> Preenchido a partir do prompt de kickoff recebido para este projeto. Segue a estrutura de `Contexto/02-documento-briefing.md`. Campos não fornecidos no kickoff ficam marcados como "não informado no kickoff".

## 1. Dados gerais da clínica

- **Nome da clínica:** Mori Ortodontia
- **Especialidade(s):** Ortodontia, Pediatria, Dentística e Prótese
- **Cidade/região de atuação:** Belo Horizonte, MG
- **Tempo de mercado:** 30 anos
- **Quem é o dono:** Mariana e Celso, ambos sócios e ortodontistas
- **Quantos profissionais atendem na clínica:** 5 dentistas no total (incluindo Mariana e Celso)
- **Estrutura da equipe:** 1 secretária (também faz recepção), 1 ASB, 1 suporte administrativo/financeiro online

## 2–4. Aquisição, funil e atendimento comercial

Não detalhados novamente no kickoff deste projeto — assumir como válido o que já consta no diagnóstico anterior da clínica (fora do escopo desta pasta).

## 5. Sistemas e organização administrativa

- **Existe CRM ou sistema de controle de leads?** Sim, na prática: a clínica já usa uma planilha própria (Google Sheets/`CRM_Mori_Ortodontia.xlsx`) com cadastro de pacientes, kanban automático, dashboard mensal e rastreamento de indicações — 52 pacientes reais registrados entre maio e setembro de 2026.
- **Como é feito o controle financeiro hoje?** Em planilha solta, sem visibilidade consolidada dos números pelo dono (gargalo diagnosticado como prioridade 1).
- **Os dados de leads/vendas estão organizados?** Sim, de forma mais estruturada do que o briefing original sugeria — ver observação abaixo.
- **O dono tem visibilidade clara dos números?** Não, apesar de os dados já existirem e já serem calculados automaticamente na planilha (show rate, taxa de fechamento). O problema identificado não é falta de dado, é falta de visibilidade/uso do dado que já existe.

## 6. Gestão e rotina do dono

- Mentoria comercial para a secretária foi diagnosticada como prioridade 2 (fora do escopo desta etapa de construção de sistema).

## 7. Percepção do próprio dono

- Não detalhado novamente neste kickoff — ver diagnóstico original.

## 8. Observações do diagnosticador

- **Contradição identificada entre o briefing original e a planilha real:** o briefing dizia que a clínica não tinha controle fiel de show rate e taxa de fechamento. Na prática, a planilha já calculava isso automaticamente (92,3% dos leads agendaram consulta, 90,4% compareceram, 32,7% fecharam tratamento — números confirmados na migração para este CRM). Isso não muda a recomendação de prioridade (sistemas continua sendo o gargalo), mas muda o motivo: o problema é falta de visibilidade e uso consolidado do dado, não ausência de dado.
- Duas datas de "1º Contato" na planilha original parecem ter erro de digitação de ano (`2024-08-07` e `2025-07-07`, quando o restante da base está entre maio e setembro de 2026) — mantidas como estão na migração, mas vale confirmar e corrigir com a clínica.
- O campo "Procedimento de Interesse" era texto livre e inconsistente (ex.: "Invisalign", "Invisaling", "inivisalign" significando a mesma coisa) — foi canonizado em uma lista fechada durante a migração (ver seção "Decisões editoriais" no relatório final desta etapa).

---

> Este arquivo é específico da migração do CRM (05-prompts-kickoff-sistemas.md / Etapa 5 do `CLAUDE.md`) e não sobrescreve o modelo em branco de `Contexto/02-documento-briefing.md`.
