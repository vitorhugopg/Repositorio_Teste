# CRM — Mori Ortodontia

CRM comercial da **Clínica que Converte**, adaptado para a **Mori Ortodontia** (Belo Horizonte, MG), com os dados reais da clínica migrados da planilha própria que ela já usava.

## Como abrir

Abra `index.html` diretamente no navegador. É um protótipo local, single-file (HTML + CSS + JS), sem backend: todo o estado fica salvo no `localStorage` do navegador (chave `cqc_crm_state_v1`). Não requer instalação nem servidor.

## Estrutura do projeto

- `index.html` — o CRM em si (Assistente de Vendas, Pacientes, Kanban, Indicações, Dashboard, Agenda, Configurações).
- `CLAUDE.md` — instruções-base do método Clínica que Converte, para continuidade de projeto no Claude Code.
- `briefing-preenchido.md` — briefing desta clínica específica.
- `Contexto/` — documentos de fundação do método (história, briefing modelo, especificação técnica do CRM-base, marketing/branding) e a planilha original da clínica (`CRM_Mori_Ortodontia.xlsx`), fonte dos 52 pacientes e 37 indicações reais migrados.

## Status

Funcional para uso interno/demonstração. **Ainda não está pronto para uso diário com pacientes reais** — falta banco de dados online e login real (ver checklist dentro do próprio CRM, em Configurações, e `Contexto/03-crm-base-clinica-que-converte.md`).

## Nota

A landing page institucional da Clínica que Converte (site público da marca) foi migrada para um repositório próprio, separado deste: [`clinica-que-converte-site`](https://github.com/vitorhugopg/clinica-que-converte-site). Este repositório permanece exclusivo do CRM da Mori Ortodontia e não deve conter nenhum arquivo do site público.
